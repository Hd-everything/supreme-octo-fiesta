#!/usr/bin/env python3
"""Vyntra cloud render worker. Runs outside Supabase Edge Functions."""
from __future__ import annotations

import json, os, shutil, subprocess, tempfile, time, urllib.error, urllib.parse, urllib.request, uuid
import requests
from pathlib import Path

SUPABASE_URL = os.environ["SUPABASE_URL"].rstrip("/")
SERVICE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
WORKER_ID = os.getenv("VYNTRA_WORKER_ID", str(uuid.uuid4()))
BUCKET = os.getenv("VYNTRA_STORAGE_BUCKET", "vyntra-media")
POLL_SECONDS = max(2, int(os.getenv("VYNTRA_POLL_SECONDS", "5")))
MAX_DURATION = int(os.getenv("VYNTRA_MAX_DURATION_SECONDS", "1800"))
MAX_INPUT_BYTES = int(os.getenv("VYNTRA_MAX_INPUT_BYTES", str(1024**3)))
ENABLE_8K = os.getenv("VYNTRA_ENABLE_8K", "false").lower() == "true"
MAX_JOBS = max(1, int(os.getenv("VYNTRA_MAX_CONCURRENT_JOBS", "1")))

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
    api("/rest/v1/vyntra_render_jobs?id=eq." + urllib.parse.quote(job_id),
        "PATCH", values, {"Prefer": "return=minimal"})

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

def storage_upload(source: Path, object_path: str):
    # Stream the output from disk; do not load large rendered files into memory.
    url = SUPABASE_URL + "/storage/v1/object/" + BUCKET + "/" + urllib.parse.quote(object_path, safe="/")
    with source.open("rb") as stream:
        response = requests.post(url, data=stream, timeout=(30, 900), headers={
            "apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}",
            "Content-Type": "video/mp4", "x-upsert": "false",
        })
    response.raise_for_status()

def probe(path: Path):
    raw = subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)], timeout=45)
    return json.loads(raw)

def safe_number(value, low, high, name):
    try: number = float(value)
    except (TypeError, ValueError): raise ValueError("invalid_" + name)
    if number < low or number > high: raise ValueError("invalid_" + name)
    return number

def output_dimensions(source_width: int, source_height: int, rotation: int, aspect_ratio: str, resolution: str):
    edge = {"720p": 720, "1080p": 1080, "1440p": 1440, "2160p": 2160, "4320p": 4320}.get(resolution)
    if edge is None: raise ValueError("unsupported_resolution")
    ratios = {"9:16": 9 / 16, "16:9": 16 / 9, "1:1": 1.0, "4:5": 4 / 5}
    if aspect_ratio == "Original":
        if rotation % 180 == 90: source_width, source_height = source_height, source_width
        target_ratio = source_width / max(1, source_height)
    elif aspect_ratio in ratios:
        target_ratio = ratios[aspect_ratio]
    else:
        raise ValueError("invalid_aspect_ratio")
    if target_ratio >= 1:
        width, height = round(edge * target_ratio), edge
    else:
        width, height = edge, round(edge / target_ratio)
    width -= width % 2
    height -= height % 2
    if width * height > 7680 * 4320: raise ValueError("output_dimensions_too_large")
    return width, height


def render(job, work: Path):
    plan = job["project_snapshot"]
    clips = plan.get("clips")
    if not isinstance(clips, list) or not 1 <= len(clips) <= 24:
        raise ValueError("unsupported_project_clip_count")
    if plan.get("transitions"): raise ValueError("unsupported_effect:transitions")
    if plan.get("speedChanges"): raise ValueError("unsupported_effect:speed_changes")
    resolution = job["resolution"]
    edge = {"720p": 720, "1080p": 1080, "1440p": 1440, "2160p": 2160, "4320p": 4320}.get(resolution)
    if edge is None: raise ValueError("unsupported_resolution")
    if resolution == "4320p":
        if not ENABLE_8K: raise ValueError("8k_not_enabled_on_worker")
        try:
            total_ram = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
        except (ValueError, OSError, AttributeError):
            total_ram = 0
        if total_ram < 8 * 1024**3 or shutil.disk_usage(tempfile.gettempdir()).free < 10 * 1024**3:
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
        storage_download(key, path)
        meta = probe(path)
        v = next((s for s in meta.get("streams", []) if s.get("codec_type") == "video"), None)
        if not v: raise ValueError("source_has_no_video")
        duration = float(meta.get("format", {}).get("duration", 0))
        start = safe_number(clip.get("startMs", 0), 0, duration * 1000, "trim_start") / 1000
        end = safe_number(clip.get("endMs", int(duration * 1000)), 1, duration * 1000, "trim_end") / 1000
        if end <= start or end - start > MAX_DURATION: raise ValueError("invalid_trim_range")
        input_args += ["-ss", str(start), "-t", str(end-start), "-i", str(path)]
        local.append(path); clip_lengths.append(end-start); probe_info.append((v, any(s.get("codec_type") == "audio" for s in meta.get("streams", []))))
    if sum(clip_lengths) > MAX_DURATION: raise ValueError("project_duration_limit")
    music_path = None
    music = plan.get("musicPath")
    if music:
        if not music.startswith(job["owner_id"] + "/"): raise ValueError("media_not_owned")
        music_path = work / "music.media"
        storage_download(music, music_path)
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
        vf += [f"scale={width}:{height}:force_original_aspect_ratio=increase", f"crop={width}:{height}", "setsar=1", "fps=30"]
        brightness = safe_number(clip.get("brightness", 0), -.25, .25, "brightness")
        contrast = 1 + safe_number(clip.get("contrast", 0), -.3, .3, "contrast")
        saturation = 1 + safe_number(clip.get("saturation", 0), -20, 30, "saturation") / 100
        if brightness or contrast != 1 or saturation != 1: vf.append(f"eq=brightness={brightness}:contrast={contrast}:saturation={saturation}")
        filters.append(f"[{i}:v]{','.join(vf)},format=yuv420p,setpts=PTS-STARTPTS[v{i}]")
        video_labels.append(f"[v{i}]")
        volume = safe_number(clip.get("volume", 1), 0, 1, "volume")
        if has_audio:
            filters.append(f"[{i}:a]asetpts=PTS-STARTPTS,volume={volume}[a{i}]")
        else:
            filters.append(f"anullsrc=r=48000:cl=stereo,atrim=duration={clip_lengths[i]:.6f},asetpts=PTS-STARTPTS[a{i}]")
        audio_labels.append(f"[a{i}]")
    filters.append("".join(video_labels + audio_labels) + f"concat=n={len(clips)}:v=1:a=1[vcat][acat]")
    video_label = "[vcat]"
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
        storage_download(key, image_path)
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
        font_size = int(safe_number(overlay.get("fontSize", 34), 16, 96, "font_size"))
        x = safe_number(overlay.get("x", 0), -1, 1, "overlay_x")
        y = safe_number(overlay.get("y", .55), -1, 1, "overlay_y")
        color = int(overlay.get("color", 0xFFFFFFFF)) & 0xFFFFFF
        next_label = f"[vt{i}]"
        filters.append(f"{video_label}drawtext=textfile='{text_file}':fontsize={font_size}:fontcolor=0x{color:06X}:x=(w-text_w)/2+({x})*w/2:y=(h-text_h)/2+({y})*h/2:enable='between(t,{start},{end})'{next_label}")
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
    cmd = input_args + ["-filter_complex", ";".join(filters), "-map", video_label, "-map", audio_label,
        "-c:v", "libx264" if codec == "h264" else "libx265", "-preset", "veryfast",
        "-crf", str(int(safe_number(job.get("quality", 23), 18, 32, "quality"))),
        "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", str(out)]
    update_job(job["id"], status="processing", progress=1, started_at=job.get("started_at") or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    duration_ms = sum(int(c.get("endMs", 0)) - int(c.get("startMs", 0)) for c in clips)
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
    stderr = proc.stderr.read() if proc.stderr else ""
    if proc.returncode != 0: raise RuntimeError("ffmpeg_failed:" + stderr[-1000:])
    meta = probe(out)
    video = next((s for s in meta.get("streams", []) if s.get("codec_type") == "video"), None)
    if not video or int(video.get("width", 0)) != width or int(video.get("height", 0)) != height:
        raise RuntimeError("output_verification_failed:dimensions")
    # Full decode verification, not just successful container creation.
    subprocess.run(["ffmpeg", "-v", "error", "-i", str(out), "-f", "null", "-"], check=True, timeout=MAX_DURATION*2)
    output_duration = float(meta.get("format", {}).get("duration", 0))
    expected_duration = sum(clip_lengths)
    if output_duration <= 0 or abs(output_duration - expected_duration) > max(1.0, len(clips) * 0.15):
        raise RuntimeError("output_verification_failed:duration")
    return out, {"width": width, "height": height, "videoCodec": video.get("codec_name"), "durationSeconds": output_duration, "bytes": out.stat().st_size}

def main():
    print("Vyntra worker ready", WORKER_ID, flush=True)
    while True:
        try:
            claimed = api("/rest/v1/rpc/vyntra_claim_render_job", "POST", {"p_worker_id": WORKER_ID})
            job = claimed[0] if isinstance(claimed, list) and claimed else None
            if not job:
                time.sleep(POLL_SECONDS); continue
            try:
                update_job(job["id"], status="processing", progress=0, worker_id=WORKER_ID)
                with tempfile.TemporaryDirectory(prefix="vyntra-render-") as directory:
                    output, metadata = render(job, Path(directory))
                    update_job(job["id"], status="finalizing", progress=96)
                    output_path = f'{job["owner_id"]}/exports/{job["id"]}.mp4'
                    storage_upload(output, output_path)
                    update_job(job["id"], status="completed", progress=100, output_path=output_path, output_metadata=metadata, completed_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), error_code=None)
            except InterruptedError:
                update_job(job["id"], status="cancelled", progress=0, completed_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
            except Exception as exc:
                message = str(exc)
                code = message.split(":",1)[0][:80] or "render_failed"
                print("job failed", job.get("id"), code, flush=True)
                update_job(job["id"], status="failed", error_code=code, progress=0, completed_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        except Exception as exc:
            print("worker loop error", type(exc).__name__, flush=True)
            time.sleep(POLL_SECONDS)

if __name__ == "__main__": main()
