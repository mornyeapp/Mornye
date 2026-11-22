import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/history_schema.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Counts the transactions History starts; every lost race starts another.
class _CountingDatabase implements Database {
  _CountingDatabase(this._inner);

  final Database _inner;
  int begins = 0;

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) {
    begins++;
    return _inner.transaction(action, exclusive: exclusive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A Library write transaction also write-locks the attached history.db.
/// These tests hold one and check that a History write takes its turn after
/// it instead of losing the race inside SQLite.
void main() {
  sqfliteFfiInit();

  late Directory root;
  late Database history;
  late Database library;
  final defaultWait = sqlite.writerQueueWait;

  // No busy timeout and no retries: a lost race fails at once, so a test
  // that passes proves the wait happened in the queue.
  Future<void> writeHistory(String value) => sqlite.transactionWithBusyRetry(
    history,
    (txn) => txn.insert('history', {'v': value}),
    retryDelays: const [],
  );

  /// Opens a Library transaction and keeps it open until [release] completes.
  Future<void> holdLibrary(Future<void> release, {Completer<void>? entered}) =>
      sqlite.transactionWithBusyRetry(library, (txn) async {
        await txn.insert('library', {'v': 'held'});
        entered?.complete();
        await release;
      });

  Future<List<Object?>> historyValues() async =>
      (await history.query('history')).map((row) => row['v']).toList();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('writer-queue-');
    final historyPath = '${root.path}/history.db';
    history = await databaseFactoryFfi.openDatabase(
      historyPath,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async {
          await db.rawQuery('PRAGMA journal_mode = WAL');
        },
        onCreate: (db, version) => db.execute('CREATE TABLE history (v TEXT)'),
      ),
    );
    library = await databaseFactoryFfi.openDatabase(
      '${root.path}/local_library.db',
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async {
          await db.rawQuery('PRAGMA journal_mode = WAL');
        },
        onCreate: (db, version) => db.execute('CREATE TABLE library (v TEXT)'),
      ),
    );
    await library.execute('ATTACH DATABASE ? AS history_db', [historyPath]);
  });

  tearDown(() async {
    sqlite.writerQueueWait = defaultWait;
    await library.close();
    await history.close();
    await root.delete(recursive: true);
  });

  test(
    'without a queue the History write loses to a Library transaction',
    () async {
      final release = Completer<void>();
      final entered = Completer<void>();
      final held = holdLibrary(release.future, entered: entered);
      await entered.future;

      await expectLater(
        writeHistory('lost'),
        throwsA(isA<DatabaseException>()),
      );

      release.complete();
      await held;
      expect(await historyValues(), isEmpty);
    },
  );

  group('with both connections in one queue', () {
    setUp(() {
      sqlite.joinWriterQueue(history, 'test-queue');
      sqlite.joinWriterQueue(library, 'test-queue');
    });

    test('the History write waits for the Library transaction', () async {
      final release = Completer<void>();
      final entered = Completer<void>();
      final held = holdLibrary(release.future, entered: entered);
      await entered.future;

      var written = false;
      final write = writeHistory('queued').then((_) => written = true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(written, isFalse, reason: 'the Library transaction is still open');

      release.complete();
      await held;
      await write;
      expect(await historyValues(), ['queued']);
    });

    test('writers run in the order they asked', () async {
      final release = Completer<void>();
      final entered = Completer<void>();
      final held = holdLibrary(release.future, entered: entered);
      await entered.future;

      final writes = [
        for (final value in ['first', 'second', 'third']) writeHistory(value),
      ];
      release.complete();
      await held;
      await Future.wait(writes);
      expect(await historyValues(), ['first', 'second', 'third']);
    });

    test('a failed transaction hands the queue on', () async {
      final failure = StateError('body failed');
      await expectLater(
        sqlite.transactionWithBusyRetry(library, (txn) async {
          await txn.insert('library', {'v': 'partial'});
          throw failure;
        }),
        throwsA(same(failure)),
      );

      await writeHistory('after failure');
      expect(await historyValues(), ['after failure']);
      expect(await library.query('library'), isEmpty);
    });

    test('a write inside the holder does not wait for itself', () async {
      Object? nested;
      await sqlite.transactionWithBusyRetry(library, (txn) async {
        await txn.insert('library', {'v': 'held'});
        try {
          await writeHistory('nested').timeout(const Duration(seconds: 5));
        } catch (error) {
          nested = error;
        }
      });

      // SQLite still refuses it, as before; it must not hang in the queue.
      expect(nested, isA<DatabaseException>());
    });

    test('a callback that outlives its transaction queues again', () async {
      late Zone holderZone;
      await sqlite.transactionWithBusyRetry(library, (txn) async {
        holderZone = Zone.current;
        await txn.insert('library', {'v': 'done'});
      });

      final release = Completer<void>();
      final entered = Completer<void>();
      final held = holdLibrary(release.future, entered: entered);
      await entered.future;

      var written = false;
      final write = holderZone
          .run(() => writeHistory('late'))
          .then((_) => written = true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(written, isFalse);

      release.complete();
      await held;
      await write;
      expect(await historyValues(), ['late']);
    });

    test('a stuck holder does not stop later writes for ever', () async {
      sqlite.writerQueueWait = const Duration(milliseconds: 200);
      final release = Completer<void>();
      final entered = Completer<void>();
      final held = holdLibrary(release.future, entered: entered);
      await entered.future;

      // After the wait the write goes to SQLite, which reports the lock.
      await expectLater(
        writeHistory('gave up').timeout(const Duration(seconds: 5)),
        throwsA(isA<DatabaseException>()),
      );

      release.complete();
      await held;
      await writeHistory('afterwards');
      expect(await historyValues(), ['afterwards']);
    });
  });

  test('a History save waits out a long Library transaction', () async {
    final path = '${root.path}/app-history.db';
    final app = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: HistoryDatabase.schemaVersion,
        onConfigure: (db) async {
          await db.rawQuery('PRAGMA journal_mode = WAL');
        },
        onCreate: (db, version) async {
          await HistorySchema.create(db, version);
        },
      ),
    );
    addTearDown(() async {
      HistoryDatabase.debugReplaceDatabaseForTest(null);
      await app.close();
    });
    final counted = _CountingDatabase(app);
    HistoryDatabase.debugReplaceDatabaseForTest(counted);
    await library.execute('ATTACH DATABASE ? AS app_history', [path]);
    sqlite.joinWriterQueue(library, sqlite.historyWriterQueue);

    final release = Completer<void>();
    final entered = Completer<void>();
    final held = holdLibrary(release.future, entered: entered);
    await entered.future;

    final save = HistoryDatabase.instance.upsert(
      DownloadHistoryItem(
        id: 'landed',
        trackName: 'Track',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: '${root.path}/landed.flac',
        service: 'test',
        downloadedAt: DateTime.utc(2026, 11, 22),
      ).toJson(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    release.complete();
    await held;
    await save;

    expect(await app.query('history', where: "id = 'landed'"), hasLength(1));
    expect(
      counted.begins,
      1,
      reason: 'the save took its turn; it never met the lock and retried',
    );
  });

  test('the Library connection joins the queue where it attaches History', () {
    final source = File(
      'lib/services/library_database.dart',
    ).readAsStringSync();
    final attach = source.indexOf("'ATTACH DATABASE ? AS history_db'");
    final join = source.indexOf(
      'sqlite.joinWriterQueue(db, sqlite.historyWriterQueue)',
    );
    expect(attach, isNonNegative);
    expect(join, greaterThan(attach));
  });
}
