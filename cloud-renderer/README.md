# Vyntra cloud renderer

This directory is a separate long-running FFmpeg worker; FFmpeg must not run inside a Supabase Edge Function.

## Current supported render plan

- Multiple ordered video clips, trims, 90-degree rotations, per-clip volume and picture adjustments.
- Aspect-ratio framing, 720p / 1080p / 1440p / 2160p output, H.264 and H.265 if `libx265` exists.
- Optional soundtrack mixing, timed text overlays, and positioned timed image overlays.
- ffprobe output metadata validation plus a full decode pass before completion.
- Private storage object paths and service-role credentials kept on the server.

Unsupported effects are rejected explicitly. Transitions and speed changes are not represented by the current editor model and fail if supplied. 8K is disabled by default, has a worker RAM/disk guard, and must not be exposed unless the deployment is explicitly enabled and passes an actual 7680x4320 decode test.

## Deploy

Build and run this container on a long-running container host (Cloud Run, Railway, Fly.io, or an equivalent worker host). Configure the variables from `.env.example` as server secrets; never put the service-role key in Flutter or commit it. Configure one worker replica initially. The Supabase project must have the migration in `supabase/migrations` applied before the worker starts.

Supabase Storage limits and egress vary by plan. This worker caps each source at 1 GiB by default and each project at 30 minutes; set lower values for a free/low-cost deployment. 4K software encoding can be slow and consumes CPU, disk, and egress. 8K is disabled by default due to high memory, CPU, and storage demands. GPU is not required for ordinary FFmpeg encoding.

## Important integration status

The current Flutter project stores project JSON in SharedPreferences and source paths are local device paths; it does not currently implement Supabase sign-in or a cloud upload client. Before a user-facing cloud export can work, the app must establish Supabase Auth sessions, upload every referenced source asset to a user-scoped object path, replace local paths with those object keys in a versioned project snapshot, and call the Edge Function. The worker intentionally rejects local paths and cross-user object paths. Do not claim end-to-end cloud rendering until that app integration and a deployed worker are tested with sample media.
