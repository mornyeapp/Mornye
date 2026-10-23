import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/library_collections_database.dart';

class PlaylistDeletionDatabase implements LibraryCollectionsDatabase {
  PlaylistDeletionDatabase(this.owner);
  final Database owner;

  @override
  Future<void> deletePlaylists(List<String> ids) =>
      LibraryCollectionsDatabase.deleteDatabasePlaylists(owner, ids);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class PlaylistDeletionCollections extends LibraryCollectionsNotifier {
  PlaylistDeletionCollections(this._initial, Database db)
    : super(database: PlaylistDeletionDatabase(db));
  final LibraryCollectionsState _initial;

  @override
  LibraryCollectionsState build() => _initial;
}

const playlistDeletionTables = [
  'playlists',
  'playlist_tracks',
  'wishlist_tracks',
  'loved_tracks',
];

Future<void> createPlaylistDeletionSchema(Database db) async {
  await db.execute('PRAGMA foreign_keys=ON');
  await db.execute('PRAGMA recursive_triggers=ON');
  await db.rawQuery('PRAGMA journal_mode=WAL');
  await db.execute('PRAGMA synchronous=NORMAL');
  await db.rawQuery('PRAGMA busy_timeout=5000');
  await db.execute('''CREATE TABLE playlists(
    id TEXT PRIMARY KEY, name TEXT NOT NULL, cover_image_path TEXT,
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL)''');
  await db.execute('''CREATE TABLE playlist_tracks(
    playlist_id TEXT NOT NULL, track_key TEXT NOT NULL, track_json TEXT NOT NULL,
    added_at TEXT NOT NULL, PRIMARY KEY(playlist_id, track_key),
    FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE)''');
  await db.execute(
    'CREATE INDEX idx_playlists_created_at ON playlists(created_at DESC)',
  );
  await db.execute(
    'CREATE INDEX idx_playlist_tracks_playlist_id ON playlist_tracks(playlist_id)',
  );
  for (final table in ['wishlist_tracks', 'loved_tracks']) {
    await db.execute('''CREATE TABLE $table(track_key TEXT PRIMARY KEY,
      track_json TEXT NOT NULL, added_at TEXT NOT NULL)''');
    await db.execute(
      'CREATE INDEX idx_${table}_added_at ON $table(added_at DESC)',
    );
  }
}

Future<LibraryCollectionsState> seedPlaylistDeletion(
  Database db,
  int count, {
  int tracksPerPlaylist = 20,
}) async {
  final now = DateTime.utc(2026);
  final stamp = now.toIso8601String();
  final entries = [
    for (var i = 0; i < tracksPerPlaylist; i++)
      CollectionTrackEntry(
        key: 'example:$i',
        addedAt: now,
        track: Track(
          id: '$i',
          name: 'Track $i — 音楽',
          artistName: 'Artist',
          albumName: 'Album',
          source: 'example',
          duration: 180,
        ),
      ),
  ];
  final playlists = [
    for (final id in [
      for (var i = 0; i < count; i++) 'playlist-$i',
      "keep'quoted",
    ])
      UserPlaylistCollection(
        id: id,
        name: 'Name $id',
        createdAt: now,
        updatedAt: now,
        coverImagePath: 'cover-$id',
        tracks: const [],
        trackKeys: entries.map((entry) => entry.key).toSet(),
        tracksLoaded: false,
      ),
  ];
  await db.transaction((txn) async {
    final batch = txn.batch();
    for (final table in playlistDeletionTables) {
      batch.delete(table);
    }
    for (final playlist in playlists) {
      batch.insert('playlists', {
        'id': playlist.id,
        'name': playlist.name,
        'cover_image_path': playlist.coverImagePath,
        'created_at': stamp,
        'updated_at': stamp,
      });
      for (final entry in entries) {
        batch.insert('playlist_tracks', {
          'playlist_id': playlist.id,
          'track_key': entry.key,
          'track_json': jsonEncode(entry.track.toJson()),
          'added_at': stamp,
        });
      }
    }
    for (final table in ['wishlist_tracks', 'loved_tracks']) {
      for (final entry in entries) {
        batch.insert(table, {
          'track_key': entry.key,
          'track_json': jsonEncode(entry.track.toJson()),
          'added_at': stamp,
        });
      }
    }
    await batch.commit(noResult: true);
  });
  return LibraryCollectionsState(
    isLoaded: true,
    playlists: playlists,
    wishlist: entries,
    loved: entries,
  );
}

Future<Map<String, List<Map<String, Object?>>>> playlistDeletionSnapshot(
  Database db,
) async => {
  for (final table in playlistDeletionTables)
    table: await db.rawQuery('SELECT rowid,* FROM $table ORDER BY rowid'),
};
