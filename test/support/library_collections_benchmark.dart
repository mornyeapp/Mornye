import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/library_collections_hydration.dart';
import 'package:mornye/services/library_playlist_search.dart';
import 'package:mornye/services/library_search.dart';

LibraryCollectionsSnapshot _fixture(int count) => LibraryCollectionsSnapshot(
  wishlistRows: [
    for (var index = 0; index < count; index++)
      {
        'track_key': 'example:$index',
        'track_json': jsonEncode(
          Track(
            id: '$index',
            name: 'Song $index',
            artistName: 'Artist ${index % 997}',
            albumName: 'Album ${index ~/ 12}',
            duration: 180 + index % 240,
            source: 'example',
            coverUrl: 'https://example.test/$index.jpg',
            isrc: 'XX000${index.toString().padLeft(7, '0')}',
          ).toJson(),
        ),
        'added_at': '2026-10-07T00:00:00Z',
      },
  ],
  lovedRows: const [],
  favoriteArtistRows: const [],
  playlistRows: [
    for (var index = 0; index < 4; index++)
      {
        'id': 'playlist-$index',
        'name': 'Playlist $index',
        'created_at': '2026-10-07T00:00:00Z',
        'updated_at': '2026-10-07T00:00:00Z',
      },
  ],
  playlistTrackRows: [
    for (var index = 0; index < count * 2; index++)
      {'playlist_id': 'playlist-${index % 4}', 'track_key': 'example:$index'},
  ],
);

String _stateDigest(LibraryCollectionsState state) => sha256
    .convert(
      utf8.encode(
        jsonEncode({
          'state': state.toJson(),
          'membership': [
            for (final playlist in state.playlists)
              {'id': playlist.id, 'keys': playlist.trackKeys.toList()..sort()},
          ],
        }),
      ),
    )
    .toString();

Future<({T value, Map<String, int> timing})> measureCollectionOperation<T>(
  FutureOr<T> Function() operation,
) async {
  final watch = Stopwatch()..start();
  var beats = 0;
  var last = 0;
  var maximumGap = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
    final now = watch.elapsedMicroseconds;
    if (now - last > maximumGap) maximumGap = now - last;
    last = now;
    beats++;
  });
  late T value;
  try {
    value = await operation();
  } finally {
    watch.stop();
    timer.cancel();
  }
  if (watch.elapsedMicroseconds - last > maximumGap) {
    maximumGap = watch.elapsedMicroseconds - last;
  }
  return (
    value: value,
    timing: {
      'microseconds': watch.elapsedMicroseconds,
      'heartbeat_count': beats,
      'maximum_gap_us': maximumGap,
    },
  );
}

Future<Map<String, dynamic>> benchmarkCollectionHydration({
  int rows = 40000,
}) async {
  final snapshot = await compute(_fixture, rows);
  final baselineDigest = await compute(
    _stateDigest,
    decodeLibraryCollectionsSnapshot(snapshot),
  );
  await hydrateLibraryCollectionsSnapshot(snapshot);
  final baseline = <Map<String, int>>[];
  final worker = <Map<String, int>>[];
  for (var sample = 0; sample < 5; sample++) {
    for (final useWorker in sample.isEven ? [false, true] : [true, false]) {
      final result = await measureCollectionOperation<LibraryCollectionsState>(
        () => useWorker
            ? hydrateLibraryCollectionsSnapshot(snapshot)
            : decodeLibraryCollectionsSnapshot(snapshot),
      );
      final digest = await compute(_stateDigest, result.value);
      if (digest != baselineDigest) {
        throw StateError('Collection parity failed');
      }
      (useWorker ? worker : baseline).add(result.timing);
    }
  }
  return {
    'rows': rows,
    'membership_rows': rows * 2,
    'baseline': baseline,
    'worker': worker,
    'digest': baselineDigest,
    'note': 'Paired hydration latency and caller heartbeat, not displayed FPS.',
  };
}

List<UserPlaylistCollection> _searchFixture(int count) => [
  for (var index = count - 1; index >= 0; index--)
    UserPlaylistCollection(
      id: '$index',
      name: switch (index % 4) {
        0 => 'rock',
        1 => 'rock mix $index',
        2 => 'my rock $index',
        _ => 'mix rock $index',
      },
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      tracks: const [],
      tracksLoaded: false,
      trackKeys: {'example:$index'},
    ),
];

List<LibrarySearchHit> _baselineSearch(List<UserPlaylistCollection> playlists) {
  final query = LibrarySearchQuery('rock');
  final matches = playlists.where((p) => query.matches(p.name)).toList()
    ..sort((a, b) {
      final rank = query.rank(a.name).compareTo(query.rank(b.name));
      if (rank != 0) return rank;
      final title = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return title != 0 ? title : a.id.compareTo(b.id);
    });
  return matches
      .skip(40)
      .take(40)
      .map(
        (p) => LibrarySearchHit(
          kind: LibrarySearchKind.playlists,
          id: p.id,
          title: p.name,
          cover: p.coverImagePath ?? p.previewCover,
          trackCount: p.trackCount,
        ),
      )
      .toList(growable: false);
}

Future<Map<String, dynamic>> benchmarkPlaylistSearch({int rows = 25000}) async {
  final playlists = await compute(_searchFixture, rows);
  final expected = _baselineSearch(playlists).map((hit) => hit.id).join(',');
  await searchLibraryPlaylists(
    playlists: playlists,
    query: 'rock',
    limit: 40,
    offset: 40,
  );
  final baseline = <Map<String, int>>[];
  final worker = <Map<String, int>>[];
  for (var sample = 0; sample < 5; sample++) {
    for (final useWorker in sample.isEven ? [false, true] : [true, false]) {
      final result = await measureCollectionOperation<List<LibrarySearchHit>>(
        () => useWorker
            ? searchLibraryPlaylists(
                playlists: playlists,
                query: 'rock',
                limit: 40,
                offset: 40,
              )
            : _baselineSearch(playlists),
      );
      if (result.value.map((hit) => hit.id).join(',') != expected) {
        throw StateError('Playlist search parity failed');
      }
      (useWorker ? worker : baseline).add(result.timing);
    }
  }
  return {
    'rows': rows,
    'offset': 40,
    'limit': 40,
    'baseline': baseline,
    'worker': worker,
    'note': 'Original full sort versus production bounded search and worker.',
  };
}

Future<Map<String, dynamic>> benchmarkPlaylistMetadataCopy({
  int rows = 100000,
}) async {
  final state = await compute(
    decodeLibraryCollectionsSnapshot,
    await compute(_fixture, rows),
  );
  final playlists = state.playlists;
  final baseline = <Map<String, int>>[];
  final optimized = <Map<String, int>>[];
  for (var sample = 0; sample < 5; sample++) {
    for (final reuse in sample.isEven ? [false, true] : [true, false]) {
      final result = await measureCollectionOperation(() {
        late LibraryCollectionsState updated;
        for (var index = 0; index < 10; index++) {
          final renamed = [
            playlists.first.copyWith(name: 'Renamed $index'),
            ...playlists.skip(1),
          ];
          updated = reuse
              ? state.copyWith(playlists: renamed)
              : LibraryCollectionsState(
                  wishlist: state.wishlist,
                  loved: state.loved,
                  favoriteArtists: state.favoriteArtists,
                  playlists: renamed,
                  isLoaded: state.isLoaded,
                );
        }
        return updated;
      });
      if (!result.value.isTrackInAnyPlaylist('example:${rows * 2 - 1}') ||
          result.value.playlists.first.name != 'Renamed 9') {
        throw StateError('Metadata membership parity failed');
      }
      (reuse ? optimized : baseline).add(result.timing);
    }
  }
  return {
    'membership_rows': rows * 2,
    'edits_per_sample': 10,
    'baseline': baseline,
    'optimized': optimized,
  };
}

Future<String> _encodeExportMap(Map<String, dynamic> value) =>
    Isolate.run(() => jsonEncode(value));
Future<String> _legacyJsonExport(LibraryCollectionsState state) =>
    _encodeExportMap(state.toJson());

Future<Map<String, dynamic>> benchmarkCollectionJsonExport({
  int rows = 40000,
}) async {
  final state = await compute(
    decodeLibraryCollectionsSnapshot,
    await compute(_fixture, rows),
  );
  final expected = await _legacyJsonExport(state);
  await exportLibraryCollectionsJson(state);
  final baseline = <Map<String, int>>[];
  final worker = <Map<String, int>>[];
  for (var sample = 0; sample < 5; sample++) {
    for (final useWorker in sample.isEven ? [false, true] : [true, false]) {
      final result = await measureCollectionOperation<String>(
        () => useWorker
            ? exportLibraryCollectionsJson(state)
            : _legacyJsonExport(state),
      );
      if (result.value != expected) {
        throw StateError('Collection JSON export parity failed');
      }
      (useWorker ? worker : baseline).add(result.timing);
    }
  }
  return {
    'rows': rows,
    'json_characters': expected.length,
    'baseline': baseline,
    'worker': worker,
    'note':
        'Full model-to-encoded-JSON: original UI map+encoding isolate versus bounded single worker JSON.',
  };
}
