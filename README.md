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
