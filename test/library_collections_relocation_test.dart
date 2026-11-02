import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/library_collections_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late LibraryCollectionsDatabase collections;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    db = await LibraryCollectionsDatabase.openWithFactory(
      databaseFactoryFfi,
      inMemoryDatabasePath,
    );
    collections = LibraryCollectionsDatabase.withDatabase(db);
  });
  tearDown(() => db.close());

  const track = Track(
    id: 'old',
    name: 'Song',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 180,
    source: 'local',
  );

  test(
    'relocation preserves likes, repeated playlist order and ISRC keys',
    () async {
      await db.insert('playlists', {
        'id': 'p',
        'name': 'Playlist',
        'created_at': '2026-01-01',
        'updated_at': '2026-01-01',
      });
      for (final key in ['local:old', 'occurrence:2:local:old']) {
        await db.insert('playlist_tracks', {
          'playlist_id': 'p',
          'track_key': key,
          'track_json': jsonEncode(track.toJson()),
          'added_at': '2026-01-01',
        });
      }
      await db.insert('loved_tracks', {
        'track_key': 'isrc:TEST123',
        'track_json': jsonEncode(track.copyWith(isrc: 'TEST123').toJson()),
        'added_at': '2026-01-01',
      });
      await db.insert('wishlist_tracks', {
        'track_key': 'broken',
        'track_json': '{',
        'added_at': '2026-01-01',
      });
      await collections.relinkLocalTrack('old', 'new');
      final rows = await db.query('playlist_tracks', orderBy: 'rowid');
      expect(rows.map((r) => r['track_key']), [
        'local:new',
        'occurrence:2:local:new',
      ]);
      for (final row in rows) {
        expect(
          (jsonDecode(row['track_json']! as String)
              as Map<String, dynamic>)['id'],
          'new',
        );
        expect(row['added_at'], '2026-01-01');
      }
      final loved = (await db.query('loved_tracks')).single;
      expect(loved['track_key'], 'isrc:TEST123');
      expect(
        (jsonDecode(loved['track_json']! as String)
            as Map<String, dynamic>)['id'],
        'new',
      );
    },
  );
}
