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
      '32ffe03bb221e2fc726157498930566e85940a10bf20aceba69514b433a0e6d5',
  'sort:oldest':
      'ba51c4e62b17d822161346ee6ced68794b782fcb5cbafe4fb0e4c08c5f18a4ee',
  'sort:a-z':
      '6dc7e3f325b8a9f2ae9444234f275fb0567fdb9ff2fcc65dc102645b2bcfe72e',
  'sort:z-a':
      '8d1361fc81213bf98e8ee6c1375771173f7b3a6f1cc7bc680ae204c0f72c520c',
  'sort:artist-asc':
      'e535993aec4175f1e00d6e74d0d4ee5d29e8b968d50c0c71299f4261ad0805a2',
  'sort:artist-desc':
      '60fc7f31e3f897fbccea4a00e41440e2dc5f32b02f54f7af3b5af9ee443912b1',
  'sort:album-asc':
      'a987ba7eb7473f3b1548fcae81b762ec2944443fadd3663a5eec23dc262481fc',
  'sort:album-desc':
      'b990d8b5ef7bf71f731469caf3d7018ac4c023f9c5711e2ea118b34313032c4a',
  'sort:release-oldest':
      '04a5e44291f4f04e2a2c4f1b942d48173fbf7cacf71ffe12dd5d1e3ef9dd1d7d',
  'sort:release-newest':
      '63d219f44e5a2c3c67347adbc3635b74c6025c3dd6f35b26bda3612cadcc3417',
  'sort:genre-asc':
      'aaae49c02f9eca25ee01161414e899aca00b3a184c1f6cce67c1f431ed89ecd6',
  'sort:genre-desc':
      'a8658b4c0661dd131b9ba5fad68817d4163772453ca727b43506a1a3d91d8675',
  'sort:size-asc':
      '85218343e8e68e7c05d84bff284463fee4501e3b804f547b1957b24434dee79e',
  'sort:size-desc':
      '00ef42759ab1af305bda3c4a1875038b946b181185b1bb4a46fa043460e3c771',
  'sort:unknown-sort':
      '32ffe03bb221e2fc726157498930566e85940a10bf20aceba69514b433a0e6d5',
  'filter:default':
      'f8e8b800aa99f603496d38e15d9c4ead288a0e9e4d158f0415e7ca67c7ead00f',
  'filter:source-downloaded':
      'c2153d2bc80e3188864c6bfccd2ec606178d52a8c74a69ce5234e0ba48f92fe3',
  'filter:source-local':
      'ebd56e568a9469ed178e79b067f5a54a133b40b68fe51f497fa2cd2d5a09d7ce',
  'filter:source-other':
      'bc15c152e43c7e7325b105267968792bb786e2b3f1d810b0851b3b4b4022ca25',
  'filter:no-local':
      'b131db8ad9f9ba235314012f8be51851ec58e98293c97993e8817801cb5748b1',
  'filter:no-local-source-local':
      'fbec44ea7617b9173b666d4b7abccefddb9be67a7e969c0a41a5a8c1b3e9852f',
  'filter:singles':
      'b83b23da96551c86af760c319bf5448efea37de8f5c8d6504f9842bf82801962',
  'filter:singles-downloaded':
      '8b3924736eeeb5a4c595b71047f7399dfc5a4991e68dfe7ae206455c6cb5034d',
  'filter:search':
      '0679a61fe34ab604f1077c1b56521497c8ac2ab25bc6ec144c339b2de90c5002',
  'filter:album-artist':
      'bbfb7efcf0e81fb97fabf4b71e2a9069b5e011b6aed9c8c27e92c61682799385',
  'filter:quality-hires':
      '9670ee9e4a35ca125174faf289e8ee24094d231ec448150cc7710add70ae79af',
  'filter:quality-cd':
      '0fbf399bc35c5c27e6a470094ca11037cabff3c67a42a9fdc8f65ae3ca71c4d1',
  'filter:quality-lossy':
      'd29c6608f891d9c7487c4dc275f6ba0b1bf3e33919d1b00494b71484d74b74d9',
  'filter:format-m4a':
      '05059fab1b27d8672b4b345aba216642e9f0f19391b7fb572f234d539d11d903',
  'filter:format-unknown':
      '634ada18b7e552481383a768afbd2948c177d28c3dccd3607d441c37032161da',
  'filter:metadata-complete':
      '99036bb9aeaf8cbce22a32d78eda90fc98bb2c7aa5bd1f440a34c80512320e85',
  'filter:metadata-missing-any':
      '2c214f254061c8e69caf9992156ba41509027b22ff9b409b23cb03c8477e4883',
  'filter:metadata-missing-year':
      '533c5e3e3fed7610951dae2c21c0a43a2c59c93946ecab23e40db15b7de3ead9',
  'filter:metadata-missing-genre':
      '9460096ab3aaf124b580b54069f79dccd207e66e779ea90b1854c66ea4432c33',
  'filter:metadata-missing-album-artist':
      '56b6e32d70da0e23519ab2aa20e459f1e53d6bc3cd893bd4ebcb146bd4674dd0',
  'filter:metadata-missing-track-number':
      'eace037c0e2ab758b1c75496808d009262a04e57df6d3d691d30143071c59b8d',
  'filter:metadata-missing-disc-number':
      '856c66ea491673b1e90e1dbde218e94e508a23b552cd205b6452ba56ca8e7eaf',
  'filter:metadata-missing-artist':
      '98c2f428a14e2b562922964b622e2340e9f2e7878f85110360f3ca54398a50a6',
  'filter:metadata-incorrect-isrc-format':
      'be35b2ed6e4de358ff7647143ef83467116784293d953234bcd3a8d4b9dc1719',
  'filter:metadata-missing-isrc':
      '1e7ebc3f425b94674789d5b8ea24d669f8fd93920a0128567f4c386a9d95a126',
  'filter:metadata-missing-label':
      'd1cf1947cb5303d997ef5a7f52e0f46eff23d37384f39fcdee3d9ae9a19b0a14',
  'filter:metadata-missing-lyrics':
      'bd20a87abb81d3c9b5ddbb51a7da6083e06efec09a41a4c511fd7ebc6303ce02',
  'filter:metadata-has-replaygain':
      '26d596a27cb091379793ed804b425ddb6dbab7d96bdf6e8c83c569ab146beb25',
  'filter:metadata-missing-replaygain':
      'f378707aa77eb2cfe04b1309171235a0a4b6e2deedad2744dbfef41602ca8b72',
  'filter:metadata-incomplete-album':
      '4e12bfad869e1da52432b4105081cd829b254a67b05f3e293693bbdfb1f1078a',
  'filter:metadata-unknown-album-completeness':
      'adc2a80d9bb9083775726af06d504afd094bdf28ef18e2752feb30d814489e5e',
  'filter:metadata-unknown-metadata':
      'a4897e14edaea96ca23afbf37caaccc05e97e44f544f809eb5407dcb073076ca',
  'filter:single-track-albums':
      '209408ded261ee9d70ab9a1a7642cac06da48585b455fc3582c72d7a51c243f9',
  'filter:single-track-albums-incomplete':
      '4e12bfad869e1da52432b4105081cd829b254a67b05f3e293693bbdfb1f1078a',
  'filter:combined':
      '6ae0f5d51d04f27ea4cc66922c54c82e7b94e828089bb222b356d737b3391454',
  'filter:combined-local':
      '0ff1f1f66bb5f8ceed9ba78aee2cc715e9311db0b9eb58d0841cbfce695ebc8b',
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
