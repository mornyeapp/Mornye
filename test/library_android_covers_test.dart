import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_android_covers.dart';
import 'package:mornye/services/library_cleanup.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory covers;
  late Database db;

  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('android-library-covers-');
    covers = await Directory('${root.path}/library_covers').create();
    db = await databaseFactoryFfi.openDatabase('${root.path}/library.db');
    await db.execute(
      'CREATE TABLE library (id TEXT PRIMARY KEY, cover_path TEXT)',
    );
    await db.execute(
      'CREATE TABLE library_state (key TEXT PRIMARY KEY, value TEXT)',
    );
    await db.execute('CREATE TABLE saved (value TEXT)');
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
  });

  Future<File> legacy(int index, String bytes) async {
    final name = index.toRadixString(16).padLeft(32, '0');
    return File('${covers.path}/cover_$name.jpg').writeAsString(bytes);
  }

  String content(String bytes) =>
      '${covers.resolveSymbolicLinksSync()}/cover_content_${sha256.convert(utf8.encode(bytes))}.jpg';

  test(
    'migration shares bytes, preserves saved references and is one-time',
    () async {
      final old = <File>[];
      for (var index = 0; index < 12; index++) {
        final file = await legacy(index, index.isEven ? 'abc' : 'abd');
        old.add(file);
        await db.insert('library', {'id': '$index', 'cover_path': file.path});
      }
      await db.insert('saved', {
        'value': jsonEncode({'artUri': Uri.file(old[0].path).toString()}),
      });
      await db.insert('saved', {
        'value': jsonEncode({'coverPath': old[1].path}),
      });

      expect(await migrateLibraryCoverPaths(db, covers), 12);
      final rows = await db.query('library');
      expect(rows.map((row) => row['cover_path']).toSet(), {
        content('abc'),
        content('abd'),
      });
      expect(
        content('abc'),
        endsWith(
          'cover_content_ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad.jpg',
        ),
      );
      expect(await File(content('abc')).readAsString(), 'abc');
      expect(await File(content('abd')).readAsString(), 'abd');
      expect(await migrateLibraryCoverPaths(db, covers), 0);
      for (final file in old) {
        expect(await file.exists(), isTrue);
      }

      final references = rows.map((row) => row['cover_path'] as String).toSet();
      expect(
        await pruneUnreferencedLibraryCovers(
          covers,
          references,
          referenceColumns: [(database: db, table: 'saved', column: 'value')],
        ),
        10,
      );
      expect(await old[0].exists(), isTrue);
      expect(await old[1].exists(), isTrue);
      expect(
        covers.listSync().whereType<File>().fold<int>(
          0,
          (sum, file) => sum + file.lengthSync(),
        ),
        12,
      );
      await db.delete('saved');
      expect(
        await pruneUnreferencedLibraryCovers(
          covers,
          references,
          referenceColumns: const [],
        ),
        2,
      );
      expect(covers.listSync().whereType<File>(), hasLength(2));
      expect(
        covers.listSync().whereType<File>().fold<int>(
          0,
          (sum, file) => sum + file.lengthSync(),
        ),
        6,
      );
      await db.delete('library', where: 'id = ?', whereArgs: ['0']);
      final remaining = (await db.query(
        'library',
      )).map((row) => row['cover_path'] as String).toSet();
      expect(
        await pruneUnreferencedLibraryCovers(
          covers,
          remaining,
          referenceColumns: const [],
        ),
        0,
      );
      expect(await File(content('abc')).exists(), isTrue);
      await db.delete(
        'library',
        where: 'cover_path = ?',
        whereArgs: [content('abc')],
      );
      final finalReferences = (await db.query(
        'library',
      )).map((row) => row['cover_path'] as String).toSet();
      expect(
        await pruneUnreferencedLibraryCovers(
          covers,
          finalReferences,
          referenceColumns: const [],
        ),
        1,
      );
      expect(await File(content('abd')).exists(), isTrue);
      await db.execute('DROP TABLE library');
      expect(await migrateLibraryCoverPaths(db, covers), 0);
    },
  );

  test(
    'failed second page leaves prior progress and retries without losing files',
    () async {
      final first = await legacy(1, 'abc');
      final second = await legacy(2, 'abd');
      final batch = db.batch();
      for (var index = 0; index < 300; index++) {
        batch.insert('library', {
          'id': index.toString().padLeft(3, '0'),
          'cover_path': index < 256 ? first.path : second.path,
        });
      }
      await batch.commit(noResult: true);
      await db.execute(
        "CREATE TRIGGER interrupted BEFORE UPDATE ON library WHEN OLD.id = '299' BEGIN SELECT RAISE(ABORT, 'interrupted'); END",
      );
      await expectLater(
        migrateLibraryCoverPaths(db, covers),
        throwsA(isA<DatabaseException>()),
      );
      expect(await db.query('library_state'), isEmpty);
      expect(
        (await db.query(
          'library',
          where: 'cover_path = ?',
          whereArgs: [content('abc')],
        )).length,
        256,
      );
      expect(
        (await db.query(
          'library',
          where: 'cover_path = ?',
          whereArgs: [second.path],
        )).length,
        44,
      );
      expect(await first.readAsString(), 'abc');
      expect(await second.readAsString(), 'abd');
      expect(await File(content('abd')).readAsString(), 'abd');
      await db.execute('DROP TRIGGER interrupted');
      expect(await migrateLibraryCoverPaths(db, covers), 44);
      expect(await migrateLibraryCoverPaths(db, covers), 0);
    },
  );

  test(
    'publication failures retry while foreign paths stay unchanged',
    () async {
      final old = await legacy(1, 'abc');
      final empty = await legacy(2, '');
      final missing = await legacy(3, 'later');
      await missing.delete();
      final foreign = await File(
        '${root.path}/cover_${'f' * 32}.jpg',
      ).writeAsString('foreign');
      for (final (index, file) in [old, empty, missing, foreign].indexed) {
        await db.insert('library', {'id': '$index', 'cover_path': file.path});
      }
      await File(content('abc')).writeAsString('different artwork');
      expect(await migrateLibraryCoverPaths(db, covers), 0);
      expect(await db.query('library_state'), isEmpty);
      expect(await File(content('abc')).readAsString(), 'different artwork');
      await File(content('abc')).delete();
      await empty.writeAsString('abc');
      await missing.writeAsString('abd');
      expect(await migrateLibraryCoverPaths(db, covers), 3);
      expect(
        (await db.query(
          'library',
          where: 'id = ?',
          whereArgs: ['3'],
        )).single['cover_path'],
        foreign.path,
      );
      expect(await foreign.readAsString(), 'foreign');
    },
  );

  test('a row changed during migration keeps its newer reference', () async {
    final first = await legacy(1, 'abc');
    final second = await legacy(2, 'abc');
    await db.insert('library', {'id': 'a', 'cover_path': first.path});
    await db.insert('library', {'id': 'b', 'cover_path': second.path});
    await db.execute(
      "CREATE TRIGGER changed AFTER UPDATE ON library WHEN NEW.id = 'a' BEGIN UPDATE library SET cover_path = '/new/art.jpg' WHERE id = 'b'; END",
    );
    expect(await migrateLibraryCoverPaths(db, covers), 1);
    expect(
      (await db.query('library', where: "id = 'b'")).single['cover_path'],
      '/new/art.jpg',
    );
    expect(await second.readAsString(), 'abc');
  });

  test(
    'missing or unusable old cache files do not repeat migration on open',
    () async {
      final empty = await legacy(1, '');
      final missing = await legacy(2, '');
      await missing.delete();
      final oversized = await legacy(3, '');
      final file = await oversized.open(mode: FileMode.write);
      await file.truncate(24 * 1024 * 1024 + 1);
      await file.close();
      final linked = '${covers.path}/cover_${'4' * 32}.jpg';
      await Link(linked).create(empty.path);
      final missingDirectory = '${root.path}/gone/cover_${'5' * 32}.jpg';
      for (final (index, path) in [
        empty.path,
        missing.path,
        oversized.path,
        linked,
        missingDirectory,
      ].indexed) {
        await db.insert('library', {'id': '$index', 'cover_path': path});
      }
      expect(await migrateLibraryCoverPaths(db, covers), 0);
      expect((await db.query('library_state')).single['value'], '1');
      expect(
        (await db.query('library')).map((row) => row['cover_path']).toSet(),
        {empty.path, missing.path, oversized.path, linked, missingDirectory},
      );
      await db.execute('DROP TABLE library');
      expect(await migrateLibraryCoverPaths(db, covers), 0);
    },
  );

  test('byte signatures normalize legacy extensions across publishers', () async {
    final png = [0x89, 0x50, 0x4e, 0x47];
    final jpeg = [0xff, 0xd8, 1];
    final first = await legacy(1, '');
    final second = File('${covers.path}/cover_${'2' * 32}.png');
    await first.writeAsBytes(png);
    await second.writeAsBytes(jpeg);
    await db.insert('library', {'id': 'png', 'cover_path': first.path});
    await db.insert('library', {'id': 'jpeg', 'cover_path': second.path});
    expect(await migrateLibraryCoverPaths(db, covers), 2);
    final rows = await db.query('library');
    expect(
      rows.singleWhere((row) => row['id'] == 'png')['cover_path'],
      '${covers.resolveSymbolicLinksSync()}/cover_content_${sha256.convert(png)}.png',
    );
    expect(
      rows.singleWhere((row) => row['id'] == 'jpeg')['cover_path'],
      '${covers.resolveSymbolicLinksSync()}/cover_content_${sha256.convert(jpeg)}.jpg',
    );
  });
}
