# Hi-Fi Listening Mode — Qobuz-inspired UX for Mornye

**Status:** Experimental. This is an independently branded interface using
Mornye's existing code and authenticated extension providers. It is **not**
the official Qobuz application, does not impersonate Qobuz, and does not
include Qobuz trademarks, artwork, credentials, or proprietary source code.

## Implemented in this branch

- **One album, two explicit actions**: primary **Play** streams in Mornye's
  internal player; secondary **Download** queues offline files using Mornye's
  original provider and quality selection.
- **One track, two explicit actions**: ▶ plays now, ↓ saves offline. Track-row
  taps now behave like a music player rather than secretly downloading music.
- Long-press ▶ to select online Hi-Res quality; long-press ↓ to choose
  offline/download quality through Mornye's original selector.
- Online albums and playlists use the existing queue and auto-advance; the
  signed streaming URL for the next track is obtained when needed.
- Previously saved audio is preferred on row taps when present; otherwise
  the app requests an authorized online stream.
- The existing mini-player, background audio, library, search, favorites,
  playlists, file downloads, and in-player quality/bitrate label are retained.
- No hidden downloading for a normal Play action.

## Usage

1. Install the custom ARM64 APK built by GitHub Actions (after a successful run).
2. Enable the **Experimental Qobuz Online 1.2.29** extension for online
   streaming; configure your legitimate music provider account as needed.
3. For offline use, enable a supported download extension/provider in Mornye.
4. Open an album: **Play** starts streaming and **Download** saves tracks.
5. Open a song: tap the title or ▶ to play, and ↓ to save. Long-press the
   relevant button for its independent quality selector.

## Limitations

- This branch does not clone Qobuz's proprietary catalog, account backend,
  recommendation algorithms, purchased music library, lyrics/credits provider,
  or Qobuz Connect. Such capabilities require licensed integrations or
  dedicated provider APIs and are **not** delivered by the mod.
- Offline downloads remain subject to the original source/provider's
  permissions, catalog availability, encryption, codec support, and terms.
- Full-length streaming through the experimental extension remains unverified
  across all releases, network conditions, and quality tiers.
- No new offline file decryption, DRM bypass, or authentication bypass.
- Build completion is not a substitute for device testing of playlist skips,
  signed URL expiry, quality fallback, album downloads, and saved-file playback.
- APK signing identities must remain stable for in-place upgrades.

## Future, separate scope

- An optional unified Listen/Downloads library screen with sorting and filters.
- Native gapless playback, improved album credits and queue editing.
- Consistent Hi-Res status on mini-player and output device diagnostics.
- A distinct, accessible visual design inspired by hi-fi music applications,
  not a pixel-for-pixel copy of any proprietary interface.
