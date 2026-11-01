import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/album_completeness.dart';
import 'package:mornye/services/library_queue_store.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;

// Whitespace outside literals is insignificant, and no literal in the queue
// SQL contains a whitespace run.
String _normalized(String sql) => sql.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Records every query and returns no rows, so the generated SQL can be pinned
/// without a database.
class _RecordingDatabase implements Database {
  final queries = <String>[];

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    queries.add('${_normalized(sql)}\n${jsonEncode(arguments)}');
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _sortModes = [
  'latest',
  'oldest',
  'a-z',
  'z-a',
  'artist-asc',
  'artist-desc',
  'album-asc',
  'album-desc',
  'release-oldest',
  'release-newest',
  'genre-asc',
  'genre-desc',
  'size-asc',
  'size-desc',
  'unknown-sort',
];

const _cursor4 = QueueLibraryDbCursor(['c0', 'c1', 2, 'c3']);
const _cursor5 = QueueLibraryDbCursor(['c0', 1, 'c2', 'c3', 'c4']);

final _filters =
    <String, QueueLibraryDbQuery Function(String, QueueLibraryDbCursor?)>{
      'default': (sort, cursor) =>
          QueueLibraryDbQuery(sortMode: sort, cursor: cursor),
      'source-downloaded': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        source: 'downloaded',
      ),
      'source-local': (sort, cursor) =>
          QueueLibraryDbQuery(sortMode: sort, cursor: cursor, source: 'local'),
      'source-other': (sort, cursor) =>
          QueueLibraryDbQuery(sortMode: sort, cursor: cursor, source: 'other'),
      'no-local': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        includeLocal: false,
      ),
      'no-local-source-local': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        includeLocal: false,
        source: 'local',
      ),
      'singles': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        filterMode: 'singles',
      ),
      'singles-downloaded': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        filterMode: 'singles',
        source: 'downloaded',
      ),
      'search': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        searchQuery: ' Hello_50% \\ World ',
      ),
      'album-artist': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        albumArtist: 'Some Artist',
      ),
      'quality-hires': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        quality: ' HiRes ',
      ),
      'quality-cd': (sort, cursor) =>
          QueueLibraryDbQuery(sortMode: sort, cursor: cursor, quality: 'cd'),
      'quality-lossy': (sort, cursor) =>
          QueueLibraryDbQuery(sortMode: sort, cursor: cursor, quality: 'lossy'),
      'format-m4a': (sort, cursor) =>
          QueueLibraryDbQuery(sortMode: sort, cursor: cursor, format: 'M4A'),
      'format-unknown': (sort, cursor) =>
          QueueLibraryDbQuery(sortMode: sort, cursor: cursor, format: 'x_y%'),
      for (final metadata in [
        'complete',
        'missing-any',
        'missing-year',
        'missing-genre',
        'missing-album-artist',
        'missing-track-number',
        'missing-disc-number',
        'missing-artist',
        'incorrect-isrc-format',
        'missing-isrc',
        'missing-label',
        'missing-lyrics',
        'has-replaygain',
        'missing-replaygain',
        'incomplete-album',
        'unknown-album-completeness',
        'unknown-metadata',
      ])
        'metadata-$metadata': (sort, cursor) => QueueLibraryDbQuery(
          sortMode: sort,
          cursor: cursor,
          metadata: metadata,
        ),
      'single-track-albums': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        includeSingleTrackAlbums: true,
      ),
      'single-track-albums-incomplete': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        includeSingleTrackAlbums: true,
        metadata: 'incomplete-album',
      ),
      'combined': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        source: 'downloaded',
        filterMode: 'singles',
        searchQuery: 'hello',
        albumArtist: 'Some Artist',
        quality: 'hires',
        format: 'flac',
        metadata: 'missing-genre',
        limit: 7,
        offset: 21,
      ),
      'combined-local': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        source: 'local',
        filterMode: 'singles',
        searchQuery: 'hello',
        albumArtist: 'Some Artist',
        quality: 'cd',
        format: 'ogg',
        metadata: 'unknown-album-completeness',
        limit: 7,
        offset: 21,
      ),
    };

/// SHA-256 of the normalized SQL and bound arguments of every query each case
/// issues. Captured from the reference implementation; a mismatch means the
/// Library order, filter or paging SQL changed.
const _expectedDigests = <String, String>{
  'sort:latest':
      '5f454cc6e3addbb5b29f51e08ef541a84749ed5bcf9da1a22e43d23bd0f923f2',
  'sort:oldest':
      '177aa1bdba1118287dcd6edda7bd0d115d04d0b778f627ea0425b9e5dda6a442',
  'sort:a-z':
      '6f8f5ecf435ab9dcfdb8c86e670f52e3c8e1a4bbd800565c84691f98ed720ea4',
  'sort:z-a':
      '6f1909c35b1a22a1e0881bbbc241125fde2b28803f7bb08435851e26f72ba88a',
  'sort:artist-asc':
      '8da0fb1dce55964159a5862a7a20889bb186474a70f9595b870f9034b05e577f',
  'sort:artist-desc':
      'abcf7dc4e3b8332471d2f84d34083a08a09b60200932ec40d0418a3ac0ad902c',
  'sort:album-asc':
      'e906b8567021383055d27a47ace61c85b7723207abb51e95d21a454587a72996',
  'sort:album-desc':
      '0aaabf7f7157d3be3abfa623b4e70108f79b5dff1adf37c5345cadd2f4224a9e',
  'sort:release-oldest':
      'ce5b91a0f34a176d920ea5ff5aced295e6c0b0f740349c37b89f6e435240cbeb',
  'sort:release-newest':
      'b3bda6b40da843ceca124b89618b9815e20592ed853cf58b0b81e8e2a6f1bac9',
  'sort:genre-asc':
      'd844ecb66d6d468c4f1332800f2a112df22bb69c2478f9f0b0646a321eb1c96d',
  'sort:genre-desc':
      '8d16a3bcfc6471912396d1240de0eab1ef06478a7f4c0d3616bf7c25f7090d82',
  'sort:size-asc':
      'f4bdefd7794a3bc8cd57019e5aefc0aef97e60689338c15f86e94381ea8946e6',
  'sort:size-desc':
      '9b8841e028660b08d392dc77d64c1822e1008866385688bd57152a8359afb7be',
  'sort:unknown-sort':
      '5f454cc6e3addbb5b29f51e08ef541a84749ed5bcf9da1a22e43d23bd0f923f2',
  'filter:default':
      'e3f8eeddb2299b73c2865b59d93f347720df749f846e60c0a6c3f794bd197b83',
  'filter:source-downloaded':
      '0b134efd64358ad588f2390ea2bc57d5a2aafda976e1705ed3516625e6b491a6',
  'filter:source-local':
      '43f5da5f7084c124f202519ef1633cf964667ca07682ad4929070ee063401121',
  'filter:source-other':
      'baca88d62f3bcd81f9b513a1daa11647cc1f949971ab18bfa51eb0b8aabe2991',
  'filter:no-local':
      'faade8268d94dc81445ba77c8e1def463109f09366136fac53dd1be9d9855423',
  'filter:no-local-source-local':
      '2f37e8a9acfbb6130cf424745afb972bd0cb930392c8b972cce4382a6d9fe3b9',
  'filter:singles':
      'acd67fb0d8a21569a99acf442b297ffff2c58d1fab7dfe48f0929421a8b4b15c',
  'filter:singles-downloaded':
      '80a4a9998c8b661a8691c03e081e02d2d28d80caf1aed075bdd9cf89b77e291a',
  'filter:search':
      'e855653be9c292d81b1245c28c82b2fc71c4c3bb1572042548552f5f422f152e',
  'filter:album-artist':
      '22dfba8ce62daa420034585fdae0a4176d10e498b3c93db557f48a73ef3a2680',
  'filter:quality-hires':
      '8523278e250c9d9a50be1676ad11db2bf5183912e2aac24e8e7c5e874bf9490e',
  'filter:quality-cd':
      '7aa8c2ad040fb9620cc13dccf6f4e436f0a42340fa29095f0fe02e35aff3c2b2',
  'filter:quality-lossy':
      '72aed01e020a72d0f96019316bddc72a2dabd7f5e4894c176f3bfc1ecec5440f',
  'filter:format-m4a':
      '2a8b0782af25d44ce5e79b8cff56d41aaecb281777ca8a99674044a44c47376c',
  'filter:format-unknown':
      'e8835f9a3feaa000eadcb3116dbfcf09e3313b25ff75a2516f11819f81972d99',
  'filter:metadata-complete':
      'e568d9798c828d2a313cc4b7cc740eb0593df095ff95a56837f51f83bad54840',
  'filter:metadata-missing-any':
      '461ec155fdfe79fee43559815e55369a53509c81e6cbd3d5142aa3ab39a1e2dc',
  'filter:metadata-missing-year':
      '4558bb9d750603622e4584caf1919f48b41b6c349bbc681150c4079b3777991a',
  'filter:metadata-missing-genre':
      '8e249101ee5b6a4a144943e22f8623cbe6b937b04756685824d25da435d9fdad',
  'filter:metadata-missing-album-artist':
      '33745cb4b821d499aef70d477e5475db1fec6be440b8493dc4f8bbc325fcd5fe',
  'filter:metadata-missing-track-number':
      'b3f758c7cad16b67359a164a8448c90a6eddcd1ec6dddc6d739cbd257dd751c7',
  'filter:metadata-missing-disc-number':
      'fd5076ccc74093f863558c22c2c6f7acbe8df0d3ff12f9e4f1737c432808b483',
  'filter:metadata-missing-artist':
      'c2508a3489e2a586c1fc9ca30e19bfa740f55a0bab2c14e3d1b22bc5ff26e73b',
  'filter:metadata-incorrect-isrc-format':
      'd1c6eb09dc78fb3a314e95b93cea9373060dab90d3dc0baeaa0840e0280b2523',
  'filter:metadata-missing-isrc':
      'd4c6bfb2c200f5c36e6911d7e7b1cbf0b4065acf6ba5adb3c933f32ffef5a989',
  'filter:metadata-missing-label':
      '68a36f7747535f9ce76af09eca9ed462e5741ae5c5e6580c3c6d5cb0c647e71d',
  'filter:metadata-missing-lyrics':
      '8300622c7fbe922ff5ab3e308f569418194bbf5b606edab2deab94093a830d71',
  'filter:metadata-has-replaygain':
      '4429725b2cde12ad850f5174c727dbe790e2885dcb24053d93fff57530a75aa9',
  'filter:metadata-missing-replaygain':
      '8a2d1efe5e59c51e379249bf1c9bfee09fff87fd9b11722588fc3ddc32b5cba9',
  'filter:metadata-incomplete-album':
      '36864a5cacd0a6abb9b5fda6ae1093aeea40cc6649944c7434cb88f92a05322b',
  'filter:metadata-unknown-album-completeness':
      'ffc8d309d9c307380aa04eec8be1479a160ab6c6646650fe64847eb80b51a1bc',
  'filter:metadata-unknown-metadata':
      '18457139305325fec69390099668c4a3a1003a4dbfc42e1883cfacad035de652',
  'filter:single-track-albums':
      '98909aa3debb5bd1979501e58a524ea430bed5312fc9600532710f5ff4f54331',
  'filter:single-track-albums-incomplete':
      '36864a5cacd0a6abb9b5fda6ae1093aeea40cc6649944c7434cb88f92a05322b',
  'filter:combined':
      '2a6bddab48e992a448448aee0803b28325d79ef83cc78a65f347d31ad9de68cc',
  'filter:combined-local':
      'e0dbe15bc2ed66fde25a50f7d4f3eec9722f93fbab6e95bf9a6b248083309341',
};

/// Each shadow check of the snapshot SQL, with the row check it replaces.
final _rowChecks = {
  for (final includeLocal in [true, false])
    _normalized(
      albumInventorySql(includeLocal: includeLocal, shadowSnapshot: true),
    ): _normalized(
      albumInventorySql(includeLocal: includeLocal),
    ),
  for (final alias in ['l', 'candidate'])
    _normalized(sqlite.libraryNotShadowedSql(alias, snapshot: true)):
        _normalized(sqlite.libraryNotShadowedSql(alias)),
};
final _snapshotSql = <String>[];

/// Also issues the shadow-snapshot SQL, which must equal the pinned SQL once
/// each shadow check is put back to its row check.
Future<String> _digest(
  Future<void> Function(LibraryQueueStore store) issue,
) async {
  final queries = <String>[];
  for (final fts in [false, true]) {
    final db = _RecordingDatabase();
    await issue(LibraryQueueStore(db, historyFts: fts, localFts: fts));
    queries.addAll(db.queries);
    final snapshot = _RecordingDatabase();
    await issue(
      LibraryQueueStore(
        snapshot,
        historyFts: fts,
        localFts: fts,
        shadowSnapshot: true,
      ),
    );
    _snapshotSql.addAll(snapshot.queries);
    expect([
      for (final sql in snapshot.queries)
        _rowChecks.entries.fold(
          sql,
          (sql, check) => sql.replaceAll(check.key, check.value),
        ),
    ], db.queries);
  }
  return sha256.convert(utf8.encode(queries.join('\n---\n'))).toString();
}

void main() {
  test(
    'queue SQL is pinned for every sort mode, filter and page shape',
    () async {
      final actual = <String, String>{};
      for (final sort in _sortModes) {
        actual['sort:$sort'] = await _digest((store) async {
          for (final cursor in [null, _cursor4, _cursor5]) {
            final request = QueueLibraryDbQuery(sortMode: sort, cursor: cursor);
            await store.trackPage(request);
            await store.albumPage(request);
          }
          final paged = QueueLibraryDbQuery(
            sortMode: sort,
            limit: 20,
            offset: 40,
          );
          await store.trackPage(paged);
          await store.albumPage(paged);
        });
      }
      for (final MapEntry(key: name, value: build) in _filters.entries) {
        actual['filter:$name'] = await _digest((store) async {
          for (final (sort, cursor) in [
            ('latest', null),
            ('latest', _cursor4),
            ('size-desc', null),
            ('size-desc', _cursor5),
            ('album-asc', _cursor4),
          ]) {
            final request = build(sort, cursor);
            await store.trackPage(request);
            await store.albumPage(request);
            await store.counts(request);
            await store.artistPage(request);
          }
        });
      }
      final mismatches = [
        for (final MapEntry(:key, :value) in actual.entries)
          if (_expectedDigests[key] != value) "    '$key': '$value',",
      ];
      expect(
        mismatches,
        isEmpty,
        reason: 'Changed SQL digests:\n${mismatches.join('\n')}',
      );
      expect(_expectedDigests.keys, unorderedEquals(actual.keys));
      // No snapshot query probes a row's path keys against History.
      expect(
        _snapshotSql.where((sql) => sql.contains('history_path_keys')),
        isEmpty,
      );
      expect(
        _snapshotSql.where((sql) => sql.contains('library_shadowed')),
        isNotEmpty,
      );
    },
  );
}
