# Unit and Widget Tests

Host tests for Dart code. They run with `flutter test` and in CI. Device
tests live in `integration_test/` (see `integration_test/README.md`).

## Layout

Test files sit directly in `test/`; only shared code has subfolders.

| Path | Contents |
| --- | --- |
| `test/*_test.dart` | All test suites |
| `test/support/` | Shared fakes, fixtures and frozen "legacy" baselines, imported by unit and device tests |
| `test/fixtures/` | Data files: JSON contract fixtures shared with Rust tests, and a TLS certificate for the WebDAV and artwork proxy tests |

### Naming

- When a suite tests one module, name it after that file:
  `lib/services/album_completeness.dart` is tested by
  `test/album_completeness_test.dart`. Roughly half of the suites follow this.
- Otherwise prefix by feature area and describe the behavior, for example
  `download_queue_persistence_test.dart`, `library_partial_scan_test.dart`,
  `mornye_bottom_bar_test.dart`, `network_storage_service_test.dart`. The
  common prefixes are `download_`, `library_`, `mornye_`, `network_`,
  `track_`, `native_` and `extension_`.
- Put a fake used by more than one suite in `test/support/`, not in a copy per
  file.

### Shared Support

| File | Use |
| --- | --- |
| `test/support/fixed_settings.dart` | `FixedSettingsNotifier`: serves fixed `AppSettings` without reading preferences |
| `test/support/sqlite_process_database.dart` | `SqliteProcessDatabase`: a sqflite `Database` backed by real SQLite through a `python3` child process |
| `test/support/app_icon_finder.dart` | `findAppIcon`: finds an icon drawn by `Icon` or `AppIcon` |
| `test/support/library_paging_fixture.dart`, `test/support/library_native_fixture.dart` | Library database fixtures |
| `test/support/re_enrich_settings.dart` | `ReEnrichTestSettings`: default settings that skip the lyrics sync to the backend |
| `test/support/virtual_time.dart` | `VirtualTime`: a timer zone that skips idle time while keeping real microtasks |
| `test/support/music_player_automix_harness.dart` | Shared AutoMix player fakes used by the `music_player_*_test.dart` suites |
| `*_benchmark.dart`, `*_baseline.dart` in `test/support/` | Frozen pre-optimization implementations, compared against production code in unit and device tests |

### Shared Contract Fixtures

Some fixtures are read by Dart and Rust tests, so both sides parse the same
data: `native_library_contract.json`, `native_metadata_parsers.json`,
`native_lyrics_parsers.json`, `native_backup_contract.json` and
`collection_restore_contract.json` in `test/fixtures/`. Change them only
together with both parsers.

## Patterns

### Notifier Subclasses

Many tests replace a Riverpod notifier with a small subclass that overrides
`build()` or one method, then install it with `overrideWith`:

```dart
class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

final container = ProviderContainer(
  overrides: [
    settingsProvider.overrideWith(() => FixedSettingsNotifier()),
    downloadHistoryProvider.overrideWith(_History.new),
  ],
);
```

This is used for `DownloadQueueNotifier`, `DownloadHistoryNotifier`,
`LocalLibraryNotifier`, `LibraryCollectionsNotifier`, `ExtensionNotifier`
and `SettingsNotifier`. Keep the public methods these tests override on the
notifier class itself when refactoring a provider; moving them to a helper
breaks the subclasses.

### Source Contract Tests

Several suites read production source text on purpose. Two of them exist
only for that:

- `test/source_contracts_test.dart` pins text across Dart, Kotlin and Swift:
  - `lib/services/app_state_database.dart`: database version 4 and its
    playback-session migration.
  - `ios/Runner/AppDelegate.swift` and
    `lib/providers/download_queue_provider.dart`: the iOS background download
    task is acquired before work starts, and expiry cancels downloads before
    notifying Dart, which pauses and requeues.
  - `NativeDownloadFinalizer.kt`, `NativeFinalizerHistory.kt`,
    `NativeHistoryStore.kt` and `DownloadServiceSnapshot.kt` (in
    `android/app/src/main/kotlin/com/zarz/mornye/`), with
    `lib/services/history_schema.dart` and
    `lib/providers/download_queue_provider_native_worker.dart`: the native
    worker contract version, the history schema version, columns and
    indexes, and the single progress-delta wait.
  - `android/app/src/test/resources/finalization_quality_cases.tsv`: quality
    labels shared with the Kotlin tests.
- `test/design_system_test.dart` scans every `.dart` file under `lib/`:
  - every `IconButton` has a tooltip;
  - only `app_sliver_header.dart` uses `expandedTitleScale`;
  - only `app_bottom_sheet.dart` draws a drag handle, and only
    `app_theme.dart` sets a modal sheet shape;
  - only `selection_bottom_bar.dart` and `app_menu_button.dart` create an
    `OverlayEntry`;
  - `album_screen.dart`, `playlist_screen.dart`, `local_album_screen.dart`,
    `downloaded_album_screen.dart` and `library_tracks_folder_screen.dart`
    use `CollectionScaffold(`, and `playlist_screen.dart` uses
    `SelectionModeMixin<PlaylistScreen>`;
  - `lib/screens/now_playing_screen.dart` uses `showAppBottomSheet` and no
    `PopupMenuButton`.

Other suites read a production file alongside their behavior tests:
`sqlite_helpers_test.dart` (`lib/services/sqlite_helpers.dart`),
`downloaded_embedded_cover_resolver_test.dart`
(`lib/screens/track_metadata_screen_cover.dart` and
`track_metadata_cards.dart`), `queue_library_refresh_policy_test.dart`
(`lib/screens/queue_tab_collection_items.dart`), and the schema tests
`library_queue_store_test.dart`, `album_completeness_test.dart`,
`album_completeness_query_test.dart` and `replaygain_library_filter_test.dart`
(`CREATE TABLE` text from `lib/services/history_schema.dart` and
`library_schema.dart`). Find them with `rg -n "File\('(lib|android|ios)/" test`.

When a refactor moves pinned code, update the path or the assertion in the
same commit. Never delete these checks.

## Host Tools

| Tool | Needed by | Without it |
| --- | --- | --- |
| `ffmpeg` on `PATH` | `ffmpeg_decryption_output_test.dart`, `automix_effect_renderer_test.dart` | The FFmpeg cases are skipped (`markTestSkipped`) |
| `ffmpeg` and `ffprobe` on `PATH` | `ffmpeg_opus_metadata_test.dart` | The round-trip cases are skipped |
| `python3` | Suites using `SqliteProcessDatabase` | Those suites fail |

`MORNYE_TEST_FFMPEG` selects another FFmpeg binary for
`automix_effect_renderer_test.dart`. The CI workflow
(`.github/workflows/ci.yml`) installs `ffmpeg` before running the tests, so
these cases are not skipped there.

Optional SMB cases are skipped unless their environment is set:
`TEST_SMB=1` (with `scripts/smb2_fixture_server.py`) and `TEST_SMB_GUEST_PORT`
in `network_storage_service_test.dart`; `TEST_SMB_UPLOAD=1` in
`network_smb_upload_test.dart`. `TEST_SMB_PORT` overrides the fixture port.
`network_smb_transport_test.dart` runs against a loopback server with the
native library bundled by dart_smb2's build hook, without a library override.

## Running

```bash
flutter test                                        # everything
flutter test test/album_completeness_test.dart      # one file
flutter test test/download_queue_persistence_test.dart --plain-name 'restores'
flutter test test/source_contracts_test.dart test/design_system_test.dart
```

`--plain-name` filters by a substring of the test name.

`test/library_browse_sqlite_paging_test.dart` pages 1000 albums through real
SQLite. Alone it took about 25 seconds on a development Mac, close to the
default 30-second per-test timeout, so it can time out when the machine is
busy (for example during a full parallel run). Re-run it alone before treating
a failure as real.
