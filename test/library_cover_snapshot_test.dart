import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/library_cover_snapshot.dart';

import 'support/sqlite_process_database.dart';

class _HandoffDatabase implements Database {
  _HandoffDatabase(this.database, this.beforeValidation);

  @override
  final SqliteProcessDatabase database;
  final Future<void> Function() beforeValidation;
  int transactions = 0;

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      database.execute(sql, arguments);

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => database.rawQuery(sql, arguments);

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) async {
    if (++transactions == 2) await beforeValidation();
    return database.transaction(action, exclusive: exclusive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<SqliteProcessDatabase> _source(String path) async {
  final database = await SqliteProcessDatabase.open(path: path);
  await database.rawQuery('PRAGMA journal_mode=WAL');
  await database.execute('PRAGMA user_version=17');
  await database.execute(
    'CREATE TABLE library (id TEXT PRIMARY KEY, source_id TEXT, cover_path TEXT)',
  );
  await database.execute(
    'CREATE TABLE library_sources (id TEXT PRIMARY KEY, enabled INTEGER, available INTEGER)',
  );
  await database.execute("INSERT INTO library_sources VALUES ('hidden', 0, 0)");
  await database.execute('''
    INSERT INTO library VALUES
      ('visible', 'default', '/covers/visible.jpg'),
      ('hidden', 'hidden', '/alias/hidden.jpg'),
      ('duplicate', 'hidden', '/covers/visible.jpg'),
      ('empty', 'default', ''),
      ('missing', 'default', NULL)
  ''');
  return database;
}

Future<void> _expectClean(Database db, Directory directory) async {
  expect(await db.rawQuery('SELECT name FROM sqlite_temp_master'), isEmpty);
  expect(
    (await db.rawQuery('PRAGMA database_list')).map((row) => row['name']),
    unorderedEquals(['main', 'temp']),
  );
  expect(
    await directory.list().where((entry) => entry is Directory).toList(),
    isEmpty,
  );
  expect(await db.rawQuery('PRAGMA integrity_check'), [
    {'integrity_check': 'ok'},
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SqliteProcessDatabase database;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cover-snapshot-test-');
    database = await _source('${directory.path}/local_library.db');
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test('native reads only detached private all-source projection', () async {
    final observed = _HandoffDatabase(database, () async {
      expect(
        (await database.rawQuery(
          'PRAGMA database_list',
        )).map((row) => row['name']),
        unorderedEquals(['main', 'temp']),
      );
    });
    expect(
      await withLibraryCoverSnapshot(observed, (path) async {
        expect(path, isNot(database.path));
        expect(path, endsWith('/local_library.db'));
        final snapshot = await SqliteProcessDatabase.open(path: path);
        try {
          expect(await snapshot.rawQuery('PRAGMA user_version'), [
            {'user_version': 17},
          ]);
          expect(await readLibraryCoverReferences(snapshot), {
            '/covers/visible.jpg',
            '/alias/hidden.jpg',
          });
          expect(await snapshot.rawQuery('PRAGMA integrity_check'), [
            {'integrity_check': 'ok'},
          ]);
        } finally {
          await snapshot.close();
        }
        return 7;
      }, temporaryDirectory: directory),
      7,
    );
    await _expectClean(database, directory);
  });

  for (final change in ['add', 'remove', 'replace']) {
    test('$change in detached handoff skips destructive callback', () async {
      var called = false;
      final observed = _HandoffDatabase(database, () async {
        switch (change) {
          case 'add':
            await database.execute(
              "INSERT INTO library VALUES ('new', 'hidden', '/covers/new.jpg')",
            );
          case 'remove':
            await database.execute("DELETE FROM library WHERE id='hidden'");
          case 'replace':
            await database.execute(
              "UPDATE library SET cover_path='/covers/new.jpg' WHERE id='hidden'",
            );
        }
      });
      expect(
        await withLibraryCoverSnapshot(observed, (_) async {
          called = true;
          return 1;
        }, temporaryDirectory: directory),
        0,
      );
      expect(called, false);
      await _expectClean(database, directory);
    });
  }

  test('same references despite row replacement remain safe to prune', () async {
    final observed = _HandoffDatabase(database, () async {
      await database.execute(
        "UPDATE library SET id='changed', source_id='hidden' WHERE id='visible'",
      );
    });
    expect(
      await withLibraryCoverSnapshot(
        observed,
        (_) async => 1,
        temporaryDirectory: directory,
      ),
      1,
    );
    await _expectClean(database, directory);
  });

  test('WAL writer barrier spans private native read and deletion', () async {
    final writer = await SqliteProcessDatabase.open(path: database.path);
    try {
      await writer.execute('PRAGMA busy_timeout=0');
      expect(
        await withLibraryCoverSnapshot(database, (path) async {
          await expectLater(
            writer.rawInsert(
              "INSERT INTO library VALUES ('new', 'hidden', '/covers/new.jpg')",
            ),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                contains('database is locked'),
              ),
            ),
          );
          final snapshot = await SqliteProcessDatabase.open(path: path);
          try {
            // Native's private BEGIN IMMEDIATE never targets the source file.
            return await snapshot.transaction((txn) async {
              expect((await readLibraryCoverReferences(txn)).length, 2);
              return 1;
            }, exclusive: true);
          } finally {
            await snapshot.close();
          }
        }, temporaryDirectory: directory),
        1,
      );
      await writer.rawInsert(
        "INSERT INTO library VALUES ('new', 'hidden', '/covers/new.jpg')",
      );
      await _expectClean(database, directory);
    } finally {
      await writer.close();
    }
  });

  test(
    'failed native maintenance cleans private files and releases barrier',
    () async {
      await expectLater(
        withLibraryCoverSnapshot(database, (_) async {
          throw StateError('native failed');
        }, temporaryDirectory: directory),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'native failed',
          ),
        ),
      );
      await database.execute(
        "INSERT INTO library VALUES ('new', 'hidden', '/covers/new.jpg')",
      );
      await _expectClean(database, directory);
    },
  );

  test(
    'cancellation before projection or before validation never prunes',
    () async {
      for (final stopAt in [1, 2, 3]) {
        var checks = 0;
        var called = false;
        expect(
          await withLibraryCoverSnapshot(
            database,
            (_) async {
              called = true;
              return 1;
            },
            canPrune: () => ++checks < stopAt,
            temporaryDirectory: directory,
          ),
          0,
        );
        expect(called, false);
        await _expectClean(database, directory);
      }
    },
  );

  test('stored references join the projection without postponing it', () async {
    final stored = {
      for (var index = 0; index < 300; index++) '/covers/stored-$index.jpg',
      '/covers/visible.jpg',
    };
    expect(
      await withLibraryCoverSnapshot(
        database,
        (path) async {
          final snapshot = await SqliteProcessDatabase.open(path: path);
          try {
            expect(await readLibraryCoverReferences(snapshot), {
              '/alias/hidden.jpg',
              ...stored,
            });
          } finally {
            await snapshot.close();
          }
          return 4;
        },
        temporaryDirectory: directory,
        storedReferences: stored,
      ),
      4,
    );
    await _expectClean(database, directory);
  });

  test('stored cover names are read in pages and rebased', () async {
    await database.execute('CREATE TABLE stored (value TEXT)');
    await database.transaction((txn) async {
      for (var index = 0; index < 300; index++) {
        await txn.rawInsert('INSERT INTO stored VALUES (?)', [
          '{"coverUrl":"/old/library_covers/page-$index.jpg"}',
        ]);
      }
    });
    await database.execute('''
      INSERT INTO stored VALUES
        ('{"artUri":"file:///old/Application%20Support/library_covers/a%20b.jpg"}'),
        ('{"coverUrl":"\\/old\\/library_covers\\/escaped.jpg"}'),
        ('[{"a":"/x/library_covers/full_scan_1/one.jpg"},{"b":"/x/library_covers/two.png"}]'),
        ('https://example.com/cover.jpg'),
        (NULL)
    ''');
    final paths = await readStoredLibraryCoverPaths(Directory('/covers'), [
      (database: database, table: 'stored', column: 'value'),
    ]);
    expect(paths, {
      for (var index = 0; index < 300; index++) '/covers/page-$index.jpg',
      '/covers/a b.jpg',
      '/covers/escaped.jpg',
      '/covers/full_scan_1/one.jpg',
      '/covers/two.png',
    });
  });

  test(
    'desktop reference pages remain bounded and retain exact distinct paths',
    () async {
      await database.transaction((txn) async {
        for (var index = 0; index < 800; index++) {
          await txn.rawInsert('INSERT INTO library VALUES (?, ?, ?)', [
            'bulk-$index',
            'hidden',
            '/covers/${index.toString().padLeft(4, '0')}.jpg',
          ]);
        }
      });
      final references = await readLibraryCoverReferences(database);
      expect(references.length, 802);
      expect(
        references,
        containsAll([
          '/covers/0000.jpg',
          '/covers/0799.jpg',
          '/alias/hidden.jpg',
        ]),
      );
    },
  );
}
