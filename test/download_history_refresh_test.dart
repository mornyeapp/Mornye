import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/services/history_database.dart';

/// Rows newest first, as `getAll` orders them.
class _StoredHistory implements HistoryDatabase {
  final rows = <DownloadHistoryItem>[];
  int pageReads = 0;
  Completer<void>? gate;

  @override
  Future<bool> migrateFromSharedPreferences() async => false;

  @override
  Future<int> getCount() async => rows.length;

  @override
  Future<List<Map<String, dynamic>>> getAll({int? limit, int? offset}) async {
    pageReads++;
    final page = rows
        .take(limit ?? rows.length)
        .map((item) => item.toJson())
        .toList();
    await gate?.future;
    return page;
  }

  @override
  Future<Map<String, dynamic>?> getById(String id) async => null;

  @override
  Future<Map<String, dynamic>?> findByFilePath(String filePath) async => null;

  @override
  Future<void> upsert(Map<String, dynamic> json) async {
    final item = DownloadHistoryItem.fromJson(json);
    rows
      ..removeWhere((row) => row.id == item.id)
      ..insert(0, item);
  }

  @override
  Future<List<Map<String, dynamic>>> getEntriesWithPathsPage({
    required int limit,
    int offset = 0,
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _History extends DownloadHistoryNotifier {
  _History(HistoryDatabase database) : super(database: database);

  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

DownloadHistoryItem _item(int index, {String quality = 'FLAC'}) =>
    DownloadHistoryItem(
      id: 'item-$index',
      spotifyId: 'track-$index',
      trackName: 'Song $index',
      artistName: 'Example artist',
      albumName: 'Example album',
      filePath: '/music/song-$index.flac',
      service: 'example-provider',
      quality: quality,
      downloadedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: index)),
    );

Future<
  ({
    ProviderContainer container,
    DownloadHistoryNotifier notifier,
    List<DownloadHistoryState> published,
  })
>
_loadedHistory(_StoredHistory db) async {
  final container = ProviderContainer(
    overrides: [downloadHistoryProvider.overrideWith(() => _History(db))],
  );
  addTearDown(container.dispose);
  final notifier = container.read(downloadHistoryProvider.notifier);
  await notifier.reloadFromStorage();
  final published = <DownloadHistoryState>[];
  final subscription = container.listen(
    downloadHistoryProvider,
    (_, next) => published.add(next),
  );
  addTearDown(subscription.close);
  return (container: container, notifier: notifier, published: published);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('an unchanged refresh notifies nobody and keeps the revision', () async {
    final db = _StoredHistory()
      ..rows.addAll([for (var i = 3; i > 0; i--) _item(i)]);
    final history = await _loadedHistory(db);
    final loaded = history.container.read(downloadHistoryProvider);
    expect(loaded.loadedIndexVersion, 1);
    expect(loaded.items.map((item) => item.id), ['item-3', 'item-2', 'item-1']);

    for (var i = 0; i < 5; i++) {
      await history.notifier.refreshFromStorage();
    }

    expect(db.pageReads, 6);
    expect(history.published, isEmpty);
    expect(
      identical(history.container.read(downloadHistoryProvider), loaded),
      isTrue,
    );
  });

  test('a refresh publishes every real change once', () async {
    final db = _StoredHistory()
      ..rows.addAll([for (var i = 101; i > 0; i--) _item(i)]);
    final history = await _loadedHistory(db);
    int revision() =>
        history.container.read(downloadHistoryProvider).loadedIndexVersion;
    expect(revision(), 1);
    expect(
      history.container.read(downloadHistoryProvider).items,
      hasLength(100),
    );

    // A native download that finished while the app was suspended.
    db.rows.insert(0, _item(102));
    await history.notifier.refreshFromStorage();
    expect(history.published, hasLength(1));
    expect(revision(), 2);
    final added = history.container.read(downloadHistoryProvider);
    expect(added.items.first.id, 'item-102');
    expect(added.lookupItems.first.id, 'item-102');
    expect(added.totalCount, 102);

    // The same row replaced in place with other metadata.
    db.rows[0] = _item(102, quality: 'MP3 320kbps');
    await history.notifier.refreshFromStorage();
    expect(history.published, hasLength(2));
    expect(revision(), 3);
    expect(
      history.container.read(downloadHistoryProvider).items.first.quality,
      'MP3 320kbps',
    );

    // A row outside the loaded page: only the count shows it.
    db.rows.removeLast();
    await history.notifier.refreshFromStorage();
    expect(history.published, hasLength(3));
    expect(revision(), 4);
    expect(history.container.read(downloadHistoryProvider).totalCount, 101);

    db.rows.removeAt(1);
    await history.notifier.refreshFromStorage();
    expect(history.published, hasLength(4));
    expect(revision(), 5);
    expect(
      history.container.read(downloadHistoryProvider).items.map((i) => i.id),
      isNot(contains('item-101')),
    );

    await history.notifier.refreshFromStorage();
    expect(history.published, hasLength(4));
    expect(revision(), 5);
  });

  test('own writes leave nothing for a later refresh to publish', () async {
    final db = _StoredHistory()..rows.add(_item(1));
    final history = await _loadedHistory(db);

    await history.notifier.addToHistory(_item(2));
    // Runs after the coalesced index bump that the write queued.
    await history.notifier.refreshFromStorage();
    await history.notifier.refreshFromStorage();

    expect(db.rows.map((item) => item.id), ['item-2', 'item-1']);
    expect(history.published, hasLength(2), reason: 'write and index bump');
    final state = history.container.read(downloadHistoryProvider);
    expect(state.loadedIndexVersion, 2);
    expect(state.items.map((item) => item.id), ['item-2', 'item-1']);
    expect(state.totalCount, 2);

    // An outside deletion of the row held in memory.
    db.rows.removeAt(0);
    await history.notifier.refreshFromStorage();
    expect(history.published, hasLength(3));
    final refreshed = history.container.read(downloadHistoryProvider);
    expect(refreshed.loadedIndexVersion, 3);
    expect(refreshed.items.map((item) => item.id), ['item-1']);
    expect(refreshed.lookupItems.map((item) => item.id), ['item-1']);
    expect(refreshed.totalCount, 1);
  });

  test('a change to any persisted field publishes', () async {
    final stored = DownloadHistoryItem(
      id: 'item-1',
      trackName: 'Song',
      artistName: 'Artist',
      albumName: 'Album',
      albumArtist: 'Album artist',
      coverUrl: 'https://example.com/cover.jpg',
      filePath: '/music/song.flac',
      storageMode: 'saf',
      downloadTreeUri: 'content://tree/music',
      safRelativeDir: 'Artist/Album',
      safFileName: 'song.flac',
      safRepaired: true,
      service: 'example-provider',
      downloadedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
      isrc: 'USEX12600001',
      spotifyId: 'track-1',
      trackNumber: 1,
      totalTracks: 10,
      discNumber: 1,
      totalDiscs: 2,
      duration: 200,
      releaseDate: '2026-01-01',
      quality: 'FLAC',
      bitDepth: 24,
      sampleRate: 96000,
      bitrate: 2000,
      format: 'flac',
      genre: 'Genre',
      composer: 'Composer',
      label: 'Label',
      copyright: 'Copyright',
      explicit: true,
      hasLyrics: true,
      lyricsMetadataScanVersion: 1,
      hasReplayGain: true,
      replayGainMetadataScanVersion: 1,
    );
    final json = stored.toJson();
    expect(json.values, everyElement(isNotNull));
    final db = _StoredHistory()..rows.add(stored);
    final history = await _loadedHistory(db);

    for (final key in json.keys) {
      final value = json[key];
      final changed = Map<String, dynamic>.of(json)
        ..[key] = switch (value) {
          _ when key == 'downloadedAt' => '2027-01-01T00:00:00.000Z',
          final String text => '$text-2',
          final int number => number + 1,
          final bool flag => !flag,
          _ => fail('unexpected $key: $value'),
        };
      final item = DownloadHistoryItem.fromJson(changed);
      expect(item.toJson()[key], isNot(value), reason: key);
      db.rows[0] = item;
      final published = history.published.length;
      await history.notifier.refreshFromStorage();
      expect(history.published, hasLength(published + 1), reason: key);
      await history.notifier.refreshFromStorage();
      expect(history.published, hasLength(published + 1), reason: key);
      db.rows[0] = stored;
      await history.notifier.refreshFromStorage();
      expect(history.published, hasLength(published + 2), reason: key);
    }
  });

  test('an explicit reload still publishes an unchanged snapshot', () async {
    final db = _StoredHistory()..rows.add(_item(1));
    final history = await _loadedHistory(db);

    await history.notifier.reloadFromStorage();

    expect(history.published, hasLength(1));
    expect(history.published.single.loadedIndexVersion, 2);
  });

  test('a refresh joins a pending reload, never the other way round', () async {
    final db = _StoredHistory()..rows.add(_item(1));
    final history = await _loadedHistory(db);
    final reads = db.pageReads;

    db.gate = Completer<void>();
    final reload = history.notifier.reloadFromStorage();
    final joined = history.notifier.refreshFromStorage();
    expect(identical(joined, reload), isTrue);
    db.gate!.complete();
    await Future.wait([reload, joined]);
    expect(db.pageReads, reads + 1);
    expect(history.published, hasLength(1));

    db.gate = Completer<void>();
    final refresh = history.notifier.refreshFromStorage();
    expect(identical(history.notifier.refreshFromStorage(), refresh), isTrue);
    final explicit = history.notifier.reloadFromStorage();
    expect(identical(explicit, refresh), isFalse);
    db.gate!.complete();
    await Future.wait([refresh, explicit]);
    expect(db.pageReads, reads + 3);
    expect(history.published, hasLength(2));
    expect(
      history.container.read(downloadHistoryProvider).loadedIndexVersion,
      3,
    );
  });

  test('app resume refreshes instead of reloading history', () {
    final source = File('lib/main.dart').readAsStringSync();
    final resumed = RegExp(
      r'if \(state == AppLifecycleState\.resumed\) \{[\s\S]*?\} else if',
    ).firstMatch(source);
    expect(resumed, isNotNull);
    expect(
      resumed!.group(0),
      contains(
        'ref.read(downloadHistoryProvider.notifier).refreshFromStorage()',
      ),
    );
    expect(
      resumed.group(0),
      isNot(contains('downloadHistoryProvider.notifier).reloadFromStorage()')),
    );
  });
}
