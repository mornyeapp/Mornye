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
