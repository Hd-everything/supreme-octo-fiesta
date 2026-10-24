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

GitHub Actions requires `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` for the primary project. The secondary output project URL is set to `https://ektasvkqwlwnzwvbbofh.supabase.co`. Add its service-role key as `VYNTRA_OUTPUT_SUPABASE_SERVICE_ROLE_KEY` in both the primary Edge Function secrets and GitHub Actions repository secrets. The Edge Function creates a private `vyntra-exports` bucket (50 MB max object size) on first use. New jobs route outputs there while source media and the render queue stay in primary; old jobs remain on their recorded storage route. If the secondary key is absent, output storage falls back to primary. Supabase Free Storage quota is 1 GB per organization shared across its projects, so the second project increases quota only when it belongs to a separate Free organization; two active Free projects are allowed across organizations. Also configure `GITHUB_RENDER_DISPATCH_TOKEN` in primary Edge Function secrets and `GITHUB_RENDER_REPOSITORY=Hd-everything/supreme-octo-fiesta`. Keep service-role keys server-side. The worker runs one job per workflow and is not a permanent polling server.

Supabase Storage limits and egress vary by plan. Status HD cloud requests are capped at 50 MiB per uploaded object and 180 seconds total video duration; the worker re-checks the actual downloaded file size and probes media duration independently. The workflow has a 25-minute timeout. 4K software encoding can be slow and consumes CPU, disk, and egress. 8K is disabled by default due to high memory, CPU, and storage demands. GPU is not required for ordinary FFmpeg encoding.

## Important integration status

The Flutter client uploads sources to the primary project, then the Edge Function validates the job and dispatches GitHub. After the app assembles and verifies the downloaded MP4, it acknowledges delivery; the Edge Function deletes the source objects in primary storage and output objects from the project's recorded output bucket. Exports use 48,000,000-byte parts and the worker defaults to a 200,000,000-byte per-export cap. These parts preserve the original encoded output; no quality reduction is performed to meet the object-size limit. Set up scheduled cleanup for abandoned jobs as a separate safeguard because a user may never finish downloading. Run a real two-project render and verify output cleanup before advertising the second-project route as active.
