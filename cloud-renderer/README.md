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

GitHub Actions requires `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` for the primary project. The secondary output project URL is `https://vfaakmxoeflzedwidlcl.supabase.co`. Add its service-role key as `VYNTRA_OUTPUT_SUPABASE_SERVICE_ROLE_KEY` in both the primary Edge Function secrets and GitHub Actions repository secrets. The Edge Function creates a private `vyntra-exports` bucket (50 MB max object size) on first use. New jobs route outputs there while source media and the render queue stay in primary; old jobs remain on their recorded storage route. If a secondary output upload fails with a capacity response (HTTP 402, 413, 507, or an explicit storage-quota error), the worker removes partial secondary output, switches the job's recorded route to primary, and retries the complete output there. The Edge Function then signs and cleans up the output from primary. Other upload errors do not trigger fallback. If the secondary key is absent, output storage falls back to primary. Supabase Free Storage quota is 1 GB per organization shared across its projects; this separate-organization project has a separate quota. Two active Free projects are allowed across organizations. Also configure `GITHUB_RENDER_DISPATCH_TOKEN` in primary Edge Function secrets and `GITHUB_RENDER_REPOSITORY=Hd-everything/supreme-octo-fiesta`. Keep service-role keys server-side. The worker runs one job per workflow and is not a permanent polling server.

Supabase Storage limits and egress vary by plan. Status HD cloud requests are capped at 50 MiB per uploaded object and 180 seconds total video duration; the worker re-checks the actual downloaded file size and probes media duration independently. The workflow has a 25-minute timeout. 4K software encoding can be slow and consumes CPU, disk, and egress. 8K is disabled by default due to high memory, CPU, and storage demands. GPU is not required for ordinary FFmpeg encoding.

## Important integration status

The Flutter client uploads sources to the primary project in 48,000,000-byte parts (up to 200 MiB combined per job), then the Edge Function validates the job and dispatches GitHub. The worker reassembles source bytes before probing/rendering. After the app assembles and verifies the downloaded MP4, it acknowledges delivery; the Edge Function deletes source objects in primary storage and output objects from the recorded output project. Rendered outputs also use 48,000,000-byte parts and have a 200,000,000-byte per-export cap. Splitting does not alter media content or quality. Set up scheduled cleanup for abandoned jobs as a separate safeguard because a user may never finish downloading. Run a real two-project render and verify output cleanup before advertising the secondary route as active.


## Optional ESPCN AI restoration

The existing render queue and GitHub Actions dispatch are unchanged. A Status HD project can opt in by setting `project_snapshot.aiEnhancement=true`; when absent or false, the original FFmpeg-only render path is unchanged. This uses the same ESPCN x3 TensorFlow Lite model already packaged by the Vyntra app, downloaded from its published Apache-2.0 source and SHA-256 verified before inference.

To protect the one-shot runner and avoid unexpectedly long exports, this initial CPU implementation is limited to video-only projects with source clips no longer than 10 seconds each, no more than 10 seconds of source video in total, source dimensions at or below 480p, and source frame rate at or below 24 fps. Mixed still-image/video projects are rejected in AI mode instead of silently skipping AI on photos. The AI pass performs frame-by-frame ESPCN tile inference, creates a 3x intermediate, then passes it into the existing editor render so framing, edits, overlays, audio, target resolution, verification, upload, and cleanup remain in the same pipeline. Ordinary jobs do not download the model or run inference.

This is a first CPU-backed integration, not a claim of production performance. The actual GitHub Actions run must pass the worker tests and a short end-to-end export before the option is exposed publicly. ESPCN can be substantially slower than ordinary exports, and its reconstructed detail is estimated rather than guaranteed to match original detail.
