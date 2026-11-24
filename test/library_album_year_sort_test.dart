import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/library_queue_store.dart';

import 'support/library_paging_fixture.dart';
import 'support/sqlite_process_database.dart';

List<String> _albums(QueueLibraryDbPage page) => [
  for (final row in page.rows) '${row['queue_source']}:${row['album_name']}',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SqliteProcessDatabase db;
  late LibraryQueueStore store;

  setUp(() async {
    db = await SqliteProcessDatabase.open();
    store = await createLibraryPagingFixture(db, albumsPerSource: 6);
    await db.execute(
      'ALTER TABLE history_db.history ADD COLUMN origin_file_path TEXT',
    );
    for (final (table, dates) in [
      (
        'history_db.history',
        ['2001', '2024-12-31', '2024-01-01', '', 'unknown', '2017-08'],
      ),
      ('library', ['2026', '2003', '2003-12', null, '0000', ' 2020-04 ']),
    ]) {
      for (final (index, date) in dates.indexed) {
        await db.update(
          table,
          {'release_date': date},
          where: 'album_name = ?',
          whereArgs: ['Album ${index.toString().padLeft(4, '0')}'],
        );
      }
    }
    // One bad tag must not hide the other track's known album year.
    await db.update(
      'history_db.history',
      {'release_date': '202A'},
      where: 'id = ?',
      whereArgs: ['download-0-2'],
    );
  });
  tearDown(() => db.close());

  const ascending = [
    'downloaded:Album 0000',
    'local:Album 0001',
    'local:Album 0002',
    'downloaded:Album 0005',
    'local:Album 0005',
    'downloaded:Album 0001',
    'downloaded:Album 0002',
    'local:Album 0000',
  ];
  const descending = [
    'local:Album 0000',
    'downloaded:Album 0001',
    'downloaded:Album 0002',
    'local:Album 0005',
    'downloaded:Album 0005',
    'local:Album 0001',
    'local:Album 0002',
    'downloaded:Album 0000',
  ];
  const undated = [
    'downloaded:Album 0003',
    'local:Album 0003',
    'downloaded:Album 0004',
    'local:Album 0004',
  ];

  for (final mode in ['year-asc', 'year-desc']) {
    test(
      '$mode sorts album years across sources with undated albums last',
      () async {
        final full = await store.albumPage(
          QueueLibraryDbQuery(sortMode: mode, limit: 100),
        );
        expect(_albums(full), [
          ...mode == 'year-asc' ? ascending : descending,
          ...undated,
        ]);
        final paged = <String>[];
        QueueLibraryDbCursor? cursor;
        for (var i = 0; i < 10; i++) {
          final page = await store.albumPage(
            QueueLibraryDbQuery(sortMode: mode, limit: 3, cursor: cursor),
          );
          if (page.rows.isEmpty) break;
          paged.addAll(_albums(page));
          cursor = page.nextCursor;
        }
        expect(paged, _albums(full));
        final offset = await store.albumPage(
          QueueLibraryDbQuery(sortMode: mode, limit: 4, offset: 4),
        );
        expect(_albums(offset), _albums(full).sublist(4, 8));
      },
    );

    for (final source in ['downloaded', 'local']) {
      test('$mode keeps year order under the $source source filter', () async {
        final page = await store.albumPage(
          QueueLibraryDbQuery(sortMode: mode, source: source),
        );
        expect(
          _albums(page),
          [
            ...mode == 'year-asc' ? ascending : descending,
            ...undated,
          ].where((id) => id.startsWith('$source:')),
        );
      });
    }
  }
}
