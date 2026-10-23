import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/library_database_models.dart';
import 'package:mornye/services/library_queue_store.dart';

/// Records every query and returns no rows, so the generated SQL can be pinned
/// without a database.
class _RecordingDatabase implements Database {
  final queries = <String>[];

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    // Whitespace outside literals is insignificant, and no literal in the
    // queue SQL contains a whitespace run.
    final normalized = sql.replaceAll(RegExp(r'\s+'), ' ').trim();
    queries.add('$normalized\n${jsonEncode(arguments)}');
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
      'd98cb9c3e00591c4b3c6092350d63b317c915cbcf0537ee91c75b9015727b4b1',
  'filter:album-artist':
      'cb63d7d4ff06d393c56ead3ac970c3b6c88ff4823812ebd55bcd5e8300eed277',
  'filter:quality-hires':
      '8fa4b85f1c1d21a75427d693284a0fa783c51e4a1a3eadf26b395e6d3bc659db',
  'filter:quality-cd':
      '7b3184be5cf7015bd1136a2714e4de0def66de53451b10b89e875381678aaff4',
  'filter:quality-lossy':
      '65c1f604a751c315df2aa911eaf2a20cc682e9588a1d987d6969f6220e085260',
  'filter:format-m4a':
      'dd2f1fad2c74fedec1e2b1350b783dd3ebb3fa28a8ab6c17ef94e63696e80b66',
  'filter:format-unknown':
      'ac14c2d401838b7b8fda27efc7af18f968e481e01a795094bf1d69f112a241f2',
  'filter:metadata-complete':
      'fb87783fd82c5907e54b7be899eb9c560670f47ef8c6035266beebf031e1b09f',
  'filter:metadata-missing-any':
      'aaae30fd24864629fc2a2b610297217aef495d910291f6128362701bb2efc362',
  'filter:metadata-missing-year':
      '116fe0127e2b621f97af5eed5d621af32e6a771b474ead896737544080231b80',
  'filter:metadata-missing-genre':
      'b6ce59dfce0c0fc84968672da1944869b2e664efd4de3b024be3d1e24e4a1784',
  'filter:metadata-missing-album-artist':
      '1c4e56cbfd15bb8855d155175ea142811da039a852e214f8c2a14263f00324fa',
  'filter:metadata-missing-track-number':
      '9d021d0221998703f962ba9df9450c0c4711e73f313a7e3f85ad490196344f33',
  'filter:metadata-missing-disc-number':
      'f09e6629557055088c60417b5801376a95d04d486cff337b004fb9ed092d507f',
  'filter:metadata-missing-artist':
      '4704c558a93f414bcd477f6a8aa0f9952a32e7c9b7fd4c2b32e632753a145a5d',
  'filter:metadata-incorrect-isrc-format':
      'ea5040bee229a234e989e005f09db1ebe9f510c09a9d4747d3e1aff38b2aae5c',
  'filter:metadata-missing-isrc':
      '8051ff1f52182083be4a747de191887b029770fa6acd36f75359b8edd57820d4',
  'filter:metadata-missing-label':
      '47d4f0e3aacae691a7e6bb0994f1bd088423ba2834f5e88788d29d780ef346d1',
  'filter:metadata-missing-lyrics':
      'c958d9f39d30efb1a563efdbd279905158810624157fc043767cb60bb33c0872',
  'filter:metadata-has-replaygain':
      'ce9669c2fa83c6f50e029dd77cfc6ef31b2cf2c89a39106c8705963c7f3207ad',
  'filter:metadata-missing-replaygain':
      '2a9d204bb1b106133842900ef910d21bc9228327881da48aee2d0a70553d0924',
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
      '448ec2bf9e111b8e5e0649c9c56741c074f96ae6c67ddf41b0d0e75db7cdaa80',
  'filter:combined-local':
      'b226159a52ced0eb1302c3abccb51ca0af82d59fbc741dce502918bc53c6d40d',
};

Future<String> _digest(
  Future<void> Function(LibraryQueueStore store) issue,
) async {
  final queries = <String>[];
  for (final fts in [false, true]) {
    final db = _RecordingDatabase();
    await issue(LibraryQueueStore(db, historyFts: fts, localFts: fts));
    queries.addAll(db.queries);
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
    },
  );
}
