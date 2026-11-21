import 'package:sqflite/sqflite.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/services/library_queue_store.dart';
import 'package:mornye/services/library_schema.dart';

/// Real schema17 local rows, two-source album ties, mirrored paths and an
/// unavailable source. The history read fixture uses the same named columns
/// and covering album index as the app; no network or production DB is touched.
Future<LibraryQueueStore> createLibraryPagingFixture(
  Database db, {
  int albumsPerSource = 500,
  String cover = '',
}) async {
  await LibrarySchema.create(db, LibrarySchema.version);
  await db.execute("ATTACH DATABASE ':memory:' AS history_db");
  await db.execute('''
    CREATE TABLE history_db.history AS
    SELECT *, track_name_norm AS sort_track, artist_name_norm AS sort_artist,
      album_name_norm AS sort_album, album_artist_norm AS sort_album_artist,
      NULL AS cover_url, NULL AS downloaded_at, NULL AS service,
      NULL AS origin_file_path
    FROM library WHERE 0
  ''');
  await db.execute(
    'CREATE INDEX history_db.idx_history_album_key ON history(album_key)',
  );
  await db.execute('''
    CREATE TABLE history_db.history_path_keys (
      item_id TEXT NOT NULL, path_key TEXT NOT NULL,
      PRIMARY KEY (item_id, path_key)
    )
  ''');
  await db.execute('''
    CREATE INDEX history_db.idx_history_path_key
    ON history_path_keys(path_key, item_id)
  ''');
  await db.insert('library_sources', {
    'id': 'offline',
    'path': '/fixture/offline',
    'display_name': 'Offline fixture',
    'available': 0,
  });
  final batch = db.batch();
  void add(int index, int number, {required bool local, bool mirror = false}) {
    final suffix = index.toString().padLeft(4, '0');
    final album = 'Album $suffix';
    final artist = 'Artist $suffix';
    final id =
        '${mirror
            ? 'mirror'
            : local
            ? 'local'
            : 'download'}-$index-$number';
    final path =
        '/fixture/${local && !mirror ? 'local' : 'download'}-$index-$number.flac';
    final fields = <String, Object?>{
      'id': id,
      'track_name': 'Song $number',
      'artist_name': artist,
      'album_artist': artist,
      'album_name': album,
      'album_key': '${album.toLowerCase()}|${artist.toLowerCase()}',
      'file_path': path,
      'track_number': number,
      'disc_number': 1,
      'total_tracks': index % 3 == 2
          ? null
          : index % 3 == 1
          ? 4
          : 2,
      'total_discs': 1,
      'sort_added': index ~/ 4,
      'release_date': '2026',
      'search_text': '$album $artist song $number'.toLowerCase(),
      'sort_genre': '',
      'sort_release': '2026',
      if (local) ...{
        'source_id': 'legacy',
        'scanned_at': '2026-10-07T00:00:00Z',
        'track_name_norm': 'song $number',
        'artist_name_norm': artist.toLowerCase(),
        'album_artist_norm': artist.toLowerCase(),
        'album_name_norm': album.toLowerCase(),
        'cover_path': cover,
      } else ...{
        'sort_track': 'song $number',
        'sort_artist': artist.toLowerCase(),
        'sort_album_artist': artist.toLowerCase(),
        'sort_album': album.toLowerCase(),
        'cover_url': cover,
        'downloaded_at': '2026-10-07T00:00:00Z',
        'service': 'example-provider',
      },
    };
    batch.insert(local ? 'library' : 'history_db.history', fields);
    batch.insert(local ? 'library_path_keys' : 'history_db.history_path_keys', {
      'item_id': id,
      'path_key': path,
    });
  }

  for (var index = 0; index < albumsPerSource; index++) {
    for (var number = 1; number <= 2; number++) {
      add(index, number, local: false);
      add(index, number, local: true);
    }
    if (index % 10 == 0) add(index, 1, local: true, mirror: true);
  }
  batch.insert('library', {
    'id': 'hidden',
    'source_id': 'offline',
    'track_name': 'Hidden track',
    'artist_name': 'Hidden artist',
    'album_name': 'Hidden album',
    'album_key': 'hidden|hidden',
    'file_path': '/fixture/hidden.flac',
    'scanned_at': '2026-10-07T00:00:00Z',
  });
  await batch.commit(noResult: true);
  return LibraryQueueStore(db, historyFts: false, localFts: false);
}

Future<LibraryBrowsePage> readLibraryPagingFixture(
  LibraryQueueStore store,
  LibraryBrowsePageRequest request,
) async {
  final query = libraryBrowseQuery(request);
  if (request.browse.artists) {
    return LibraryBrowsePage.fromRows(
      await store.artistPage(query),
      artists: true,
    );
  }
  final page = await store.albumPage(query);
  return LibraryBrowsePage.fromRows(
    page.rows,
    artists: false,
    nextCursor: page.nextCursor,
  );
}

List<String> libraryPagingIdentities(Iterable<LibraryBrowseEntry> entries) => [
  for (final entry in entries)
    '${entry.source}:${entry.key}:${entry.trackCount}:${entry.completeness?.badge}',
];
