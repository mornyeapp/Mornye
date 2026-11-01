import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/history_maintenance.dart';

class _ReloadDatabase implements HistoryDatabase {
  _ReloadDatabase(this.rows);

  final Map<String, DownloadHistoryItem> rows;
  final snapshotRead = Completer<void>();
  final count = Completer<int>();
  bool failDeletion = false;

  @override
  Future<bool> migrateFromSharedPreferences() async => false;

  @override
  Future<int> getCount() => count.future;

  @override
  Future<List<Map<String, dynamic>>> getAll({int? limit, int? offset}) async {
    final snapshot = rows.values.map((item) => item.toJson()).toList();
    snapshotRead.complete();
    return snapshot;
  }

  @override
  Future<List<String>> getPhysicalFileIds(Iterable<String> paths) async => [
    for (final item in rows.values)
      if (paths.contains(item.filePath)) item.id,
  ];

  @override
  Future<int> deleteByIds(List<String> ids) async {
    if (failDeletion) throw StateError('database write failed');
    final previousCount = rows.length;
    rows.removeWhere((id, _) => ids.contains(id));
    return previousCount - rows.length;
  }

  @override
  Future<void> clearAll() async {
    if (failDeletion) throw StateError('database write failed');
    rows.clear();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HistoryNotifier extends DownloadHistoryNotifier {
  _HistoryNotifier(
    HistoryDatabase database,
    Iterable<DownloadHistoryItem> items,
  ) : _initialItems = items.toList(),
      super(database: database);

  final List<DownloadHistoryItem> _initialItems;

  @override
  DownloadHistoryState build() => DownloadHistoryState(
    items: _initialItems,
    totalCount: _initialItems.length,
  );
}

class _MutationDatabase implements HistoryDatabase {
  _MutationDatabase(DownloadHistoryItem item) : rows = {item.id: item};

  final Map<String, DownloadHistoryItem> rows;
  final writeStarted = Completer<void>();
  final releaseWrite = Completer<void>();
  bool failWrite = false;

  @override
  Future<Map<String, dynamic>?> getById(String id) async => rows[id]?.toJson();

  @override
  Future<void> upsert(Map<String, dynamic> json) async {
    if (!writeStarted.isCompleted) writeStarted.complete();
    await releaseWrite.future;
    if (failWrite) throw StateError('database write failed');
    final item = DownloadHistoryItem.fromJson(json);
    rows[item.id] = item;
  }

  @override
  Future<int> deleteByIds(List<String> ids) async {
    final previousCount = rows.length;
    rows.removeWhere((id, _) => ids.contains(id));
    return previousCount - rows.length;
  }

  @override
  Future<int> getCount() async => rows.length;

  @override
  Future<Set<String>> updateExistingBatch(
    List<Map<String, dynamic>> items,
  ) async {
    final changedIds = <String>{};
    for (final json in items) {
      final id = json['id'] as String;
      if (!rows.containsKey(id)) continue;
      rows[id] = DownloadHistoryItem.fromJson(json);
      changedIds.add(id);
    }
    return changedIds;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _InspectionDatabase extends _MutationDatabase {
  _InspectionDatabase(super.item);

  final snapshotRead = Completer<void>();
  final releaseSnapshot = Completer<void>();

  @override
  Future<List<Map<String, dynamic>>> getEntriesWithPathsPage({
    required int limit,
    int offset = 0,
  }) async {
    final snapshot = [
      for (final item in rows.values)
        {
          'id': item.id,
          'file_path': item.filePath,
          'storage_mode': item.storageMode,
          'download_tree_uri': item.downloadTreeUri,
          'saf_relative_dir': item.safRelativeDir,
          'saf_file_name': item.safFileName,
          'downloaded_at': item.downloadedAt.toUtc().toIso8601String(),
        },
    ];
    if (!snapshotRead.isCompleted) snapshotRead.complete();
    await releaseSnapshot.future;
    return snapshot;
  }
}

class _HistoryRows implements DatabaseExecutor {
  final statements = <Map<String, Object?>>[];
  final _keys = _PathKeys();

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    statements.add({
      'sql':
          'UPDATE $table SET ${values.keys.map((key) => '$key = ?').join(', ')} WHERE $where',
      'args': [...values.values, ...?whereArgs],
    });
    return whereArgs!.single == 'kept' ? 1 : 0;
  }

  @override
  Batch batch() => _keys;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PathKeys implements Batch {
  final statements = <Map<String, Object?>>[];

  @override
  void delete(String table, {String? where, List<Object?>? whereArgs}) {
    statements.add({
      'sql': 'DELETE FROM $table WHERE $where',
      'args': whereArgs,
    });
  }

  @override
  void insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    expect(conflictAlgorithm, ConflictAlgorithm.ignore);
    statements.add({
      'sql':
          'INSERT OR IGNORE INTO $table (${values.keys.join(', ')}) VALUES (${values.keys.map((_) => '?').join(', ')})',
      'args': values.values.toList(),
    });
  }

  @override
  Future<List<Object?>> commit({
    bool? exclusive,
    bool? noResult,
    bool? continueOnError,
  }) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DownloadHistoryItem _track(String id) => DownloadHistoryItem(
  id: id,
  trackName: 'Song $id',
  artistName: 'Artist',
  albumName: 'Album',
  filePath: '/music/$id.flac',
  service: 'test',
  downloadedAt: DateTime.utc(2026),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('an older reload cannot restore a deleted physical file', () async {
    final item = _track('removed');
    final db = _ReloadDatabase({item.id: item});
    final container = ProviderContainer(
      overrides: [
        downloadHistoryProvider.overrideWith(
          () => _HistoryNotifier(db, db.rows.values),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(downloadHistoryProvider.notifier);
    final reload = notifier.reloadFromStorage();
    await db.snapshotRead.future;
    final removal = notifier.removePhysicalFiles([item.filePath]);
    await Future<void>.delayed(Duration.zero);
    expect(db.rows.keys, [
      item.id,
    ], reason: 'deletion waits for the older reload');
    db.count.complete(1);
    await Future.wait([reload, removal]);
    final state = container.read(downloadHistoryProvider);
    expect(db.rows, isEmpty);
    expect(state.items, isEmpty);
    expect(state.lookupItems, isEmpty);
    expect(state.totalCount, 0);
  });

  test(
    'failed index deletion is reported and keeps the current state',
    () async {
      final item = _track('retained');
      final db = _ReloadDatabase({item.id: item})..failDeletion = true;
      final container = ProviderContainer(
        overrides: [
          downloadHistoryProvider.overrideWith(
            () => _HistoryNotifier(db, db.rows.values),
          ),
        ],
      );
      addTearDown(container.dispose);
      await expectLater(
        container.read(downloadHistoryProvider.notifier).removePhysicalFiles([
          item.filePath,
        ]),
        throwsStateError,
      );
      expect(db.rows.keys, [item.id]);
      expect(container.read(downloadHistoryProvider).items, [item]);
      expect(container.read(downloadHistoryProvider).totalCount, 1);
    },
  );

  for (final deletion in ['single', 'many', 'clear']) {
    Future<void> remove(DownloadHistoryNotifier notifier, String id) =>
        switch (deletion) {
          'single' => notifier.removeFromHistory(id),
          'many' => notifier.removeManyFromHistory([id]),
          _ => notifier.clearHistory(),
        };

    test('$deletion deletion waits for an older reload', () async {
      final item = _track('removed');
      final db = _ReloadDatabase({item.id: item});
      final container = ProviderContainer(
        overrides: [
          downloadHistoryProvider.overrideWith(
            () => _HistoryNotifier(db, db.rows.values),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(downloadHistoryProvider.notifier);
      final reload = notifier.reloadFromStorage();
      await db.snapshotRead.future;
      final deletion = remove(notifier, item.id);
      await Future<void>.delayed(Duration.zero);
      expect(db.rows.keys, [item.id]);
      db.count.complete(1);
      await Future.wait([reload, deletion]);
      final state = container.read(downloadHistoryProvider);
      expect(db.rows, isEmpty);
      expect(state.items, isEmpty);
      expect(state.lookupItems, isEmpty);
      expect(state.totalCount, 0);
    });

    test('failed $deletion deletion keeps the visible record', () async {
      final item = _track('retained');
      final db = _ReloadDatabase({item.id: item})..failDeletion = true;
      final container = ProviderContainer(
        overrides: [
          downloadHistoryProvider.overrideWith(
            () => _HistoryNotifier(db, db.rows.values),
          ),
        ],
      );
      addTearDown(container.dispose);
      await remove(container.read(downloadHistoryProvider.notifier), item.id);
      final state = container.read(downloadHistoryProvider);
      expect(db.rows.keys, [item.id]);
      expect(state.items, [item]);
      expect(state.totalCount, 1);
      expect(state.loadedIndexVersion, 0);
    });
  }

  for (final audioOnly in [false, true]) {
    Future<void> update(DownloadHistoryNotifier notifier, String id) =>
        audioOnly
        ? notifier.updateAudioMetadataForItem(id: id, quality: '24-bit/96kHz')
        : notifier.updateMetadataForItem(
            id: id,
            trackName: 'Updated',
            artistName: 'Artist',
            albumName: 'Album',
          );

    test('failed metadata save keeps state (audio: $audioOnly)', () async {
      final item = _track('retained');
      final db = _MutationDatabase(item)..failWrite = true;
      db.releaseWrite.complete();
      final container = ProviderContainer(
        overrides: [
          downloadHistoryProvider.overrideWith(
            () => _HistoryNotifier(db, db.rows.values),
          ),
        ],
      );
      addTearDown(container.dispose);
      await expectLater(
        update(container.read(downloadHistoryProvider.notifier), item.id),
        throwsStateError,
      );
      final state = container.read(downloadHistoryProvider);
      expect(db.rows.values, [item]);
      expect(state.items, [item]);
      expect(state.lookupItems, [item]);
      expect(state.loadedIndexVersion, 0);
    });

    test(
      'metadata cannot revive a deleted record (audio: $audioOnly)',
      () async {
        final item = _track('removed');
        final db = _MutationDatabase(item);
        final container = ProviderContainer(
          overrides: [
            downloadHistoryProvider.overrideWith(
              () => _HistoryNotifier(db, db.rows.values),
            ),
          ],
        );
        addTearDown(container.dispose);
        final notifier = container.read(downloadHistoryProvider.notifier);
        final updating = update(notifier, item.id);
        await db.writeStarted.future;
        final deleting = notifier.removeFromHistory(item.id);
        await Future<void>.delayed(Duration.zero);
        expect(db.rows.keys, [item.id]);
        expect(container.read(downloadHistoryProvider).items, [item]);
        db.releaseWrite.complete();
        await Future.wait([updating, deleting]);
        final state = container.read(downloadHistoryProvider);
        expect(db.rows, isEmpty);
        expect(state.items, isEmpty);
        expect(state.lookupItems, isEmpty);
        expect(state.totalCount, 0);
      },
    );
  }

  test('delayed maintenance preserves newer metadata edits', () async {
    final original = _track('kept').copyWith(composer: 'Old composer');
    final db = _MutationDatabase(original);
    db.releaseWrite.complete();
    final container = ProviderContainer(
      overrides: [
        downloadHistoryProvider.overrideWith(
          () => _HistoryNotifier(db, db.rows.values),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(downloadHistoryProvider.notifier);
    await notifier.updateMetadataForItem(
      id: original.id,
      trackName: 'User title',
      artistName: original.artistName,
      albumName: original.albumName,
      composer: 'User composer',
    );
    await notifier.applyMaintenanceUpdates([
      HistoryMaintenanceUpdate(
        original: original,
        updated: original.copyWith(
          quality: '24-bit/96kHz',
          composer: 'Probed composer',
          filePath: '/music/repaired.flac',
        ),
      ),
    ]);
    final stored = db.rows[original.id]!;
    final visible = container.read(downloadHistoryProvider).items.single;
    for (final item in [stored, visible]) {
      expect(item.trackName, 'User title');
      expect(item.composer, 'User composer');
      expect(item.quality, '24-bit/96kHz');
      expect(item.filePath, '/music/repaired.flac');
    }
  });

  test('newer tag scan results survive an older metadata probe', () {
    final original = _track('kept');
    final current = original.copyWith(
      lyricsMetadataScanVersion: 2,
      replayGainMetadataScanVersion: 2,
    );
    final merged = HistoryMaintenanceUpdate(
      original: original,
      updated: original.copyWith(
        hasLyrics: true,
        lyricsMetadataScanVersion: 1,
        hasReplayGain: true,
        replayGainMetadataScanVersion: 1,
      ),
    ).mergeInto(current)!;
    expect(merged.hasLyrics, isFalse);
    expect(merged.hasReplayGain, isFalse);
    expect(merged.lyricsMetadataScanVersion, 2);
    expect(merged.replayGainMetadataScanVersion, 2);
  });

  for (final replacedPath in [false, true]) {
    test('old orphan inspection keeps a replacement ($replacedPath)', () async {
      final original = _track('replaced');
      final db = _InspectionDatabase(original);
      db.releaseWrite.complete();
      final container = ProviderContainer(
        overrides: [
          downloadHistoryProvider.overrideWith(
            () => _HistoryNotifier(db, db.rows.values),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(downloadHistoryProvider.notifier);
      final cleanup = notifier.cleanupOrphanedDownloads();
      await db.snapshotRead.future;
      final replacement = DownloadHistoryItem.fromJson({
        ...original.toJson(),
        'filePath': replacedPath ? '/music/new-file.flac' : original.filePath,
        'downloadedAt': original.downloadedAt
            .add(const Duration(days: 1))
            .toUtc()
            .toIso8601String(),
      });
      await notifier.addToHistory(replacement);
      db.releaseSnapshot.complete();
      expect(await cleanup, 0);
      expect(db.rows[original.id]!.filePath, replacement.filePath);
      expect(
        container.read(downloadHistoryProvider).items.single.filePath,
        replacement.filePath,
      );
      expect(container.read(downloadHistoryProvider).totalCount, 1);
    });
  }

  test(
    'late maintenance cannot recreate deleted rows or their path keys',
    () async {
      final db = _HistoryRows();
      final updated = await updateExistingHistoryRows(db, [
        {
          'id': 'removed',
          'file_path': '/music/removed.flac',
          'quality': '24-bit',
        },
        {'id': 'kept', 'file_path': '/music/kept.opus', 'quality': 'Opus'},
      ]);
      expect(updated, {'kept'});
      final result = await Process.run('python3', [
        '-c',
        r'''
import json, sqlite3, sys
db = sqlite3.connect(':memory:')
db.executescript("""
CREATE TABLE history(id TEXT PRIMARY KEY, file_path TEXT, quality TEXT);
CREATE TABLE history_path_keys(item_id TEXT, path_key TEXT, UNIQUE(item_id,path_key));
INSERT INTO history VALUES ('removed','/music/removed.flac','16-bit'),('kept','/music/kept.flac','16-bit');
INSERT INTO history_path_keys SELECT id,file_path FROM history;
DELETE FROM history WHERE id='removed';
DELETE FROM history_path_keys WHERE item_id='removed';
""")
with db:
    for statement in json.loads(sys.argv[1]):
        db.execute(statement['sql'], statement['args'])
print(json.dumps({
  'rows': list(db.execute('SELECT id,file_path,quality FROM history')),
  'keys': list(db.execute('SELECT item_id,path_key FROM history_path_keys'))
}))
''',
        jsonEncode([...db.statements, ...db._keys.statements]),
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final data = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      expect(data['rows'], [
        ['kept', '/music/kept.opus', 'Opus'],
      ]);
      expect(
        (data['keys'] as List).every((row) => (row as List).first == 'kept'),
        isTrue,
      );
      expect(data['keys'], isNotEmpty);
    },
  );

  test(
    '20 removed downloads stay removed when an old metadata probe finishes',
    () {
      final oldSnapshot = [for (var i = 0; i < 20; i++) _track('$i')];
      final fresh = _track('new-download');
      final current = DownloadHistoryState(
        items: [fresh],
        totalCount: 1,
        loadedIndexVersion: 7,
      );
      final result = mergeHistoryMaintenanceUpdates(current, [
        oldSnapshot.last.copyWith(quality: '24-bit'),
      ], {});
      expect(identical(result, current), isTrue);
      expect(result.items.map((item) => item.id), ['new-download']);
      expect(result.lookupItems.map((item) => item.id), ['new-download']);
      expect(result.totalCount, 1);
    },
  );

  test(
    'live ordering, new downloads and lookup-only items survive maintenance',
    () {
      final kept = _track('kept');
      final fresh = _track('fresh');
      final lookupOnly = _track('lookup');
      final current = DownloadHistoryState(
        items: [fresh, kept],
        lookupItems: [lookupOnly, fresh, kept],
        totalCount: 42,
        loadedIndexVersion: 3,
      );
      final result = mergeHistoryMaintenanceUpdates(
        current,
        [
          kept.copyWith(quality: '24-bit'),
          lookupOnly.copyWith(quality: 'Opus'),
          _track('deleted'),
        ],
        {'kept', 'lookup'},
      );
      expect(result.items.map((item) => item.id), ['fresh', 'kept']);
      expect(result.items.last.quality, '24-bit');
      expect(result.lookupItems.map((item) => item.id), [
        'lookup',
        'fresh',
        'kept',
      ]);
      expect(result.lookupItems.first.quality, 'Opus');
      expect(result.totalCount, 42);
      expect(result.loadedIndexVersion, 4);
    },
  );
}
