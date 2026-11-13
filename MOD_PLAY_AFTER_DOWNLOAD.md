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

## Experimental direct Qobuz FLAC streaming

The GitHub workflow `.github/workflows/qobuz-online-extension.yml`
builds `Qobuz-Online-Experimental-sflx` from the public Qobuz source in
`mornyeapp/Mornye-Extension` and applies
`scripts/patch_qobuz_online_extension.py`.

1. Build and install the **modified Mornye APK**.
2. Download the `Qobuz-Online-Experimental-sflx` GitHub Actions artifact,
   extract `qobuz-web.sflx`, and install/update it as a local extension in
   Mornye's extension management UI.
3. Enable that experimental Qobuz extension.
4. Select **Play online** on a track; the extension resolves a verified Qobuz
   track match, retrieves the signed HTTPS FLAC URL, and hands the URL to the
   internal Mornye network player without using Mornye's download queue.

This is **experimental and not validated on a device**. The signed URL may
expire or be inaccessible to Android's player because the normal downloader
uses a custom user-agent. Some provider URLs contain previews, despite being
returned by the full-track download resolver; unlike the normal download
pipeline, this mod does not download the file to validate duration. Full
track playback is therefore **not guaranteed**. If direct streaming is
unavailable, the app offers streaming service links instead.

The experimental package reuses existing signed-session authentication and
does not disable or bypass service authentication. Users must comply with
their service's terms and content rights.

## Playback features (experimental v2)

- **Play online** appears inline beside each album and playlist track; the
  collection header has a direct ▶ control for the complete album/playlist.
- Normal tap starts the selected track. A **long press on the inline ▶**
  opens a global stream quality picker and immediately restarts that track
  using the new choice.
- The default quality for new installs is `HI_RES_LOSSLESS` (highest offered
  Qobuz tier). Alternatives: `HI_RES` and `LOSSLESS`. Selection persists
  on the device.
- Album and playlist playback uses one native player queue, with each
  following track's signed HTTPS URL resolved only when that track starts.
  Native skip/next and normal end-of-track transitions can advance the queue.
- The player shows FLAC, provider-reported bit depth and sample rate.
  A file-wide **average encoded kbps** estimate appears only if HTTP HEAD
  exposes a trustworthy Content-Length and the track has a known duration.
  FLAC's instantaneous bitrate varies; unavailable data is not fabricated.
- These are **in-app network streams**; Mornye does not enqueue downloads or
  save completed audio files. Ordinary decoder/network buffering may occur.

### Limitations

Only the experimental Qobuz extension currently supports the resolver in
this fork. Changes must be installed **as a pair**: the new Lite APK and
Qobuz (Experimental Online) v1.2.29 `.sflx`. Actual Android auto-advance,
URL expiration, and average bitrate availability require on-device testing.
The signed stream may stop if authentication or its expiration policy prevents
refreshing the URL.

The Home and search result lists also expose a direct ▶ control, without
opening the track options dialog. The chooser for alternate quality uses a
long press on this control.
