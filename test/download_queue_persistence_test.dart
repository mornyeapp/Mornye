import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/download_queue_persistence.dart';
import 'package:mornye/utils/chunked_list.dart';

DownloadItem _item(
  String id, {
  DownloadStatus status = DownloadStatus.queued,
}) => DownloadItem(
  id: id,
  track: const Track(
    id: 'example:track',
    name: 'Song',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 1000,
  ),
  service: 'extension.example',
  status: status,
  createdAt: DateTime.utc(2026),
  networkDownloadFolder: 'Albums',
  qualityOverride: 'HI_RES',
  preserveQualityVariant: true,
);

class _Store {
  final Map<String, Map<String, dynamic>> rows = {};
  int writes = 0;

  Future<List<Map<String, dynamic>>> load() async => rows.values.toList();

  Future<void> apply({
    required List<Map<String, dynamic>> upserts,
    required List<String> deletedIds,
  }) async {
    writes++;
    for (final id in deletedIds) {
      rows.remove(id);
    }
    for (final row in upserts) {
      rows[row['id'] as String] = row;
    }
  }

  void seed(DownloadItem item, {String? rowStatus}) {
    rows[item.id] = {
      'id': item.id,
      'status': rowStatus ?? item.status.name,
      'item_json': jsonEncode(item.toJson()),
    };
  }
}

class _CountingTrack extends Track {
  _CountingTrack(String id)
    : super(
        id: id,
        name: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 1000,
      );

  int serializations = 0;

  @override
  Map<String, dynamic> toJson() {
    serializations++;
    return super.toJson();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'verification waits and failures survive a restart; a failure is not retried',
    () async {
      final store = _Store();
      var items = [
        _item(
          'waiting',
          status: DownloadStatus.downloading,
        ).copyWith(errorType: DownloadErrorType.verificationRequired),
        _item(
          'timeout',
          status: DownloadStatus.failed,
        ).copyWith(errorType: DownloadErrorType.verificationRequired),
        _item(
          'unavailable',
          status: DownloadStatus.failed,
        ).copyWith(errorType: DownloadErrorType.notFound, error: 'No match'),
        _item('done', status: DownloadStatus.completed),
        _item('cancelled', status: DownloadStatus.skipped),
      ];
      DownloadQueuePersistence create() => DownloadQueuePersistence(
        currentItems: () => items,
        onError: (error) => fail('$error'),
        loadRows: store.load,
        applyChanges: store.apply,
      );
      final first = create();
      await first.flush(requireDurable: true);
      first.dispose();
      items = [];
      final restarted = create();
      addTearDown(restarted.dispose);
      items = await restarted.restore();
      expect(items.map((item) => item.id), [
        'waiting',
        'timeout',
        'unavailable',
        'cancelled',
      ]);
      expect(items.map((item) => item.status), [
        DownloadStatus.queued,
        DownloadStatus.queued,
        DownloadStatus.failed,
        DownloadStatus.skipped,
      ]);
      expect(items[2].errorType, DownloadErrorType.notFound);
      expect(items[2].error, 'No match');
      expect(store.rows['timeout']!['status'], 'queued');
      expect(store.rows['unavailable']!['status'], 'failed');
      // Dismissing the failed song removes it for good.
      items = [
        for (final item in items)
          if (item.id != 'unavailable') item,
      ];
      await restarted.flush(requireDurable: true);
      expect(store.rows.keys, isNot(contains('unavailable')));
      expect(items.first.qualityOverride, 'HI_RES');
    },
  );

  test(
    'browser handoff flush reports disk failure and a later flush retries',
    () async {
      final store = _Store();
      final errors = <Object>[];
      var attempts = 0;
      final persistence = DownloadQueuePersistence(
        currentItems: () => [_item('pending')],
        onError: errors.add,
        loadRows: store.load,
        applyChanges: ({required upserts, required deletedIds}) async {
          if (++attempts == 1) throw StateError('disk unavailable');
          await store.apply(upserts: upserts, deletedIds: deletedIds);
        },
      );
      addTearDown(persistence.dispose);
      await expectLater(
        persistence.flush(requireDurable: true),
        throwsStateError,
      );
      expect(store.rows, isEmpty);
      expect(errors, hasLength(1));
      await persistence.flush(requireDurable: true);
      expect(store.rows.keys, ['pending']);
    },
  );

  test(
    'restores active/cancelled items and repairs corrupt or terminal rows',
    () async {
      final store = _Store()
        ..seed(
          _item(
            'active',
            status: DownloadStatus.finalizing,
          ).copyWith(progress: .99),
        )
        ..seed(_item('cancelled', status: DownloadStatus.skipped))
        ..seed(_item('completed', status: DownloadStatus.completed))
        ..seed(_item('mismatch'), rowStatus: 'finalizing');
      store.rows['corrupt'] = {
        'id': 'corrupt',
        'status': 'queued',
        'item_json': '{broken',
      };
      store.rows['invalid-payload'] = {
        'id': 'invalid-payload',
        'status': 'queued',
        'item_json': 123,
      };
      var items = <DownloadItem>[];
      final errors = <Object>[];
      final persistence = DownloadQueuePersistence(
        currentItems: () => items,
        onError: errors.add,
        loadRows: store.load,
        applyChanges: store.apply,
      );
      items = await persistence.restore();
      expect(items.map((item) => item.id), ['active', 'cancelled', 'mismatch']);
      expect(items.first.status, DownloadStatus.queued);
      expect(items.first.progress, 0);
      expect(items[1].status, DownloadStatus.skipped);
      expect(items.first.networkDownloadFolder, 'Albums');
      expect(items.first.qualityOverride, 'HI_RES');
      expect(items.first.preserveQualityVariant, isTrue);
      await persistence.flush();
      expect(store.rows.keys, ['active', 'cancelled', 'mismatch']);
      expect(store.rows['mismatch']!['status'], 'queued');
      expect(
        store.rows['active']!['item_json'],
        encodeDownloadQueueItemForPersistence(items.first),
      );
      expect(errors, isEmpty);
    },
  );

  test(
    'transfer samples do not rewrite durable rows; completion deletes them',
    () async {
      final store = _Store();
      var items = [_item('track')];
      final persistence = DownloadQueuePersistence(
        currentItems: () => items,
        onError: (error) => fail('$error'),
        loadRows: store.load,
        applyChanges: store.apply,
      );
      await persistence.flush();
      items = [
        items.first.copyWith(
          status: DownloadStatus.downloading,
          progress: .42,
          speedMBps: 3.2,
          bytesReceived: 500,
          bytesTotal: 1000,
          preparationStage: 'decrypt',
        ),
      ];
      await persistence.flush();
      expect(store.writes, 1);
      items = [items.first.copyWith(status: DownloadStatus.completed)];
      await persistence.flush();
      expect(store.writes, 2);
      expect(store.rows, isEmpty);
    },
  );

  test(
    'untouched tracks are not serialized again; failed changes still retry',
    () async {
      final store = _Store();
      final untouched = _CountingTrack('untouched');
      final changed = _CountingTrack('changed');
      var items = [
        _item('untouched').copyWith(track: untouched),
        _item('changed').copyWith(track: changed),
      ];
      var rejectWrite = false;
      final errors = <Object>[];
      final persistence = DownloadQueuePersistence(
        currentItems: () => items,
        onError: errors.add,
        loadRows: store.load,
        applyChanges: ({required upserts, required deletedIds}) async {
          if (rejectWrite) throw StateError('disk unavailable');
          await store.apply(upserts: upserts, deletedIds: deletedIds);
        },
      );
      await persistence.flush();
      expect([untouched.serializations, changed.serializations], [1, 1]);
      items = [
        items.first,
        items.last.copyWith(status: DownloadStatus.skipped),
      ];
      rejectWrite = true;
      await persistence.flush();
      expect(errors, hasLength(1));
      expect([untouched.serializations, changed.serializations], [1, 2]);
      rejectWrite = false;
      await persistence.flush();
      expect(store.rows['changed']!['status'], 'skipped');
      expect([untouched.serializations, changed.serializations], [1, 3]);
      await persistence.flush();
      expect([untouched.serializations, changed.serializations], [1, 3]);
    },
  );

  test(
    'immutable snapshots are retried after failed combined writes',
    () async {
      final store = _Store();
      final track = _CountingTrack('retained');
      var items = ChunkedList.from([
        _item('retained').copyWith(track: track),
        _item('removed'),
      ]);
      var rejectWrite = false;
      final errors = <Object>[];
      final persistence = DownloadQueuePersistence(
        currentItems: () => items,
        onError: errors.add,
        loadRows: store.load,
        applyChanges: ({required upserts, required deletedIds}) async {
          if (rejectWrite) throw StateError('disk unavailable');
          await store.apply(upserts: upserts, deletedIds: deletedIds);
        },
      );
      addTearDown(persistence.dispose);
      await persistence.flush();
      await persistence.flush();
      expect(track.serializations, 1);
      expect(store.writes, 1);
      final original = items;
      items = ChunkedList.from([
        items.first.copyWith(playlistName: 'Updated'),
        _item('added'),
      ]);
      rejectWrite = true;
      await persistence.flush();
      expect(errors, hasLength(1));
      expect(store.rows.keys, ['retained', 'removed']);
      expect(store.writes, 1);
      rejectWrite = false;
      await persistence.flush();
      expect(store.rows.keys, ['retained', 'added']);
      expect(
        store.rows['retained']!['item_json'],
        encodeDownloadQueueItemForPersistence(items.first),
      );
      final serialized = track.serializations;
      await persistence.flush();
      expect(track.serializations, serialized);
      expect(store.writes, 2);
      items = original;
      await persistence.flush();
      expect(store.rows.keys, ['retained', 'removed']);
      expect(
        store.rows['retained']!['item_json'],
        encodeDownloadQueueItemForPersistence(original.first),
      );
      expect(store.writes, 3);
    },
  );

  test(
    'in-place mutable list edits are never treated as a saved snapshot',
    () async {
      final store = _Store();
      final items = [_item('first'), _item('removed')];
      final persistence = DownloadQueuePersistence(
        currentItems: () => items,
        onError: (error) => fail('$error'),
        loadRows: store.load,
        applyChanges: store.apply,
      );
      addTearDown(persistence.dispose);
      await persistence.flush();
      items[0] = items[0].copyWith(playlistName: 'Updated');
      items.removeLast();
      items.add(_item('added'));
      await persistence.flush();
      expect(store.rows.keys, ['first', 'added']);
      expect(
        store.rows['first']!['item_json'],
        encodeDownloadQueueItemForPersistence(items.first),
      );
      items.clear();
      await persistence.flush();
      expect(store.rows, isEmpty);
      expect(store.writes, 3);
    },
  );

  test('restore invalidates the previously saved immutable snapshot', () async {
    final store = _Store();
    final items = ChunkedList.from([_item('retained')]);
    final persistence = DownloadQueuePersistence(
      currentItems: () => items,
      onError: (error) => fail('$error'),
      loadRows: store.load,
      applyChanges: store.apply,
    );
    addTearDown(persistence.dispose);
    await persistence.flush();
    store.rows.clear();
    store.seed(_item('external'));
    expect((await persistence.restore()).single.id, 'external');
    await persistence.flush();
    expect(store.rows.keys, ['retained']);
    expect(store.writes, 2);
  });

  test(
    'failed writes retry and concurrent flushes retain the latest snapshot',
    () async {
      final store = _Store();
      var items = [_item('first')];
      final started = Completer<void>();
      final release = Completer<void>();
      final errors = <Object>[];
      var attempts = 0;
      final persistence = DownloadQueuePersistence(
        currentItems: () => items,
        onError: errors.add,
        loadRows: store.load,
        applyChanges: ({required upserts, required deletedIds}) async {
          attempts++;
          if (attempts == 1) throw StateError('disk temporarily unavailable');
          if (attempts == 2) {
            started.complete();
            await release.future;
          }
          await store.apply(upserts: upserts, deletedIds: deletedIds);
        },
      );
      await persistence.flush();
      expect(errors, hasLength(1));
      final first = persistence.flush();
      await started.future;
      items = [_item('latest', status: DownloadStatus.skipped)];
      final second = persistence.flush();
      await Future<void>.delayed(Duration.zero);
      expect(attempts, 2);
      release.complete();
      await Future.wait([first, second]);
      expect(attempts, 3);
      expect(store.rows.keys, ['latest']);
      expect(store.rows['latest']!['status'], 'skipped');
    },
  );

  testWidgets(
    'debounces mutations and captures a pending snapshot on disposal',
    (tester) async {
      final store = _Store();
      var items = [_item('one')];
      var disposed = false;
      final persistence = DownloadQueuePersistence(
        currentItems: () {
          if (disposed) throw StateError('provider disposed');
          return items;
        },
        onError: (error) => fail('$error'),
        loadRows: store.load,
        applyChanges: store.apply,
      );
      persistence.schedule();
      await tester.pump(const Duration(milliseconds: 200));
      items = [_item('two')];
      persistence.schedule();
      await tester.pump(const Duration(milliseconds: 200));
      expect(store.writes, 0);
      await tester.pump(const Duration(milliseconds: 150));
      expect(store.rows.keys, ['two']);
      items = [_item('three')];
      persistence.schedule();
      disposed = true;
      persistence.dispose();
      items = [];
      await tester.pump();
      expect(store.rows.keys, ['three']);
      await tester.pump(const Duration(seconds: 1));
      expect(store.writes, 2);
    },
  );

  test('queued flushes retain snapshots after disposal', () async {
    final store = _Store();
    var items = [_item('first')];
    var disposed = false;
    final started = Completer<void>();
    final release = Completer<void>();
    final errors = <Object>[];
    final persistence = DownloadQueuePersistence(
      currentItems: () {
        if (disposed) throw StateError('provider disposed');
        return items;
      },
      onError: errors.add,
      loadRows: store.load,
      applyChanges: ({required upserts, required deletedIds}) async {
        if (!started.isCompleted) {
          started.complete();
          await release.future;
        }
        await store.apply(upserts: upserts, deletedIds: deletedIds);
      },
    );
    final first = persistence.flush();
    await started.future;
    items = [_item('latest')];
    final second = persistence.flush();
    persistence.dispose();
    disposed = true;
    release.complete();
    await Future.wait([first, second]);
    expect(store.rows.keys, ['latest']);
    expect(errors, isEmpty);
  });

  test('flush waits for ordered user pause writes', () async {
    final store = _Store();
    final persistence = DownloadQueuePersistence(
      currentItems: () => [],
      onError: (error) => fail('$error'),
      loadRows: store.load,
      applyChanges: store.apply,
    );
    persistence.setUserPaused(true);
    persistence.setUserPaused(false);
    persistence.setUserPaused(true);
    await persistence.flush();
    expect(await persistence.loadUserPaused(), isTrue);
    persistence.setUserPaused(false);
    await persistence.flush();
    expect(await persistence.loadUserPaused(), isFalse);
  });

  test(
    'large worker snapshots retry and retain the latest ordered write',
    () async {
      final store = _Store();
      var items = List.generate(2100, (index) => _item('initial:$index'));
      final latest = List.generate(
        1100,
        (index) => _item('latest:$index', status: DownloadStatus.skipped),
      );
      final errors = <Object>[];
      final started = Completer<void>();
      final release = Completer<void>();
      var attempts = 0;
      final persistence = DownloadQueuePersistence(
        currentItems: () => items,
        onError: errors.add,
        loadRows: store.load,
        applyChanges: ({required upserts, required deletedIds}) async {
          attempts++;
          if (attempts == 1) throw StateError('disk unavailable');
          if (attempts == 2) {
            started.complete();
            await release.future;
          }
          await store.apply(upserts: upserts, deletedIds: deletedIds);
        },
      );
      await persistence.flush();
      expect(errors, hasLength(1));
      expect(store.rows, isEmpty);
      final initialWrite = persistence.flush();
      await started.future;
      items = latest;
      final latestWrite = persistence.flush();
      persistence.dispose();
      release.complete();
      await Future.wait([initialWrite, latestWrite]);
      expect(store.rows.keys, latest.map((item) => item.id));
      for (final item in latest) {
        expect(
          store.rows[item.id]!['item_json'],
          encodeDownloadQueueItemForPersistence(item),
        );
      }
      await persistence.flush();
      expect(attempts, 3);
      expect(errors, hasLength(1));
    },
  );

  test(
    'restore worker cannot be overtaken by a flush or pending disposal',
    () async {
      final store = _Store();
      final old = List.generate(2100, (index) => _item('old:$index'));
      for (final item in old) {
        store.seed(item);
      }
      final loaded = Completer<void>();
      final release = Completer<void>();
      var items = [_item('latest')];
      var disposed = false;
      final errors = <Object>[];
      final persistence = DownloadQueuePersistence(
        currentItems: () {
          if (disposed) throw StateError('provider disposed');
          return items;
        },
        onError: errors.add,
        loadRows: () async {
          final rows = await store.load();
          loaded.complete();
          await release.future;
          return rows;
        },
        applyChanges: store.apply,
      );
      final restored = persistence.restore();
      await loaded.future;
      final flushed = persistence.flush();
      persistence.schedule();
      persistence.dispose();
      disposed = true;
      items = [];
      expect(store.writes, 0);
      release.complete();
      expect(
        (await restored).map((item) => item.id),
        old.map((item) => item.id),
      );
      await flushed;
      expect(store.rows.keys, ['latest']);
      expect(errors, isEmpty);
    },
  );

  test(
    'a failed restore propagates without poisoning later durable writes',
    () async {
      final store = _Store();
      final persistence = DownloadQueuePersistence(
        currentItems: () => [_item('latest')],
        onError: (error) => fail('$error'),
        loadRows: () async => throw StateError('database unavailable'),
        applyChanges: store.apply,
      );
      await expectLater(persistence.restore(), throwsStateError);
      await persistence.flush();
      expect(store.rows.keys, ['latest']);
    },
  );

  test('SQLite restores cancelled rows in creation order for retry', () async {
    SharedPreferences.setMockInitialValues({
      'app_state_migrated_queue_to_sqlite_v1': true,
    });
    final previousFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactorySqflitePlugin;
    addTearDown(() => databaseFactory = previousFactory);
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const sqlite = MethodChannel('com.tekartik.sqflite');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => '/test/documents');
    addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
    final fixture = [
      for (final status in [
        DownloadStatus.queued,
        DownloadStatus.skipped,
        DownloadStatus.downloading,
        DownloadStatus.finalizing,
        DownloadStatus.completed,
        DownloadStatus.failed,
      ])
        _item(status.name, status: status).toJson(),
    ];
    messenger.setMockMethodCallHandler(sqlite, (call) async {
      if (call.method == 'openDatabase') return {'id': 1};
      if (call.method != 'query') return null;
      final arguments = call.arguments as Map;
      final sql = arguments['sql'] as String;
      if (sql.toUpperCase().contains('PRAGMA')) {
        return {
          'columns': ['user_version'],
          'rows': [
            [4],
          ],
        };
      }
      final result = await Process.run('python3', [
        '-c',
        r'''
import json, sqlite3, sys
data = json.loads(sys.argv[1])
db = sqlite3.connect(':memory:')
db.row_factory = sqlite3.Row
db.execute('CREATE TABLE download_queue_items (id, item_json, status, created_at, updated_at)')
for row in data['rows']:
    db.execute('INSERT INTO download_queue_items VALUES (?, ?, ?, ?, ?)',
               (row['id'], json.dumps(row), row['status'], row['createdAt'], row['createdAt']))
print(json.dumps([dict(row) for row in db.execute(data['sql'], data['arguments'])]))
''',
        jsonEncode({
          'rows': fixture,
          'sql': sql,
          'arguments': arguments['arguments'],
        }),
      ]);
      if (result.exitCode != 0) throw StateError('${result.stderr}');
      final rows = (jsonDecode(result.stdout as String) as List)
          .map((row) => Map<String, Object?>.from(row as Map))
          .toList();
      final columns = rows.first.keys.toList();
      return {
        'columns': columns,
        'rows': [
          for (final row in rows) [for (final column in columns) row[column]],
        ],
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(sqlite, null));
    final persistence = DownloadQueuePersistence(
      currentItems: () => [],
      onError: (error) => fail('$error'),
    );
    final restored = await persistence.restore();
    expect(restored.map((item) => item.id), [
      'queued',
      'skipped',
      'downloading',
      'finalizing',
      'failed',
    ]);
    expect(restored[1].status, DownloadStatus.skipped);
    expect(restored[3].status, DownloadStatus.queued);
    expect(restored.last.status, DownloadStatus.failed);
    await (await AppStateDatabase.instance.database).close();
  });
}
