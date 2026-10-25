import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';

import 'support/fixed_settings.dart';

class _Library extends Fake implements LibraryDatabase {
  /// Scanned files by track name.
  final Map<String, String> paths = {};

  @override
  Future<List<Map<String, dynamic>?>> findExistingBatch(
    List<LocalLibraryBatchLookupRequest> requests,
  ) async => [
    for (final request in requests)
      if (paths[request.trackName] case final path?)
        {'filePath': path}
      else
        null,
  ];
}

class _HistoryDatabase extends Fake implements HistoryDatabase {
  final Map<String, String> paths = {};
  final List<List<String>> deletes = [];
  bool failDelete = false;

  @override
  Future<List<Map<String, dynamic>?>> findExistingTracks(
    List<HistoryLookupRequest> requests,
  ) async => [
    for (final request in requests)
      {'id': request.spotifyId, 'filePath': paths[request.spotifyId]},
  ];

  @override
  Future<int> deleteByIds(List<String> ids) async {
    deletes.add(List.of(ids));
    if (failDelete) throw StateError('write failed');
    var deleted = 0;
    for (final id in ids) {
      if (paths.remove(id) != null) deleted++;
    }
    return deleted;
  }
}

class _History extends DownloadHistoryNotifier {
  _History(this.database) : super(database: database);
  final _HistoryDatabase database;

  @override
  DownloadHistoryState build() {
    final items = [
      for (final entry in database.paths.entries)
        DownloadHistoryItem(
          id: entry.key,
          trackName: 'Track ${entry.key}',
          artistName: 'Artist',
          albumName: 'Album',
          filePath: entry.value,
          service: 'example',
          downloadedAt: DateTime(2026),
        ),
    ];
    return DownloadHistoryState(
      items: items,
      lookupItems: items,
      totalCount: items.length,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  List<Track> tracks(int count) => [
    for (var index = 0; index < count; index++)
      Track(
        id: '$index',
        name: 'Track $index',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 180,
      ),
  ];

  ProviderContainer containerFor(
    _HistoryDatabase history, {
    _Library? library,
    bool localLibrary = false,
  }) {
    final container = ProviderContainer(
      overrides: [
        playbackProvider.overrideWith(
          () => PlaybackController(
            library: library ?? _Library(),
            history: history,
          ),
        ),
        downloadHistoryProvider.overrideWith(() => _History(history)),
        settingsProvider.overrideWith(
          () => FixedSettingsNotifier(
            AppSettings(localLibraryEnabled: localLibrary),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('scanned files play only while Local Library is on', () async {
    final library = _Library()..paths['Track 0'] = 'content://library/0';
    final database = _HistoryDatabase()..paths['1'] = 'content://downloads/1';
    messenger.setMockMethodCallHandler(channel, (call) async {
      final uris = List<String>.from(
        jsonDecode((call.arguments as Map)['uris_json'] as String) as List,
      );
      return jsonEncode({for (final uri in uris) uri: 'found'});
    });
    for (final enabled in [false, true]) {
      final paths = await containerFor(
        database,
        library: library,
        localLibrary: enabled,
      ).read(playbackProvider.notifier).resolveTrackFilePaths(tracks(2));
      expect(paths, [
        enabled ? 'content://library/0' : null,
        'content://downloads/1',
      ]);
    }
  });

  test('large SAF queues use bounded batches and deduplicate paths', () async {
    final database = _HistoryDatabase();
    for (var index = 0; index < 131; index++) {
      database.paths['$index'] = 'content://music/${index % 130}';
    }
    final batches = <List<String>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'safExistsBatch');
      final uris = List<String>.from(
        jsonDecode((call.arguments as Map)['uris_json'] as String) as List,
      );
      batches.add(uris);
      return jsonEncode({for (final uri in uris) uri: 'found'});
    });
    final container = containerFor(database);
    final paths = await container
        .read(playbackProvider.notifier)
        .resolveTrackFilePaths(tracks(131));
    expect(paths, database.paths.values);
    expect(batches.map((batch) => batch.length), [64, 64, 2]);
    expect(database.deletes, isEmpty);
  });

  test(
    'confirmed missing rows delete once while unknown SAF rows survive',
    () async {
      final database = _HistoryDatabase()
        ..paths.addAll({
          '0': 'content://music/missing',
          '1': 'content://music/found',
          '2': 'content://music/unknown',
        });
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'safExists') return false;
        return jsonEncode({
          'content://music/missing': 'missing',
          'content://music/found': 'found',
        });
      });
      final container = containerFor(database);
      var revisions = 0;
      container.listen(
        downloadHistoryProvider.select((state) => state.loadedIndexVersion),
        (_, _) => revisions++,
      );
      final paths = await container
          .read(playbackProvider.notifier)
          .resolveTrackFilePaths(tracks(3));
      expect(paths, [null, 'content://music/found', null]);
      expect(calls, ['safExistsBatch', 'safExists']);
      expect(database.deletes, [
        ['0'],
      ]);
      expect(revisions, 1);
      final state = container.read(downloadHistoryProvider);
      expect(state.items.map((item) => item.id), ['1', '2']);
      expect(state.totalCount, 2);
    },
  );

  test(
    'batch deletion deduplicates IDs and a failed write keeps the snapshot',
    () async {
      final database = _HistoryDatabase()..paths['0'] = '/music/track.flac';
      final container = containerFor(database);
      final before = container.read(downloadHistoryProvider);
      database.failDelete = true;
      await container
          .read(downloadHistoryProvider.notifier)
          .removeManyFromHistory(['0', '0']);
      expect(database.deletes, [
        ['0'],
      ]);
      expect(container.read(downloadHistoryProvider), same(before));
      database.failDelete = false;
      await container
          .read(downloadHistoryProvider.notifier)
          .removeManyFromHistory(['0', '0']);
      expect(container.read(downloadHistoryProvider).items, isEmpty);
      expect(container.read(downloadHistoryProvider).loadedIndexVersion, 1);
    },
  );
}
