# Contributing to Mornye

Thank you for helping improve Mornye. Bug reports, focused pull
requests, documentation, and translations are all welcome.

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md) when participating in
the project.

## Before You Start

- Search the [existing issues](https://github.com/mornyeapp/Mornye/issues)
  before opening a new one.
- Use the issue template that best matches the problem.
- Keep pull requests focused. Separate unrelated fixes into separate PRs.
- Never commit credentials, signing files, downloaded media, or generated build
  artifacts.

Translations are managed through the
[Mornye Crowdin project](https://crowdin.com/project/mornye).
The English source strings live in `lib/l10n/arb/app_en.arb`.

## Toolchain

The repository is the source of truth for tool versions:

- Flutter: `.fvmrc`
- Dart: bundled with the pinned Flutter SDK
- Rust: `rust_backend/rust-toolchain.toml` and `rust_backend/Cargo.lock`
- Android SDK, NDK, and Java: `.github/workflows/ci.yml`
- Xcode: required only for iOS builds

[FVM](https://fvm.app/) is recommended. If you do not use FVM, install the
exact Flutter version declared in `.fvmrc` and replace `fvm flutter` with
`flutter` (and `fvm dart` with `dart`) in the commands below.

## Development Setup

1. Fork and clone the repository:

   ```bash
   git clone https://github.com/YOUR_USERNAME/Mornye.git
   cd Mornye
   git remote add upstream https://github.com/mornyeapp/Mornye.git
   ```

2. Install the pinned Flutter SDK and Dart dependencies:

   ```bash
   fvm install
   fvm dart scripts/prepare_flutter_sdk.dart
   fvm flutter pub get
   ```

   The preparation step backports the semantics geometry fix proposed in
   [Flutter #192724](https://github.com/flutter/flutter/pull/192724), which is
   still a draft upstream. It changes one cache lookup in the pinned SDK and
   is safe to run again after restoring an SDK cache. Run it once for every
   fresh Flutter installation before testing or building on any platform.
   Use `--check` to verify an SDK without changing it. Review or retire the
   patch when changing `.fvmrc`; unsupported versions fail before modification.

3. Install Rust with rustup, then run `(cd rust_backend && rustup show)` to
   activate the pinned toolchain. Install Clang/libclang for the native bindings
   (`libclang-dev` on Ubuntu, Xcode command-line tools on macOS). Android Gradle
   builds the Rust libraries and bindings automatically. For a manual host build,
   run `bash scripts/build_rust_backend.sh host`.

4. Run the app:

   ```bash
   fvm flutter run --dart-define="GIT_COMMIT=$(git rev-parse --short=8 HEAD)"
   ```

The About footer shows the short commit supplied through `GIT_COMMIT` at
compile time. Android Gradle and the iOS Flutter build phase supply it
automatically, including direct mobile Flutter builds and Xcode builds.
An explicit `--dart-define` takes precedence. Supply it when building from
a source archive without Git metadata or running desktop Flutter commands
directly; without a revision, the footer shows only the copyright.

## Building the App

### Android APKs

For production releases, stage the official Discord Social SDK with
`bash scripts/setup_discord_sdk.sh /path/to/discord_social_sdk`, then build:

```bash
bash scripts/build_android.sh --production
```

Production mode requires the staged SDK and rejects `--lite`. Release CI uses
this mode and requires Discord on both Android and iOS. Fresh hosted runners
must prepare the SDK before the release checks can pass. See
[Discord build setup](third_party/mornye_discord/README.md#build-setup) for
local staging and the CI decryption secret. Unencrypted SDK files are not
committed to the repository.

For development release APKs, use `bash scripts/build_android.sh`. Full builds
remain the default; add `--lite` to omit the optional Discord SDK while keeping
playback and downloads. Debug builds can also run without the SDK.

To build only ARM64, set `MORNYE_RUST_ANDROID_ABIS=arm64-v8a`. The script uses
the Flutter version in `.fvmrc` and audits the selected split APKs and universal
APK. Android Gradle builds the Rust native artifacts automatically.

### iOS Builds

On macOS, run `bash scripts/build_ios.sh`, then `(cd ios && pod install)` before
opening `ios/Runner.xcworkspace`. The application uses the Rust backend.

For iOS Lite, run CocoaPods and the app build with `MORNYE_DISCORD_SDK=0`.
An existing Pods installation must be regenerated with that setting. Production
release CI requires the staged Discord SDK on iOS as well.

For native iOS codec checks, see the
[FFmpeg capability probe](scripts/README_ios_ffmpeg_capabilities.md).

### Android Crash Symbols

Android release builds, including plain `flutter build apk --release`, keep Dart
debug data in `build/symbols/android/app.<architecture>.symbols` to reduce APK
size. The release script also uses `--obfuscate` to shorten internal Dart names;
when building directly, add `--obfuscate --split-debug-info=build/symbols/android`
for the smaller APK. An explicit `--split-debug-info` path overrides the default;
plain `--analyze-size` builds retain Flutter's normal behavior.

Keep these symbols with the matching APK before another local build replaces
them. Decode a trace with:

```bash
fvm flutter symbolize --debug-info=<symbols-file> --input=crash.txt
```

CI and release jobs retain an `android-symbols-…` artifact with the commit, APK
SHA-256 hashes, Dart symbols, and R8 mapping, identified by run and attempt.
Archive it before its 90-day retention expires and match the reported APK hash
when choosing symbols; equal version numbers do not guarantee a match.

### Last.fm Desktop Integration

Create a Last.fm API account for Mornye at
<https://www.last.fm/api/account/create>. Desktop authorization uses a request
token and a browser approval, so no callback URL is needed. Put its API key
and shared secret in the Git-ignored `.env.lastfm` file:

```dotenv
LASTFM_API_KEY=your_application_key
LASTFM_API_SECRET=your_application_shared_secret
```

Pass `--dart-define-from-file=.env.lastfm` to `fvm flutter run` or a desktop
Flutter build. Desktop CI and release jobs read the repository secrets
`LASTFM_API_KEY` and `LASTFM_API_SECRET`; fork builds omit the integration's
credentials. Never commit real values. Each listener's session is stored
separately in the OS secure storage and is not part of the offline queue.

The controls are in Settings > Playback > Last.fm. Only the local built-in
player is observed, including music a paired device asks it to play. A Link
remote session and catalog previews do not submit listening history.

## Project Boundaries

```text
lib/          Flutter UI, state, models, and platform orchestration
rust_backend/ Production backend, native bindings, and unit tests
android/      Android platform bridge and foreground worker
ios/          iOS platform bridge and application project
test/         Flutter unit and widget tests
integration_test/ Device and emulator tests (including performance drivers)
third_party/  Vendored and patched packages (audio_service, audioplayers forks,
              Discord bridge and encrypted SDK)
assets/       Images, fonts, and bundled resources
docs/         Local documentation and migration archives (gitignored)
scripts/      Reproducible project build helpers
```

Mornye is extension-driven. Extension-specific behavior must be
declared through a generic manifest field, capability, or reusable app API.
Do not add provider-name checks such as `if source == 'provider-name'` to the
main app. The backend should parse and expose the generic declaration, and Dart
should consume that declaration without knowing which extension uses it.

The sections below expand this layout. Folder guides hold the details that are
not repeated here: [android/README.md](android/README.md) (native channel
contract), [rust_backend/README.md](rust_backend/README.md) (crate map),
[test/README.md](test/README.md),
[integration_test/README.md](integration_test/README.md),
[lib/theme/README.md](lib/theme/README.md), and the `MORNYE_PATCHES.md` file
in each `third_party/` fork, for example
[audio_service](third_party/audio_service/MORNYE_PATCHES.md).

## Codebase Map

### Flutter (`lib/`)

App files import each other as `package:mornye/...`. The intended
direction is screens and widgets on top, then controllers, providers, services,
and models and utilities at the bottom. The last column is the current state
found by scanning import lines, including today's exceptions; do not add new
ones.

| Folder | What belongs there | Imports today |
| --- | --- | --- |
| `main.dart`, `app.dart` | Startup, `ProviderScope`, `MornyeApp`, and the `GoRouter` (`/`, `/setup`, `/tutorial`) | Any folder |
| `screens/` | Routes and tab roots; large screens split into `<screen>_*.dart` files; settings pages in `screens/settings/` | Any folder |
| `widgets/` | Reusable widgets and design-system components | Any folder except `screens/`; exceptions: `library_search_results.dart`, `artist_concerts_button.dart`, `mini_player.dart` |
| `controllers/` | UI logic shared by screens and widgets: selection mixins, batch actions, the metadata editor | controllers, widgets, providers, services, models, utils, theme, l10n; `clickable_metadata.dart` also imports `screens/` |
| `providers/` | Riverpod notifiers and state; large notifiers split into `part` files | providers, services, models, utils, constants |
| `services/` | `PlatformBridge`, SQLite stores, the music player, FFmpeg, network storage, notifications | services, models, utils, constants; exceptions: re-export stubs into `providers/` and `controllers/`, and `notification_service.dart` imports `l10n/` |
| `models/` | Data classes and their `json_serializable` output (`*.g.dart`) | models, utils; `library_database_models.dart` imports `sqlite_helpers.dart` from `services/` |
| `utils/` | Small helpers, pure policies, and the settings search catalog | utils, models, constants, l10n; seven files import `services/` (for example `file_access.dart`, `logger.dart`), `saf_download_tree.dart` imports `providers/`, three re-export stubs point into `controllers/` |
| `theme/` | `AppTheme`, `AppTokens`, motion, icons, and the Mornye theme | theme, models; `dynamic_color_wrapper.dart` imports `providers/`, `cover_palette.dart` imports `widgets/` and `services/` |
| `l10n/` | ARB sources in `arb/`, the `context.l10n` extension in `l10n.dart`, and `supported_locales.dart`; `app_localizations*.dart` is generated | utils |
| `constants/` | App info, language choices, `MusicServices` IDs | l10n |
| `routes/` | `now_playing_route.dart` | services, theme |

No provider or service imports `screens/` or `widgets/`. Among services, only
the navigation, orientation, music player, and player widget services import
Flutter's `material.dart` or `widgets.dart`; among providers, the preview
player, extension, download queue, download queue policy and theme providers
do.

### Rust (`rust_backend/crates/`)

Workspace dependencies point only downward:

| Crate | Package | Role | Depends on |
| --- | --- | --- | --- |
| `core/` | `mornye-core` | Shared logic without bindings: tags, lyrics parsing and provider config, metadata, filenames, CUE, covers | none |
| `network/` | `mornye-network` | Shared, cancellable HTTP transport | none |
| `providers/` | `mornye-providers` | Built-in clients: Deezer, MusicBrainz, platform resolver, lyrics | core, network |
| `extensions/` | `mornye-extensions` | Extension JavaScript runtime (rquickjs), host functions, manager, repository, and backend operations such as downloads, library scan, and tags | core, network, providers |
| `mobile/` | `mornye-mobile` | UniFFI API, mostly methods on `ExtensionManager`; built as `cdylib` and `staticlib`; Kotlin package `com.mornye.backend`, Swift module `MornyeBackend` | core, network, extensions |
| `bindgen/` | `mornye-bindgen` | UniFFI bindgen CLI used by `scripts/build_rust_backend.sh` | none |

### Native

Android Kotlin lives in `android/app/src/main/kotlin/com/zarz/mornye/`.
`android/app/build.gradle.kts` adds `android/app/src/rust/kotlin/com/zarz/mornye/`
and the generated bindings to the same source set.

| Files | Role |
| --- | --- |
| `MainActivity.kt` | Backend channel `com.zarz.mornye/backend`, the `nativeBackendMethods` set, and the `when (call.method)` dispatch |
| `MainActivity*Calls.kt`, `MainActivitySaf*.kt`, `MainActivityProgressStreams.kt`, `MainActivitySmallChannels.kt` | `MainActivity.handleX(call, result)` extension functions grouped by area, progress EventChannels, small channels |
| `DownloadService*.kt`, `BackgroundWorkService.kt` | Foreground services: the native download worker and its snapshot, other background work |
| `NativeDownloadFinalizer.kt`, `NativeFinalizer*.kt`, `NativeHistoryStore.kt` | Post-download finalization and the native history write |
| `Saf*.kt` | Storage Access Framework helpers |
| `UsbBitPerfectPlugin.kt`, `Usb*.kt`, `BitPerfectPcm.kt`, `Dsd*.kt`, `HiResPlayback.kt`, `NativeAudio.kt` | Bit-perfect and USB playback (`com.zarz.mornye/usb_pcm`) |
| `PlayerWidget*.kt`, `DownloadQueueWidgetProvider.kt` | Home-screen widgets |
| `CoreBackend.kt`; `SelectedCoreBackend.kt`, `RustCoreBackendApplication.kt`, `NativeDataJobs.kt` | The `CoreBackend` interface and its Rust implementation `RustCoreBackend`, which maps method names to UniFFI calls |

iOS code lives in `ios/Runner/`: `AppDelegate.swift` (backend channel,
`handleMethodCall` and its `osMethods` set, progress EventChannels, background
tasks), `CoreBackend.swift` (Rust calls through `MornyeBackend`,
`invokeApplication`), and smaller bridges such as `PlayerWidgetBridge.swift`
and `ConcertCalendarBridge.swift`. The WidgetKit extension is in
`ios/PlayerWidget/`.

## Where Each Feature Lives

Dart paths are under `lib/`, Rust paths under `rust_backend/crates/`, and
Kotlin files in the Android folders above.

| Feature | Dart | Rust | Native |
| --- | --- | --- | --- |
| Search and URL import | `providers/track_provider.dart` (`TrackNotifier`), `controllers/home_search_logic.dart` | `extensions/src/backend/provider_metadata.rs`, `mobile/src/metadata.rs` | `RustCoreBackendApplication.kt`, `CoreBackend.swift` |
| Download | `providers/download_queue_provider.dart` and its `download_queue_provider_*.dart` parts, `services/download_request_payload.dart` | `extensions/src/backend/downloads.rs`, `mobile/src/manager.rs` | `DownloadService.kt`, `SafDownloadHandler.kt`, `NativeDownloadFinalizer.kt` |
| Queue persistence and history | `services/download_queue_persistence.dart`, `providers/download_history_provider.dart`, `services/history_database.dart`, `services/history_schema.dart` | none | `NativeHistoryStore.kt`, `NativeFinalizerHistory.kt`, `DownloadServiceSnapshot.kt` |
| Local library scan | `providers/local_library_provider.dart` and its `local_library_provider_*.dart` parts, `services/library_database.dart` | `extensions/src/backend/library/scan.rs`, `mobile/src/tags.rs`, `mobile/src/native_library.rs` | `MainActivityLibraryScanCalls.kt`; SAF trees in `MainActivitySafScan.kt` and the `Saf*.kt` files |
| Playback and queue | `providers/playback_provider.dart`, `providers/music_player_provider.dart`, `services/music_player_service.dart` (automix and autoplay parts), `services/music_player_runtime.dart`, `services/music_playback_deck.dart` | AutoMix analysis: `core/src/native_audio_analysis.rs` via `mobile/src/data_jobs.rs` | `UsbBitPerfectPlugin.kt`; forks in `third_party/audio_service`, `third_party/audioplayers_android`, `third_party/audioplayers_darwin` |
| Lyrics | `utils/lyrics_parser.dart`, `utils/lyrics_metadata_helper.dart`, `controllers/player_metadata_controller.dart` | `providers/src/lyrics/`, `core/src/lyrics/`, `extensions/src/lyrics.rs`, `mobile/src/lyrics.rs`, `mobile/src/native_lyrics.rs` | `SelectedCoreBackend.kt`, `CoreBackend.swift` |
| Metadata editing and conversion | `controllers/metadata_editor_controller.dart`, `screens/track_metadata_edit_sheet.dart`, `screens/track_metadata_convert.dart`, `services/ffmpeg_service.dart` (FFmpeg Kit through `services/ffmpeg_support.dart`) | `core/src/tags/`, `extensions/src/backend/tags.rs`, `mobile/src/tags.rs` | `MainActivityMetadataCalls.kt` |
| Extensions and repository | `providers/extension_provider.dart`, `providers/repo_provider.dart`, `models/extension.dart`, `screens/settings/extensions_page.dart`, `screens/repo_tab.dart` | `extensions/src/manifest.rs`, `extensions/src/runtime.rs`, `extensions/src/manager/`, `extensions/src/repository/`, `mobile/src/extensions.rs`, `mobile/src/repository.rs` | `RustCoreBackendApplication.kt`, `ExtensionAuthCallbacks.kt`, `MainActivityExtensionIntents.kt`, `ExtensionCallbackParser.swift` |
| Settings | `providers/settings_provider.dart`, `models/settings.dart`, `screens/settings/`, `utils/settings_search_catalog.dart` | none; values the backend needs are pushed by the `_sync*ToBackend` methods of `SettingsNotifier` | none |
| Statistics and Rewind | `providers/listening_statistics_provider.dart`, `services/listening_statistics.dart`, `providers/listening_rewind_provider.dart`, `services/listening_rewind.dart` | none | none |
| Widgets and notifications | `services/player_widget_service.dart`, `services/notification_service.dart`, `services/playback_notification.dart`, `providers/playback_notification_provider.dart` | none | `PlayerWidgetProvider.kt`, `DownloadQueueWidgetProvider.kt`, notifications in `DownloadService.kt`, `PlayerWidgetBridge.swift`, `ios/PlayerWidget/` |

## Data Flow

### Download (Android native worker)

1. `downloadSingleTrack` (`lib/widgets/track_detail_actions.dart`) calls
   `DownloadQueueNotifier.addToQueue`, which appends a `DownloadItem`, saves
   the queue, and schedules `_processQueue`.
2. `_processQueueSingleFlight` (`lib/providers/download_queue_provider.dart`)
   checks storage and network mode, then calls
   `_tryProcessQueueWithAndroidNativeWorker`
   (`lib/providers/download_queue_provider_native_worker.dart`). It proceeds
   only when `_canUseAndroidNativeWorker` holds: Android,
   `nativeDownloadWorkerEnabled` and `useExtensionProviders` on, an enabled
   extension with a download provider, a download tree URI when SAF storage is
   in use, and no network-folder items.
3. It builds the first request with `_buildAndroidNativeWorkerRequest` and calls
   `PlatformBridge.startNativeDownloadWorker`, which writes requests and
   settings to JSON files and sends their paths. Remaining items follow with
   `appendNativeDownloadWorkerRequests` and
   `finishNativeDownloadWorkerPreparation`.
4. `MainActivity.handleStartNativeDownloadWorker` (`MainActivityServiceCalls.kt`)
   calls `DownloadService.startNativeQueueFromFiles`, which starts the
   foreground service. `onStartCommand` runs `startNativeWorker`, then
   `runNativeWorkerConcurrent` and `processConcurrentNativeRequest` per item.
5. `SafDownloadHandler.handle` calls `CoreBackend.downloadByStrategy`. The Rust
   implementation in `SelectedCoreBackend.kt` calls the UniFFI
   `ExtensionManager.downloadByStrategy` (`mobile/src/manager.rs`), which runs
   `download_by_strategy` in `extensions/src/backend/downloads.rs`.
6. On success, `NativeDownloadFinalizer.finalize` finishes the file and, when
   `save_download_history` is set, writes the row with
   `NativeHistoryStore.upsert`. `writeNativeWorkerSnapshot`
   (`DownloadServiceSnapshot.kt`) publishes item state.
7. `NativeDownloadWorkerMonitor.run` polls
   `PlatformBridge.getNativeDownloadWorkerSnapshot`.
   `_applyAndroidNativeWorkerSnapshot` updates the items and acknowledges them
   with `acknowledgeNativeDownloadWorkerItems`; `_completeAndroidNativeWorkerItem`
   calls `reconcileNativeDownloadHistory` (`lib/services/native_download_history.dart`)
   so `DownloadHistoryNotifier` adopts or reloads the native row.

Without the native worker (iOS, or when the gate fails), items run through
`_downloadSingleItem` (`lib/providers/download_queue_provider_single_item.dart`),
which calls `PlatformBridge.downloadByStrategy`, finalizes in Dart, and records
history with `DownloadHistoryNotifier.addToHistory`. Android handles that call
in `handleDownloadByStrategy`; iOS in `CoreBackend.swift`.

### Playback

1. A screen calls `PlaybackController` (`lib/providers/playback_provider.dart`),
   for example `playTrackList` from `library_tracks_folder_screen.dart`. When
   `playerMode` is not `internal` and the source is not `network://`, it opens
   the file in an external app instead.
2. `MusicPlayerController.playAll` (`lib/providers/music_player_provider.dart`)
   calls `ensureInitialized`, which runs `MusicPlayerRuntime.initialize`
   (`lib/services/music_player_runtime.dart`),
   which creates the `MusicPlayerHandler` through `AudioService.init` from the
   `third_party/audio_service` fork, then calls `setQueueAndPlay`.
3. `MusicPlayerHandler.setQueueAndPlay` (`lib/services/music_player_service.dart`)
   publishes `queue`, then `_playIndex` and `_loadIndex` publish `mediaItem`
   and call `_startResolvedSource`.
4. `_startResolvedSource` calls `MusicPlaybackDeck.setSource` or
   `setNetworkSource` and `resume` (`lib/services/music_playback_deck.dart`).
   The deck wraps an audioplayers `AudioPlayer`, served by the
   `third_party/audioplayers_android` and `third_party/audioplayers_darwin`
   overrides; with USB bit-perfect enabled on Android it first tries to
   prepare the file through `UsbBitPerfectPlugin.kt`.
5. Player events reach `_broadcastState`, which updates `playbackState`.
   `MusicPlayerRuntime.playbackStateEvents`, `mediaItemEvents`, and
   `queueEvents` feed `playbackStateProvider`, `currentMediaItemProvider`, and
   `playQueueProvider`, which the mini player and Now Playing screen watch.

## How to Add Things

### A Setting

- Add the field and its default to `AppSettings` (`lib/models/settings.dart`,
  constructor and `copyWith`), then run `build_runner` (see
  [Generated Files](#generated-files)) to refresh `settings.g.dart`.
- `SettingsNotifier` stores `AppSettings.toJson()` as one JSON string under the
  SharedPreferences key `app_settings`, so the JSON key is the Dart field name.
  Renaming a field changes the stored key. Use a `@JsonKey(fromJson: ...)`
  helper to clamp stored values, as the AutoMix fields do.
- Add a setter to `SettingsNotifier` (`lib/providers/settings_provider.dart`):
  `state = state.copyWith(...)` followed by `_saveSettings()`. If the backend
  needs the value, push it as `_syncLyricsSettingsToBackend` does.
- Rewrites of existing stored values go in `_runMigrations`: bump
  `_currentMigrationVersion` and guard the step with `if (lastMigration < N)`.
- Add the row to the owning page in `lib/screens/settings/` and a
  `SettingsSearchEntry` to the matching list in
  `lib/utils/settings_search_catalog.dart`.
- Add strings to `lib/l10n/arb/app_en.arb` with an `@key` description and read
  them through `context.l10n`.
- Test with the JSON round trip in `test/app_settings_model_test.dart`, setter
  and persistence cases like `test/settings_persistence_test.dart` (a
  `SettingsNotifier` subclass over a fake `SharedPreferences`), and
  `test/settings_search_test.dart`.

### A Screen

- Put it in `lib/screens/` (settings pages in `lib/screens/settings/`) and split
  a large screen into `<screen>_*.dart` files.
- Push it with `Navigator.push` and a `MaterialPageRoute` or `slidePageRoute`
  (`lib/widgets/animation_utils.dart`). Tabs keep their own `Navigator` from
  `_TabNavigator` in `lib/screens/main_shell.dart`; `GoRouter` in `lib/app.dart`
  owns only `/`, `/setup`, and `/tutorial`.
- Use the shared components: `AppSliverHeader`, `showAppBottomSheet` and
  `AppSheetHandle`, `SettingsGroup`, and the `AppTokens` scale.
- A track collection screen uses `CollectionScaffold` and `SelectionModeMixin`,
  and its file name joins the `screens` list in the "every collection screen
  goes through the shared shell" test.
- `test/design_system_test.dart` scans every file in `lib/`: each `IconButton`
  and `AppIconButton` passes `tooltip`, and only allowlisted files may contain
  `expandedTitleScale` (`app_sliver_header.dart`), a hand-built drag handle
  (`app_bottom_sheet.dart`), a modal sheet shape (`app_theme.dart`), or
  `OverlayEntry(` (`selection_bottom_bar.dart`, `app_menu_button.dart`).

### A Platform Channel Method

- Dart: add a static method to `PlatformBridge` in
  `lib/services/platform_bridge.dart` that calls `_channel.invokeMethod` with
  snake_case argument keys; helper classes and codecs can go in a part under
  `lib/services/platform_bridge/`. Decode JSON results with
  `_decodeJsonResultAsync` or `_decodeRequiredMapResultAsync`.
- Rust-backed methods: on Android a name outside `nativeBackendMethods` goes
  through `dispatchBackendApplication` (`SelectedCoreBackend.kt`) to
  `RustCoreBackend.dispatchApplication` (`RustCoreBackendApplication.kt`); add
  the case there. On iOS add it to `invokeApplication` in
  `ios/Runner/CoreBackend.swift`.
- Android-only methods: add the name to `nativeBackendMethods` and a case to
  the `when (call.method)` block in `MainActivity.kt`, calling a
  `MainActivity.handleX` function in the matching `MainActivity*Calls.kt` file.
  `MainActivityRoutingTest.kt` fails when the set and the cases differ.
- iOS-only methods: add the name to `osMethods` in `handleMethodCall`
  (`ios/Runner/AppDelegate.swift`) and handle it there or in `invokeOsMethod`.
  `test/source_contracts_test.dart` pins parts of that file.
- Large JSON: `bridgeJsonResult` in `MainActivity.kt` and `AppDelegate.swift`
  writes a result of 256 KiB or more to a temporary file and returns
  `{"__json_file": "<path>"}`; Dart reads and deletes it. Use it for any result
  that can grow with the library.
- New Rust entry points are `#[uniffi::export]` items in
  `rust_backend/crates/mobile/src/`; the build regenerates bindings (see
  [Development Setup](#development-setup)).
- Dart tests stub `com.zarz.mornye/backend` with `setMockMethodCallHandler`,
  for example `test/extension_initialization_test.dart`.

### A Lyrics Provider

- Provider-specific sources fit an extension first: installed lyrics
  extensions appear in the provider order as `extension:<id>` entries, and
  `InstalledLyricsFetcher` (`rust_backend/crates/extensions/src/lyrics.rs`)
  lists and calls them.
- A built-in provider is a `pub(super) fn` on `BuiltinLyricsClient` in a file
  under `rust_backend/crates/providers/src/lyrics/builtin/` (`apple.rs`,
  `direct.rs`, `proxy.rs`, `ttml.rs`), taking `&SearchRequest` and
  `&Check<'_>` and returning `Result<LyricsResponse, LyricsError>`.
- Add its match arm to `BuiltinLyricsClient::fetch_once`
  (`rust_backend/crates/providers/src/lyrics/builtin.rs`).
- Add the ID to `BUILTIN_PROVIDERS` and `available_providers` in
  `rust_backend/crates/core/src/lyrics/config.rs`; `normalize_provider_order`
  drops unknown IDs. `DEFAULT_PROVIDERS` mirrors the Dart default
  `AppSettings.lyricsProviders`; changing either for existing users needs a
  settings migration (see Migration 13 in `_runMigrations`).
- Dart UI: `_builtInProviderIds` and `_getLyricsProviderInfo` in
  `lib/screens/settings/lyrics_provider_priority_page.dart`,
  `_providerDisplayNames` in `lib/screens/settings/lyrics_settings_page.dart`,
  and a description key like `lyricsProviderLrclibDesc`.
- Tests: `rust_backend/crates/providers/src/lyrics/service/tests.rs`, plus the
  shared usability cases described in [Validation](#validation).

### An Extension-Facing API

- The manifest contract is `rust_backend/crates/extensions/src/manifest.rs`.
  Host functions are registered by `register` in
  `rust_backend/crates/extensions/src/host.rs` and the `*_host.rs` modules; the
  JavaScript side is `rust_backend/crates/extensions/src/prelude.js`.
- Surface results as generic fields, such as `has_download_provider` from
  `rust_backend/crates/extensions/src/manager/info.rs` read by
  `Extension.fromJson` (`lib/models/extension.dart`), never as extension-name
  checks (see [Project Boundaries](#project-boundaries)).
- Treat existing host functions and manifest fields as a contract with
  installed extensions; add new ones rather than changing them.
- Tests: `rust_backend/crates/extensions/src/runtime/tests.rs`,
  `rust_backend/crates/extensions/src/manager/tests.rs`,
  `rust_backend/crates/extensions/tests/`, and the `test/extension_*_test.dart`
  files.
- Keep tests provider-neutral: generic extension IDs, display names,
  namespaces, and example URLs; no copied extension source and no dependency
  on the separate extension repository. Platform names stay only where the
  fixed API, metadata schema, URL parsing, or legacy compatibility needs them.

## Testing Each Layer

Commands are in [Validation](#validation).

| Layer | Location | Notes |
| --- | --- | --- |
| Dart unit and widget | `test/` | [test/README.md](test/README.md); fixtures in `test/fixtures/`, helpers in `test/support/` |
| Device and performance | `integration_test/` | [integration_test/README.md](integration_test/README.md) |
| Kotlin JVM | `android/app/src/test/kotlin/com/zarz/mornye/` | Case tables in `android/app/src/test/resources/` are also read by Dart tests |
| Rust | `tests.rs` modules beside the code, `rust_backend/crates/extensions/tests/` | For example `rust_backend/crates/extensions/src/runtime/tests.rs` |
| iOS | `ios/RunnerTests/` | `RunnerTests.swift` |

## Conventions

- Split large Dart classes with `part` files: the library declares
  `part 'name_area.dart';`, the part starts with `part of 'name.dart';` and
  holds `extension _Area on Name { ... }` or private helper classes. Parts that
  use the notifier's `state` start with
  `// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member`,
  as most `download_queue_provider_*.dart` parts do.
- Public notifier methods stay on the class. More than 120 test classes
  subclass `DownloadQueueNotifier`, `DownloadHistoryNotifier`,
  `LocalLibraryNotifier`, `LibraryCollectionsNotifier`, `ExtensionNotifier`,
  and `SettingsNotifier` to override them; only private members move to parts.
- After moving a file, leave a one-line `export` of the new path at the old one
  while other files import it, as `lib/services/batch_track_actions.dart` does.
- Source-text contracts: `test/source_contracts_test.dart` pins literal text in
  files such as `ios/Runner/AppDelegate.swift`, `NativeDownloadFinalizer.kt`,
  `NativeHistoryStore.kt`, `DownloadServiceSnapshot.kt`, and
  `lib/services/history_schema.dart`; `test/design_system_test.dart` pins file
  names; `MainActivityRoutingTest.kt` reads `MainActivity.kt`. When code moves,
  update the path or assertion in the same commit and never delete the check.
- Keep hand-written files under about 800 lines, split by responsibility.
  Exceptions: generated or frozen tables such as
  `rust_backend/crates/core/src/metadata/musicbrainz/case_data.rs`, the
  settings search catalog `lib/utils/settings_search_catalog.dart`, upstream
  code in `third_party/` and `rust_backend/vendor/`, ARB files, and generated
  `*.g.dart` and localization files.
- Never write the em dash character (U+2014) in code, comments, strings, docs,
  or commit messages; use a comma, colon, parentheses, or a new sentence.
- Commit messages follow [Code and Commit Style](#code-and-commit-style).

## Generated Files

- After changing ARB files, run `fvm flutter gen-l10n` (or `fvm flutter pub get`)
  to refresh the localization sources. They are generated and not committed:
  `.gitignore` carries `/lib/l10n/app_localizations*.dart` ("Generated by
  Flutter from lib/l10n/arb during pub get/build."). Commit only the ARB files.
- Run `fvm dart run build_runner build --delete-conflicting-outputs` only when a
  model or generator input changes, then commit the relevant generated source.
- Do not commit `build/`, `.dart_tool/`, AAR/XCFramework output, IDE state, or
  local research directories.

## Validation

Run checks that cover the code you changed. Before opening a PR, the relevant
commands should pass.

Cross-language lyric usability cases live in
`android/app/src/test/resources/lyrics_usability_cases.tsv`. Dart and Android
tests read the same cases; add a case there when changing
that policy.

Test layers:

| Layer | Location | Command |
| --- | --- | --- |
| Dart unit and widget | `test/` | `fvm flutter test` |
| Device and emulator | `integration_test/` | `fvm flutter test integration_test/<file>` |
| Performance | `integration_test/*_performance_test.dart` | `fvm flutter drive --driver=integration_test/performance_driver.dart --target=integration_test/<file> --keep-app-running` |
| Kotlin JVM | `android/app/src/test/` | `gradle -p android :app:testDebugUnitTest` |
| Rust | `rust_backend/` | `bash scripts/check_rust_backend.sh` |
| Python script tests | `scripts/test_*.py` | `python3 -m unittest discover -s scripts -p 'test_<name>.py'` |

Flutter and Dart:

```bash
fvm dart format --output=none --set-exit-if-changed lib test integration_test
fvm flutter analyze
fvm flutter test
```

Some Dart tests render audio and need `ffmpeg` and `ffprobe` on `PATH`. Set
`MORNYE_TEST_FFMPEG` to an `ffmpeg` binary to override the path used by the
automix renderer test; the other ffmpeg tests read `PATH` directly.

Performance drive runs need a dedicated emulator, `--profile` on Android and
`--debug` on iOS simulators. See the header of
`integration_test/performance_driver.dart`.

Rust formatting, Clippy, and unit tests:

```bash
bash scripts/check_rust_backend.sh
```

Android native code (Gradle builds the Rust artifacts automatically). The
repository has no Gradle wrapper; install the Gradle version CI uses
(`.github/workflows/ci.yml`) and generate the Flutter configuration first:

```bash
fvm flutter pub get
fvm flutter build apk --config-only
gradle -p android :app:compileDebugKotlin :app:testDebugUnitTest
```

For user-facing changes, add or update tests where practical and include
before/after screenshots for UI changes.

## Code and Commit Style

- Follow `analysis_options.yaml`, `.editorconfig`, and existing module patterns.
- Keep user-facing strings in the localization files.
- Prefer small functions and explicit error handling at platform boundaries.
- Use [Conventional Commits](https://www.conventionalcommits.org/), for example:

  ```text
  feat(download): add batch selection
  fix(storage): handle revoked folder access
  docs(contributing): refresh Android setup
  ```

## Pull Requests

1. Create a branch from an up-to-date `main`.
2. Make one focused change and include tests or verification evidence.
3. Complete the pull request template, including any checks that were not run
   and why.
4. Link related issues with `Fixes #123` where appropriate.
5. Respond to review feedback with follow-up commits; maintainers may squash
   commits when merging.

When reporting a crash, include the Mornye version, release channel,
device/OS, exact reproduction steps, storage mode, and exported app logs. For a
cold-start Android crash, `adb logcat -b crash -d` is especially useful.
