# Local Android audio patch

Based on audioplayers_android 5.3.0 (license retained in LICENSE).

The root `pubspec.yaml` overrides the federated package with this copy
(`dependency_overrides: audioplayers_android: path:
third_party/audioplayers_android`), next to `audioplayers: ^6.8.1`. The
version is the one in this folder's `pubspec.yaml` (5.3.0, unchanged).

## Patches

### Proc descriptor sources

`UrlSource` duplicates app-owned `/proc/self/fd/<fd>` sources and passes the
descriptor directly to MediaPlayer. Android AppFuse proxies, including remote
SAF providers, permit only the original open; reopening the proc path fails.
The caller must hold the original lease until source preparation completes.
Other URLs and file paths retain upstream behavior.

Only local sources (`isLocal`) with a non-negative descriptor number take
this path. The app opens these leases with `safOpenPlaybackLease` (see
`android/README.md` in the app).

### Per-player equalizer

A `setEqualizer` method (argument `configuration`) on the per-player method
channel, handled in AudioplayersPlugin.kt, WrappedPlayer.kt and
MediaPlayerWrapper.kt, with the new player/PlaybackEqualizer.kt. On
Android 9 (API 28) and later it attaches a `DynamicsProcessing` effect to the
player's own nonzero audio session; it never attaches to session zero. It
accepts 5, 10, 15 or 31 bands with gains from -24 to 24 dB. Below API 28,
enabling it fails and disabling it is a no-op. The effect is closed on
`reset` and `release`. `README.md` describes the user-facing behavior; the
Dart caller is `lib/services/music_playback_deck.dart` in the app.

### Rate and start

- `setRate(1.0)` no longer calls `setPlaybackParams` until a different rate
  was applied, so normal playback avoids the time-stretch path. After a
  change, 1.0 is applied again to restore the original speed.
- `start()` always calls `MediaPlayer.start()` after `setRate`, instead of
  relying on `setPlaybackParams` (or, before API 23, `setRate(1.0)`) to start
  output.

### Next player

A `setNextPlayer` method with an optional `nextPlayerId` links two players
for gapless playback. `WrappedPlayer.setNext` requires both to hold a
prepared source and calls `MediaPlayer.setNextMediaPlayer`, so the platform
starts the next player as the current one completes. `onCompletion` then
marks the next player as playing before reporting completion, so a later
`resume` from Dart confirms its state without restarting it. A new source
or a release drops the link; no `nextPlayerId` unlinks it.

### Error state

`WrappedPlayer.onError` now marks the player as not prepared and not playing,
releases audio focus, reports "Android could not open this audio source." or
"Android could not play this audio." (depending on whether the source was
prepared) with the `what` and `extra` codes as details, and returns `true`.
Upstream returns `false`, which makes MediaPlayer also call the completion
listener, so the app's queue advanced after a playback failure.

`MediaPlayerWrapper` retires its callbacks before resetting and releasing the
native player. A late error, prepared, seek or completion callback from a
cancelled network source cannot change the replacement source's shared
`WrappedPlayer` state or report its error as a failure of the new song.

### Build

`android/build.gradle`: Kotlin 1.7.10 to 2.4.21, coroutines 1.6.4 to 1.11.0,
AGP 7.3.1 to 9.4.1, android-junit5 1.7.1.1 to 2.0.2, compileSdk 36 to 37,
`androidx.core:core-ktx` 1.9.0 to 1.19.1, `kotlin-stdlib-jdk7` replaced by
`kotlin-stdlib`, and newer JUnit Jupiter and AssertJ test dependencies.
`CHANGELOG.md` differs only by removed trailing whitespace.

## Changed Files

Compared against the pub.dev 5.3.0 package in the local pub cache:

- `android/build.gradle`
- `android/src/main/kotlin/xyz/luan/audioplayers/AudioplayersPlugin.kt`
- `android/src/main/kotlin/xyz/luan/audioplayers/player/MediaPlayerWrapper.kt`
- `android/src/main/kotlin/xyz/luan/audioplayers/player/PlaybackEqualizer.kt` (new)
- `android/src/main/kotlin/xyz/luan/audioplayers/player/WrappedPlayer.kt`
- `android/src/main/kotlin/xyz/luan/audioplayers/source/UrlSource.kt`
- `README.md` (the "Mornye local changes" section), `CHANGELOG.md`

## Upgrading

1. Fetch both versions: `dart pub cache add audioplayers_android --version 5.3.0`
   and the same for the new version.
2. Record the local patch:
   `diff -ru ~/.pub-cache/hosted/pub.dev/audioplayers_android-5.3.0 third_party/audioplayers_android`.
3. Replace the sources with the new upstream files and re-apply each patch
   above. Check whether upstream now handles proc descriptors, the error
   return value, or starting after `setPlaybackParams`.
4. Keep the Gradle values in step with the app's `android/app/build.gradle.kts`.
5. Test playback from a remote SAF provider, the equalizer, a playback error
   in the middle of a queue, and rate changes back to 1.0.
6. Run `flutter pub get` and update this file.
