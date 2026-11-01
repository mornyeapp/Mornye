import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/history_row_mapper.dart';
import 'package:mornye/services/history_schema.dart';

import 'support/sqlite_process_database.dart';

Future<Set<String>> _columns(SqliteProcessDatabase db) async => {
  for (final row in await db.rawQuery('PRAGMA table_info(history)'))
    '${row['name']} ${row['type']} ${row['notnull']} ${row['dflt_value']}',
};

Future<Map<String, Object?>> _schemaObjects(SqliteProcessDatabase db) async => {
  for (final row in await db.rawQuery(
    "SELECT name, sql FROM sqlite_master WHERE type = 'index' "
    "AND sql IS NOT NULL AND tbl_name = 'history'",
  ))
    row['name'] as String: row['sql'],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'v15 index migration preserves rows and removes recreated indexes',
    () async {
      final db = await SqliteProcessDatabase.open();
      addTearDown(db.close);
      await HistorySchema.create(db, HistoryDatabase.schemaVersion);
      const removed = {
        'idx_downloaded_at': 'downloaded_at DESC',
        'idx_album': 'album_name, album_artist',
        'idx_history_track_artist': 'track_name, artist_name',
      };
      await db.execute('DROP INDEX idx_history_sort_album_artist');
      await db.insert(
        'history',
        HistoryRowMapper.jsonToDbRow({
          'id': 'persisted',
          'trackName': 'Song',
          'artistName': 'Artist',
          'albumName': 'Album',
          'filePath': '/music/song.flac',
          'service': 'example-provider',
          'downloadedAt': '2026-01-02T03:04:05.000Z',
        }),
      );
      final rows = await db.query('history');
      for (var attempt = 0; attempt < 2; attempt++) {
        for (final MapEntry(:key, :value) in removed.entries) {
          await db.execute('CREATE INDEX $key ON history($value)');
        }
        await HistorySchema.upgrade(db, 15, HistoryDatabase.schemaVersion);
        expect(await db.query('history'), rows);
        expect(
          (await _schemaObjects(db)).keys,
          isNot(anyElement(isIn(removed.keys))),
        );
        final plan = await db.rawQuery(
          'EXPLAIN QUERY PLAN SELECT id FROM history WHERE sort_album_artist = ?',
          ['artist'],
        );
        expect(
          plan.single['detail'],
          contains('idx_history_sort_album_artist'),
        );
      }
    },
  );

  test(
    'v1 upgrade reaches the fresh history schema and backfills rows',
    () async {
      final fresh = await SqliteProcessDatabase.open();
      final upgraded = await SqliteProcessDatabase.open();
      addTearDown(fresh.close);
      addTearDown(upgraded.close);
      await HistorySchema.create(fresh, HistoryDatabase.schemaVersion);

      await upgraded.execute('''CREATE TABLE history (
      id TEXT PRIMARY KEY, track_name TEXT NOT NULL, artist_name TEXT NOT NULL,
      album_name TEXT NOT NULL, album_artist TEXT, cover_url TEXT,
      file_path TEXT NOT NULL, service TEXT NOT NULL,
      downloaded_at TEXT NOT NULL, isrc TEXT, spotify_id TEXT,
      track_number INTEGER, disc_number INTEGER, duration INTEGER,
      release_date TEXT, quality TEXT, bit_depth INTEGER, sample_rate INTEGER,
      genre TEXT, label TEXT, copyright TEXT
    )''');
      await upgraded.insert('history', {
        'id': 'old',
        'track_name': ' Song ',
        'artist_name': 'ARTIST',
        'album_name': 'Album',
        'file_path': '/music/Album/Song.flac',
        'service': 'test',
        'downloaded_at': '2026-01-02T03:04:05.000Z',
        'isrc': 'us-abc-26-00001',
        'spotify_id': ' Track-ID ',
        'release_date': ' 2026-01-01 ',
        'genre': ' Pop ',
      });

      await HistorySchema.upgrade(upgraded, 1, HistoryDatabase.schemaVersion);

      expect(await _columns(upgraded), await _columns(fresh));
      final freshIndexes = await _schemaObjects(fresh);
      final upgradedIndexes = await _schemaObjects(upgraded);
      for (final name in upgradedIndexes.keys) {
        expect(upgradedIndexes[name], freshIndexes[name], reason: name);
      }
      expect(
        upgradedIndexes.keys,
        containsAll(<String>[
          'idx_history_sort_album_artist',
          'idx_history_spotify_id_norm',
          'idx_history_isrc_norm',
          'idx_history_match_key',
          'idx_history_album_key',
          'idx_history_queue_added',
          'idx_history_queue_track',
          'idx_history_queue_artist',
          'idx_history_queue_album',
          'idx_history_queue_genre',
          'idx_history_queue_release',
        ]),
      );
      for (final indexes in [freshIndexes, upgradedIndexes]) {
        expect(
          indexes.keys,
          isNot(anyElement(isIn(HistorySchema.unusedIndexes))),
        );
      }

      final row = (await upgraded.query('history')).single;
      final expected = {
        ...HistoryRowMapper.normalizedColumns(
          spotifyId: ' Track-ID ',
          isrc: 'us-abc-26-00001',
          trackName: ' Song ',
          artistName: 'ARTIST',
          albumName: 'Album',
          albumArtist: null,
        ),
        ...HistoryRowMapper.queueSortColumns(
          trackName: ' Song ',
          artistName: 'ARTIST',
          albumName: 'Album',
          albumArtist: null,
          genre: ' Pop ',
          releaseDate: ' 2026-01-01 ',
          downloadedAt: '2026-01-02T03:04:05.000Z',
        ),
        'explicit': 0,
        'has_lyrics': 0,
        'lyrics_metadata_scan_version': 0,
        'has_replaygain': 0,
        'replaygain_metadata_scan_version': 0,
      };
      for (final entry in expected.entries) {
        expect(row[entry.key], entry.value, reason: entry.key);
      }
      expect(row['match_key'], 'song|artist');
      expect(row['sort_genre'], 'pop');
      expect(await upgraded.query('history_path_keys'), isNotEmpty);
    },
  );
}
