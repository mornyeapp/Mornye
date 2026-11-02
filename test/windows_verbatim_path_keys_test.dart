import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/library_duplicates.dart';
import 'package:mornye/services/library_schema.dart';
import 'package:mornye/services/sqlite_helpers.dart';
import 'package:mornye/utils/path_match_keys.dart';

import 'support/sqlite_process_database.dart';

const _plain = r'C:\Users\me\Music\Mornye\Artist\Album\01 - Song.flac';
const _verbatim = '\\\\?\\$_plain';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('withoutWindowsVerbatimPrefix', () {
    test('drops the prefix of drive and UNC paths in both spellings', () {
      expect(withoutWindowsVerbatimPrefix(_verbatim), _plain);
      expect(
        withoutWindowsVerbatimPrefix(r'\\?\UNC\server\share\Song.flac'),
        r'\\server\share\Song.flac',
      );
      expect(withoutWindowsVerbatimPrefix('//?/D:/Song.flac'), 'D:/Song.flac');
      expect(
        withoutWindowsVerbatimPrefix('//?/unc/server/Song.flac'),
        '//server/Song.flac',
      );
    });

    test('leaves other paths alone', () {
      for (final path in [
        _plain,
        r'\\server\share\Song.flac',
        r'\\?\Volume{1234}\Song.flac',
        r'\\.\C:\Song.flac',
        '/storage/emulated/0/Music/Song.flac',
        'content://provider/document/1',
        r'\\?\C',
      ]) {
        expect(withoutWindowsVerbatimPrefix(path), isNull, reason: path);
      }
    });
  });

  test('a verbatim path and its plain path are the same physical file', () {
    expect(physicalFilePathsMatch(_verbatim, _plain), isTrue);
    expect(physicalFilePathsMatch(_plain, _verbatim), isTrue);
    expect(
      physicalFilePathsMatch(
        r'\\?\UNC\100.64.0.1\Music\Song.flac',
        r'\\100.64.0.1\Music\Song.flac',
      ),
      isTrue,
    );
    // The extension still tells a converted copy apart.
    expect(
      physicalFilePathsMatch(_verbatim, _plain.replaceAll('.flac', '.opus')),
      isFalse,
    );
    expect(
      buildPathMatchKeys(_verbatim),
      containsAll(buildPathMatchKeys(_plain)),
    );
  });

  group('stored keys', () {
    late SqliteProcessDatabase db;

    setUp(() async {
      db = await SqliteProcessDatabase.open();
      await LibrarySchema.create(db, LibrarySchema.version);
      await db.execute("ATTACH DATABASE ':memory:' AS history_db");
      await db.execute('''CREATE TABLE history_db.history (
        id TEXT PRIMARY KEY, track_name TEXT, artist_name TEXT,
        album_name TEXT, file_path TEXT, isrc TEXT, bit_depth INTEGER,
        sample_rate INTEGER, bitrate INTEGER, format TEXT
      )''');
      await db.execute('''CREATE TABLE history_db.history_path_keys (
        item_id TEXT NOT NULL, path_key TEXT NOT NULL,
        PRIMARY KEY (item_id, path_key)
      )''');
    });
    tearDown(() => db.close());

    Future<void> addDownload(String path) async {
      await db.insert('history_db.history', {
        'id': 'download',
        'track_name': 'Song',
        'artist_name': 'Artist',
        'album_name': 'Album',
        'file_path': path,
        'isrc': 'SAME',
      });
      for (final key in buildPathMatchKeys(path)) {
        await db.insert('history_db.history_path_keys', {
          'item_id': 'download',
          'path_key': key,
        });
      }
    }

    /// A scanned row with the keys the previous builder wrote: the verbatim
    /// spelling and its slash and lowercase variants only.
    Future<void> addScannedWithOldKeys(String id, String path) async {
      await db.insert('library', {
        'id': id,
        'track_name': 'Song',
        'artist_name': 'Artist',
        'album_name': 'Album',
        'file_path': path,
        'isrc': 'SAME',
        'scanned_at': '2026-11-02',
        'source_id': LocalLibraryItem.legacySourceId,
      });
      await db.delete(
        'library_path_keys',
        where: 'item_id = ?',
        whereArgs: [id],
      );
      final slash = path.replaceAll(r'\', '/');
      for (final key in {
        path,
        path.toLowerCase(),
        slash,
        slash.toLowerCase(),
      }) {
        await db.insert('library_path_keys', {'item_id': id, 'path_key': key});
      }
    }

    Future<List<String>> visibleScannedIds() async => [
      for (final row in await db.rawQuery(
        'SELECT l.id FROM library l '
        'WHERE ${libraryNotShadowedSql('l')} ORDER BY l.id',
      ))
        row['id'] as String,
    ];

    test('repair hides the scanned copy of a downloaded file', () async {
      await addDownload(_plain);
      await addScannedWithOldKeys('scanned', _verbatim);
      await addScannedWithOldKeys('other', r'\\?\UNC\server\share\Other.flac');
      await addScannedWithOldKeys('device', r'\\?\Volume{1}\Device.flac');
      expect(await visibleScannedIds(), ['device', 'other', 'scanned']);

      expect(
        await repairWindowsVerbatimPathKeys(db, 'library', 'library_path_keys'),
        2,
      );
      expect(await visibleScannedIds(), ['device', 'other']);
      final keys = await db.query(
        'library_path_keys',
        where: 'item_id = ?',
        whereArgs: ['other'],
      );
      expect(
        keys.map((row) => row['path_key']),
        contains(r'\\server\share\Other.flac'),
      );
      // Repaired rows, and rows without a plain spelling, are not revisited.
      expect(
        await repairWindowsVerbatimPathKeys(db, 'library', 'library_path_keys'),
        0,
      );
    });

    test('duplicate review does not offer a file against itself', () async {
      await addDownload(_plain);
      await addScannedWithOldKeys('scanned', _verbatim);
      expect(await readIsrcDuplicateGroups(db), isEmpty);

      await addScannedWithOldKeys(
        'copy',
        r'\\?\D:\Backup\Artist\Album\01 - Song.flac',
      );
      final group = (await readIsrcDuplicateGroups(db)).single;
      expect(group.entries.map((entry) => entry.filePath), [
        _plain,
        r'\\?\D:\Backup\Artist\Album\01 - Song.flac',
      ]);
    });
  });
}
