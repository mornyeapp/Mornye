import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/library_schema.dart';
import 'package:mornye/utils/path_match_keys.dart';
import 'package:sqflite/sqflite.dart';
// ignore: depend_on_referenced_packages
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;

const _oldRoot =
    '/var/mobile/Containers/Data/Application/'
    '11111111-1111-4111-8111-111111111111';
const _currentRoot =
    '/var/mobile/Containers/Data/Application/'
    '22222222-2222-4222-8222-222222222222';
const _nextRoot =
    '/private/var/mobile/Containers/Data/Application/'
    '33333333-3333-4333-8333-333333333333';

Map<String, Object?> _track(
  String id, {
  String root = _oldRoot,
  String source = LocalLibraryItem.legacySourceId,
}) => LibraryRowMapper.encode(
  LocalLibraryItem(
    id: id,
    sourceId: source,
    trackName: id,
    artistName: 'Artist',
    albumName: 'Album',
    filePath: '$root/Documents/Music/$id.flac',
    coverPath: '$root/Library/Caches/$id.jpg',
    scannedAt: DateTime.utc(2026),
  ).toJson(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Database db;
  late DatabaseFactory factory;
  final reads = <SqfliteLoggerSqlEvent<Object?>>[];

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('library-ios-paths-');
    // ignore: experimental_member_use
    factory = SqfliteDatabaseFactoryLogger(
      databaseFactoryFfi,
      options: SqfliteLoggerOptions(
        type: SqfliteDatabaseFactoryLoggerType.all,
        log: (event) {
          if (event is SqfliteLoggerSqlEvent<Object?> &&
              event.sql.trimLeft().startsWith('SELECT')) {
            reads.add(event);
          }
        },
      ),
    );
    db = await factory.openDatabase('${directory.path}/library.db');
    await LibrarySchema.create(db, LibrarySchema.version);
    reads.clear();
    addTearDown(() async {
      await db.close();
      await directory.delete(recursive: true);
    });
  });

  test('rebases bounded pages and persists the repeat-open guard', () async {
    final batch = db.batch();
    for (var index = 0; index < 600; index++) {
      batch.insert(
        'library',
        _track('old-${index.toString().padLeft(3, '0')}'),
      );
    }
    for (var index = 0; index < 300; index++) {
      batch.insert('library', _track('current-$index', root: _currentRoot));
    }
    batch.insert('library_sources', {
      'id': 'bookmarked',
      'path': '$_oldRoot/Documents/External',
      'display_name': 'External',
      'bookmark': 'bookmark-data',
    });
    batch.insert('library', _track('external', source: 'bookmarked'));
    batch.insert('library_sources', {
      'id': 'local',
      'path': '$_oldRoot/Documents/Music',
      'display_name': 'Music',
    });
    for (final table in [
      'library_cue_split_sources',
      'library_cue_split_outputs',
    ]) {
      batch.insert(table, {
        'file_path': '$_oldRoot/Documents/Music/disc.flac',
        'cue_path': '$_oldRoot/Documents/Music/disc.cue',
      });
    }
    await batch.commit(noResult: true);
    reads.clear();

    expect(
      await LibrarySchema.rebaseContainerPaths(db, '$_currentRoot/Documents'),
      isTrue,
    );
    final pages = reads.where((event) => event.sql.contains('FROM library '));
    expect(pages, hasLength(3));
    for (final page in pages) {
      expect(page.sql, contains('ORDER BY id LIMIT 256'));
      expect(page.sql, contains('substr(file_path, 1, ?) != ?'));
      expect((page.result as List).length, lessThanOrEqualTo(256));
    }
    expect(pages.expand((page) => page.result as List), hasLength(601));
    final rows = await db.query('library');
    expect(rows, hasLength(901));
    for (final row in rows) {
      final id = row['id'] as String;
      expect(
        row['file_path'],
        '${id == 'external' ? _oldRoot : _currentRoot}/Documents/Music/$id.flac',
      );
      expect(row['cover_path'], '$_currentRoot/Library/Caches/$id.jpg');
    }
    final keys = await db.query(
      'library_path_keys',
      where: 'item_id = ?',
      whereArgs: ['old-599'],
    );
    expect(
      keys.map((row) => row['path_key']),
      unorderedEquals(
        buildPathMatchKeys('$_currentRoot/Documents/Music/old-599.flac'),
      ),
    );
    expect(
      (await db.query(
        'library_sources',
        where: 'id = ?',
        whereArgs: ['local'],
      )).single['path'],
      '$_currentRoot/Documents/Music',
    );
    expect(
      (await db.query(
        'library_sources',
        where: 'id = ?',
        whereArgs: ['bookmarked'],
      )).single['path'],
      '$_oldRoot/Documents/External',
    );
    for (final table in [
      'library_cue_split_sources',
      'library_cue_split_outputs',
    ]) {
      expect((await db.query(table)).single, {
        'file_path': '$_currentRoot/Documents/Music/disc.flac',
        'cue_path': '$_currentRoot/Documents/Music/disc.cue',
      });
    }

    final path = db.path;
    await db.close();
    db = await factory.openDatabase(path);
    reads.clear();
    expect(
      await LibrarySchema.rebaseContainerPaths(db, '$_currentRoot/Documents'),
      isFalse,
    );
    expect(reads, hasLength(1));
    expect(reads.single.sql, contains('FROM library_state'));

    expect(
      await LibrarySchema.rebaseContainerPaths(db, '$_nextRoot/Documents'),
      isTrue,
    );
    expect(
      (await db.query(
        'library',
        where: 'id = ?',
        whereArgs: ['old-599'],
      )).single['file_path'],
      '$_nextRoot/Documents/Music/old-599.flac',
    );
  });

  test(
    'a v20 downgrade and v21 reopen preserve rows and the container guard',
    () async {
      await db.insert('library', _track('song'));
      await db.setVersion(LibrarySchema.version);
      await LibrarySchema.rebaseContainerPaths(db, '$_currentRoot/Documents');
      final rows = await db.query('library');
      final path = db.path;
      await db.close();
      db = await factory.openDatabase(
        path,
        options: OpenDatabaseOptions(version: 20),
      );
      expect(await db.getVersion(), 20);
      expect(await db.query('library'), rows);
      expect(
        await db.rawQuery(
          'SELECT id FROM library INDEXED BY idx_library_file_path WHERE file_path = ?',
          ['$_currentRoot/Documents/Music/song.flac'],
        ),
        [
          {'id': 'song'},
        ],
      );
      await db.close();
      db = await factory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: LibrarySchema.version,
          onUpgrade: LibrarySchema.upgrade,
        ),
      );
      expect(await db.query('library'), rows);
      reads.clear();
      expect(
        await LibrarySchema.rebaseContainerPaths(db, '$_currentRoot/Documents'),
        isFalse,
      );
      expect(reads, hasLength(1));
    },
  );

  test(
    'CUE migration pages remain bounded while their path keys change',
    () async {
      final batch = db.batch();
      for (final table in [
        'library_cue_split_sources',
        'library_cue_split_outputs',
      ]) {
        for (var index = 0; index < 600; index++) {
          batch.insert(table, {
            'file_path': '$_oldRoot/Documents/Music/$index.flac',
            'cue_path': '$_oldRoot/Documents/Music/$index.cue',
          });
        }
      }
      await batch.commit(noResult: true);
      reads.clear();
      await LibrarySchema.rebaseContainerPaths(db, '$_currentRoot/Documents');
      final pages = reads.where(
        (event) => event.sql.contains('FROM library_cue_split_'),
      );
      expect(pages, hasLength(6));
      for (final page in pages) {
        expect(page.sql, contains('ORDER BY rowid LIMIT 256'));
        expect((page.result as List).length, lessThanOrEqualTo(256));
      }
      for (final table in [
        'library_cue_split_sources',
        'library_cue_split_outputs',
      ]) {
        final rows = await db.query(table);
        expect(rows, hasLength(600));
        for (final row in rows) {
          expect(row['file_path'], startsWith('$_currentRoot/Documents/'));
          expect(row['cue_path'], startsWith('$_currentRoot/Documents/'));
        }
      }
    },
  );

  test(
    'a failed migration rolls back paths and retries without a marker',
    () async {
      await db.insert('library', _track('song'));
      await db.execute('''
      CREATE TRIGGER fail_rebase BEFORE UPDATE ON library
      BEGIN SELECT RAISE(ABORT, 'test failure'); END
    ''');
      await expectLater(
        LibrarySchema.rebaseContainerPaths(db, '$_currentRoot/Documents'),
        throwsA(isA<DatabaseException>()),
      );
      expect(await db.query(LibrarySchema.stateTable), isEmpty);
      expect(
        (await db.query('library')).single['file_path'],
        '$_oldRoot/Documents/Music/song.flac',
      );
      await db.execute('DROP TRIGGER fail_rebase');
      expect(
        await LibrarySchema.rebaseContainerPaths(db, '$_currentRoot/Documents'),
        isTrue,
      );
      expect(
        (await db.query('library')).single['file_path'],
        '$_currentRoot/Documents/Music/song.flac',
      );
    },
  );
}
