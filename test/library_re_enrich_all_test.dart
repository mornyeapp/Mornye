import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/library_re_enrich_all.dart';
import 'package:mornye/models/library_database_models.dart';

Map<String, dynamic> _local(String id, String path) => {
  'source': 'local',
  'item': {
    'id': id,
    'trackName': 'Song $id',
    'artistName': 'Artist',
    'albumName': 'Album',
    'filePath': path,
    'scannedAt': '2026-01-01T00:00:00.000Z',
  },
};

Map<String, dynamic> _downloaded(String id, String path) => {
  'source': 'downloaded',
  'item': {
    'id': id,
    'trackName': 'Song $id',
    'artistName': 'Artist',
    'albumName': 'Album',
    'filePath': path,
    'service': 'tidal',
    'downloadedAt': '2026-01-01T00:00:00.000Z',
  },
};

void main() {
  test('pages through the whole Library and skips network songs', () async {
    final pages = [
      [
        _downloaded('d1', r'C:\Music\a.flac'),
        _local('l1', 'network://navidrome/subsonic/song/1.flac'),
      ],
      [_local('l2', '/music/b.flac'), _local('l3', 'network://smb/c.flac')],
      [_local('l4', '/music/d.flac')],
    ];
    final queries = <QueueLibraryDbQuery>[];
    final items = await loadReEnrichableLibraryItems(
      includeLocal: true,
      pageSize: 2,
      readPage: (query) async {
        queries.add(query);
        final index = queries.length - 1;
        return QueueLibraryDbPage(
          rows: pages[index],
          nextCursor: index + 1 < pages.length
              ? QueueLibraryDbCursor(['after-$index'])
              : null,
        );
      },
    );

    expect(items.map((item) => item.filePath), [
      r'C:\Music\a.flac',
      '/music/b.flac',
      '/music/d.flac',
    ]);
    expect(queries, hasLength(3));
    expect(queries.first.cursor, isNull);
    expect(queries[1].cursor, const QueueLibraryDbCursor(['after-0']));
    expect(queries[2].cursor, const QueueLibraryDbCursor(['after-1']));
    expect(queries.every((query) => query.includeLocal), isTrue);
    expect(queries.every((query) => query.source == null), isTrue);
    expect(queries.every((query) => query.metadata == null), isTrue);
  });

  test('stops after a short page', () async {
    var reads = 0;
    final items = await loadReEnrichableLibraryItems(
      includeLocal: false,
      pageSize: 5,
      readPage: (query) async {
        reads++;
        expect(query.includeLocal, isFalse);
        return QueueLibraryDbPage(
          rows: [_downloaded('d1', '/music/a.flac')],
          nextCursor: const QueueLibraryDbCursor(['next']),
        );
      },
    );
    expect(reads, 1);
    expect(items, hasLength(1));
  });

  test('only plain and document paths are writable', () {
    expect(isReEnrichableLibraryPath('/music/a.flac'), isTrue);
    expect(isReEnrichableLibraryPath(r'C:\Music\a.flac'), isTrue);
    expect(
      isReEnrichableLibraryPath('content://com.android/tree/x/document/y'),
      isTrue,
    );
    expect(
      isReEnrichableLibraryPath('network://abc/subsonic/song/1.flac'),
      isFalse,
    );
    expect(isReEnrichableLibraryPath('  '), isFalse);
  });
}
