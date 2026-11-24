# Native Channel Contract

How the Flutter app talks to the Android and iOS hosts. Channel names, method
names, argument keys and reply keys below are a compatibility contract: Dart,
Kotlin and Swift must change together.

Kotlin sources live in `android/app/src/main/kotlin/com/zarz/mornye/`
(abbreviated `kotlin/` below). Swift sources live in `ios/Runner/`.

## The Backend Channel

All app-level calls use one `MethodChannel` named `com.zarz.mornye/backend`.

| Side | Where |
| --- | --- |
| Dart caller | `lib/services/platform_bridge.dart` (`PlatformBridge`) and its `part` files in `lib/services/platform_bridge/` |
| Android dispatcher | `android/app/src/main/kotlin/com/zarz/mornye/MainActivity.kt`, `configureFlutterEngine` |
| Android handlers | `MainActivity*.kt` extension functions in `kotlin/` (table below) |
| Android Rust route | `android/app/src/rust/kotlin/com/zarz/mornye/SelectedCoreBackend.kt` |
| Routing test | `android/app/src/test/kotlin/com/zarz/mornye/MainActivityRoutingTest.kt` |
| iOS dispatcher | `ios/Runner/AppDelegate.swift`, `handleMethodCall` |

### Routing on Android

`MainActivity` keeps a `nativeBackendMethods` set. A call whose name is in the
set is handled by the backend `when (call.method)` in MainActivity.kt.
Every other name goes to `dispatchBackendApplication` in
SelectedCoreBackend.kt, which runs it on `Dispatchers.IO` through
`coreBackend.invokeApplication` (the Rust backend). That function also handles
`runNativeDataJob`, `cancelNativeDataJob`, and the SAF temp-copy wrapper for
`getLyricsLRC` and `getLyricsLRCWithSource`. A Rust-side name that is not
connected fails with "Rust application method is not connected yet".

Exceptions from either path are returned as `result.error(code, message)`.
The code is `foreground_service_start_not_allowed` when Android refused a
foreground service start, otherwise `ERROR` (`ForegroundServiceStartPolicy`).

`MainActivityRoutingTest` reads MainActivity.kt and fails when the set and
the `when` case labels differ. To add a native method, add the name to both,
put the handler in the matching `MainActivity*.kt` file, and run the JVM tests:

```bash
gradle -p android :app:testDebugUnitTest --tests 'com.zarz.mornye.MainActivityRoutingTest'
```

### Native Method Table

Handler file key: Lifecycle = `android/app/src/main/kotlin/com/zarz/mornye/MainActivityLifecycleCalls.kt`,
Service = `android/app/src/main/kotlin/com/zarz/mornye/MainActivityServiceCalls.kt`,
Scan = `android/app/src/main/kotlin/com/zarz/mornye/MainActivityLibraryScanCalls.kt`,
SAF = `android/app/src/main/kotlin/com/zarz/mornye/MainActivitySafCalls.kt`,
Metadata = `android/app/src/main/kotlin/com/zarz/mornye/MainActivityMetadataCalls.kt`,
Picker = `android/app/src/main/kotlin/com/zarz/mornye/MainActivitySafTreePicker.kt`,
inline = a case body in MainActivity.kt.

Reply key: "JSON text" is a `String` that Dart decodes; "spill" means the
reply may instead be a `__json_file` map (see below); "map", "bool", "string"
and "null" are typed channel values. Arguments are map keys unless noted.

| Method | Purpose | Handler | Reply |
| --- | --- | --- | --- |
| `setScreenAwake` | Adds or clears `FLAG_KEEP_SCREEN_ON` (`enabled`) | Lifecycle | null |
| `getBackendImplementations` | Implementation name for `filename`, `file_metadata`, `extensions`, `downloads` | Lifecycle | map |
| `ensureInstallMarker` | Creates the no-backup install marker; returns `marker_existed`, `marker_created`, `fresh_package_install` | Lifecycle | map |
| `prepareRuntimeState` | Builds runtime state from `data_dir` signed sessions and hands it to the backend | Lifecycle | map `{ready}` |
| `downloadByStrategy` | Runs one download; SAF requests go through `SafDownloadHandler`. The argument is the request JSON string | Service | JSON text |
| `runPostProcessingV2` | Post-processing for `input` and `metadata`; content URIs use a temp copy | Metadata | JSON text |
| `readAudioMetadata` | Audio metadata for `file_path` (SAF read through the URI) | Metadata | JSON text |
| `readFileMetadata` | Tag metadata for `file_path`, `display_name` | Metadata | JSON text |
| `checkHiResAuthenticity` | Hi-Res check for `file_path`, `options_json` | Metadata | JSON text |
| `editFileMetadata` | Writes `metadata_json`; SAF edits a temp copy (see SAF Model) | Metadata | JSON text |
| `reEnrichFile` | Re-enriches from online metadata (`request_json`); may rewrite the LRC sidecar | Metadata | JSON text |
| `setLibraryCoverCacheDir` | Sets the library cover cache directory (`cache_dir`) | Scan | null |
| `scanLibraryFolderToNDJSONFile` | Full scan of `folder_path` into `output_path` | Scan | map `{path, count, error_count}` |
| `scanLibraryFolderIncremental` | Incremental scan of `folder_path` against `existing_files` | Scan | JSON text, spill |
| `scanSafTreeToNDJSONFile` | Full SAF scan of `tree_uri` into `output_path`, with a resume checkpoint | Scan | map `{path, count, error_count}` |
| `scanSafTreeIncremental` | Incremental SAF scan of `tree_uri` against `existing_files` | Scan | JSON text, spill |
| `getLibraryScanProgress` | SAF scan progress while a SAF scan is active, else the backend's | Scan | map |
| `cancelLibraryScan` | Cancels the SAF and backend scans | Scan | null |
| `pauseLibraryScan` | Pauses the SAF and backend scans | Scan | null |
| `resumeLibraryScan` | Resumes the SAF and backend scans | Scan | null |
| `parseCueSheet` | Parses `cue_path`; for SAF, finds the sibling audio document | Metadata | JSON text |
| `pickSafTree` | Opens the folder picker (`for_setup`) and persists the grant | Picker | JSON text or null |
| `readSetupFolderSelection` | Picker result saved for setup by `SetupFolderPickerStore` | inline | string or null |
| `acknowledgeSetupFolderSelection` | Clears the saved result when it equals `payload` | inline | null |
| `processPendingExtensionCallbacks` | Completes queued extension OAuth and session-grant callbacks | inline | null |
| `safExists` | Whether the document at `uri` exists | SAF | bool |
| `safExistsBatch` | `found`, `missing` or `unknown` per URI in `uris_json` | SAF | JSON text |
| `isSafTreeAccessible` | Persisted read and write grant and a writable tree for `tree_uri` | SAF | bool |
| `probeSafTreeReadAccess` | Read probe of `tree_uri`; null when inconclusive | SAF | bool or null |
| `safDelete` | Deletes the document at `uri` | SAF | bool |
| `safStat` | Size, modification time and MIME type of `uri` | SAF | JSON text |
| `resolveSafFile` | Finds `file_name` under `tree_uri` and `relative_dir`, then a bounded tree walk | SAF | JSON text `{uri, relative_dir}` |
| `inspectSafFiles` | Batch lookup for `requests_json`, walking each tree at most once | SAF | JSON text |
| `safCopyToTemp` | Copies `uri` to an app temp file | SAF | string path or null |
| `safOpenPlaybackLease` | Opens a playback descriptor lease for `uri` | SAF | map `{token, path, display_name}` or null |
| `safClosePlaybackLease` | Closes the lease `token` | SAF | null |
| `openContentUri` | `ACTION_VIEW` for `uri`, `mime_type` (error `open_failed`) | SAF | null |
| `shareContentUri` | `ACTION_SEND` chooser for `uri`, `title` (error `share_failed`) | SAF | bool |
| `getSafFileModTimes` | URI to last-modified millis for `uris` | SAF | JSON text |
| `safCreateFromPath` | Creates or reuses a document and copies `src_path` into it | SAF | string URI or null |
| `safCreateIfAbsentFromPath` | Publishes `src_path` only when the name is free | SAF | JSON text or null |
| `safCreateUniqueFromPath` | Publishes under a unique name (`preserved_suffix`) | SAF | JSON text or null |
| `safCreateCollisionAwareFromPath` | Publishes as `clean_file_name` or `variant_file_name` | SAF | JSON text or null |
| `writeTempToSaf` | Copies `temp_path` to `saf_uri`, then deletes the temp file | SAF | JSON text `{success, error}` |
| `writeSafSidecarLrc` | Writes `lyrics` as a `.lrc` beside `saf_uri` | SAF | JSON text `{success, error}` |
| `downloadCoverToFile` | Downloads `cover_url` (`max_dimension`); a temp file when `output_path` is empty | Metadata | JSON text |
| `extractCoverToFile` | Extracts the embedded cover of `audio_path` to `output_path` | Metadata | JSON text |
| `rewriteSplitArtistTags` | Rewrites `artist` and `album_artist` tags | Metadata | JSON text |
| `writeM4AFreeformTags` | Writes M4A freeform tags from `metadata_json` | Metadata | JSON text |
| `ensureAC4Config` | Ensures the AC-4 configuration, using `source_path` | Metadata | JSON text |
| `writeAC4Metadata` | Writes AC-4 tags and `cover_path` | Metadata | JSON text |
| `releaseMemory` | Releases idle backend resources | Lifecycle | null |
| `releaseMemoryUnderPressure` | Releases backend memory under system pressure | Lifecycle | null |
| `startDownloadService` | Starts `DownloadService` (`track_name`, `artist_name`, `queue_count`) | Service | null |
| `stopDownloadService` | Stops `DownloadService` | inline | null |
| `updateDownloadServiceProgress` | Updates the download notification (`progress`, `total`, `status`) | Service | null |
| `isDownloadServiceRunning` | Whether `DownloadService` is running | inline | bool |
| `startBackgroundWork` | Starts `BackgroundWorkService` for `kind` (`title`, `text`) | Service | bool |
| `updateBackgroundWork` | Updates the `kind` notification (`progress`, negative for indeterminate) | Service | null |
| `stopBackgroundWork` | Ends the `kind` work | inline | null |
| `startNativeDownloadWorker` | Starts the native queue from inline JSON or `requests_path`, `settings_path` | Service | null |
| `appendNativeDownloadWorkerRequests` | Appends `requests_path` to run `run_id` | Service | null |
| `finishNativeDownloadWorkerPreparation` | Marks run `run_id` as fully queued | Service | null |
| `acknowledgeNativeDownloadWorkerItems` | Acknowledges `item_ids_json` for run `run_id` | Service | null |
| `pauseNativeDownloadWorker` | Pauses the native queue | inline | null |
| `resumeNativeDownloadWorker` | Resumes the native queue | inline | null |
| `cancelNativeDownloadWorker` | Cancels the native queue | inline | null |
| `getNativeDownloadWorkerSnapshot` | Worker snapshot since `since_state_serial`, decoded off the main thread | Service | map |
| `consumeVerificationNotification` | Returns and clears the pending verification notification payload | Lifecycle | string or null |
| `exitApp` | Disables the back callback and calls `finishAndRemoveTask` | Lifecycle | null |

### Host-to-Dart Events

Native code calls Dart over the same channel. `PlatformBridge` handles them in
`_ensureBackendEventHandler`.

| Method | Sent by | Payload |
| --- | --- | --- |
| `extensionAuthCallbackReceived` | Android | none |
| `extensionSessionGrantCompleted` | Android, iOS | `{extension_id, success}`; iOS only sends `success: true` |
| `extensionVerificationNotificationTapped` | Android | none |
| `setupFolderSelectionChanged` | Android | none |
| `libraryScanError` | Android | `{path, operation, message}` |
| `libraryStorageChanged` | Android | `{action}` (media mount and unmount broadcasts) |
| `iosBackgroundDownloadExpired` | iOS | JSON list of cancelled item IDs |

Session-grant events raised before the channel exists are queued and sent
when the engine is configured, on both platforms.

## The `__json_file` Spill

Large JSON replies are written to a file and the reply becomes
`{"__json_file": "<absolute path>"}`.

- Threshold: 256 KiB of UTF-8 (`LARGE_JSON_RESULT_FILE_THRESHOLD_BYTES` in
  MainActivity.kt and AppDelegate.swift). Keep both in step.
- Android writes a `bridge_json_` file (nanoTime suffix) in `cacheDir`, through
  `bridgeJsonResult` or the streaming `SpillJsonWriter` (which inlines a small
  result and deletes its file). Users: `scanLibraryFolderIncremental`,
  `scanSafTreeIncremental`, and `runNativeDataJob`
  (`android/app/src/rust/kotlin/com/zarz/mornye/NativeDataJobs.kt`).
- iOS writes a `bridge_json_` file (UUID suffix) in the temporary directory. Users:
  `scanLibraryFolderIncremental` and `runNativeDataJob`.
- Dart reads and deletes the file in `_decodeJsonResultAsync`
  (`lib/services/platform_bridge.dart`), decoding it in a background isolate.
- Android also sweeps `bridge_json_`, `saf_`, `native_saf_` and `ms_` files
  older than one hour from `cacheDir` at engine setup, for files orphaned by a
  killed process.

## Progress Streams

Two `EventChannel`s, registered on Android in
`android/app/src/main/kotlin/com/zarz/mornye/MainActivityProgressStreams.kt`
and on iOS in AppDelegate.swift. Dart listens in platform_bridge.dart.

| Channel | Payload | Emission |
| --- | --- | --- |
| `com.zarz.mornye/download_progress_stream` | Backend delta: `seq`, optional `reset`, `items` (by item ID), `removed` | Long poll `waitDelta(seq, 15000 ms)`. Android pauses 250 ms after each delivered change or error. iOS (`ios/Runner/DownloadProgressSubscription.swift`) pauses 0.25 s before every next wait |
| `com.zarz.mornye/library_scan_progress_stream` | `total_files`, `scanned_files`, `current_file`, `error_count`, `progress_pct`, `is_complete` | Polled; sent only when the JSON changed. Android: every 400 ms (`LIBRARY_SCAN_PROGRESS_STREAM_POLLING_INTERVAL_MS`). iOS: every 800 ms (timer in `startLibraryScanProgressStream`) |

The library-scan poll interval differs between the platforms (400 ms versus
800 ms). Whether that is intended is an open question; do not "fix" one side
without checking with the maintainer.

## Other Android Channels

| Channel | Owner |
| --- | --- |
| `com.zarz.mornye/concert_calendar`, `com.zarz.mornye/audio_output` | `android/app/src/main/kotlin/com/zarz/mornye/MainActivitySmallChannels.kt` |
| `com.zarz.mornye/usb_pcm`, `com.zarz.mornye/usb_pcm/events` (EventChannel), `com.zarz.mornye/audio_route` | `android/app/src/main/kotlin/com/zarz/mornye/UsbBitPerfectPlugin.kt` |
| `com.zarz.mornye/media3_player`, `com.zarz.mornye/media3_player/events/<playerId>` (EventChannel) | `android/app/src/main/kotlin/com/zarz/mornye/Media3PlayerPlugin.kt` |
| `com.zarz.mornye/haptics` | `android/app/src/main/kotlin/com/zarz/mornye/MusicHapticsPlugin.kt` |
| `com.zarz.mornye/local_network` | `android/app/src/main/kotlin/com/zarz/mornye/LocalNetworkPlugin.kt` |
| `com.zarz.mornye/player_widget` | `android/app/src/main/kotlin/com/zarz/mornye/PlayerWidgetProvider.kt` |

## Foreground Services

Both services are declared with `foregroundServiceType="dataSync"` in
`android/app/src/main/AndroidManifest.xml` and call `startForeground` with
`FOREGROUND_SERVICE_TYPE_DATA_SYNC` on API 29 and later.

| | `DownloadService` | `BackgroundWorkService` |
| --- | --- | --- |
| File | `android/app/src/main/kotlin/com/zarz/mornye/DownloadService.kt` | `android/app/src/main/kotlin/com/zarz/mornye/BackgroundWorkService.kt` |
| Channels | `download_channel` (progress), `download_alerts_v1` (alerts) | `background_work` |
| Notification IDs | 1001 (foreground), 1 (result), 4 (verification required) | 1002 |
| Wake lock tag | `Mornye:DownloadWakeLock` | `Mornye:BackgroundWorkWakeLock` |
| Wake lock timing | 30 min timeout, renewed on progress updates once 15 min have passed | 30 min timeout, re-acquired by a 15 min timer |
| Started by | `startDownloadService`, `startNativeDownloadWorker` (intent actions `com.zarz.mornye.action.*`) | `startBackgroundWork` for a `kind` (Dart uses `library_scan` and `app_update`) |
| Stopped by | `stopDownloadService`, the native queue finishing or being cancelled, an invalid queue payload, a null restart intent, `onTimeout` | `stopBackgroundWork` for the last active kind, `onTimeout` |

`BackgroundWorkService.start` returns false when Android refuses the start;
the work then continues without the service. `onTimeout` (Android 15 dataSync
limit) stops both services cleanly. The native download worker also writes
its state to native_download_worker_state.json in `filesDir` for
`getNativeDownloadWorkerSnapshot`.

## SAF Model

- Folder grants: `pickSafTree` launches `ACTION_OPEN_DOCUMENT_TREE` with
  persistable read and write flags and calls `takePersistableUriPermission`.
  The reply carries `tree_uri`, `display_name` (a readable path such as
  `/storage/emulated/0/Music`), `volume_id` and `is_removable`. Only one
  picker can be pending (`saf_pending`).
- Setup folder selection: while setup is picking (`for_setup`), the result is
  stored in the `setup_folder_picker` SharedPreferences
  (`SetupFolderPickerStore`) so it survives process death.
  `setupFolderSelectionChanged` tells Dart; Dart reads it with
  `readSetupFolderSelection` and clears it with
  `acknowledgeSetupFolderSelection`.
- Playback leases: `safOpenPlaybackLease` opens a seekable read descriptor and
  returns its `/proc/self/fd/<fd>` path and a `token`. At most four leases stay
  open (the oldest is closed first) and all are closed in `onDestroy`
  (`android/app/src/main/kotlin/com/zarz/mornye/MainActivitySafLeases.kt`).
- Temp copies: metadata calls that need a file path copy the document to a
  temp file, run the backend, and write the result back. For MP3 and Opus the
  backend replies with `method: "ffmpeg"`; Android then returns `temp_path`
  and `saf_uri` and Dart finishes with FFmpeg and `writeTempToSaf`.
- Scanning: the full and incremental scans and their progress state live in
  `android/app/src/main/kotlin/com/zarz/mornye/MainActivitySafScan.kt`. The
  helpers sit beside it: `SafTreeListing.kt` (tree walking and thread pools),
  `SafFileInspection.kt` (resolving download history files inside a tree),
  `SafScanCheckpoint.kt` (resume checkpoints), `SafCueScan.kt` (CUE sheet
  resolution) and `SafBatchQueries.kt` (batch exists and modtime queries).
  URI IO helpers live in `MainActivitySafIo.kt` in the same folder.

## Rust Bridge Files

`android/app/build.gradle.kts` adds `android/app/src/rust/kotlin` as a source
directory, plus the generated UniFFI Kotlin bindings in
`rust_backend/target/bindings/kotlin/` (package `com.mornye.backend`) and
the native libraries in `rust_backend/target/android/jniLibs/`. The
`buildRustBackend` task runs `scripts/build_rust_backend.sh android` before
`preBuild`.

- `android/app/src/rust/kotlin/com/zarz/mornye/SelectedCoreBackend.kt`:
  `createCoreBackend`, `dispatchBackendApplication`, and `RustCoreBackend`,
  the `CoreBackend` implementation over the generated bindings.
- `android/app/src/rust/kotlin/com/zarz/mornye/RustCoreBackendApplication.kt`:
  `dispatchApplication`, the method-name switch behind `invokeApplication`.
- `android/app/src/rust/kotlin/com/zarz/mornye/NativeDataJobs.kt`:
  `runNativeDataJob` and its cancellation registry.

The generated bindings load `libmornye_mobile.so` through JNA
(`Native.register` with the `cdylib_name` from
`rust_backend/crates/mobile/uniffi.toml`). The app depends on
`net.java.dev.jna:jna` for this, and `android/app/proguard-rules.pro` keeps
`com.sun.jna`.

## iOS

`ios/Runner/AppDelegate.swift` registers the same `com.zarz.mornye/backend`
channel and both progress `EventChannel`s on the `mornye-player` engine.
`handleMethodCall` routes in this order:

1. `setScreenAwake` sets `isIdleTimerDisabled`.
2. Names outside the `osMethods` set go to Rust:
   `coreBackend.invokeApplication` in `ios/Runner/CoreBackend.swift`.
   Unknown names fail there with "Rust application method is not connected
   yet" as a `FlutterError` with code `ERROR`. iOS never replies
   `notImplemented` on this channel.
3. `osMethods` names run in `AppDelegate`: background tasks, the folder
   picker and `startWebAuthSession` inline, the rest in `invokeOsMethod`.

Handled in `AppDelegate` on iOS: `getBackendImplementations`,
`rewriteSplitArtistTags`, `writeM4AFreeformTags`, `ensureAC4Config`,
`writeAC4Metadata`, `downloadCoverToFile`, `extractCoverToFile`,
`reEnrichFile`, `checkHiResAuthenticity`, `releaseMemory`,
`releaseMemoryUnderPressure`, `setLibraryCoverCacheDir`,
`scanLibraryFolderToNDJSONFile`, `scanLibraryFolderIncremental`,
`getLibraryScanProgress`, `cancelLibraryScan`, `pauseLibraryScan`,
`resumeLibraryScan`, `parseCueSheet`, `startBackgroundWork`,
`updateBackgroundWork` (a no-op) and `stopBackgroundWork`.

Android-native names that iOS sends to Rust: `downloadByStrategy`,
`readFileMetadata`, `editFileMetadata`, `readAudioMetadata`,
`runPostProcessingV2`.

Android-native names with no iOS implementation (they reach Rust and fail):
every `saf*` method, `pickSafTree`, `isSafTreeAccessible`,
`probeSafTreeReadAccess`, `resolveSafFile`, `inspectSafFiles`,
`getSafFileModTimes`, `scanSafTreeToNDJSONFile`, `scanSafTreeIncremental`,
`openContentUri`, `shareContentUri`, `writeTempToSaf`, `writeSafSidecarLrc`,
`readSetupFolderSelection`, `acknowledgeSetupFolderSelection`,
`ensureInstallMarker`, `prepareRuntimeState`,
`processPendingExtensionCallbacks`, `consumeVerificationNotification`,
`exitApp`, the download service methods and the native download worker
methods. Dart must guard these with `Platform.isAndroid`.

iOS-only names: `beginBackgroundDownloadTask`, `endBackgroundDownloadTask`
(a `UIApplication` background task while downloads run), `pickIosDirectory`
(returns `{path, bookmark}`), `startAccessingIosBookmark` (returns
`{path, token}`, a security-scoped lease), `stopAccessingIosBookmark`
(`token`) and `startWebAuthSession` (`url`, `callback_scheme`).

On iOS `startBackgroundWork` begins a `UIApplication` background task per
`kind` and returns true; when a `library_scan` task expires, the scan is
cancelled. Other iOS channels: `ios/Runner/ConcertCalendarBridge.swift`,
`ios/Runner/PlayerWidgetBridge.swift`, `ios/Runner/MusicHaptics.swift`, and
`ios/Runner/AudioOutputView.swift` (`playback_notification`, `audio_route`,
and the per-view `com.zarz.mornye/audio_output/<id>`).
