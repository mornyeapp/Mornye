import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/collection_suggestions.dart';

Track _track(
  String name,
  String artist, {
  String? id,
  String? isrc,
  String? source,
}) => Track(
  id: id ?? name,
  name: name,
  artistName: artist,
  albumName: 'Album',
  duration: 200,
  isrc: isrc,
  source: source,
);

/// Counts reads of the fields a collection song is matched by.
class _CountingTrack extends Track {
  _CountingTrack(String name, String artist, {super.isrc})
    : super(
        id: name,
        name: name,
        artistName: artist,
        albumName: 'Album',
        duration: 200,
      );

  static int reads = 0;

  @override
  String get name {
    reads++;
    return super.name;
  }

  @override
  String get artistName {
    reads++;
    return super.artistName;
  }

  @override
  String? get isrc {
    reads++;
    return super.isrc;
  }
}

/// filterCollectionSuggestions as it was before the keys were reused.
List<Track> _referenceFilter(
  Iterable<Track> candidates,
  Iterable<Track> collection,
) {
  String primaryArtist(String artists) => artists
      .split(RegExp(r'\s*(?:,|;|&| feat\.? | ft\.? | x )\s*'))
      .first
      .trim();
  String titleKey(String name) => name
      .toLowerCase()
      .replaceAll(RegExp(r'\s*[(\[].*?[)\]]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  List<String> trackKeys(Track track) => [
    if (track.isrc?.trim() case final isrc? when isrc.isNotEmpty)
      'isrc:${isrc.toUpperCase()}',
    'name:${titleKey(track.name)}|${primaryArtist(track.artistName).toLowerCase()}',
  ];
  final seen = <String>{};
  for (final track in collection) {
    seen.addAll(trackKeys(track));
  }
  final result = <Track>[];
  for (final track in candidates) {
    if (result.length == collectionSuggestionCount) break;
    if (track.name.trim().isEmpty) continue;
    final keys = trackKeys(track);
    if (keys.any(seen.contains)) continue;
    seen.addAll(keys);
    result.add(track);
  }
  return result;
}

Extension _extension(
  String id, {
  bool related = false,
  bool metadata = false,
  bool enabled = true,
}) => Extension(
  id: id,
  name: id,
  displayName: id,
  version: '1',
  description: '',
  enabled: enabled,
  status: 'loaded',
  hasMetadataProvider: metadata,
  capabilities: {if (related) 'relatedTracks': true},
);

Map<String, dynamic> _map(
  String name,
  String artist, {
  String? isrc,
  String provider = 'example.related',
}) => {
  'id': 'id-$name',
  'name': name,
  'artists': artist,
  'album_name': 'Album',
  'duration_ms': 180000,
  'isrc': ?isrc,
  'provider_id': provider,
};

void main() {
  group('collectionSuggestionSource', () {
    test('prefers an extension that suggests related songs', () {
      final source = collectionSuggestionSource(
        ExtensionState(
          extensions: [
            _extension('example.search', metadata: true),
            _extension('example.related', related: true),
          ],
        ),
        [_track('Song', 'Artist')],
      );
      expect(source?.extensionId, 'example.related');
      expect(source?.related, isTrue);
    });

    test('picks the related extension most seeds came from', () {
      final source = collectionSuggestionSource(
        ExtensionState(
          extensions: [
            _extension('example.first', related: true),
            _extension('example.second', related: true),
          ],
          metadataProviderPriority: const ['example.first', 'example.second'],
        ),
        [
          _track('A', 'Artist', source: 'example.second'),
          _track('B', 'Artist', source: 'example.second'),
          _track('C', 'Artist', source: 'example.first'),
        ],
      );
      expect(source?.extensionId, 'example.second');
    });

    test('falls back to the first metadata provider in priority order', () {
      final source = collectionSuggestionSource(
        ExtensionState(
          extensions: [
            _extension('example.later', metadata: true),
            _extension('example.first', metadata: true),
            _extension('example.off', related: true, enabled: false),
          ],
          metadataProviderPriority: const ['example.first', 'example.later'],
        ),
        const [],
      );
      expect(source?.extensionId, 'example.first');
      expect(source?.related, isFalse);
    });

    test('is null without a usable extension', () {
      expect(
        collectionSuggestionSource(
          ExtensionState(extensions: [_extension('example.none')]),
          const [],
        ),
        isNull,
      );
    });

    test('its key ignores extensions that cannot suggest', () {
      final before = ExtensionState(
        extensions: [
          _extension('example.related', related: true),
          _extension('example.other'),
        ],
      );
      final after = ExtensionState(
        extensions: [_extension('example.related', related: true)],
      );
      expect(
        collectionSuggestionSourceKey(before),
        collectionSuggestionSourceKey(after),
      );
    });
  });

  group('collectionSuggestionSeeds', () {
    final tracks = [
      _track('First', 'Artist A'),
      _track('Second', 'Artist A'),
      _track('Third', 'Artist B'),
      _track('Fourth', 'Artist C'),
      _track('Fifth', 'Artist A'),
    ];

    test('starts from the first songs, one per artist first', () {
      final seeds = collectionSuggestionSeeds(tracks, count: 3);
      expect(seeds.map((t) => t.name), ['First', 'Third', 'Fourth']);
    });

    test('fills with other songs of the same artists when needed', () {
      final seeds = collectionSuggestionSeeds(tracks, count: 4);
      expect(seeds.map((t) => t.name), ['First', 'Third', 'Fourth', 'Second']);
    });

    test('a later round starts from later songs', () {
      final seeds = collectionSuggestionSeeds(tracks, count: 2, round: 1);
      expect(seeds.first.name, 'Third');
    });
  });

  test('filterCollectionSuggestions drops songs the collection has', () {
    final collection = [
      _track('Kept Out', 'Artist', isrc: 'EXAMPLE00001'),
      _track('Same Title', 'Artist B'),
    ];
    final result = filterCollectionSuggestions(
      [
        _track('Other Name', 'Other', isrc: 'example00001'),
        _track('Same Title (Remastered)', 'Artist B feat. Guest'),
        _track('New Song', 'Artist C'),
        _track('New Song', 'Artist C', id: 'duplicate'),
        _track('Another', 'Artist D'),
      ],
      collection,
      limit: 2,
    );
    expect(result.map((t) => t.name), ['New Song', 'Another']);
  });

  group('CollectionSuggestionFilter', () {
    test('keeps the collection keys across rebuilds of the same songs', () {
      final collection = [
        for (var i = 0; i < 200; i++)
          _CountingTrack('Song $i', 'Artist ${i % 7}', isrc: 'EXAMPLE$i'),
      ];
      final candidates = [
        _track('Song 3 (Live)', 'Artist 3 feat. Guest'),
        _track('Fresh', 'Artist Z'),
        _track('Other', 'Artist Y', isrc: 'example5'),
        _track('Another', 'Artist X'),
      ];
      final filter = CollectionSuggestionFilter();
      _CountingTrack.reads = 0;
      final first = filter(candidates, collection);
      expect(first.map((t) => t.name), ['Fresh', 'Another']);
      expect(_CountingTrack.reads, 600);

      _CountingTrack.reads = 0;
      for (var build = 0; build < 60; build++) {
        expect(identical(filter(candidates, collection), first), isTrue);
        expect(identical(filter(candidates, [...collection]), first), isTrue);
      }
      expect(_CountingTrack.reads, 0);

      for (var build = 0; build < 120; build++) {
        expect(_referenceFilter(candidates, collection), first);
      }
      expect(_CountingTrack.reads, 72000);

      final rebuilt = [
        for (final track in collection)
          Track(
            id: 'rebuilt-${track.id}',
            name: track.name,
            artistName: track.artistName,
            albumName: 'Other album',
            duration: 1,
            isrc: track.isrc,
          ),
      ];
      expect(identical(filter(candidates, rebuilt), first), isTrue);

      final refreshed = [...candidates];
      final again = filter(refreshed, rebuilt);
      expect(identical(again, first), isTrue);
      expect(again.map((t) => t.name), ['Fresh', 'Another']);

      final added = [...rebuilt, _track('Fresh', 'Artist Z')];
      expect(filter(refreshed, added).map((t) => t.name), ['Another']);
      final retagged = [
        ...rebuilt.take(5),
        _track('Renamed', 'Artist 5', isrc: 'REPLACED5'),
        ...rebuilt.skip(6),
      ];
      expect(filter(candidates, retagged).map((t) => t.name), [
        'Fresh',
        'Other',
        'Another',
      ]);
    });

    test('sees a collection list that changed in place', () {
      final collection = [_track('Song', 'Artist')];
      final candidates = [_track('Fresh', 'Artist Z')];
      final filter = CollectionSuggestionFilter();
      expect(filter(candidates, collection).map((t) => t.name), ['Fresh']);
      collection.add(_track('Fresh', 'Artist Z'));
      expect(filter(candidates, collection), isEmpty);
      collection[1] = _track('Fresh', 'Artist Y');
      expect(filter(candidates, collection).map((t) => t.name), ['Fresh']);
    });

    test('sees candidate replacements, ordering and mutations in place', () {
      final collection = [_track('Song', 'Artist', isrc: 'EXAMPLE1')];
      final candidates = [
        _track('Fresh', 'Artist Z'),
        _track('Another', 'Artist Y'),
      ];
      final filter = CollectionSuggestionFilter();
      final first = filter(candidates, collection);
      final edited = candidates[0].copyWith(
        id: 'edited',
        albumName: 'Edited album',
        coverUrl: 'https://example.com/edited.jpg',
        previewUrl: 'https://example.com/edited.mp3',
        source: 'example.edited',
      );
      candidates[0] = edited;
      final refreshed = filter(candidates, collection);
      expect(identical(refreshed, first), isFalse);
      expect(identical(refreshed.first, edited), isTrue);

      candidates.insert(0, candidates.removeLast());
      expect(filter(candidates, collection), [candidates[0], edited]);
      candidates.add(_track('Duplicate', 'Other', isrc: 'example1'));
      expect(filter(candidates, collection), [candidates[0], edited]);
      candidates[2] = _track('Third', 'Third artist');
      expect(filter(candidates, collection).map((t) => t.name), [
        'Another',
        'Fresh',
        'Third',
      ]);
      candidates.removeAt(1);
      expect(filter(candidates, collection).map((t) => t.name), [
        'Another',
        'Third',
      ]);
      candidates.clear();
      expect(filter(candidates, collection), isEmpty);
    });

    test('invalidates for each collection match field independently', () {
      final collection = [_track('Song', 'Artist', isrc: 'EXAMPLE1')];
      final candidates = [
        _track('Fresh', 'Artist'),
        _track('Song', 'Other'),
        _track('Unrelated', 'Unrelated', isrc: 'EXAMPLE2'),
      ];
      final filter = CollectionSuggestionFilter();
      expect(filter(candidates, collection), candidates);
      collection[0] = collection[0].copyWith(name: 'Fresh');
      expect(filter(candidates, collection), candidates.skip(1));
      collection[0] = _track('Song', 'Other', isrc: 'EXAMPLE1');
      expect(filter(candidates, collection), [candidates[0], candidates[2]]);
      collection[0] = _track('Song', 'Artist', isrc: 'EXAMPLE2');
      expect(filter(candidates, collection), candidates.take(2));
      collection.clear();
      expect(filter(candidates, collection), candidates);
    });

    test('matches filterCollectionSuggestions as both change', () {
      final random = Random(7);
      const titles = [
        'Song',
        'song',
        'Song (Live)',
        'Song [Remix]',
        'Other  Song',
        'Other Song',
        'Tune',
        '  ',
        'Ballad',
        'Intro',
      ];
      const artists = [
        'Artist',
        'artist',
        'Artist feat. Guest',
        'Artist, Other',
        'Band & Friends',
        'Band',
        'Solo x Duo',
        'Duo',
      ];
      Track randomTrack() => _track(
        titles[random.nextInt(titles.length)],
        artists[random.nextInt(artists.length)],
        id: '${random.nextInt(1 << 30)}',
        isrc: switch (random.nextInt(4)) {
          0 => null,
          1 => ' ',
          _ => 'example${random.nextInt(6)}',
        },
      );
      final filter = CollectionSuggestionFilter();
      var collection = [for (var i = 0; i < 12; i++) randomTrack()];
      var candidates = [for (var i = 0; i < 20; i++) randomTrack()];
      for (var round = 0; round < 500; round++) {
        switch (random.nextInt(10)) {
          case 0:
            collection = [...collection, randomTrack()];
          case 1:
            if (collection.isNotEmpty) {
              collection = [...collection]
                ..removeAt(random.nextInt(collection.length));
            }
          case 2:
            if (collection.isNotEmpty) {
              final index = random.nextInt(collection.length);
              collection = [...collection]..[index] = randomTrack();
            }
          case 3:
            candidates = [for (var i = 0; i < 20; i++) randomTrack()];
          case 4:
            collection = [...collection];
          case 5:
            collection.add(randomTrack());
          case 6:
            break;
          case 7:
            candidates.add(randomTrack());
          case 8:
            if (candidates.isNotEmpty) {
              candidates[random.nextInt(candidates.length)] = randomTrack();
            }
          case 9:
            if (candidates.isNotEmpty) {
              candidates.removeAt(random.nextInt(candidates.length));
            }
        }
        final expected = _referenceFilter(candidates, collection);
        expect(
          filter(candidates, collection).map((t) => '${t.id}:${t.name}'),
          expected.map((t) => '${t.id}:${t.name}'),
          reason: 'round $round',
        );
        expect(
          filterCollectionSuggestions(
            candidates,
            collection,
          ).map((t) => '${t.id}:${t.name}'),
          expected.map((t) => '${t.id}:${t.name}'),
        );
      }
    });
  });

  test('interleaveSuggestions takes one from each list in turn', () {
    expect(
      interleaveSuggestions([
        [1, 2, 3],
        [10],
        [20, 21],
      ]),
      [1, 10, 20, 2, 21, 3],
    );
  });

  group('loadCollectionSuggestions', () {
    final tracks = [
      _track('Mine', 'Artist A', source: 'example.related'),
      _track('Theirs', 'Artist B & Guest'),
    ];

    test('asks the related extension with the seeds', () async {
      List<Map<String, dynamic>>? sentSeeds;
      final result = await loadCollectionSuggestions(
        tracks: tracks,
        source: const CollectionSuggestionSource(
          extensionId: 'example.related',
          related: true,
        ),
        round: 0,
        related: (id, seeds, limit) async {
          sentSeeds = seeds;
          expect(id, 'example.related');
          expect(limit, greaterThanOrEqualTo(collectionSuggestionCount));
          return [_map('Mine', 'Artist A'), _map('Fresh', 'Artist Z')];
        },
        search: (_, _) => fail('no search with a related source'),
      );
      expect(sentSeeds?.map((seed) => seed['name']), ['Mine', 'Theirs']);
      expect(sentSeeds?.first['provider_id'], 'example.related');
      expect(sentSeeds?.first['duration_ms'], 200000);
      expect(result.related, isTrue);
      expect(result.tracks.map((t) => t.name), ['Fresh']);
      expect(result.tracks.single.source, 'example.related');
    });

    test('searches the collection artists without one', () async {
      final queries = <String>[];
      final result = await loadCollectionSuggestions(
        tracks: tracks,
        source: const CollectionSuggestionSource(
          extensionId: 'example.search',
          related: false,
        ),
        round: 0,
        related: (_, _, _) => fail('no related call with a search source'),
        search: (id, query) async {
          queries.add(query);
          if (query == 'Artist B') throw StateError('offline');
          return [
            _map('Mine', 'Artist A'),
            _map('Hit', 'Artist A'),
            _map('Unrelated', 'Someone Else'),
          ];
        },
      );
      expect(queries, ['Artist A', 'Artist B']);
      expect(result.related, isFalse);
      expect(result.tracks.map((t) => t.name), ['Hit']);
    });

    test('is empty for an empty collection', () async {
      final result = await loadCollectionSuggestions(
        tracks: const [],
        source: const CollectionSuggestionSource(
          extensionId: 'example.related',
          related: true,
        ),
        round: 0,
        related: (_, _, _) => fail('nothing to ask'),
        search: (_, _) => fail('nothing to search'),
      );
      expect(result.tracks, isEmpty);
    });
  });
}
