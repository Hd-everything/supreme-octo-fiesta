# Vyntra cloud renderer

This directory contains the FFmpeg worker used by the one-shot GitHub Actions workflows. FFmpeg must not run inside a Supabase Edge Function.

## Current supported render plan

- Multiple ordered video clips, trims, 90-degree rotations, per-clip volume and picture adjustments.
- Aspect-ratio framing, 720p / 1080p / 1440p (2K/QHD) / 2160p (4K) / 2880p (5K) / 3456p (6K) output, H.264 and H.265 if `libx265` exists.
- Optional soundtrack mixing, timed text overlays, and positioned timed image overlays.
- ffprobe output metadata validation plus a full decode pass before completion.
- Private storage object paths and service-role credentials kept on the server.

Unsupported effects are rejected explicitly. Transitions and speed changes are not represented by the current editor model and fail if supplied. 8K is disabled by default, has a worker RAM/disk guard, and must not be exposed unless the deployment is explicitly enabled and passes an actual 7680x4320 decode test.

## Deployment and worker pool

The shared Supabase database is the source of truth for a **100-job global ceiling**, with a **20-job ceiling per worker repository**. The `vyntra_enforce_render_pool_limit` trigger serializes slot acquisition so concurrent claims cannot exceed either cap. Worker IDs include their repository to enforce the per-repository ceiling. Apply `supabase/migrations/202610270001_vyntra_global_worker_limit.sql` before enabling the pool. All five workers must use the same control-plane Supabase project and release repository.

In Supabase Edge Function secrets configure `GITHUB_RENDER_WORKER_TARGETS` as a JSON array of `{ "repo": "owner/name", "token": "..." }` entries for the five repositories. Each token must be scoped to dispatch `vyntra_render_requested` to its one listed repository. The dispatcher sends new jobs to the least-loaded configured repository with an available slot; when all slots are occupied, jobs stay queued and the five-minute queue pumps pick them up as capacity frees. The old single-worker `GITHUB_RENDER_DISPATCH_TOKEN` plus `GITHUB_RENDER_REPOSITORY` remains a fallback. Configure `VYNTRA_RELEASE_TOKEN` in Supabase and in each worker repository's Actions secrets; use a fine-grained token restricted to the private `fasmora-continue/here` repository with Contents read/write. `VYNTRA_RELEASE_REPOSITORY=fasmora-continue/here` is the default. Never put any of these credentials in Flutter, logs, or committed files.

Each worker repository needs the render workflow and a scheduled queue pump (every five minutes). Push events run validation but never claim production jobs. Set the repository Actions variable `VYNTRA_RENDER_WORKER_ENABLED=true` only after the shared Supabase migration, Edge Functions, and that repository's secrets are deployed; until then scheduled/dispatch worker jobs are skipped. Worker Actions secrets are `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, and `VYNTRA_RELEASE_TOKEN`. The worker downloads every source part, verifies its declared size and SHA-256, then sends a job-scoped HMAC receipt to `vyntra-render-receipt`. Supabase deletes only that job's source objects after accepting the receipt. The worker renders from its verified local copies, uploads a deterministic private Release asset, and asks `vyntra-render-complete` to verify the release, asset name, state, and size before marking the job complete. `vyntra-render-jobs` then issues a short-lived signed asset URL; Vyntra immediately downloads directly from GitHub, verifies size and SHA-256, and acknowledges delivery. Supabase does not stream the MP4. Acknowledgement deletes the asset and per-job release. Unacknowledged outputs expire after six hours.

The 100-job ceiling is a database admission limit across the five repositories, with at most 20 active jobs assigned to each. The advertised configured capacity scales with the number of worker targets (up to 100), but it is not a promise that GitHub will always have that many runners available. Actual concurrency depends on each owner account's plan, current Actions usage, and successful repository setup.

Vyntra retains the existing 50 MiB source-file limit, 48,000,000-byte source parts, 200 MiB project input/output limit, 180-second render limit, 24-clip limit, and per-user active-job limit. 4K software encoding can be slow and consumes CPU, disk, and egress. 8K is disabled by default due to high memory, CPU, and storage demands. GPU is not required for ordinary FFmpeg encoding.

## Important integration status

The Flutter client establishes a Supabase anonymous guest session in the background (no sign-in UI), validates source and duration limits, hashes each uploaded part, uploads to a guest-scoped object path, rewrites local paths in the project snapshot, and calls `vyntra-render-jobs`. Deploy the migration and the `vyntra-render-jobs`, `vyntra-render-receipt`, and `vyntra-render-complete` functions before routing production renders. Enable anonymous sign-ins in Supabase Auth. Verify a real render, an interrupted direct download with a renewed signed URL, SHA-256 validation, and both source and output cleanup before public use.
