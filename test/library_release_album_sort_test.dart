import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/library_queue_store.dart';

import 'support/library_paging_fixture.dart';
import 'support/sqlite_process_database.dart';

List<String> _tracks(QueueLibraryDbPage page) => [
  for (final row in page.rows) '${row['source']}:${(row['item'] as Map)['id']}',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SqliteProcessDatabase db;
  late LibraryQueueStore store;

  setUp(() async {
    db = await SqliteProcessDatabase.open();
    store = await createLibraryPagingFixture(db, albumsPerSource: 6);
    // The paging fixture's history table mirrors the local rows; the track
    // page also reads the download-only columns.
    for (final column in [
      'origin_file_path TEXT',
      'storage_mode TEXT',
      'download_tree_uri TEXT',
      'saf_relative_dir TEXT',
      'saf_file_name TEXT',
      'saf_repaired INTEGER',
      'spotify_id TEXT',
      'replaygain_metadata_scan_version INTEGER',
      'quality TEXT',
    ]) {
      await db.execute('ALTER TABLE history_db.history ADD COLUMN $column');
    }
    // One album per release date: November 2025, then March, May and July
    // 2026, one undated album, and two albums sharing the May date.
    const dates = [
      '2026-03-10',
      '2026-05-20',
      '2026-07-01',
      '2025-11-05',
      '',
      '2026-05-20',
    ];
    for (final table in ['history_db.history', 'library']) {
      for (final (index, date) in dates.indexed) {
        await db.update(
          table,
          {'release_date': date, 'sort_release': date},
          where: 'album_name = ?',
          whereArgs: ['Album ${index.toString().padLeft(4, '0')}'],
        );
      }
    }
    // Album 0001's first track is named after its second one, so only the
    // track number can keep the album in track order.
    for (final (table, titleColumn, normColumn, firstId, secondId) in [
      (
        'history_db.history',
        'track_name',
        'sort_track',
        'download-1-1',
        'download-1-2',
      ),
      ('library', 'track_name', 'track_name_norm', 'local-1-1', 'local-1-2'),
    ]) {
      await db.update(
        table,
        {titleColumn: 'Zebra', normColumn: 'zebra'},
        where: 'id = ?',
        whereArgs: [firstId],
      );
      await db.update(
        table,
        {titleColumn: 'Apple', normColumn: 'apple'},
        where: 'id = ?',
        whereArgs: [secondId],
      );
    }
  });
  tearDown(() => db.close());

  // The fixture also inserts a local mirror of Album 0000's first track
  // under the same path; the Library lists one row per path, so it never
  // appears here.
  List<String> album(int index) => [
    'downloaded:download-$index-1',
    'local:local-$index-1',
    'downloaded:download-$index-2',
    'local:local-$index-2',
  ];

  const oldest = ['release-album-oldest'];
  const newest = ['release-album-newest'];

  for (final mode in [...oldest, ...newest]) {
    final dated = mode == 'release-album-oldest'
        ? [3, 0, 1, 5, 2]
        : [2, 1, 5, 0, 3];
    test(
      '$mode keeps albums whole on a release timeline, undated last',
      () async {
        final full = await store.trackPage(
          QueueLibraryDbQuery(sortMode: mode, limit: 100),
        );
        expect(_tracks(full), [
          for (final index in dated) ...album(index),
          ...album(4),
        ]);
        final paged = <String>[];
        QueueLibraryDbCursor? cursor;
        for (var i = 0; i < 10; i++) {
          final page = await store.trackPage(
            QueueLibraryDbQuery(sortMode: mode, limit: 3, cursor: cursor),
          );
          if (page.rows.isEmpty) break;
          paged.addAll(_tracks(page));
          cursor = page.nextCursor;
        }
        expect(paged, _tracks(full));
        final offset = await store.trackPage(
          QueueLibraryDbQuery(sortMode: mode, limit: 4, offset: 4),
        );
        expect(_tracks(offset), _tracks(full).sublist(4, 8));
      },
    );
  }

  test('release-newest still breaks albums apart, by track title', () async {
    final page = await store.trackPage(
      const QueueLibraryDbQuery(sortMode: 'release-newest', limit: 100),
    );
    final tracks = _tracks(page);
    // Album 0001's second track sorts before its first one: the old
    // release sort breaks the album tie on the track title.
    expect(
      tracks.indexOf('downloaded:download-1-2'),
      lessThan(tracks.indexOf('downloaded:download-1-1')),
    );
  });
}
