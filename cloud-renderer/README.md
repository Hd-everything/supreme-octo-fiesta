# Vyntra cloud renderer

This directory contains the FFmpeg worker used by the one-shot GitHub Actions workflow. FFmpeg must not run inside a Supabase Edge Function.

## Current supported render plan

- Multiple ordered video clips, trims, 90-degree rotations, per-clip volume and picture adjustments.
- Aspect-ratio framing, 720p / 1080p / 1440p (2K/QHD) / 2160p (4K) / 2880p (5K) / 3456p (6K) output, H.264 and H.265 if `libx265` exists.
- Optional soundtrack mixing, timed text overlays, and positioned timed image overlays.
- ffprobe output metadata validation plus a full decode pass before completion.
- Private storage object paths and service-role credentials kept on the server.

Unsupported effects are rejected explicitly. Transitions and speed changes are not represented by the current editor model and fail if supplied. 8K is disabled by default, has a worker RAM/disk guard, and must not be exposed unless the deployment is explicitly enabled and passes an actual 7680x4320 decode test.

## Deploy

GitHub Actions can run one job per workflow run using `.github/workflows/status-hd-render.yml`. Configure repository Actions secrets `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`. In Supabase Edge Function secrets, configure `GITHUB_RENDER_DISPATCH_TOKEN` as a fine-grained token scoped only to this repository with Actions/Contents permissions required to dispatch repository events, and `GITHUB_RENDER_REPOSITORY=Hd-everything/supreme-octo-fiesta`. Never put either secret in Flutter, logs, or committed files. Set `VYNTRA_RENDER_WORKER_READY=true` only after a real render test succeeds. The workflow uses a one-shot worker and does not run a permanent polling server.

Supabase Storage limits and egress vary by plan. Status HD cloud requests are capped at 50 MiB per uploaded object and 180 seconds total video duration; the worker re-checks the actual downloaded file size and probes media duration independently. The workflow has a 25-minute timeout. 4K software encoding can be slow and consumes CPU, disk, and egress. 8K is disabled by default due to high memory, CPU, and storage demands. GPU is not required for ordinary FFmpeg encoding.

## Important integration status

The Flutter client establishes a Supabase anonymous guest session in the background (no sign-in UI), validates 50 MiB / 180-second limits, uploads each referenced source asset to a guest-scoped object path, rewrites local paths in the project snapshot, and calls the Edge Function. The Edge Function authenticates the user JWT, limits active jobs, validates owner-scoped paths, and dispatches GitHub without exposing its token. Anonymous sign-ins must be enabled in Supabase Auth. The worker intentionally rejects local paths and cross-guest object paths. After the user has configured the required secrets, test a short sample end-to-end. The client acknowledges a successful local download so the Edge Function can delete temporary input/output objects. Also configure a scheduled cleanup for abandoned jobs and test that failure path before enabling public use. GitHub Actions is a temporary job runner, not an always-on server. The current worker uses FFmpeg quality filters; a dedicated AI restoration model is not yet wired into this pipeline.
