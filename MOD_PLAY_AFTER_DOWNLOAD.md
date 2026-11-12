# Mornye — external player mod

This experimental fork adds **Play after download** to the track options menus
on Android and desktop. The original **Download** action remains available.

## Operation

1. Open any track's options menu.
2. Choose **Play after download**.
3. If configured, select a provider and quality in the normal Mornye picker.
4. Mornye downloads, decrypts, finalizes and saves the file normally.
5. On successful completion, Android opens the audio via its external player
   chooser or default music player. A compatible player (e.g. VLC) must be
   installed. The saved file remains in the library.

**This is not progressive streaming:** full-file playback starts only after
the provider has finished downloading and processing the audio. Online streaming
would require an additional extension/backend API to expose an authorized audio
stream that remains valid during playback (and handles any necessary auth,
headers, encryption or transcoding). Do not use preview clips to represent
full-length streaming.

## Build

A GitHub Actions workflow lives in
`.github/workflows/mornye-play-android.yml` and targets the branch
`feature/play-after-download`. It builds a Lite arm64 APK using Mornye's
pinned Flutter/Rust/Android toolchain.

- In the repo, open **Actions** and enable workflows if GitHub asks.
- Opening a pull request from `feature/play-after-download` into `main`,
  or pushing a source change to the feature branch, triggers the build
  when GitHub Actions is enabled.
- **Run workflow** also becomes available after this workflow file is
  merged into the default branch (`main`).
- When the job succeeds, open its **Artifacts** and download
  `Mornye-Play-ARM64-APK`; extract
  `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`.

### Signing

Without private signing secrets, the workflow produces an APK signed with
Gradle's default test/debug key. This is installable for testing but its
signature is not guaranteed to remain stable between hosted runners.

For a **stable release signing key**, generate a private JKS locally and set
these GitHub repository Actions secrets:

- `MOD_KEYSTORE_BASE64` — base64-encoded contents of the JKS
- `MOD_KEYSTORE_PASSWORD`
- `MOD_KEY_ALIAS`
- `MOD_KEY_PASSWORD`

Never commit the keystore or passwords. Keep an offline backup of the JKS.
Because this fork uses Mornye's package identifier, a different signing
certificate means it cannot replace an installation signed by another key.
Back up user data before uninstalling the existing app.

## Verification

The code was committed and structurally matched against the source tree;
on-device functionality and CI build results must be checked separately.
A successful CI build does not by itself prove an external player opens every
provider's result, especially SAF URIs and nonstandard audio codecs.
