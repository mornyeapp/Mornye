# Mornye Play — standalone Android music player

**Status:** experimental Android ARM64 build, based on Mornye 5.3.1.

## Separate installation

- Launcher name: **Mornye Play**
- Android application ID: `com.drshlemko.mornyeplay`
- Original Mornye application ID: `com.zarz.mornye`
- Both apps can be installed on the same phone with separate private storage,
  preferences, streaming extensions, downloads and login sessions.
- The Android Kotlin namespace remains `com.zarz.mornye` to preserve native
  classes, while AndroidManifest component names are fully qualified.
- `Mornye Play` is an independent, unofficial edition and is not affiliated
  with Qobuz or the original Mornye developers.
- Updating Mornye Play in place requires the **same signing keystore** on
  subsequent builds. Without GitHub Actions signing secrets, separate builds
  may have incompatible test signatures; back up data before replacement.

## Full playback, not preview

- Every old `PreviewButton` now starts the built-in full-track player (local
  file first, then the supported full-length HTTPS extension resolver).
  It NEVER uses `track.previewUrl` or the short preview player.
- Suggested songs: ▶ full-length stream, ↓ offline download, + playlist.
  Entire suggestions become a queue; track taps start full audio.
- Popular songs in artist pages: ▶ full-length stream, ↓ offline download.
  Track taps use local playback or full streaming and do not download secretly.
  The options sheet remains accessible by long-press.
- Search, albums, playlists, and Home already have separate ▶ and ↓ controls.
  Search-row taps now play rather than silently downloading a track.
- The existing Hi-Res quality selection is on long-press ▶; download format
  selection is on long-press ↓. Audio bitrate is shown only when verifiable.

## Install

1. Download the signed `Mornye_Play_v5.3.1_ARM64.apk` from the successful
   `Mornye Play standalone Android APK` GitHub Actions artifact.
2. Install it beside your official Mornye (do not uninstall the original).
3. In Mornye Play install and enable experimental
   `Qobuz Online v1.2.29.sflx` for online tracks (account/availability
   restrictions still apply).
4. Configure a legitimate download extension/provider if you want offline files.

## Caveats

- The Qobuz experimental online resolver cannot guarantee access to every
  track or highest tier; source authentication and regional/contractual
  restrictions apply.
- It is not a Qobuz client or bypass of subscriptions or copy protection.
- The separate Android package does not automatically transfer the old app's
  extensions, playlists, login data or download history.
- Android OAuth/custom scheme deep links retained from Mornye can show an app
  chooser if both editions are installed. Select the desired application.
- APK build and Android package checks must succeed; runtime testing is still
  required for signed URL expiry, auto-next, and saving files offline.
