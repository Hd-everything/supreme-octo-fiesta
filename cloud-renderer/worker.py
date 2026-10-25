#!/usr/bin/env python3
"""Vyntra cloud render worker. Runs outside Supabase Edge Functions."""
from __future__ import annotations

import json, os, shutil, subprocess, tempfile, time, urllib.error, urllib.parse, urllib.request, uuid
from pathlib import Path
import re

SUPABASE_URL = os.environ["SUPABASE_URL"].rstrip("/")
SERVICE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
WORKER_ID = os.getenv("VYNTRA_WORKER_ID", str(uuid.uuid4()))
BUCKET = os.getenv("VYNTRA_STORAGE_BUCKET", "vyntra-media")
POLL_SECONDS = max(2, int(os.getenv("VYNTRA_POLL_SECONDS", "5")))
MAX_DURATION = min(180, max(1, int(os.getenv("VYNTRA_MAX_DURATION_SECONDS", "180"))))
MAX_INPUT_BYTES = min(50 * 1024 * 1024, max(1, int(os.getenv("VYNTRA_MAX_INPUT_BYTES", str(50 * 1024 * 1024)))))
SOURCE_PART_BYTES = 48_000_000
MAX_SOURCE_FILE_BYTES = 200 * 1024 * 1024
MAX_PROJECT_SOURCE_BYTES = 200 * 1024 * 1024
OUTPUT_PART_BYTES = 48_000_000
MAX_OUTPUT_BYTES = max(OUTPUT_PART_BYTES, int(os.getenv("VYNTRA_MAX_OUTPUT_BYTES", "200000000")))
ONESHOT = os.getenv("VYNTRA_ONESHOT", "false").lower() == "true"
ENABLE_8K = os.getenv("VYNTRA_ENABLE_8K", "false").lower() == "true"
MAX_JOBS = max(1, int(os.getenv("VYNTRA_MAX_CONCURRENT_JOBS", "1")))

def safe_ffmpeg_diagnostic(stderr: str, work_dir: Path | None = None) -> str:
    """Return a bounded FFmpeg diagnostic with secrets, URLs, and temp paths removed."""
    text = stderr.replace("\x00", "")
    if work_dir:
        for work_path in {str(work_dir), str(work_dir).replace("\\", "/")}:
            text = text.replace(work_path, "[render-workdir]")
    text = re.sub(r"https?://\S+", "[url-redacted]", text, flags=re.IGNORECASE)
    text = re.sub(r"(?i)\bbearer\s+[^\s,;]+", "Bearer [redacted]", text)
    text = re.sub(
        r"(?i)\b(authorization|bearer|apikey|service[_ -]?role|access[_ -]?token|refresh[_ -]?token|password|secret)\b\s*[:=]?\s*[^\s,;]+",
        r"\1=[redacted]", text,
    )
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", text)
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    # FFmpeg often ends with the unhelpful "Conversion failed!"; keep the
    # preceding filter/stream errors and omit that generic footer.
    while lines and lines[-1].lower() == "conversion failed!":
        lines.pop()
    return " | ".join(line[-600:] for line in lines[-8:])[-3600:]


def ffmpeg_error_code(diagnostic: str) -> str:
    """Fit a useful, already-sanitized summary into the existing 100-char DB field."""
    if not diagnostic:
        return "ffmpeg_failed"
    summary = diagnostic.split(" | ")[-1]
    summary = re.sub(r"\s+", " ", summary).strip()
    return ("ffmpeg_failed:" + summary)[:100]

def api(path: str, method="GET", payload=None, headers=None, raw=False):
    data = payload if raw else (json.dumps(payload).encode() if payload is not None else None)
    h = {"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}"}
    if not raw: h["Content-Type"] = "application/json"
    if headers: h.update(headers)
    req = urllib.request.Request(SUPABASE_URL + path, data=data, headers=h, method=method)
    with urllib.request.urlopen(req, timeout=90) as response:
        body = response.read()
        return json.loads(body) if body and not raw else body

def update_job(job_id, **values):
    # Refresh the lease on progress updates so a live FFmpeg render is not marked dead.
    values.setdefault("updated_at", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    api("/rest/v1/vyntra_render_jobs?id=eq." + urllib.parse.quote(job_id),
        "PATCH", values, {"Prefer": "return=minimal"})

def claim_render_job(target_job_id=None):
    if target_job_id:
        try:
            target_job_id = str(uuid.UUID(target_job_id))
        except (ValueError, TypeError, AttributeError):
            raise ValueError("invalid_dispatched_job_id")
        current = api("/rest/v1/vyntra_render_jobs?id=eq." + urllib.parse.quote(target_job_id) + "&select=id,status,attempts,started_at")
        if not current or current[0].get("status") != "queued":
            return None
        row = current[0]
        if int(row.get("attempts", 0)) >= 3:
            return None
        started_at = row.get("started_at") or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        claimed = api(
            "/rest/v1/vyntra_render_jobs?id=eq." + urllib.parse.quote(target_job_id) + "&status=eq.queued",
            "PATCH",
            {"status": "processing", "progress": 0, "worker_id": WORKER_ID,
             "started_at": started_at, "attempts": int(row.get("attempts", 0)) + 1,
             "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
            {"Prefer": "return=representation"},
        )
        return claimed[0] if claimed else None
    claimed = api("/rest/v1/rpc/vyntra_claim_render_job", "POST", {"p_worker_id": WORKER_ID})
    return claimed[0] if isinstance(claimed, list) and claimed else None

def storage_download(object_path: str, destination: Path):
    if not object_path or object_path.startswith("/") or ".." in Path(object_path).parts:
        raise ValueError("invalid_media_path")
    url = SUPABASE_URL + "/storage/v1/object/" + BUCKET + "/" + urllib.parse.quote(object_path, safe="/")
    req = urllib.request.Request(url, headers={"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}"})
    total = 0
    with urllib.request.urlopen(req, timeout=120) as response, destination.open("wb") as out:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk: break
            total += len(chunk)
            if total > MAX_INPUT_BYTES: raise ValueError("input_too_large")
            out.write(chunk)

def download_source_asset(object_path: str, parts, owner_id: str, destination: Path):
    """Download a normal source object or reconstruct a byte-split upload."""
    if not isinstance(object_path, str) or not object_path.startswith(owner_id + "/"):
        raise ValueError("media_not_owned")
    if parts is None:
        storage_download(object_path, destination)
        if destination.stat().st_size > MAX_SOURCE_FILE_BYTES:
            raise ValueError("source_file_too_large")
        return
    if not isinstance(parts, list) or not 2 <= len(parts) <= 6:
        raise ValueError("invalid_source_parts")
    if any(not isinstance(part, dict) for part in parts):
        raise ValueError("invalid_source_parts")
    if parts[0].get("path") != object_path:
        raise ValueError("invalid_source_parts")
    total = 0
    destination.unlink(missing_ok=True)
    try:
        for index, part in enumerate(parts):
            if not isinstance(part, dict):
                raise ValueError("invalid_source_parts")
            part_path = part.get("path")
            expected_bytes = part.get("bytes")
            if (not isinstance(part_path, str) or not part_path.startswith(owner_id + "/") or
                    not isinstance(expected_bytes, int) or expected_bytes < 1 or expected_bytes > SOURCE_PART_BYTES):
                raise ValueError("invalid_source_parts")
            total += expected_bytes
            if total > MAX_SOURCE_FILE_BYTES:
                raise ValueError("source_file_too_large")
            temp_part = destination.with_name(destination.name + f".part{index:03d}")
            storage_download(part_path, temp_part)
            actual_bytes = temp_part.stat().st_size
            if actual_bytes != expected_bytes:
                raise ValueError("source_part_size_mismatch")
            with temp_part.open("rb") as incoming, destination.open("ab") as assembled:
                shutil.copyfileobj(incoming, assembled, 1024 * 1024)
            temp_part.unlink(missing_ok=True)
        if destination.stat().st_size != total:
            raise ValueError("source_reassembly_size_mismatch")
    except Exception:
        destination.unlink(missing_ok=True)
        for index in range(len(parts)):
            destination.with_name(destination.name + f".part{index:03d}").unlink(missing_ok=True)
        raise

def validate_source_manifest(plan, owner_id: str):
    manifest = plan.get("uploadedSourceParts")
    if manifest is None:
        return
    if not isinstance(manifest, list) or len(manifest) > 128:
        raise ValueError("invalid_source_parts")
    sizes = {}
    for part in manifest:
        if not isinstance(part, dict):
            raise ValueError("invalid_source_parts")
        path, size = part.get("path"), part.get("bytes")
        if (not isinstance(path, str) or not path.startswith(owner_id + "/") or
                not isinstance(size, int) or size < 1 or size > SOURCE_PART_BYTES):
            raise ValueError("invalid_source_parts")
        if path in sizes and sizes[path] != size:
            raise ValueError("source_part_size_mismatch")
        sizes[path] = size
    if sum(sizes.values()) > MAX_PROJECT_SOURCE_BYTES:
        raise ValueError("project_source_size_limit")

def output_storage_config(job):
    """Return the storage endpoint for this job's rendered output."""
    snapshot = job.get("project_snapshot") if isinstance(job, dict) else None
    if isinstance(snapshot, dict) and snapshot.get("vyntraOutputStore") == "secondary":
        url = os.getenv("VYNTRA_OUTPUT_SUPABASE_URL", "").rstrip("/")
        key = os.getenv("VYNTRA_OUTPUT_SUPABASE_SERVICE_ROLE_KEY", "")
        if not url or not key:
            raise ValueError("output_storage_not_configured")
        return url, key, os.getenv("VYNTRA_OUTPUT_BUCKET", "vyntra-exports")
    return SUPABASE_URL, SERVICE_KEY, BUCKET


def storage_upload(source: Path, object_path: str, job=None):
    import requests
    # Stream the output from disk; do not load large rendered files into memory.
    storage_url, storage_key, storage_bucket = output_storage_config(job or {})
    url = storage_url + "/storage/v1/object/" + storage_bucket + "/" + urllib.parse.quote(object_path, safe="/")
    with source.open("rb") as stream:
        response = requests.post(url, data=stream, timeout=(30, 900), headers={
            "apikey": storage_key, "Authorization": f"Bearer {storage_key}",
            "Content-Type": "video/mp4", "x-upsert": "true",
        })
    if not response.ok:
        diagnostic = safe_ffmpeg_diagnostic(response.text)
        detail = diagnostic or response.reason or "no response details"
        error = requests.HTTPError(
            f"storage_upload_failed:http_{response.status_code}:{detail}", response=response
        )
        error.vyntra_storage_upload = True
        raise error


def is_storage_capacity_error(exc):
    """Only quota/object-cap failures should move an output to primary storage."""
    if not getattr(exc, "vyntra_storage_upload", False):
        return False
    response = getattr(exc, "response", None)
    status = getattr(response, "status_code", None)
    # Supabase reports object limits as 413 and project quota restrictions as 402.
    # 507 is the standard insufficient-storage response for compatible gateways.
    if status in (402, 413, 507):
        return True
    body = str(getattr(response, "text", "")).lower()
    return any(code in body for code in (
        "exceed_storage_size_quota", "exceeded_storage_quota",
        "storage_quota_exceeded", "insufficient_storage", "storage is full",
    ))


def storage_remove(object_paths: list[str], job=None):
    if not object_paths:
        return
    storage_url, storage_key, storage_bucket = output_storage_config(job or {})
    payload = json.dumps({"prefixes": object_paths}).encode()
    request = urllib.request.Request(
        storage_url + "/storage/v1/object/" + storage_bucket,
        data=payload,
        headers={"apikey": storage_key, "Authorization": f"Bearer {storage_key}", "Content-Type": "application/json"},
        method="DELETE",
    )
    with urllib.request.urlopen(request, timeout=90) as response:
        response.read()


def job_output_paths(job) -> list[str]:
    metadata = job.get("output_metadata")
    chunks = metadata.get("chunks", []) if isinstance(metadata, dict) else []
    paths = [chunk.get("path") for chunk in chunks if isinstance(chunk, dict)] if isinstance(chunks, list) else []
    if job.get("output_path"):
        paths.append(job["output_path"])
    return list(dict.fromkeys(path for path in paths if isinstance(path, str) and path))


def set_output_storage_target(job, target: str):
    """Persist the actual output route so signing and cleanup use the same project."""
    snapshot = job.get("project_snapshot") if isinstance(job, dict) else None
    snapshot = dict(snapshot) if isinstance(snapshot, dict) else {}
    snapshot["vyntraOutputStore"] = target
    job["project_snapshot"] = snapshot
    update_job(job["id"], project_snapshot=snapshot, output_path=None, output_metadata=None)


def _upload_output_parts_on_current_store(source: Path, job, metadata: dict, work: Path) -> tuple[str, dict]:
    total_bytes = source.stat().st_size
    if total_bytes <= 0:
        raise ValueError("empty_render_output")
    if total_bytes > MAX_OUTPUT_BYTES:
        raise ValueError("output_exceeds_free_storage_limit")
    if total_bytes <= OUTPUT_PART_BYTES:
        object_path = f'{job["owner_id"]}/exports/{job["id"]}.mp4'
        try:
            storage_upload(source, object_path, job)
            output_metadata = {**metadata, "bytes": total_bytes}
            update_job(job["id"], status="finalizing", progress=99,
                       output_path=object_path, output_metadata=output_metadata)
            current = api("/rest/v1/vyntra_render_jobs?id=eq." + urllib.parse.quote(job["id"]) + "&select=status")
            if current and current[0]["status"] == "cancel_requested":
                raise InterruptedError("cancelled")
            return object_path, output_metadata
        except Exception:
            try:
                storage_remove([object_path], job)
            except Exception as cleanup_error:
                print("partial output cleanup failed", type(cleanup_error).__name__, flush=True)
            try:
                update_job(job["id"], output_path=None, output_metadata=None)
            except Exception as update_error:
                print("partial output record cleanup failed", type(update_error).__name__, flush=True)
            raise
    part_count = (total_bytes + OUTPUT_PART_BYTES - 1) // OUTPUT_PART_BYTES
    uploaded = []
    attempted_paths = []
    try:
        with source.open("rb") as rendered:
            for index in range(part_count):
                current = api("/rest/v1/vyntra_render_jobs?id=eq." + urllib.parse.quote(job["id"]) + "&select=status")
                if current and current[0]["status"] == "cancel_requested":
                    raise InterruptedError("cancelled")
                data = rendered.read(OUTPUT_PART_BYTES)
                if not data:
                    raise RuntimeError("render_output_truncated")
                part_path = work / f"output_part_{index:03d}.mp4"
                part_path.write_bytes(data)
                object_path = f'{job["owner_id"]}/exports/{job["id"]}.part{index:03d}'
                attempted_paths.append(object_path)
                storage_upload(part_path, object_path, job)
                part_path.unlink(missing_ok=True)
                uploaded.append({"path": object_path, "bytes": len(data)})
                output_metadata = {**metadata, "bytes": total_bytes, "chunked": True, "chunks": uploaded.copy()}
                progress = min(99, 96 + int(3 * len(uploaded) / part_count))
                update_job(job["id"], status="finalizing", progress=progress,
                           output_path=uploaded[0]["path"], output_metadata=output_metadata)
        current = api("/rest/v1/vyntra_render_jobs?id=eq." + urllib.parse.quote(job["id"]) + "&select=status")
        if current and current[0]["status"] == "cancel_requested":
            raise InterruptedError("cancelled")
        return uploaded[0]["path"], {**metadata, "bytes": total_bytes, "chunked": True, "chunks": uploaded}
    except Exception:
        try:
            storage_remove(attempted_paths, job)
        except Exception as cleanup_error:
            print("partial output cleanup failed", type(cleanup_error).__name__, flush=True)
        try:
            update_job(job["id"], output_path=None, output_metadata=None)
        except Exception as update_error:
            print("partial output record cleanup failed", type(update_error).__name__, flush=True)
        raise


def upload_output_parts(source: Path, job, metadata: dict, work: Path) -> tuple[str, dict]:
    snapshot = job.get("project_snapshot") if isinstance(job, dict) else None
    storage_target = "secondary" if isinstance(snapshot, dict) and snapshot.get("vyntraOutputStore") == "secondary" else "primary"
    total_bytes = source.stat().st_size
    print(f"uploading {total_bytes} output bytes to {storage_target} storage", flush=True)
    try:
        return _upload_output_parts_on_current_store(source, job, metadata, work)
    except Exception as exc:
        if storage_target != "secondary" or not is_storage_capacity_error(exc):
            raise
        status = getattr(getattr(exc, "response", None), "status_code", "unknown")
        print(f"secondary output storage rejected an object for capacity/size (HTTP {status}); falling back to primary", flush=True)
        set_output_storage_target(job, "primary")
        print("retrying the complete output in primary storage", flush=True)
        return _upload_output_parts_on_current_store(source, job, metadata, work)

def probe(path: Path):
    raw = subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)], timeout=45)
    return json.loads(raw)

def safe_number(value, low, high, name):
    try: number = float(value)
    except (TypeError, ValueError): raise ValueError("invalid_" + name)
    if number < low or number > high: raise ValueError("invalid_" + name)
    return number

def clip_trim_range(clip, duration_seconds):
    # The editor saves duration from the platform player, while FFprobe reads
    # the decoded container duration. Treat FFprobe as authoritative and clamp
    # a saved end to that duration instead of rejecting a valid trim because
    # those metadata sources differ.
    actual_duration_ms = duration_seconds * 1000
    declared_duration_ms = safe_number(
        clip.get("durationMs", int(actual_duration_ms)), 1, MAX_DURATION * 1000, "clip_duration"
    )
    start_ms = safe_number(clip.get("startMs", 0), 0, actual_duration_ms, "trim_start")
    requested_end_ms = safe_number(clip.get("endMs", int(actual_duration_ms)), 1, declared_duration_ms, "trim_end")
    end_ms = min(requested_end_ms, actual_duration_ms)
    start, end = start_ms / 1000, end_ms / 1000
    if end <= start:
        raise ValueError("invalid_trim_range")
    return start, end

def output_dimensions(source_width: int, source_height: int, rotation: int, aspect_ratio: str, resolution: str):
    edge = {"480p": 480, "540p": 540, "720p": 720, "1080p": 1080, "1440p": 1440, "1620p": 1620, "2160p": 2160, "2880p": 2880, "3456p": 3456, "4320p": 4320}.get(resolution)
    if edge is None: raise ValueError("unsupported_resolution")
    ratios = {"9:16": 9 / 16, "16:9": 16 / 9, "1:1": 1.0, "4:5": 4 / 5, "3:4": 3 / 4, "4:3": 4 / 3, "21:9": 21 / 9}
    if aspect_ratio == "Original":
        if rotation % 180 == 90: source_width, source_height = source_height, source_width
        target_ratio = source_width / max(1, source_height)
    elif aspect_ratio in ratios:
        target_ratio = ratios[aspect_ratio]
    else:
        raise ValueError("invalid_aspect_ratio")
    if target_ratio >= 1:
        width, height = round(edge * target_ratio / 2) * 2, edge
    else:
        width, height = edge, round(edge / target_ratio / 2) * 2
    if width * height > 7680 * 4320: raise ValueError("output_dimensions_too_large")
    return width, height


def visual_effect_filters(effect: str, width: int, height: int) -> list[str]:
    """Map editor effect IDs to FFmpeg filters; reject unknown IDs explicitly."""
    filters = {
        "none": [],
        "flash": ["eq=brightness=0.10:enable='lt(mod(t,0.4),0.08)'"],
        "shake": [f"crop=iw-24:ih-24:x=12+8*sin(2*PI*12*t):y=12+8*cos(2*PI*10*t),scale={width}:{height}"],
        "blur": ["boxblur=4:1"],
        "glitch": ["rgbashift=rh=8:bh=-8:enable='lt(mod(t,0.5),0.08)'"],
        "phonk": ["eq=contrast=1.25:saturation=1.35"],
        "grayscale": ["hue=s=0"],
        "negative": ["negate"],
        "soft": ["gblur=sigma=1.5"],
        "cinematic": ["eq=brightness=0.015:contrast=1.13:saturation=1.08"],
        "moody": ["eq=brightness=-0.06:contrast=1.20:saturation=0.97"],
        "vivid": ["eq=brightness=0.025:contrast=1.20:saturation=1.20"],
        "dramatic": ["eq=contrast=1.30:saturation=1.10"],
        "vintage": ["colorbalance=rs=0.08:gs=0.02:bs=-0.05", "eq=saturation=0.85:contrast=0.92"],
        "fade": ["eq=contrast=0.84:saturation=0.94:brightness=0.025"],
        "night": ["eq=brightness=-0.10:contrast=1.08:saturation=0.90", "colorbalance=bs=0.08"],
        "sunset": ["colorbalance=rs=0.08:gs=0.02:bs=-0.08", "eq=saturation=1.13"],
        "noir": ["hue=s=0", "eq=contrast=1.25:brightness=-0.02"],
        "dreamy": ["gblur=sigma=2", "eq=brightness=0.03:saturation=1.10"],
    }
    if effect not in filters:
        raise ValueError("unsupported_effect")
    return filters[effect]


def render(job, work: Path):
    plan = job["project_snapshot"]
    validate_source_manifest(plan, job["owner_id"])
    clips = plan.get("clips")
    if not isinstance(clips, list) or not 1 <= len(clips) <= 24:
        raise ValueError("unsupported_project_clip_count")
    resolution = job["resolution"]
    edge = {"480p": 480, "540p": 540, "720p": 720, "1080p": 1080, "1440p": 1440, "1620p": 1620, "2160p": 2160, "2880p": 2880, "3456p": 3456, "4320p": 4320}.get(resolution)
    if edge is None: raise ValueError("unsupported_resolution")
    if resolution in ("2880p", "3456p", "4320p"):
        try:
            total_ram = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
        except (ValueError, OSError, AttributeError):
            total_ram = 0
        free_disk = shutil.disk_usage(tempfile.gettempdir()).free
        if resolution == "2880p" and (total_ram < 4 * 1024**3 or free_disk < 6 * 1024**3):
            raise ValueError("5k_worker_resources_insufficient")
        if resolution == "3456p" and (total_ram < 6 * 1024**3 or free_disk < 8 * 1024**3):
            raise ValueError("6k_worker_resources_insufficient")
        if resolution == "4320p":
            if not ENABLE_8K: raise ValueError("8k_not_enabled_on_worker")
            if total_ram < 8 * 1024**3 or free_disk < 10 * 1024**3:
                raise ValueError("8k_worker_resources_insufficient")
    codec = job.get("codec", "h264")
    encoders = subprocess.check_output(["ffmpeg", "-hide_banner", "-encoders"], stderr=subprocess.STDOUT, text=True)
    if codec == "h265" and "libx265" not in encoders: raise ValueError("encoder_unavailable:h265")
    if codec not in ("h264", "h265"): raise ValueError("unsupported_codec")

    local = []
    clip_lengths = []
    input_args = ["ffmpeg", "-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-loglevel", "error"]
    probe_info = []
    for i, clip in enumerate(clips):
        key = clip.get("path", "")
        if not key.startswith(job["owner_id"] + "/"):
            raise ValueError("media_not_owned")
        path = work / f"clip_{i}.media"
        download_source_asset(key, clip.get("sourceParts"), job["owner_id"], path)
        meta = probe(path)
        v = next((s for s in meta.get("streams", []) if s.get("codec_type") == "video"), None)
        if not v: raise ValueError("source_has_no_video")
        media_type = clip.get("mediaType", "video")
        if media_type not in ("video", "image"): raise ValueError("unsupported_media_type")
        duration = float(meta.get("format", {}).get("duration", 0))
        if media_type == "image":
            if Path(key).suffix.lower() not in (".png", ".jpg", ".jpeg", ".webp"): raise ValueError("unsupported_image_format")
            duration = safe_number(clip.get("durationMs", 0), 1, MAX_DURATION * 1000, "image_duration") / 1000
        if duration <= 0 or duration > MAX_DURATION:
            raise ValueError("source_duration_limit")
        start, end = clip_trim_range(clip, duration)
        if end <= start or end - start > MAX_DURATION: raise ValueError("invalid_trim_range")
        speed = safe_number(clip.get("speed", 1.0), .25, 4.0, "speed")
        reverse = clip.get("reverse", False)
        if not isinstance(reverse, bool): raise ValueError("invalid_reverse")
        if media_type == "image":
            input_args += ["-loop", "1", "-t", str(end-start), "-i", str(path)]
        else:
            input_args += ["-ss", str(start), "-t", str(end-start), "-i", str(path)]
        freeze_ms = safe_number(clip.get("freezeFrameMs", 0), 0, 10000, "freeze_frame")
        local.append(path); clip_lengths.append((end-start)/speed + freeze_ms/1000); probe_info.append((v, media_type == "video" and any(s.get("codec_type") == "audio" for s in meta.get("streams", []))))
    if sum(clip_lengths) > MAX_DURATION: raise ValueError("project_duration_limit")
    music_path = None
    music = plan.get("musicPath")
    if music:
        if not music.startswith(job["owner_id"] + "/"): raise ValueError("media_not_owned")
        music_path = work / "music.media"
        download_source_asset(music, plan.get("musicSourceParts"), job["owner_id"], music_path)
        input_args += ["-i", str(music_path)]

    first = probe_info[0][0]
    width, height = output_dimensions(
        int(first.get("width", 16)), int(first.get("height", 9)),
        int(clips[0].get("rotation", 0)), plan.get("aspectRatio", "Original"), resolution,
    )

    filters, video_labels, audio_labels = [], [], []
    for i, (clip, (v, has_audio)) in enumerate(zip(clips, probe_info)):
        rot = int(clip.get("rotation", 0)) % 360
        if rot not in (0, 90, 180, 270): raise ValueError("unsupported_rotation")
        vf = []
        if rot == 90: vf.append("transpose=clock")
        elif rot == 180: vf.extend(["hflip", "vflip"])
        elif rot == 270: vf.append("transpose=cclock")
        speed = safe_number(clip.get("speed", 1.0), .25, 4.0, "speed")
        reverse = clip.get("reverse", False)
        volume = safe_number(clip.get("volume", 1), 0, 1, "volume")
        effect = clip.get("effect", "none")
        effect_vf = visual_effect_filters(effect, width, height)
        if reverse: vf.append("reverse")
        frame_rate = int(safe_number(plan.get("exportFrameRate", 30), 24, 60, "frame_rate"))
        if frame_rate not in (24, 25, 30, 50, 60): raise ValueError("unsupported_frame_rate")
        vf += [f"scale={width}:{height}:force_original_aspect_ratio=increase:flags=lanczos", f"crop={width}:{height}", "setsar=1", f"fps={frame_rate}"]
        vf += effect_vf
        if speed != 1.0: vf.append(f"setpts=(PTS-STARTPTS)/{speed}")
        freeze_ms = safe_number(clip.get("freezeFrameMs", 0), 0, 10000, "freeze_frame")
        if freeze_ms: vf.append(f"tpad=stop_mode=clone:stop_duration={freeze_ms/1000:.6f}")
        brightness = safe_number(clip.get("brightness", 0), -.25, .25, "brightness")
        contrast = 1 + safe_number(clip.get("contrast", 0), -.3, .3, "contrast")
        saturation = 1 + safe_number(clip.get("saturation", 0), -20, 30, "saturation") / 100
        sharpness = safe_number(clip.get("sharpness", 0), 0, .5, "sharpness")
        keyframes = clip.get("keyframes", [])
        if not isinstance(keyframes, list) or len(keyframes) > 100:
            raise ValueError("invalid_keyframes")
        normalized = []
        for keyframe in keyframes:
            if not isinstance(keyframe, dict):
                raise ValueError("invalid_keyframe")
            time_ms = safe_number(keyframe.get("timeMs", 0), 0, (end-start)/speed, "keyframe_time")
            kb = safe_number(keyframe.get("brightness", brightness), -.25, .25, "keyframe_brightness")
            kc = 1 + safe_number(keyframe.get("contrast", contrast-1), -.3, .3, "keyframe_contrast")
            ks = 1 + safe_number(keyframe.get("saturation", (saturation-1)*100), -20, 30, "keyframe_saturation") / 100
            kv = safe_number(keyframe.get("volume", volume), 0, 1, "keyframe_volume")
            normalized.append((time_ms/1000, kb, kc, ks, kv))
        normalized.sort(key=lambda item: item[0])
        def keyframe_expr(column, fallback):
            value = f"{normalized[-1][column] if normalized else fallback:.6f}"
            for left, right in reversed(list(zip(normalized, normalized[1:]))):
                t0, t1 = left[0], right[0]
                v0, v1 = left[column], right[column]
                if t1 > t0:
                    value = f"if(lt(t\\,{t1:.6f})\\,{v0:.6f}+({v1-v0:.6f})*(t-{t0:.6f})/{t1-t0:.6f}\\,{value})"
            if normalized:
                value = f"if(lt(t\\,{normalized[0][0]:.6f})\\,{normalized[0][column]:.6f}\\,{value})"
            return value
        if normalized:
            vf.append(f"eq=eval=frame:brightness='{keyframe_expr(1, brightness)}':contrast='{keyframe_expr(2, contrast)}':saturation='{keyframe_expr(3, saturation)}'")
        elif brightness or contrast != 1 or saturation != 1:
            vf.append(f"eq=brightness={brightness}:contrast={contrast}:saturation={saturation}")
        if sharpness > 0:
            vf.append(f"unsharp=5:5:{sharpness:.3f}:5:5:0")
        # Some effects (notably shake's crop/scale chain) can adjust SAR after
        # the initial canvas normalization. Reassert square pixels immediately
        # before concat/xfade so mixed clips have matching stream parameters.
        filters.append(f"[{i}:v]{','.join(vf)},setsar=1,format=yuv420p,setpts=PTS-STARTPTS[v{i}]")
        video_labels.append(f"[v{i}]")
        if has_audio:
            af = "areverse," if reverse else ""
            if speed != 1.0:
                remaining = speed
                tempo = []
                while remaining > 2.0:
                    tempo.append("atempo=2.0"); remaining /= 2.0
                while remaining < 0.5:
                    tempo.append("atempo=0.5"); remaining /= 0.5
                tempo.append(f"atempo={remaining:.6f}")
                af += ",".join(tempo) + ","
            audio_fx = []
            if clip.get("audioDenoise") is True: audio_fx.append("afftdn=nf=-25")
            highpass = int(safe_number(clip.get("audioHighPassHz", 0), 0, 300, "audio_highpass"))
            if highpass: audio_fx.append(f"highpass=f={highpass}")
            if clip.get("audioCompressor") is True: audio_fx.append("acompressor=threshold=0.125:ratio=3:attack=20:release=250")
            if clip.get("audioNormalize") is True: audio_fx.append("loudnorm=I=-16:TP=-1.5:LRA=11")
            if normalized:
                audio_fx.append(f"volume='{keyframe_expr(4, volume)}':eval=frame")
            else:
                audio_fx.append(f"volume={volume}")
            filters.append(f"[{i}:a]{af}asetpts=PTS-STARTPTS,{','.join(audio_fx)}[abase{i}]")
            fade_in = safe_number(clip.get("audioFadeInMs", 0), 0, 10000, "audio_fade_in") / 1000
            fade_out = safe_number(clip.get("audioFadeOutMs", 0), 0, 10000, "audio_fade_out") / 1000
            audio_filters = []
            if fade_in: audio_filters.append(f"afade=t=in:st=0:d={min(fade_in, clip_lengths[i]):.6f}")
            if fade_out: audio_filters.append(f"afade=t=out:st={max(0, clip_lengths[i]-fade_out):.6f}:d={min(fade_out, clip_lengths[i]):.6f}")
            filters.append(f"[abase{i}]{','.join(audio_filters)}[a{i}]" if audio_filters else f"[abase{i}]anull[a{i}]")
        else:
            filters.append(f"anullsrc=r=48000:cl=stereo,atrim=duration={clip_lengths[i]:.6f},asetpts=PTS-STARTPTS[a{i}]")
        audio_labels.append(f"[a{i}]")
    # Real transitions are rendered by FFmpeg, not simulated only in the editor preview.
    transition_map = {name: name for name in (
        "fade", "fadeblack", "fadewhite", "dissolve", "pixelize", "radial", "distance", "rectcrop",
        "wipeleft", "wiperight", "wipeup", "wipedown", "slideleft", "slideright", "slideup", "slidedown",
        "smoothleft", "smoothright", "smoothup", "smoothdown", "circleopen", "circleclose",
        "vertopen", "vertclose", "horzopen", "horzclose", "diagtl", "diagtr", "diagbl", "diagbr",
        "hlslice", "hrslice", "vuslice", "vdslice", "coverleft", "coverright", "coverup", "coverdown",
        "revealleft", "revealright", "revealup", "revealdown",
    )}
    active_transitions = []
    for i in range(1, len(clips)):
        kind = clips[i].get("transition", "cut")
        if kind != "cut" and kind not in transition_map:
            raise ValueError("unsupported_transition")
        duration = safe_number(clips[i].get("transitionMs", 0), 0, 2000, "transition_duration") / 1000
        if kind != "cut" and duration > 0:
            duration = min(duration, clip_lengths[i-1] * .45, clip_lengths[i] * .45)
        active_transitions.append((transition_map.get(kind, "fade"), duration if kind != "cut" else 0))
    if any(duration > 0 for _, duration in active_transitions):
        current = video_labels[0]
        elapsed = clip_lengths[0]
        for i, (kind, duration) in enumerate(active_transitions, start=1):
            next_label = f"[vjoin{i}]"
            if duration <= 0:
                filters.append(f"{current}[v{i}]concat=n=2:v=1:a=0{next_label}")
                elapsed += clip_lengths[i]
            else:
                filters.append(f"{current}[v{i}]xfade=transition={kind}:duration={duration:.6f}:offset={max(0, elapsed-duration):.6f}{next_label}")
                elapsed += clip_lengths[i] - duration
            current = next_label
        video_label = current
    else:
        filters.append("".join(video_labels) + f"concat=n={len(clips)}:v=1:a=0[vcat]")
        video_label = "[vcat]"
    if any(duration > 0 for _, duration in active_transitions):
        current_audio = audio_labels[0]
        for i, (_, duration) in enumerate(active_transitions, start=1):
            next_audio = f"[ajoin{i}]"
            if duration > 0:
                filters.append(f"{current_audio}{audio_labels[i]}acrossfade=d={duration:.6f}:c1=tri:c2=tri{next_audio}")
            else:
                filters.append(f"{current_audio}{audio_labels[i]}concat=n=2:v=0:a=1{next_audio}")
            current_audio = next_audio
        audio_label = current_audio
    else:
        filters.append("".join(audio_labels) + f"concat=n={len(clips)}:v=0:a=1[acat]")
        audio_label = "[acat]"
    if music_path:
        music_index = len(clips)
        music_volume = safe_number(plan.get("musicVolume", .35), 0, 1, "music_volume")
        offset = int(safe_number(plan.get("musicOffsetMs", 0), 0, MAX_DURATION * 1000, "music_offset"))
        filters.append(f"[{music_index}:a]asetpts=PTS-STARTPTS,volume={music_volume},adelay={offset}|{offset}[music]")
        filters.append(f"{audio_label}[music]amix=inputs=2:duration=first:dropout_transition=2[aout]")
        audio_label = "[aout]"

    # Add user-scoped still-image overlays as looped inputs. The base video controls output duration.
    image_inputs = []
    for image_index, overlay in enumerate(plan.get("imageOverlays", [])):
        key = overlay.get("path", "")
        if not key.startswith(job["owner_id"] + "/"): raise ValueError("media_not_owned")
        suffix = Path(key).suffix.lower()
        if suffix not in (".png", ".jpg", ".jpeg", ".webp"): raise ValueError("unsupported_image_format")
        image_path = work / f"overlay_{image_index}{suffix}"
        download_source_asset(key, overlay.get("sourceParts"), job["owner_id"], image_path)
        input_args += ["-loop", "1", "-i", str(image_path)]
        image_inputs.append((len(clips) + (1 if music_path else 0) + image_index, overlay))

    # Timed text and image overlays are supported; unknown effects fail explicitly.
    for i, overlay in enumerate(plan.get("overlays", [])):
        text = str(overlay.get("text", ""))
        if not text or len(text) > 160: raise ValueError("invalid_text_overlay")
        # Use a text file rather than interpolating user text into a filter expression.
        text_file = work / f"text_{i}.txt"
        text_file.write_text(text, encoding="utf-8")
        start = safe_number(overlay.get("startMs", 0), 0, MAX_DURATION*1000, "overlay_start") / 1000
        end = safe_number(overlay.get("endMs", 1000), start*1000+1, MAX_DURATION*1000, "overlay_end") / 1000
        font_size = int(safe_number(overlay.get("fontSize", 34), 16, 160, "font_size"))
        x = safe_number(overlay.get("x", 0), -1, 1, "overlay_x")
        y = safe_number(overlay.get("y", .55), -1, 1, "overlay_y")
        argb = int(overlay.get("color", 0xFFFFFFFF))
        color = argb & 0xFFFFFF
        alpha = ((argb >> 24) & 0xFF) / 255 if argb > 0xFFFFFF else 1.0
        next_label = f"[vt{i}]"
        border_width = max(2, round(font_size * .035))
        filters.append(f"{video_label}drawtext=textfile='{text_file}':fontsize={font_size}:fontcolor=0x{color:06X}@{alpha:.3f}:borderw={border_width}:bordercolor=black@0.82:x=(w-text_w)/2+({x})*w/2:y=(h-text_h)/2+({y})*h/2:enable='between(t,{start},{end})'{next_label}")
        video_label = next_label

    for i, (image_index, overlay) in enumerate(image_inputs):
        start = safe_number(overlay.get("startMs", 0), 0, MAX_DURATION * 1000, "image_start") / 1000
        end = safe_number(overlay.get("endMs", 1000), start * 1000 + 1, MAX_DURATION * 1000, "image_end") / 1000
        scale = safe_number(overlay.get("scale", .28), .05, 1, "image_scale")
        x = safe_number(overlay.get("x", .65), -1, 1, "image_x")
        y = safe_number(overlay.get("y", .55), -1, 1, "image_y")
        next_label = f"[vi{i}]"
        filters.append(f"[{image_index}:v]scale={max(2, int(width * scale))}:-1,format=rgba[img{i}]")
        filters.append(f"{video_label}[img{i}]overlay=x=(W-w)/2+({x})*W/2:y=(H-h)/2+({y})*H/2:enable='between(t,{start},{end})':eof_action=pass{next_label}")
        video_label = next_label
    out = work / "render.mp4"
    bitrate = plan.get("exportBitrateKbps")
    encoder_args = ["-c:v", "libx264" if codec == "h264" else "libx265", "-preset", "veryfast"]
    if bitrate is None:
        encoder_args += ["-crf", str(int(safe_number(job.get("quality", 23), 18, 32, "quality")))]
    else:
        bitrate = int(safe_number(bitrate, 1000, 80000, "bitrate"))
        encoder_args += ["-b:v", f"{bitrate}k", "-maxrate", f"{int(bitrate * 1.25)}k", "-bufsize", f"{bitrate * 2}k"]
    cmd = input_args + ["-filter_complex", ";".join(filters), "-map", video_label, "-map", audio_label] + encoder_args + [
        "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", str(out)]
    update_job(job["id"], status="processing", progress=1, started_at=job.get("started_at") or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    stderr_path = work / "ffmpeg.stderr"
    with stderr_path.open("w+b") as stderr_file:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=stderr_file, text=True, bufsize=1)
        duration_ms = int(sum(clip_lengths) * 1000)
        while proc.poll() is None:
            line = proc.stdout.readline() if proc.stdout else ""
            if line.startswith("out_time_ms="):
                try:
                    done = int(line.split("=", 1)[1].strip()) // 1000
                    progress = min(94, max(1, int(done * 94 / max(1, duration_ms))))
                    update_job(job["id"], progress=progress)
                except ValueError: pass
            # Worker restarts and cancellation are observed through the job record.
            current = api("/rest/v1/vyntra_render_jobs?id=eq." + urllib.parse.quote(job["id"]) + "&select=status")
            if current and current[0]["status"] == "cancel_requested":
                proc.terminate(); proc.wait(timeout=10); raise InterruptedError("cancelled")
            time.sleep(.1)
        stderr_file.flush()
        stderr_file.seek(0)
        stderr = stderr_file.read().decode("utf-8", errors="replace")
    if proc.returncode != 0:
        diagnostic = safe_ffmpeg_diagnostic(stderr, work)
        print("FFmpeg failed with exit code", proc.returncode, flush=True)
        print("FFmpeg diagnostic:", diagnostic or "[no diagnostic output]", flush=True)
        raise RuntimeError("ffmpeg_failed:" + diagnostic)
    meta = probe(out)
    video = next((s for s in meta.get("streams", []) if s.get("codec_type") == "video"), None)
    if not video or int(video.get("width", 0)) != width or int(video.get("height", 0)) != height:
        raise RuntimeError("output_verification_failed:dimensions")
    # Full decode verification, not just successful container creation.
    subprocess.run(["ffmpeg", "-v", "error", "-i", str(out), "-f", "null", "-"], check=True, timeout=MAX_DURATION*2)
    output_duration = float(meta.get("format", {}).get("duration", 0))
    expected_duration = sum(clip_lengths) - sum(duration for _, duration in active_transitions)
    if output_duration <= 0 or abs(output_duration - expected_duration) > max(1.0, len(clips) * 0.15):
        raise RuntimeError("output_verification_failed:duration")
    return out, {"width": width, "height": height, "videoCodec": video.get("codec_name"), "durationSeconds": output_duration, "bytes": out.stat().st_size}

def main():
    print("Vyntra worker ready", WORKER_ID, flush=True)
    while True:
        try:
            target_job_id = os.getenv("VYNTRA_TARGET_JOB_ID") if ONESHOT else None
            job = claim_render_job(target_job_id)
            if not job:
                if ONESHOT:
                    print("No queued Vyntra render jobs", flush=True)
                    return
                time.sleep(POLL_SECONDS); continue
            stage = "prepare"
            try:
                storage_url, _, storage_bucket = output_storage_config(job)
                output_route = "secondary" if storage_url != SUPABASE_URL else "primary"
                print(f"job output route: {output_route} ({storage_bucket})", flush=True)
                update_job(job["id"], status="processing", progress=0, worker_id=WORKER_ID)
                stale_output_paths = job_output_paths(job)
                if stale_output_paths:
                    storage_remove(stale_output_paths, job)
                    update_job(job["id"], output_path=None, output_metadata=None)
                with tempfile.TemporaryDirectory(prefix="vyntra-render-") as directory:
                    stage = "render_and_verify"
                    output, metadata = render(job, Path(directory))
                    current = api("/rest/v1/vyntra_render_jobs?id=eq." + urllib.parse.quote(job["id"]) + "&select=status")
                    if current and current[0]["status"] == "cancel_requested":
                        raise InterruptedError("cancelled")
                    update_job(job["id"], status="finalizing", progress=96)
                    stage = "upload_output_parts"
                    output_path, metadata = upload_output_parts(output, job, metadata, Path(directory))
                    stage = "complete_job_record"
                    update_job(job["id"], status="completed", progress=100, output_path=output_path, output_metadata=metadata, completed_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), error_code=None)
            except InterruptedError:
                update_job(job["id"], status="cancelled", progress=0, completed_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
            except Exception as exc:
                message = str(exc)
                raw_code = message.split(":",1)[0][:80] or "render_failed"
                if raw_code == "ffmpeg_failed":
                    code = ffmpeg_error_code(message.partition(":")[2])
                elif raw_code == "storage_upload_failed":
                    code = ("storage_upload_failed:" + ":".join(message.split(":")[1:]))[:100]
                else:
                    code = raw_code
                safe_message = safe_ffmpeg_diagnostic(message)
                print("job failed", job.get("id"), "at", stage, type(exc).__name__, flush=True)
                print("job error summary:", safe_message or "[no diagnostic output]", flush=True)
                http_status = getattr(getattr(exc, "response", None), "status_code", None)
                http_status_is_transient = http_status is None or http_status >= 500 or http_status == 429
                retryable = (
                    isinstance(exc, (urllib.error.URLError, TimeoutError, ConnectionError))
                    or (exc.__class__.__module__.startswith("requests.") and http_status_is_transient)
                    or raw_code == "ffmpeg_failed"
                )
                if int(job.get("attempts", 0)) < 3 and retryable:
                    update_job(job["id"], status="queued", error_code=code, progress=0)
                else:
                    update_job(job["id"], status="failed", error_code=code, progress=0, completed_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
            if ONESHOT:
                return
        except Exception as exc:
            print("worker loop error", type(exc).__name__, flush=True)
            if ONESHOT:
                raise
            time.sleep(POLL_SECONDS)

if __name__ == "__main__": main()
