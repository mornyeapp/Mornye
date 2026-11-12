# Mornye — Play online experimental mod

This fork replaces the previous **Play after download** action with a
**Play online** action in Mornye's track menu.

## Important difference

**Play online never invokes the download queue and does not save a song file.**

It tries two genuine online mechanisms:

1. If an installed extension explicitly advertises
   `capabilities.fullTrackStreaming: true` and implements the custom action
   `resolvePlaybackStream`, it requests a full-length HTTPS audio URL and
   uses Mornye's existing internal player. The action must return
   `{"url":"https://...","full_track":true}`; it must be immediately
   decodable without extra authorization headers or client decryption.
   Preview clips are rejected. **The official download providers do not
   currently expose this action.**
2. Otherwise, it resolves track links using the existing Mornye
   cross-platform link lookup and presents the available streaming services.
   Selecting a service opens the track in that provider's official app or
   browser, not in VLC. Full-length playback may require a subscription or
   sign-in. When no cross-platform match exists, it falls back to the track's
   own service link.

No part of this action downloads the file via Mornye. The target service
might use its own transient streaming cache; that is controlled by the
service, not by Mornye.

**Not yet implemented:** direct in-app or VLC playback of full-length
FLAC from the currently installed Qobuz, Tidal, Amazon or Deezer download
extensions. Their download APIs do not currently offer a reusable,
authorized full-track HTTP stream URL. Supporting these directly needs a
matching update to those extensions and potentially the Rust backend for
headers, session renewal, segmented media, or encryption handling.

## Build APK

GitHub Actions workflow:
`.github/workflows/mornye-play-android.yml`

Branch:
`feature/play-after-download` (historical branch name retained).

The workflow builds Mornye Lite for Android ARM64. Open **Actions** in the
fork to view runs and download the successful
`Mornye-Online-ARM64-APK` artifact.

Private signing secrets can be configured as described below; otherwise
the APK uses the default Gradle development signing key, not a permanent
release key. Keep a stable key backup before installing future updates:

- `MOD_KEYSTORE_BASE64`
- `MOD_KEYSTORE_PASSWORD`
- `MOD_KEY_ALIAS`
- `MOD_KEY_PASSWORD`

Building an APK doesn't guarantee provider account permissions, reliable
track matching, or successful online playback on every phone. Device
testing is still required.
