import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/history_maintenance.dart';
import 'package:mornye/services/history_row_mapper.dart';
import 'package:mornye/services/history_schema.dart';
import 'package:mornye/services/library_queue_store.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/library_schema.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/path_match_keys.dart';

import 'support/sqlite_process_database.dart';

const _oldContainer = '/var/mobile/Containers/Data/Application/AAAA';
const _currentContainer = '/var/mobile/Containers/Data/Application/BBBB';
const _oldPath = '$_oldContainer/Documents/Music/Album/Song.flac';
const _currentPath = '$_currentContainer/Documents/Music/Album/Song.flac';

Map<String, dynamic> _download(String id, String path) => DownloadHistoryItem(
  id: id,
  trackName: 'Song',
  artistName: 'Artist',
  albumName: 'Album',
  filePath: path,
  service: 'example',
  downloadedAt: DateTime.utc(2026),
).toJson();

Future<void> _replaceHistory(
  Database db,
  Iterable<Map<String, dynamic>> items,
) async {
  final batch = db.batch()
    ..delete('history_path_keys')
    ..delete('history');
  for (final row in items.map(HistoryRowMapper.jsonToDbRow)) {
    batch.insert('history', row);
    sqlite.putPathKeysInBatch(
      batch,
      'history_path_keys',
      row['id'] as String,
      row['file_path'] as String?,
    );
  }
  await batch.commit(noResult: true);
}

// Supply iOS storage policy on the host while exercising the real notifier,
// codecs, migration, SQLite schemas, and Library queries.
class _IosRestoreDatabase implements HistoryDatabase {
  _IosRestoreDatabase(this.rows, this.prefs);

  final Database rows;
  final SharedPreferences prefs;
  final forcedMigrations = <bool>[];
  int _restoredCount = 0;

  @override
  Future<bool> migrateIosContainerPaths({bool force = false}) async {
    forcedMigrations.add(force);
    final count = await migrateIosHistoryPaths(
      rows,
      prefs,
      containerPath: _currentContainer,
      force: force,
    );
    return count != null && count > 0;
  }

  @override
  Future<bool> migrateFromSharedPreferences() async => false;

  Future<void> restore(Map<String, dynamic> item) async {
    await _replaceHistory(rows, [item]);
    _restoredCount = 1;
  }

  @override
  Future<int> getCount() async => _restoredCount;

  @override
  Future<List<Map<String, dynamic>>> getAll({
    int? limit,
    int? offset,
  }) async => [
    for (final row in await rows.query('history', limit: limit, offset: offset))
      HistoryRowMapper.dbRowToJson(row, row['file_path'] as String),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _History extends DownloadHistoryNotifier {
  _History(HistoryDatabase db) : super(database: db);

  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late SqliteProcessDatabase history;
  late SqliteProcessDatabase library;
  late SharedPreferences prefs;
  late LibraryQueueStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ios-history-restore-');
    history = await SqliteProcessDatabase.open(path: '${root.path}/history.db');
    await HistorySchema.create(history, HistoryDatabase.schemaVersion);
    library = await SqliteProcessDatabase.open();
    await LibrarySchema.create(library, LibrarySchema.version);
    await library.execute('ATTACH DATABASE ? AS history_db', [history.path]);
    store = LibraryQueueStore(library, historyFts: false, localFts: false);
    SharedPreferences.setMockInitialValues({
      'ios_last_container_path': _currentContainer,
    });
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() async {
    await library.close();
    await history.close();
    await root.delete(recursive: true);
  });

  Future<void> addLocal(String id, String path) async {
    await library.insert(
      'library',
      LibraryRowMapper.encode(
        LocalLibraryItem(
          id: id,
          trackName: 'Song',
          artistName: 'Artist',
          albumName: 'Album',
          filePath: path,
          scannedAt: DateTime.utc(2026),
        ).toJson(),
      ),
    );
    final batch = library.batch();
    sqlite.putPathKeysInBatch(batch, 'library_path_keys', id, path);
    await batch.commit(noResult: true);
  }

  test(
    'startup repairs a previous restore despite an unchanged container',
    () async {
      await _replaceHistory(history, [_download('download', _oldPath)]);
      await addLocal('scanned', _currentPath);
      const request = QueueLibraryDbQuery();
      expect((await store.trackPage(request)).rows, hasLength(2));
      expect(
        await sqlite.findPhysicalFileRowIds(history, 'history', [_currentPath]),
        isEmpty,
      );

      expect(
        await migrateIosHistoryPaths(
          history,
          prefs,
          containerPath: _currentContainer,
        ),
        1,
      );
      final rows = (await store.trackPage(request)).rows;
      expect(rows, hasLength(1));
      expect(rows.single['source'], 'downloaded');
      expect((rows.single['item'] as Map)['filePath'], _currentPath);
      expect((await store.counts(request)).allTrackCount, 1);
      expect(
        (await store.trackPage(
          const QueueLibraryDbQuery(source: 'local'),
        )).rows,
        isEmpty,
      );
      final keys = (await history.query(
        'history_path_keys',
      )).map((row) => row['path_key']).toSet();
      expect(keys, buildPathMatchKeys(_currentPath));
      expect(keys.intersection(buildPathMatchKeys(_oldPath)), isEmpty);
      expect(
        await sqlite.findPhysicalFileRowIds(history, 'history', [_currentPath]),
        ['download'],
        reason: 'file deletion can find its restored history row again',
      );
      expect(
        await migrateIosHistoryPaths(
          history,
          prefs,
          containerPath: _currentContainer,
        ),
        isNull,
        reason: 'unchanged launches should skip the completed repair',
      );
      await addLocal(
        'independent-copy',
        '$_currentContainer/Documents/Other/Song.flac',
      );
      expect((await store.trackPage(request)).rows, hasLength(2));
    },
  );

  test('restore repairs paths before publication', () async {
    await migrateIosHistoryPaths(
      history,
      prefs,
      containerPath: _currentContainer,
    );
    await addLocal('scanned', _currentPath);
    final db = _IosRestoreDatabase(history, prefs);
    final container = ProviderContainer(
      overrides: [downloadHistoryProvider.overrideWith(() => _History(db))],
    );
    addTearDown(container.dispose);
    final publications = <String>[];
    container.listen(downloadHistoryProvider, (_, next) {
      publications.addAll(next.items.map((item) => item.filePath));
    });
    final notifier = container.read(downloadHistoryProvider.notifier);
    for (var attempt = 0; attempt < 2; attempt++) {
      await notifier.restoreFromBackupOperation(
        () => db.restore(_download('download', _oldPath)),
      );
      expect(
        container.read(downloadHistoryProvider).items.single.filePath,
        _currentPath,
      );
      expect(
        (await store.trackPage(const QueueLibraryDbQuery())).rows,
        hasLength(1),
      );
      expect(
        (await history.query('history')).single['file_path'],
        _currentPath,
      );
    }
    expect(db.forcedMigrations, [true, true]);
    expect(publications, isNotEmpty);
    expect(publications.every((path) => path == _currentPath), isTrue);
  });

  test(
    'a failed path repair does not publish restored history as successful',
    () async {
      final db = _IosRestoreDatabase(history, prefs);
      final container = ProviderContainer(
        overrides: [downloadHistoryProvider.overrideWith(() => _History(db))],
      );
      addTearDown(container.dispose);
      final notifier = container.read(downloadHistoryProvider.notifier);
      await history.execute(
        'CREATE TRIGGER reject_path BEFORE UPDATE OF file_path ON history '
        "BEGIN SELECT RAISE(ABORT, 'write failure'); END",
      );
      await expectLater(
        notifier.restoreFromBackupOperation(
          () => db.restore(_download('download', _oldPath)),
        ),
        throwsStateError,
      );
      expect(container.read(downloadHistoryProvider).items, isEmpty);
      expect(prefs.getInt('ios_history_path_migration_version'), isNull);
    },
  );

  test(
    'paged repair rolls back paths, keys, and markers on a late failure',
    () async {
      await _replaceHistory(history, [
        for (var i = 0; i < 257; i++)
          _download(
            'track-${i.toString().padLeft(3, '0')}',
            '$_oldContainer/Documents/$i.flac',
          ),
      ]);
      final beforeKeys = await history.query(
        'history_path_keys',
        orderBy: 'item_id,path_key',
      );
      await history.execute(
        "CREATE TRIGGER reject_path BEFORE UPDATE OF file_path ON history "
        "WHEN old.id = 'track-256' BEGIN SELECT RAISE(ABORT, 'write failure'); END",
      );
      await expectLater(
        migrateIosHistoryPaths(
          history,
          prefs,
          containerPath: _currentContainer,
        ),
        throwsStateError,
      );
      expect(
        (await history.query('history')).every(
          (row) => (row['file_path'] as String).startsWith(_oldContainer),
        ),
        isTrue,
      );
      expect(
        await history.query('history_path_keys', orderBy: 'item_id,path_key'),
        beforeKeys,
      );
      expect(prefs.getInt('ios_history_path_migration_version'), isNull);
      await history.execute('DROP TRIGGER reject_path');
      expect(
        await migrateIosHistoryPaths(
          history,
          prefs,
          containerPath: _currentContainer,
        ),
        257,
      );
      expect(
        (await history.query('history')).every(
          (row) => (row['file_path'] as String).startsWith(_currentContainer),
        ),
        isTrue,
      );
    },
  );

  test('external, network, SAF, and traversal paths remain unchanged', () async {
    const paths = [
      '/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Song.flac',
      'network://connection/Music/Song.flac',
      'content://example.documents/tree/root/document/song.flac',
      '$_oldContainer/Documents/../tmp/Song.flac',
    ];
    await _replaceHistory(history, [
      for (var i = 0; i < paths.length; i++) _download('$i', paths[i]),
    ]);
    expect(
      await migrateIosHistoryPaths(
        history,
        prefs,
        containerPath: _currentContainer,
      ),
      0,
    );
    expect(
      (await history.query(
        'history',
        orderBy: 'id',
      )).map((row) => row['file_path']),
      paths,
    );
  });
}
