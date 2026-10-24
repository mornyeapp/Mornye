# Local audio_service 0.18.19 patch

Source: the published `audio_service` 0.18.19 package (MIT; see LICENSE).
Only runtime sources are vendored. This replaces the same dependency, without
adding another playback engine or native SDK.

The root `pubspec.yaml` uses this copy as a path dependency
(`audio_service: path: third_party/audio_service`), so the version is the one
in this folder's `pubspec.yaml` (0.18.19, unchanged from upstream).
`example/`, `test/`, `analysis_options.yaml` and `darwin/audio_service/.swiftpm`
from the upstream package are not vendored.

## Patches

- Android: accept renderer shell arguments via
  `AudioServicePlugin.setFlutterEngineArguments` before shared engine creation.
  The app supplies its device compatibility flags in `Application.onCreate`;
  fragment shell arguments arrive too late when attaching this cached engine.
  This also covers engine creation by a background media service.
- Android: include custom media actions in MediaStyle notifications on Android
  12 and older. Upstream exposes them only through PlaybackState, which hides
  them on those versions. Keep custom action order and compact indices aligned.
  AudioService.java adds each custom control as a notification action with
  its own PendingIntent. Without an activity class, the intent is a broadcast
  to `MediaButtonReceiver` with the new `ACTION_CUSTOM`
  (`com.ryanheise.audioservice.intent.action.CUSTOM`), which calls
  `AudioService.handleCustomNotificationAction` and so the session's
  `onCustomAction`.
- Android: allow a custom action to supply an explicit in-app activity class
  using the `mornye.activity` extra. Its notification PendingIntent opens the
  output picker directly. These activity controls are excluded from
  PlaybackState custom actions: background launches from media-session binder
  callbacks are blocked on newer Android. Use its native output switcher.
  This is only for app-owned controls, not extension input. No app code
  (Dart, Kotlin or Swift) currently sets `mornye.activity`.
- Android: bound retained browser metadata to 256 recent items with
  `PinnedMetadataCache`. The active queue and current item stay pinned so
  notification, Android Auto and browser lookups survive recent-item eviction.
  Replacing the queue and clearing the service release their pinned metadata.
  To support eviction, the `ServiceListener` queue and play-item callbacks
  take a `MediaDescriptionCompat` instead of `MediaMetadataCompat`.
  AudioServicePlugin.java resolves the metadata from the cache, then from
  the description extras (browsed items carry it under
  `com.ryanheise.audio_service.metadata`), then from Dart `getMediaItem`.
  After `onDestroy`, metadata writes throw instead of repopulating the cache.
  PinnedMetadataCacheTest.java (JUnit, under `android/src/test`) covers it.
- Android: `setMediaItem` and `setQueue` run on one serial `mediaWorker`
  executor per handler interface, instead of a new single-thread executor per
  call. Each call captures the current `AudioService` and fails with "Audio
  service is no longer attached" when the service changed or the interface
  was destroyed; `destroy()` also clears the method handler and shuts the
  executor down.
- Android build (`android/build.gradle.kts`): AGP 9.0.1 to 9.4.1, compileSdk
  35 to 37, `androidx.media:media` 1.7.0 to 1.8.0, `androidx.core:core`
  1.13.1 to 1.19.1, a `junit:junit:4.13.2` test dependency, and
  `-Xlint:deprecation` dropped (androidx.media 1.8 deprecates the whole compat
  media-session API this plugin uses). The Gradle wrapper moves from 8.7 to
  9.8.2. These follow the app's Android toolchain.
- iOS: allow the active music handler to re-publish retained Now Playing
  metadata after restoring its audio session on app lifecycle/video changes.
  Refresh keeps artwork and extrapolates elapsed time without restarting audio;
  it never activates the audio session or revives a stopped service.
  `lib/audio_service.dart` adds `AudioService.refreshNowPlayingInfo()`, which
  calls the new `refreshNowPlayingInfo` method in AudioServicePlugin.m;
  `lib/services/music_player_service.dart` in the app calls it.

Android 13+ still chooses the positions and built-in transport icons in System
UI. We preserve real play/pause/previous/next semantics for headsets, lock screen
and Android Auto instead of disguising them as unrelated custom actions.

## Changed Files

Compared against the pub.dev 0.18.19 package in the local pub cache:

- `android/build.gradle.kts`, `android/gradle/wrapper/gradle-wrapper.properties`
- `android/src/main/java/com/ryanheise/audioservice/AudioService.java`
- `android/src/main/java/com/ryanheise/audioservice/AudioServicePlugin.java`
- `android/src/main/java/com/ryanheise/audioservice/MediaButtonReceiver.java`
- `android/src/main/java/com/ryanheise/audioservice/PinnedMetadataCache.java` (new)
- `android/src/test/java/com/ryanheise/audioservice/PinnedMetadataCacheTest.java` (new)
- `darwin/audio_service/Sources/audio_service/AudioServicePlugin.m`
- `lib/audio_service.dart`

## Upgrading

1. Fetch both versions: `dart pub cache add audio_service --version 0.18.19`
   and the same for the new version.
2. Record the local patch:
   `diff -ru ~/.pub-cache/hosted/pub.dev/audio_service-0.18.19 third_party/audio_service`.
3. Replace the runtime sources with the new upstream files, then re-apply
   each patch above by hand. Check first whether upstream now shows custom
   actions on Android 12 and older, bounds its metadata cache, or reuses its
   media executor.
4. Keep the Gradle values in step with the app's `android/app/build.gradle.kts`.
5. Test notification controls on Android 12 or older and on Android 13+,
   Android Auto browsing, and iOS lock screen controls after a video plays.
6. Run `flutter pub get` so the root `pubspec.lock` records the new version,
   and update this file.
