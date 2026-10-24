# Vyntra cloud renderer

This directory contains the FFmpeg worker used by the one-shot GitHub Actions workflow. FFmpeg must not run inside a Supabase Edge Function.

## Current supported render plan

The worker supports photos and the editing operations below. Unsupported edits are rejected rather than silently omitted.

- Ordered video clips and still photos (`png`, `jpg`, `jpeg`, `webp`), with trim points, 90-degree rotation, reverse, speed changes, freeze frames, per-clip volume, audio fades, and audio cleanup.
- Cut, fade, fade-to-black, dissolve, wipe-left, and slide-right transitions, with audio crossfades.
- Per-clip brightness, contrast, saturation, keyframed adjustments, and built-in looks: flash, shake, blur, glitch, phonk, grayscale, negative, cinematic, moody, vivid, dramatic, vintage, fade, night, sunset, noir, soft, and dreamy.
- Original, 9:16, 16:9, 1:1, 4:5, 3:4, 4:3, and 21:9 framing.
- Optional soundtrack mixing, timed text overlays, and positioned timed image overlays.
- 24, 25, 30, 50, or 60 fps output; 720p through 6K output and opt-in 8K; H.264 and H.265 when `libx265` is available.
- ffprobe output metadata validation plus a full decode pass before completion.
- Private storage object paths and service-role credentials kept on the server.

Each export is limited to 24 clips, 180 seconds of rendered timeline, and 50 MiB per source object. AI restoration, body tracking, background removal, optical-flow slow motion, animated sticker packs, and advanced masks are not implemented. 8K is disabled by default, has a worker RAM/disk guard, and must not be exposed unless the deployment is explicitly enabled and passes an actual 7680x4320 decode test.

## Deploy

GitHub Actions can run one job per workflow run using `.github/workflows/status-hd-render.yml`. Configure repository Actions secrets `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`. In Supabase Edge Function secrets, configure `GITHUB_RENDER_DISPATCH_TOKEN` as a fine-grained token scoped only to this repository with Actions/Contents permissions required to dispatch repository events, and `GITHUB_RENDER_REPOSITORY=Hd-everything/supreme-octo-fiesta`. Never put either secret in Flutter, logs, or committed files. Set `VYNTRA_RENDER_WORKER_READY=true` only after a real render test succeeds. The workflow uses a one-shot worker and does not run a permanent polling server.

Source media and export parts stay in the private `vyntra-media` bucket. Each rendered MP4 larger than 49 MiB is split into ordered 49 MiB objects and reassembled byte-for-byte on the device, so the bucket's 50 MiB per-object and Supabase Free global upload limits are respected without changing the selected resolution or bitrate. The worker caps a rendered file at 850 MiB to leave some headroom under the Free plan's 1 GB total Storage quota; a project with less remaining space can still be rejected by Storage. Smaller MP4s remain a single object for compatibility. The source-upload cap remains 50 MiB per object.

Supabase Storage limits and egress vary by plan. Status HD cloud requests are capped at 50 MiB per uploaded object and 180 seconds total video duration; the worker re-checks the actual downloaded file size and probes media duration independently. The workflow has a 25-minute timeout. 4K software encoding can be slow and consumes CPU, disk, and egress. 8K is disabled by default due to high memory, CPU, and storage demands. GPU is not required for ordinary FFmpeg encoding.

## Important integration status

The Flutter client establishes a Supabase anonymous guest session in the background (no sign-in UI), validates 50 MiB / 180-second limits, uploads each referenced source asset to a guest-scoped object path, rewrites local paths in the project snapshot, and calls the Edge Function. The Edge Function authenticates the user JWT, limits active jobs, validates owner-scoped paths, and dispatches GitHub without exposing its token. Anonymous sign-ins must be enabled in Supabase Auth. The worker intentionally rejects local paths and cross-guest object paths. After the user has configured the required secrets, test a short sample end-to-end. The client acknowledges a successful local download so the Edge Function can delete temporary input/output objects. Also configure a scheduled cleanup for abandoned jobs and test that failure path before enabling public use. GitHub Actions is a temporary job runner, not an always-on server. The current worker uses FFmpeg quality filters; a dedicated AI restoration model is not yet wired into this pipeline.
