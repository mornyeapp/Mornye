import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/library_schema.dart';

import 'support/sqlite_process_database.dart';

Map<String, dynamic> _track(String id, {String isrc = 'same'}) =>
    LocalLibraryItem(
      id: id,
      trackName: ' Song ',
      artistName: 'ARTIST',
      albumName: 'Album',
      filePath: '/music/$id.flac',
      scannedAt: DateTime.utc(2026),
      isrc: isrc,
      trackNumber: 1,
      totalTracks: 2,
      hasLyrics: true,
      hasReplayGain: true,
    ).toJson();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SqliteProcessDatabase db;
  setUp(() async {
    db = await SqliteProcessDatabase.open();
    await db.execute('PRAGMA recursive_triggers = ON');
  });
  tearDown(() => db.close());

  test(
    'fresh schema maintains lookup counts across replace, source move and deletion',
    () async {
      await LibrarySchema.create(db, LibrarySchema.version);
      for (final id in ['a', 'b']) {
        await db.insert(
          'library',
          LibraryRowMapper.encode(_track(id)),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      Future<List<Map<String, Object?>>> counts() => db.query(
        LibrarySchema.lookupSummaryTable,
        orderBy: 'source_id, kind, value',
      );
      expect((await counts()).map((row) => row['ref_count']), [2, 2]);
      await db.insert(
        'library',
        LibraryRowMapper.encode(_track('a', isrc: 'new')),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      expect((await counts()).map((row) => row['ref_count']), [1, 1, 2]);
      await db.insert('library_sources', {
        'id': 'nas',
        'path': 'network://nas/music',
        'display_name': 'NAS',
      });
      await db.update(
        'library',
        {'source_id': 'nas'},
        where: 'id = ?',
        whereArgs: ['a'],
      );
      expect((await db.query(LibrarySchema.visibleView)).length, 2);
      await db.update(
        'library_sources',
        {'available': 0},
        where: 'id = ?',
        whereArgs: ['nas'],
      );
      expect((await db.query(LibrarySchema.visibleView)).single['id'], 'b');
      await db.delete('library', where: 'id = ?', whereArgs: ['a']);
      expect((await counts()).map((row) => row['ref_count']), [1, 1]);
      await db.delete('library');
      expect(await counts(), isEmpty);
    },
  );

  test(
    'v1 upgrade preserves tracks and backfills current search and path identities',
    () async {
      await db.execute('''CREATE TABLE library (
      id TEXT PRIMARY KEY, track_name TEXT NOT NULL, artist_name TEXT NOT NULL,
      album_name TEXT NOT NULL, album_artist TEXT, file_path TEXT NOT NULL UNIQUE,
      scanned_at TEXT NOT NULL, isrc TEXT, track_number INTEGER, disc_number INTEGER,
      duration INTEGER, release_date TEXT, bit_depth INTEGER, sample_rate INTEGER,
      genre TEXT, format TEXT
    )''');
      await db.insert('library', {
        'id': 'old',
        'track_name': ' Song ',
        'artist_name': 'ARTIST',
        'album_name': 'Album',
        'file_path':
            'content://example.documents/document/nas%3AMusic%2FSong.flac',
        'scanned_at': '2026-01-01T00:00:00.000Z',
        'isrc': 'legacy-isrc',
        'genre': ' Pop ',
      });
      await LibrarySchema.upgrade(db, 1, LibrarySchema.version);
      final row = (await db.query('library')).single;
      expect(row['source_id'], LocalLibraryItem.legacySourceId);
      expect(row['search_text'], 'song artist album artist');
      expect(row['match_key'], 'song|artist');
      expect(row['sort_genre'], 'pop');
      expect(row['audio_metadata_scan_version'], 0);
      expect(row['has_lyrics'], 0);
      expect(row['has_replaygain'], 0);
      expect(
        (await db.query(
          'library_path_keys',
        )).every((key) => key['item_id'] == 'old'),
        isTrue,
      );
      expect(await db.query('library_path_keys'), isNotEmpty);
      expect((await db.query(LibrarySchema.visibleView)).single['id'], 'old');
      expect(
        (await db.query(
          LibrarySchema.lookupSummaryTable,
        )).map((row) => row['ref_count']),
        [1, 1],
      );
    },
  );

  test(
    'v16 upgrade repairs existing lookup counts and replacement triggers',
    () async {
      await LibrarySchema.create(db, 16);
      await db.execute('DROP TRIGGER library_lookup_insert_isrc');
      await db.execute('''
      CREATE TRIGGER library_lookup_insert_isrc AFTER INSERT ON library
      WHEN NEW.isrc IS NOT NULL AND NEW.isrc != ''
      BEGIN
        INSERT OR IGNORE INTO library_lookup_summary(source_id, kind, value, ref_count)
        VALUES (NEW.source_id, 'isrc', NEW.isrc, 0);
        UPDATE library_lookup_summary SET ref_count = ref_count + 1
        WHERE source_id = NEW.source_id AND kind = 'isrc' AND value = NEW.isrc;
      END
    ''');
      for (final id in ['a', 'b']) {
        await db.insert(
          'library',
          LibraryRowMapper.encode(_track(id)),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      Future<List<Map<String, Object?>>> counts() =>
          db.query(LibrarySchema.lookupSummaryTable, orderBy: 'kind');
      expect((await counts()).map((row) => row['ref_count']), [1, 2]);
      await LibrarySchema.upgrade(db, 16, LibrarySchema.version);
      expect((await counts()).map((row) => row['ref_count']), [2, 2]);
      await db.insert(
        'library',
        LibraryRowMapper.encode(_track('a')),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      expect((await counts()).map((row) => row['ref_count']), [2, 2]);
      await db.delete('library', where: 'id = ?', whereArgs: ['a']);
      expect((await counts()).map((row) => row['ref_count']), [1, 1]);
      expect((await db.query('library')).single['id'], 'b');
    },
  );

  test(
    'v17 upgrade retains existing rows and adds network file versions',
    () async {
      await LibrarySchema.create(db, 17);
      await db.execute('ALTER TABLE library DROP COLUMN network_file_version');
      await db.insert('library', {
        'id': 'old',
        'track_name': 'Song',
        'artist_name': 'Artist',
        'album_name': 'Album',
        'file_path': 'network://nas/song.flac',
        'scanned_at': '2026-10-19',
      });
      await LibrarySchema.upgrade(db, 17, LibrarySchema.version);
      expect(
        (await db.query('library')).single['network_file_version'],
        isNull,
      );
      expect((await db.query('library')).single['id'], 'old');
    },
  );

  test('row mapping round-trips metadata and preserves unknown scan flags', () {
    final track = _track('full');
    track['networkFileVersion'] = 'network-fingerprint';
    expect(LibraryRowMapper.decode(LibraryRowMapper.encode(track)), track);
    final filename = LibraryRowMapper.encode({
      ...track,
      'sourceId': 'nas',
      'metadataFromFilename': true,
      'hasReplayGain': false,
    });
    expect(filename['source_id'], 'nas');
    expect(filename['audio_metadata_scan_version'], 0);
    expect(filename['has_replaygain'], 0);
    final tagged = LibraryRowMapper.encode({
      ...track,
      'hasReplayGain': false,
      'replaygain_track_gain': '-4.5 dB',
      'explicit': 1,
      'audioMetadataScanVersion': 3,
    });
    expect(tagged['has_replaygain'], 1);
    expect(tagged['audio_metadata_scan_version'], 3);
    expect(LibraryRowMapper.decode(tagged)['explicit'], true);
  });
}
