import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.57.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const bucket = "vyntra-media";
const maxUploadBytes = Number(Deno.env.get("VYNTRA_MAX_UPLOAD_BYTES") ?? 1_073_741_824);
const allowedMime = new Set(["video/mp4", "video/quicktime", "video/x-matroska", "audio/mpeg", "audio/mp4", "image/png", "image/jpeg", "image/webp"]);
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" },
});

function objectPaths(project: Record<string, unknown>, userId: string): string[] {
  const clips = project.clips;
  if (!Array.isArray(clips) || clips.length < 1 || clips.length > 24) throw new Error("invalid_clip_count");
  const paths: string[] = [];
  const add = (value: unknown) => {
    if (typeof value !== "string" || !value.startsWith(userId + "/") || value.startsWith("/") ||
      value.split("/").includes("..") || value.length > 700) throw new Error("invalid_media_path");
    paths.push(value);
  };
  for (const item of clips) {
    if (!item || typeof item !== "object") throw new Error("invalid_clip");
    const clip = item as Record<string, unknown>;
    const start = Number(clip.startMs ?? 0), end = Number(clip.endMs ?? 0), duration = Number(clip.durationMs ?? end);
    if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end <= start || (duration > 0 && end > duration)) throw new Error("invalid_trim_range");
    const rotation = Number(clip.rotation ?? 0);
    if (![0, 90, 180, 270].includes(((rotation % 360) + 360) % 360)) throw new Error("unsupported_rotation");
    if (Number(clip.volume ?? 1) < 0 || Number(clip.volume ?? 1) > 1) throw new Error("invalid_volume");
    add(clip.path);
  }
  if (project.musicPath) add(project.musicPath);
  if (Array.isArray(project.imageOverlays)) {
    for (const item of project.imageOverlays) {
      if (!item || typeof item !== "object") throw new Error("invalid_image_overlay");
      add((item as Record<string, unknown>).path);
    }
  }
  if (!["Original", "9:16", "16:9", "1:1", "4:5"].includes(String(project.aspectRatio ?? "Original"))) throw new Error("invalid_aspect_ratio");
  return [...new Set(paths)];
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json({ error: "server_not_configured" }, 503);
  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!token) return json({ error: "unauthorized" }, 401);
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: userData, error: authError } = await admin.auth.getUser(token);
  if (authError || !userData.user) return json({ error: "unauthorized" }, 401);
  const userId = userData.user.id;

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "invalid_json" }, 400); }
  const action = body.action;
  try {
    if (action === "capabilities") {
      const workerReady = Deno.env.get("VYNTRA_RENDER_WORKER_READY") === "true";
      const enable8k = workerReady && Deno.env.get("VYNTRA_ENABLE_8K") === "true";
      return json({ workerReady, resolutions: workerReady ? ["720p", "1080p", "1440p", "2160p", "2880p", "3456p", ...(enable8k ? ["4320p"] : [])] : [], codecs: workerReady ? ["h264", "h265"] : [], maxUploadBytes, guestAccess: true });
    }
    if (action === "prepare_upload") {
      const name = typeof body.fileName === "string" ? body.fileName.split(/[\\/]/).pop()!.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-100) : "media.bin";
      const mime = typeof body.contentType === "string" ? body.contentType : "";
      const bytes = Number(body.sizeBytes);
      if (!allowedMime.has(mime)) return json({ error: "unsupported_content_type" }, 415);
      if (!Number.isSafeInteger(bytes) || bytes < 1 || bytes > maxUploadBytes) return json({ error: "upload_size_limit", maxBytes: maxUploadBytes }, 413);
      const path = `${userId}/sources/${crypto.randomUUID()}-${name}`;
      const { data, error } = await admin.storage.from(bucket).createSignedUploadUrl(path);
      if (error || !data) return json({ error: "upload_url_unavailable", message: "Could not prepare a secure upload." }, 503);
      return json({ path, token: data.token, signedUrl: data.signedUrl, bucket, expiresInSeconds: 7200 });
    }

    if (action === "create_job") {
      const project = body.projectSnapshot;
      if (!project || typeof project !== "object" || Array.isArray(project)) return json({ error: "invalid_project_snapshot" }, 400);
      const snapshot = project as Record<string, unknown>;
      const projectId = typeof body.projectId === "string" ? body.projectId.slice(0, 160) : "";
      const idem = typeof body.idempotencyKey === "string" ? body.idempotencyKey : "";
      if (!projectId || idem.length < 8 || idem.length > 160) return json({ error: "invalid_job_identity" }, 400);
      let paths: string[];
      try { paths = objectPaths(snapshot, userId); } catch (error) { return json({ error: String(error).replace("Error: ", "") }, 422); }
      const resolution = String(body.resolution ?? "");
      if (!["720p", "1080p", "1440p", "2160p", "2880p", "3456p", "4320p"].includes(resolution)) return json({ error: "unsupported_resolution" }, 400);
      if (resolution === "4320p" && Deno.env.get("VYNTRA_ENABLE_8K") !== "true") return json({ error: "8k_not_enabled" }, 409);
      const codec = String(body.codec ?? "h264");
      if (!["h264", "h265"].includes(codec)) return json({ error: "unsupported_codec" }, 400);
      const quality = Number(body.quality ?? 23);
      if (!Number.isInteger(quality) || quality < 18 || quality > 32) return json({ error: "invalid_quality" }, 400);

      const { data: prior } = await admin.from("vyntra_render_jobs").select("*").eq("owner_id", userId).eq("idempotency_key", idem).maybeSingle();
      if (prior) return json({ job: prior, reused: true });
      const { count } = await admin.from("vyntra_render_jobs").select("id", { count: "exact", head: true }).eq("owner_id", userId).in("status", ["queued", "uploading", "processing", "finalizing", "cancel_requested"]);
      if ((count ?? 0) >= 2) return json({ error: "active_job_limit", message: "You already have two active cloud exports." }, 429);
      const { data, error } = await admin.from("vyntra_render_jobs").insert({
        owner_id: userId, project_id: projectId, idempotency_key: idem,
        project_snapshot: snapshot, source_object_paths: paths, resolution, codec, quality,
        status: "queued", progress: 0,
      }).select("*").single();
      if (error) {
        const { data: duplicate } = await admin.from("vyntra_render_jobs").select("*").eq("owner_id", userId).eq("idempotency_key", idem).maybeSingle();
        if (duplicate) return json({ job: duplicate, reused: true });
        console.error("Vyntra job creation failed", error.code);
        return json({ error: "job_creation_failed" }, 500);
      }
      return json({ job: data, reused: false }, 201);
    }

    if (action === "status" || action === "cancel" || action === "download_url") {
      const jobId = typeof body.jobId === "string" ? body.jobId : "";
      if (!jobId) return json({ error: "invalid_job_id" }, 400);
      const { data: job, error } = await admin.from("vyntra_render_jobs").select("*").eq("id", jobId).eq("owner_id", userId).maybeSingle();
      if (error || !job) return json({ error: "job_not_found" }, 404);
      if (action === "cancel") {
        if (["queued", "uploading", "processing", "finalizing"].includes(job.status)) {
          const nextStatus = job.status === "queued" || job.status === "uploading" ? "cancelled" : "cancel_requested";
          const { data: updated, error: updateError } = await admin.from("vyntra_render_jobs").update({
            status: nextStatus, progress: nextStatus === "cancelled" ? 0 : job.progress, updated_at: new Date().toISOString(),
          }).eq("id", job.id).eq("owner_id", userId).select("*").single();
          if (updateError) return json({ error: "cancel_failed" }, 500);
          return json({ job: updated });
        }
        return json({ job, cancelAccepted: false });
      }
      if (action === "download_url") {
        if (job.status !== "completed" || !job.output_path) return json({ error: "export_not_ready" }, 409);
        const { data, error: signError } = await admin.storage.from(bucket).createSignedUrl(job.output_path, 300);
        if (signError || !data) return json({ error: "download_url_unavailable" }, 503);
        return json({ job, signedUrl: data.signedUrl, expiresInSeconds: 300 });
      }
      return json({ job });
    }
    return json({ error: "unknown_action" }, 400);
  } catch (error) {
    console.error("Vyntra render API error", error instanceof Error ? error.message : "unknown");
    return json({ error: "request_failed" }, 500);
  }
});
