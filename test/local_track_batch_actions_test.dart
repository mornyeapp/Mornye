import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/local_track_batch_actions.dart';
import 'package:mornye/services/local_track_redownload_service.dart';

LocalLibraryItem item(String id) => LocalLibraryItem(
  id: id,
  trackName: 'Song $id',
  artistName: 'Artist',
  albumName: 'Album',
  filePath: '/music/$id.flac',
  scannedAt: DateTime(2026),
);
void progress(int index, LocalLibraryItem item) {}
bool running() => false;

class _BatchSettings extends SettingsNotifier {
  final phases = <AppSettings>[];
  @override
  AppSettings build() => const AppSettings();
  @override
  Future<void> syncLyricsSettingsToBackend({AppSettings? settings}) async {
    phases.add(settings ?? state);
  }
}

class _BatchLibrary extends LocalLibraryNotifier {
  final refreshed = Completer<void>();
  bool _refreshStarted = false;
  @override
  LocalLibraryState build() => LocalLibraryState();
  @override
  Future<void> scanAllSources({bool forceFullScan = false}) {
    _refreshStarted = true;
    return refreshed.future;
  }
}

void main() {
  test(
    'lyrics-only batch retains provider identity without metadata lookups',
    () async {
      final requests = <Map<String, dynamic>>[];
      final runner = BatchReEnrichRunner(
        beginPhase: () async => const AppSettings(embedLyrics: true),
        sourceTrackIds: {'1': 'provider-a:track-1'},
        reEnrich: (request) async {
          requests.add(request);
          return request['preview_only'] == true
              ? {
                  'method': 'preview',
                  'enriched_metadata': {
                    'spotify_id': request['spotify_id'],
                    'duration_ms': request['duration_ms'],
                  },
                }
              : {'method': 'native', 'lyrics_status': 'updated'};
        },
        writeSidecar:
            ({required audioFilePath, required reEnrichResult}) async {},
      );
      final previews = await runner.preview(
        [item('1')],
        const ReEnrichFieldSelection(
          mode: ReEnrichBatchMode.selectedFields,
          fields: [ReEnrichFields.lyrics],
        ),
        shouldStop: running,
        onProgress: progress,
      );
      expect(previews.single.updateFields, ['lyrics']);
      expect(
        await runner.apply(previews, shouldStop: running, onProgress: progress),
        1,
      );
      expect(requests, hasLength(2));
      expect(
        requests.map((request) => request['spotify_id']),
        everyElement('provider-a:track-1'),
      );
      expect(
        requests.map((request) => request['search_online']),
        everyElement(false),
      );
      expect(
        requests.map((request) => request['track_name']),
        everyElement('Song 1'),
      );
    },
  );

  test(
    'lookup/apply each capture settings once, dispatch native/ffmpeg, and retain partial success',
    () async {
      var phaseCount = 0;
      var currentSettings = const AppSettings(lyricsMode: 'preview');
      final requests = <Map<String, dynamic>>[];
      final sidecars = <String>[];
      final ffmpegModes = <String>[];
      final reported = <String>[];
      final runner = BatchReEnrichRunner(
        beginPhase: () async {
          phaseCount++;
          return currentSettings;
        },
        reEnrich: (request) async {
          requests.add(request);
          if (request['preview_only'] == true) {
            return {
              'method': 'preview',
              'enriched_metadata': {'isrc': 'USABC2600001'},
            };
          }
          // A mid-phase change must not alter the captured apply settings.
          currentSettings = currentSettings.copyWith(
            artistTagMode: 'later',
            lyricsMode: 'later',
          );
          return switch (request['file_path']) {
            '/music/1.flac' => {'method': 'native'},
            '/music/2.flac' => {'method': 'ffmpeg'},
            '/music/3.flac' => throw StateError('write failed'),
            _ => {'method': 'unsupported'},
          };
        },
        writeSidecar:
            ({required audioFilePath, required reEnrichResult}) async {
              sidecars.add(audioFilePath);
            },
        applyFfmpeg:
            ({required item, required result, required artistTagMode}) async {
              ffmpegModes.add(artistTagMode);
              return true;
            },
      );
      final previews = await runner.preview(
        [item('1'), item('2'), item('3'), item('4')],
        const ReEnrichFieldSelection(mode: ReEnrichBatchMode.isrcOnly),
        shouldStop: running,
        onProgress: progress,
      );
      expect(previews.length, 4);
      expect(phaseCount, 1);
      currentSettings = const AppSettings(
        lyricsMode: 'apply',
        artistTagMode: 'split_vorbis',
      );
      final successes = await runner.apply(
        previews,
        shouldStop: running,
        onProgress: progress,
        onResult: (result) => reported.add(result['method'] as String),
      );
      expect(successes, 2);
      expect(reported, ['native', 'ffmpeg']);
      expect(phaseCount, 2);
      expect(sidecars, ['/music/1.flac']);
      expect(ffmpegModes, ['split_vorbis']);
      expect(
        requests.take(4).map((request) => request['lyrics_mode']),
        everyElement('preview'),
      );
      expect(
        requests.skip(4).map((request) => request['lyrics_mode']),
        everyElement('apply'),
      );
      expect(
        requests.skip(4).map((request) => request['search_online']),
        everyElement(false),
      );
    },
  );

  test(
    'manual previews avoid lookups; cancellation before apply performs no writes or phase sync',
    () async {
      var phases = 0;
      var calls = 0;
      final runner = BatchReEnrichRunner(
        beginPhase: () async {
          phases++;
          return const AppSettings();
        },
        reEnrich: (_) async {
          calls++;
          return {};
        },
      );
      final previews = await runner.preview(
        [item('1'), item('2')],
        const ReEnrichFieldSelection(
          mode: ReEnrichBatchMode.manualValues,
          manualValues: {'genre': 'Jazz'},
        ),
        shouldStop: running,
        onProgress: progress,
      );
      expect(previews.length, 2);
      expect(calls, 0);
      expect(
        await runner.apply(
          previews,
          shouldStop: () => true,
          onProgress: progress,
        ),
        0,
      );
      expect(calls, 0);
      expect(phases, 1);
    },
  );

  test(
    'lookup failures do not discard useful previews and cancellation stops subsequent tracks',
    () async {
      var cancelled = false;
      var lookups = 0;
      final runner = BatchReEnrichRunner(
        beginPhase: () async => const AppSettings(),
        reEnrich: (_) async {
          lookups++;
          if (lookups == 1) throw StateError('lookup failed');
          cancelled = true;
          return {
            'method': 'preview',
            'enriched_metadata': {'isrc': 'USABC2600001'},
          };
        },
      );
      final previews = await runner.preview(
        [item('1'), item('2'), item('3')],
        const ReEnrichFieldSelection(mode: ReEnrichBatchMode.isrcOnly),
        shouldStop: () => cancelled,
        onProgress: progress,
      );
      expect(lookups, 2);
      expect(previews.single.item.id, '2');
    },
  );

  test(
    'FLAC matching retains reliable partial results and counts failures when cancelled',
    () async {
      var cancelled = false;
      var calls = 0;
      final result = await matchLocalTracksForFlac(
        [item('1'), item('2'), item('3'), item('4'), item('5')],
        shouldStop: () => cancelled,
        onProgress: progress,
        resolve: (local) async {
          calls++;
          if (local.id == '2') throw StateError('lookup failed');
          if (local.id == '4') cancelled = true;
          return LocalTrackRedownloadResolution(
            match: local.id == '3'
                ? null
                : Track(
                    id: local.id,
                    name: local.trackName,
                    artistName: 'Artist',
                    albumName: 'Album',
                    duration: 1,
                  ),
          );
        },
      );
      expect(calls, 4);
      expect(result.tracks.map((track) => track.id), ['1', '4']);
      expect(result.skipped, 2);
    },
  );

  for (final leaveDuringRefresh in [false, true]) {
    testWidgets(
      'batch completion respects owner lifecycle during refresh: $leaveDuringRefresh',
      (tester) async {
        const channel = MethodChannel('com.zarz.mornye/backend');
        final settings = _BatchSettings();
        final library = _BatchLibrary();
        var active = true;
        final events = <String>[];
        Future<void>? action;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            if (call.method != 'reEnrichFile') {
              throw StateError('unexpected call');
            }
            final request =
                jsonDecode((call.arguments as Map)['request_json'] as String)
                    as Map;
            return request['preview_only'] == true
                ? {
                    'method': 'preview',
                    'enriched_metadata': {'isrc': 'USABC2600001'},
                  }
                : {'method': 'native'};
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(() => settings),
              localLibraryProvider.overrideWith(() => library),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => TextButton(
                    onPressed: () {
                      action = reEnrichLocalTracks(
                        context,
                        ref,
                        [item('1'), item('2')],
                        isActive: () => active,
                        onSelectionHide: () async {
                          events.add('hide');
                        },
                        onSelectionRestore: () => events.add('restore'),
                        onComplete: () => events.add('complete'),
                      );
                    },
                    child: const Text('Start'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Start'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Review changes'));
        await tester.pumpAndSettle();
        expect(settings.phases.length, 1);
        await tester.tap(find.text('Apply changes'));
        await tester.pumpAndSettle();
        expect(library._refreshStarted, isTrue);
        // The result is visible even while an entire-library scan is blocked.
        expect(
          find.text('Metadata re-enriched successfully (2/2)'),
          findsOneWidget,
        );
        expect(settings.phases.length, 2);
        active = !leaveDuringRefresh;
        library.refreshed.complete();
        await tester.pumpAndSettle();
        if (!leaveDuringRefresh) {
          await tester.tap(find.text('OK'));
          await tester.pumpAndSettle();
        }
        await action;
        expect(events, leaveDuringRefresh ? ['hide'] : ['hide', 'complete']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final overlaySelection in [false, true]) {
    testWidgets(
      'cancel restores ${overlaySelection ? 'removed overlay' : 'animated bar'} selection',
      (tester) async {
        final navigatorKey = GlobalKey<NavigatorState>();
        final events = <String>[];
        OverlayEntry? overlay;
        Future<void>? action;
        Widget button(BuildContext context, WidgetRef ref) => TextButton(
          onPressed: () {
            action = reEnrichLocalTracks(
              context,
              ref,
              [item('1')],
              isActive: () => true,
              onSelectionHide: () async {
                events.add('hide');
                if (overlaySelection) {
                  overlay!.remove();
                } else {
                  await Future<void>.delayed(const Duration(milliseconds: 300));
                }
              },
              onSelectionRestore: () => events.add('restore'),
              onComplete: () => events.add('complete'),
            );
          },
          child: const Text('Start'),
        );
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              navigatorKey: navigatorKey,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) {
                    if (!overlaySelection) return button(context, ref);
                    return TextButton(
                      onPressed: () {
                        overlay = OverlayEntry(
                          builder: (context) => Material(
                            child: Center(child: button(context, ref)),
                          ),
                        );
                        Overlay.of(context).insert(overlay!);
                      },
                      child: const Text('Select'),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        if (overlaySelection) {
          await tester.tap(find.text('Select'));
          await tester.pump();
        }
        await tester.tap(find.text('Start'));
        await tester.pumpAndSettle();
        expect(events, ['hide']);
        expect(navigatorKey.currentState!.canPop(), isTrue);
        navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        await action;
        expect(events, ['hide', 'restore']);
        expect(tester.takeException(), isNull);
        overlay?.dispose();
      },
    );
  }
}
