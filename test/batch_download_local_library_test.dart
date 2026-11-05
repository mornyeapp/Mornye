import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/widgets/track_detail_actions.dart';

import 'support/fixed_settings.dart';

const _isrcTrack = Track(
  id: 'catalog-isrc',
  name: 'Catalog title',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
  isrc: 'USEXA2600001',
);
const _nameTrack = Track(
  id: 'catalog-name',
  name: 'Stored song',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
);
const _missingTrack = Track(
  id: 'catalog-missing',
  name: 'Missing song',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
);

class _Database extends Fake implements LibraryDatabase {
  final requests = <List<LocalLibraryBatchLookupRequest>>[];
  Completer<void>? ready;

  @override
  Future<List<Map<String, dynamic>?>> findExistingBatch(
    List<LocalLibraryBatchLookupRequest> tracks,
  ) async {
    requests.add(tracks);
    if (ready != null) await ready!.future;
    return [
      for (final track in tracks)
        if (track.isrc == _isrcTrack.isrc || track.trackName == _nameTrack.name)
          {
            'id': 'local-${track.trackName}',
            'trackName': 'Stored song',
            'artistName': 'Artist',
            'albumName': 'Album',
            'filePath': 'D:/Music Archive/song.flac',
            'scannedAt': '2026-11-01T00:00:00.000',
          }
        else
          null,
    ];
  }
}

class _Library extends LocalLibraryNotifier {
  _Library(LibraryDatabase database) : super(database: database);

  @override
  LocalLibraryState build() => LocalLibraryState(isLoading: true);
}

class _Queue extends DownloadQueueNotifier {
  final added = <Track>[];
  String? playlist;

  @override
  DownloadQueueState build() => const DownloadQueueState();

  @override
  void addMultipleToQueue(
    List<Track> tracks,
    String service, {
    String? qualityOverride,
    String? playlistName,
    List<int?>? playlistPositions,
  }) {
    added.addAll(tracks);
    playlist = playlistName;
  }
}

void main() {
  for (final showIndicator in [false, true]) {
    testWidgets(
      'bulk download checks persisted local files with indicator=$showIndicator',
      (tester) async {
        final database = _Database()..ready = Completer<void>();
        final queue = _Queue();
        await _pump(
          tester,
          database: database,
          queue: queue,
          settings: AppSettings(
            defaultService: 'example-provider',
            askQualityBeforeDownload: false,
            localLibraryEnabled: true,
            localLibraryShowDuplicates: showIndicator,
          ),
        );
        await tester.tap(find.text('Download All'));
        await tester.pump();
        expect(database.requests, hasLength(1));
        expect(queue.added, isEmpty, reason: 'Wait for the persisted lookup');
        database.ready!.complete();
        await tester.pumpAndSettle();
        expect(queue.added, [_missingTrack]);
        expect(queue.playlist, 'Example playlist');
        expect(
          database.requests.single.map((r) => r.isrc).first,
          _isrcTrack.isrc,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('all-local batch skips queueing with empty download history', (
    tester,
  ) async {
    final queue = _Queue();
    await _pump(
      tester,
      database: _Database(),
      queue: queue,
      tracks: const [_isrcTrack, _nameTrack],
    );
    await tester.tap(find.text('Download All'));
    await tester.pumpAndSettle();
    expect(queue.added, isEmpty);
    expect(find.text('0 added, 2 already downloaded'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'local library and download history both exclude existing tracks',
    (tester) async {
      final queue = _Queue();
      await _pump(
        tester,
        database: _Database(),
        queue: queue,
        historyHasMissing: true,
      );
      await tester.tap(find.text('Download All'));
      await tester.pumpAndSettle();
      expect(queue.added, isEmpty);
      expect(find.text('0 added, 3 already downloaded'), findsOneWidget);
    },
  );

  testWidgets('local exclusion still works if the history lookup fails', (
    tester,
  ) async {
    final queue = _Queue();
    await _pump(tester, database: _Database(), queue: queue, failHistory: true);
    await tester.tap(find.text('Download All'));
    await tester.pumpAndSettle();
    expect(queue.added, [_missingTrack]);
  });

  for (final (deduplicate, libraryEnabled) in [
    (false, true),
    (false, false),
    (true, false),
  ]) {
    testWidgets(
      'respects deduplication=$deduplicate and local library=$libraryEnabled',
      (tester) async {
        final database = _Database();
        final queue = _Queue();
        await _pump(
          tester,
          database: database,
          queue: queue,
          settings: AppSettings(
            defaultService: 'example-provider',
            askQualityBeforeDownload: false,
            localLibraryEnabled: libraryEnabled,
            deduplicateDownloads: deduplicate,
          ),
        );
        await tester.tap(find.text('Download All'));
        await tester.pumpAndSettle();
        expect(queue.added, [_isrcTrack, _nameTrack, _missingTrack]);
        expect(database.requests, isEmpty);
      },
    );
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required _Database database,
  required _Queue queue,
  AppSettings settings = const AppSettings(
    defaultService: 'example-provider',
    askQualityBeforeDownload: false,
    localLibraryEnabled: true,
    localLibraryShowDuplicates: false,
  ),
  List<Track> tracks = const [_isrcTrack, _nameTrack, _missingTrack],
  bool historyHasMissing = false,
  bool failHistory = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(() => FixedSettingsNotifier(settings)),
        localLibraryProvider.overrideWith(() => _Library(database)),
        downloadQueueProvider.overrideWith(() => queue),
        downloadHistoryBatchExistsProvider.overrideWith((ref, request) async {
          if (failHistory) throw StateError('History lookup failed');
          return {
            if (historyHasMissing)
              historyLookupForTrack(_missingTrack).lookupKey,
          };
        }),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => queueTracksSkippingDownloaded(
                context,
                ref,
                tracks,
                artistNameForPicker: 'Example playlist',
                playlistName: 'Example playlist',
                resolveDefaultService: false,
              ),
              child: const Text('Download All'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
