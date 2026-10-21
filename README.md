# Vyntra — Video Editor & AI Studio

Vyntra is an on-device Flutter media editor for Android. The Android application ID remains `com.ptip.statushd` so existing installs and signing identity can be preserved.

## Editing today

- Create and reopen local projects containing up to 24 video clip entries.
- Reorder clips, trim source in/out points, split at the preview playhead, and remove clips.
- Autosave project clip order and trim ranges locally. Source videos are never overwritten.
- Export a project as one MP4 by composing its trimmed clips with AndroidX Media3 Transformer; original clip audio is retained.
- Preview the selected source clip, then review, save, or share the rendered project export.
- Rename, duplicate, and delete project metadata from the project library.
- Open the existing video preparation workflow for conventional picture adjustments, output sizing, crop, and trim.
- Open Movie Player for local playback, resume support, subtitle tracks, sleep timer, A–B repeat, and picture tuning.
- Process photos locally with crop, rotate, color adjustments, and a separate JPEG export.
- Save preferences and recent export metadata on-device. No account or media-upload backend is required.

## Editing limitations

The project timeline currently edits a single video sequence. Preview playback is per selected source clip, not a gapless composition preview. Project export concatenates the ordered trimmed clips and their original audio. Crossfades, timed text and image overlays, separate music tracks, speed changes, project-wide crop/filters, and multi-track editing are not implemented in the project renderer. The existing enhancement workflow is separate from project editing. Neural enhancement is available only when the Android runtime reports its model pipeline ready; conventional upscaling does not reconstruct missing detail.

Projects store local source paths. Moving or deleting a source can make that clip unavailable; the editor reports missing sources instead of replacing them. Android video editing and export are implemented through Media3. The repository does not currently include a generated iOS project, so iOS editing parity is not available here.

## Development

Use Flutter stable and Java 17. From the repository root:

```sh
flutter pub get
dart format lib test
flutter analyze
flutter test
flutter build apk --release
```

The generated application ID is `com.ptip.statushd`. Keep it unchanged when generating platform project files. Release signing material is supplied to GitHub Actions through repository secrets and must not be committed.

## GitHub Actions

The **Build Vyntra** workflow verifies the Flutter code, runs tests, configures Android signing from repository secrets, and uploads the release APK as `vyntra-android-release` when its signing secrets are configured.

Vyntra is independent and is not affiliated with WhatsApp, TikTok, Instagram, or YouTube. Those platforms may recompress media after upload.


## Cloud export status

Vyntra now includes an authenticated Supabase cloud-export client, the `vyntra-render-jobs` Edge Function, an isolated `vyntra_render_jobs` table, and a separate FFmpeg container under `cloud-renderer/`. The app offers local or cloud export; cloud export deliberately refuses to upload media until the server reports that a worker has been deployed and verified.

### Configure the Flutter app

Add GitHub Actions repository secrets `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`. The workflows pass these as Dart defines; neither value is a service-role credential. The app keeps editing available when these are absent, but cloud sign-in is disabled.

The first cloud export requires a Supabase Auth account. Source clips, soundtrack, and image overlays are uploaded to the private `vyntra-media` bucket under the signed-in user's UUID prefix. Uploads are limited to 1 GiB per file by default. Supabase's plan-level storage limits still apply.

### Deploy the FFmpeg worker

See [cloud-renderer/README.md](cloud-renderer/README.md). Deploy the container to a long-running worker host, configure its server-only Supabase URL and service-role key, and verify a real test render. The worker polls the database queue; Edge Functions do not run FFmpeg.

Only after deployment and end-to-end verification should the Supabase Edge Function secrets `VYNTRA_RENDER_WORKER_READY=true` be set. Keep `VYNTRA_ENABLE_8K` false until the worker has enough RAM and disk and a genuine 7680×4320 sample has been rendered and decoded. The repository's GitHub Actions build does not deploy the worker automatically.

### Current limitations

- Local projects still store device paths. Cloud export uploads referenced assets and sends a project snapshot; it does not sync editable projects across devices.
- Upload retries/resume after app restart are not yet implemented; failed uploads can be retried by starting a new export.
- The current worker handles clip order/trims, 90-degree rotation, picture adjustments, volume, aspect ratio, soundtrack mixing, and timed text/image overlays. It explicitly rejects transitions and speed changes because those are not currently represented by the saved project model.
- The worker is not deployed from this repository by CI. No end-to-end cloud 4K or 8K export is claimed until a worker host is configured and tested with sample media.
- Gemini is used only for structured AI edit suggestions. It does not render video or claim to restore missing image detail.
