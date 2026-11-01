# Integration Tests

Device tests for the native bridges, the Rust backend, real SQLite, real
FFmpeg and on-device rendering. They need an Android emulator or device, or
an iOS simulator. CI formats and analyzes this folder but does not run it.

## Running

Run one suite on a device:

```bash
flutter test integration_test/network_playback_test.dart -d emulator-5554
```

Add `--dart-define=NAME=value` for the gated suites below. Android Gradle
builds the Rust backend automatically; for iOS run
`bash scripts/build_rust_backend.sh ios` and `(cd ios && pod install)` first.

Avoid `flutter test integration_test` for the whole folder: the
aggregate files import other suites, so those suites run twice.

### Performance Driver

Suites that import `integration_test/performance_probe.dart` measure engine
frame timings and store results in the binding's `reportData`. To save the
report on the host, run the suite through
`integration_test/performance_driver.dart`:

```bash
MORNYE_PERFORMANCE_REPORT=build/perf/mornye.json \
  flutter drive --profile --keep-app-running -d emulator-5554 \
  --driver=integration_test/performance_driver.dart \
  --target=integration_test/mornye_performance_test.dart
```

- `MORNYE_PERFORMANCE_REPORT` (host environment variable) selects the
  JSON output; the default is `/tmp/mornye-performance.json`.
  Screenshots are written as PNG files beside it.
- Use `--profile` on Android and `--debug` on iOS simulators.
- Pass `--keep-app-running`; otherwise `flutter drive` uninstalls the app
  when it finishes.
- Use a dedicated emulator for measurements.
- Reports retain the 60 Hz fields and add `frame_budgets` for 60, 90, 120 Hz
  and the display's reported refresh rate. These compare engine phase times
  to each budget; they do not claim the display actually ran at all those rates.
- Run `material_performance_test.dart` through the same driver for Material
  lyrics and artwork transitions with the same fixtures and gestures as the
  Mornye suites, plus seek playback, dragging and paused idle in both styles.
- Use `player_performance_test.dart` to compare lyrics, artwork and seek in
  both styles in a single build.
- Use `pipeline_performance_test.dart` on an isolated macOS profile build
  for Library, download, playback and both lyrics styles with synthetic files and
  local HTTP fixtures. Its stage timelines include persistence and idle
  work; each report states which setup and platform features are excluded.
  Use a separate bundle identifier while another Mornye copy is running.
  Keep the measured window visible and avoid accessibility inspection during
  the run, which can change semantics work and invalidate the test teardown.

### Emulators and Fixtures

- Android emulators reach the host loopback as `10.0.2.2`; iOS simulators use
  `127.0.0.1`.
- SMB suites need a fixture server on the host:
  `python3 scripts/smb3_fixture_server.py` (Samba 4, port 1445 by default) or
  `scripts/smb2_fixture_server.py` (impacket). See `NETWORK_STORAGE.md`.
- `discord_sdk_test.dart` needs the staged Discord Social SDK
  (`third_party/mornye_discord/README.md`).
- `download_queue_access_failure_test.dart` uses SAF storage on Android and
  app storage on iOS.

## Build-Time Defines

| Define | Suite | Effect |
| --- | --- | --- |
| `SMB_TEST_URL` | `network_smb_test.dart` | SMB URL, for example `smb://10.0.2.2:1445/MUSIC/`; skipped when empty |
| `SMB_TEST_URL` | `network_audio_analysis_test.dart` | Analyse a file on SMB; when empty, a local FFmpeg-made FLAC is used |
| `TEST_SMB_ADDRESS` | `network_smb_file_actions_test.dart` | SMB address of `smb2_fixture_server.py --deletion`; skipped when empty |
| `REPLAYGAIN_COMPLETION_BASELINE` | `album_replaygain_completion_test.dart` | Records a baseline run and skips the album-gain assertions |
| `GLASS_PREVIEW` | `mornye_liquid_glass_test.dart` | Holds the Home screen for 25 s for manual viewing |
| `MORNYE_GLASS_FOCUS` | `mornye_rendering_performance_test.dart` | Measures only clarity 0.6 and 1.0 |
| `MORNYE_GLASS_FLAT_BACKDROP` | `mornye_glass_visual_test.dart` | Flat surfaces instead of the generated stripes and grid |
| `DOWNLOAD_GLASS_LEVEL` | `mornye_download_picker_test.dart` | Forces `flat`, `frosted` or `liquid` |
| `DOWNLOAD_BRIGHTNESS` | `mornye_download_picker_test.dart` | Runs only `light` or `dark` |
| `DOWNLOAD_QUALITY_COUNT` | `mornye_download_picker_test.dart` | Number of fixture quality options (default 16) |
| `DOWNLOAD_PRELOAD_GLASS`, `DOWNLOAD_WARMUP_GLASS` (default true), `DOWNLOAD_SHELL_GLASS` | `mornye_download_picker_test.dart` | Glass preload, warm-up and shell glass toggles |
| `DOWNLOAD_TRACE_FIRST_OPEN`, `DOWNLOAD_FIRST_OPEN_ONLY` | `mornye_download_picker_test.dart` | Trace the first opening; stop after it |

## Suite Index

Aggregates (each runs other suites as groups):

| File | Runs |
| --- | --- |
| `collection_batch_write_test.dart` | `playlist_batch_write_test.dart`, `loved_batch_write_test.dart` |
| `mornye_performance_test.dart` | The rendering, screens, artwork and lyrics Mornye performance suites; driver target |
| `material_performance_test.dart` | Material lyrics/artwork and shared seek scenarios in both styles; driver target |
| `player_performance_test.dart` | Shared lyrics, artwork and seek scenarios for Material and Mornye; driver target |
| `pipeline_performance_test.dart` | Library, foreground download, native playback and both lyrics styles with isolated fixtures; macOS profile driver target |
| `remaining_optimization_test.dart` | Collection restore, history staging, library staging, cache maintenance, collection workers, queue workers, backup archive |

Support files (not tests): `performance_driver.dart` (host driver) and
`performance_probe.dart` (`PerformanceTestBinding`, `PerformanceProbe`).

Suites:

| File | Exercises |
| --- | --- |
| `album_replaygain_completion_test.dart` | Full-queue album ReplayGain completion, with the native worker on Android |
| `album_replaygain_readiness_test.dart` | Album readiness checks for large queues |
| `automix_analysis_test.dart` | Native decoding for AutoMix beats; Auto and crossfade playback |
| `automix_effects_test.dart` | Bundled FFmpeg supports every AutoMix transition effect |
| `collection_remove_batch_test.dart` | Removing 2000 tracks from a collection; rollback and retry |
| `desktop_ffmpeg_bundle_test.dart` | macOS only (`-d macos`, after `bash scripts/fetch_desktop_ffmpeg.sh`): the app finds ffmpeg and ffprobe in its bundle, converts a generated tone to FLAC through soxr and to MP3, Opus, AAC and ALAC, and probes the FLAC |
| `desktop_playback_deck_test.dart` | macOS only (`-d macos`): the default deck plays a generated tone, applies an EQ preset and in-app volume, pauses |
| `discord_sdk_test.dart` | Native Discord SDK initialize, stop and restart |
| `download_cancel_dispatch_test.dart` | Native cancel and clear of queued IDs; invalid batches |
| `download_lossless_container_test.dart` | Foreground queue finalizes lossless M4A without provider hints |
| `download_output_container_test.dart` | Foreground queue handles each returned container and extension |
| `download_pipeline_performance_test.dart` | Native loopback downloads through conversion, metadata, durable history and notification; cancel/retry latency and FFmpeg process counts |
| `download_queue_access_failure_test.dart` | A denied output folder fails only the queued requests |
| `download_queue_selection_test.dart` | Enqueuing large track and playlist selections; persistence rollback |
| `download_queue_workers_test.dart` | Queue restore with bounded real sqflite reads |
| `download_retry_dispatch_test.dart` | Resetting idle cancellation flags across chunks |
| `download_scheduler_admission_test.dart` | Scheduler admission of slots from large queues |
| `extension_storage_recovery_test.dart` | Unreadable extension settings; secure storage written with old defaults |
| `library_collections_workers_test.dart` | Large playlist search pages and metadata-only playlist copies |
| `library_paging_performance_test.dart` | Long-scroll Library paging on real SQLite (performance) |
| `library_pipeline_performance_test.dart` | Native SQLite startup, retained Library pages, artwork scrolling, scan ingestion and large collections with isolated fixtures |
| `logs_performance_test.dart` | Production logs scrolling, log bursts and idle in both styles with 500 synthetic entries (performance) |
| `playback_pipeline_performance_test.dart` | Native local and HTTP playback, metadata, seek, rapid source replacement, cancellation and paused idle with private storage |
| `loved_batch_write_test.dart` | Love All add and remove on real SQLite |
| `lyrics_file_access_test.dart` | Embedding, sidecar and export of lyrics outside Downloads |
| `lyrics_timing_test.dart` | Native lyrics parser timing cases |
| `mornye_artwork_performance_test.dart` | Mornye player panel transitions and artwork cache (performance) |
| `mornye_download_picker_test.dart` | Mornye download picker glass and queue feedback (performance) |
| `mornye_glass_visual_test.dart` | Native Mornye glass poses and layers, with screenshots |
| `mornye_liquid_glass_test.dart` | Liquid glass lens and drag behavior |
| `mornye_lyrics_performance_test.dart` | Word-synced lyrics and manual scrolling (performance) |
| `mornye_menu_presentation_test.dart` | Anchored glass menu presentation (performance) |
| `mornye_rendering_performance_test.dart` | Mornye rendering at several glass clarities (performance) |
| `mornye_screens_performance_test.dart` | Mornye screens with 2000-track data (performance) |
| `native_backup_archive_test.dart` | Native ZIP backup routes, old archive formats, compression parity |
| `native_cache_maintenance_test.dart` | Native cover cache budget, pruning and sweep |
| `native_collection_restore_test.dart` | Native collection restore, exact rows, atomic rejection |
| `native_data_jobs_test.dart` | `runNativeDataJob` operations against the production parsers and schema |
| `native_history_snapshot_test.dart` | Native history staging and publication through its owner |
| `native_library_staging_test.dart` | Native library scan staging, publication, retries and cancellation |
| `network_audio_analysis_test.dart` | Network audio cards with real FFmpeg and Rust analysers |
| `network_playback_test.dart` | Native player prepare and seek through the network proxy |
| `network_scan_overhead_test.dart` | Network scan component costs; failed output never published |
| `network_scan_speed_test.dart` | Native WebDAV scan latency overlap |
| `network_smb_file_actions_test.dart` | SMB file deletion keeps siblings (needs a fixture) |
| `network_smb_listing_test.dart` | Preparing large SMB listings |
| `network_smb_test.dart` | SMB3 listing and seek ranges (needs a fixture) |
| `network_webdav_encoding_test.dart` | WebDAV parent URI encodings and encoded album listing |
| `playlist_batch_write_test.dart` | Playlist publication parity, rollback and recovery on real SQLite |
| `playlist_deletion_batch_test.dart` | Deleting many playlists with shared tracks |
| `queue_candidate_selection_test.dart` | Selecting queued candidates by pattern |
| `queue_index_read_test.dart` | Queue selectors and sparse progress after removals |
| `queue_persistence_snapshot_test.dart` | Queue snapshot persistence, rollback and reload |
| `queue_progress_selection_test.dart` | Selecting active items in large queues |
| `queue_removal_test.dart` | Removing completed items; notifier publish and persist |

All files listed here live in `integration_test/`. Shared fixtures and
benchmarks come from `test/support/`.
