import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/constants/music_services.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/csv_import_service.dart';
import 'package:mornye/utils/service_track_link.dart';

void main() {
  test(
    'playlist enrichment uses generic lookup with bounded concurrency',
    () async {
      var active = 0;
      var maxActive = 0;
      final progress = <int>[];
      final tracks = List.generate(
        5,
        (index) => Track(
          id: 'original-$index',
          name: 'Song $index',
          artistName: 'Artist',
          albumName: '',
          isrc: 'TEST0000000$index',
          duration: 0,
        ),
      );

      final enriched = await CsvImportService.enrichTracksMetadata(
        tracks,
        concurrency: 2,
        onProgress: (current, _) => progress.add(current),
        lookup: (query, limit) async {
          active++;
          if (active > maxActive) maxActive = active;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          active--;
          final index = int.parse(query.substring(query.length - 1));
          return [
            {
              'id': 'provider-$index',
              'provider_id': 'generic-provider',
              'name': 'Song $index',
              'artists': 'Artist',
              'album_name': 'Album',
              'cover_url': 'https://example.test/$index.jpg',
              'duration_ms': 180000,
              'isrc': query,
            },
          ];
        },
      );

      expect(maxActive, 2);
      expect(progress, [1, 2, 3, 4, 5]);
      // A candidate with a source brings its own id for the download fill-in.
      expect(enriched.map((track) => track.id), [
        for (var index = 0; index < 5; index++) 'provider-$index',
      ]);
      expect(
        enriched.every((track) => track.source == 'generic-provider'),
        isTrue,
      );
      expect(enriched.every((track) => track.duration == 180), isTrue);
      expect(enriched[3].coverUrl, 'https://example.test/3.jpg');
    },
  );

  test('ISRC enrichment rejects a provider mismatch', () async {
    const track = Track(
      id: 'original',
      name: 'Wanted Song',
      artistName: 'Wanted Artist',
      albumName: '',
      isrc: 'AAABC1200001',
      duration: 0,
    );
    var calls = 0;

    final enriched = await CsvImportService.enrichTracksMetadata(
      const [track],
      lookup: (query, limit) async {
        calls++;
        if (calls == 1) {
          return [
            {
              'id': 'wrong',
              'name': 'Other Song',
              'artists': 'Other Artist',
              'isrc': 'ZZZZZ9900000',
              'duration_ms': 100000,
            },
          ];
        }
        return [
          {
            'id': 'right',
            'name': 'Wanted Song',
            'artists': 'Wanted Artist',
            'cover_url': 'https://example.test/right.jpg',
            'duration_ms': 210000,
          },
        ];
      },
    );

    expect(calls, 2);
    expect(enriched.single.id, 'original');
    expect(enriched.single.duration, 210);
    expect(enriched.single.coverUrl, 'https://example.test/right.jpg');
  });

  Track row(
    String id, {
    String name = 'Unknown Track',
    String artist = 'Unknown Artist',
    String? isrc,
  }) => Track(
    id: id,
    name: name,
    artistName: artist,
    albumName: 'Unknown Album',
    isrc: isrc,
    duration: 0,
  );

  Track linked(String id, {String? isrc}) => Track(
    id: id,
    name: 'Linked $id',
    artistName: 'Linked Artist',
    albumName: 'Linked Album',
    coverUrl: 'https://example.com/$id.jpg',
    isrc: isrc,
    duration: 200,
    source: 'generic-extension',
    comment: 'https://example.com/track/$id',
  );

  Future<List<Map<String, dynamic>>> noLookup(String query, int limit) async =>
      fail('unexpected provider lookup for "$query"');

  test('link rows resolve in CSV order and expand collections', () async {
    final asked = <String>[];
    final lookups = <String>[];
    final enriched = await CsvImportService.enrichTracksMetadata(
      [
        row('https://example.com/track/1'),
        row('https://example.com/album/2', name: 'Ignored', artist: 'Text'),
        row('https://example.com/track/3', isrc: 'TEST00000003'),
      ],
      lookup: (query, limit) async {
        lookups.add('$query/$limit');
        return const [];
      },
      resolveLink: (url) async {
        asked.add(url);
        // The album answers last; its tracks must still keep their place.
        if (url.endsWith('/album/2')) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return [linked('a1'), linked('a2')];
        }
        return [linked(url.substring(url.length - 1))];
      },
    );

    expect(asked, hasLength(3));
    expect(enriched.map((track) => track.id), ['1', 'a1', 'a2', '3']);
    expect(enriched.first.source, 'generic-extension');
    expect(enriched.first.comment, 'https://example.com/track/1');
    expect(enriched.first.coverUrl, 'https://example.com/1.jpg');
    // A link without an ISRC keeps the row's own.
    expect(enriched.last.isrc, 'TEST00000003');
    // Only the cover check runs, by ISRC, with one result.
    expect(lookups, ['TEST00000003/1']);
  });

  test('a playlist link keeps its covers without a search per song', () async {
    final enriched = await CsvImportService.enrichTracksMetadata(
      [row('https://example.com/playlist/9')],
      lookup: noLookup,
      resolveLink: (url) async => [
        linked('p1', isrc: 'TEST00000001'),
        linked('p2', isrc: 'TEST00000002'),
      ],
    );
    expect(enriched.map((track) => track.coverUrl), [
      'https://example.com/p1.jpg',
      'https://example.com/p2.jpg',
    ]);
  });

  test('a priority provider with the exact ISRC supplies the cover', () async {
    Track albumTrack(String id, String isrc) => Track(
      id: id,
      name: 'Linked $id',
      artistName: 'Linked Artist',
      albumName: 'Linked Album',
      albumId: 'album-1',
      coverUrl: 'https://example.com/link.jpg',
      isrc: isrc,
      duration: 200,
      source: 'link-extension',
    );
    final lookups = <String>[];
    final enriched = await CsvImportService.enrichTracksMetadata(
      [
        row('https://example.com/album/1'),
        row('https://example.com/track/same'),
        row('https://example.com/track/near'),
      ],
      concurrency: 1,
      resolveLink: (url) async => switch (url.split('/').last) {
        'same' => [
          linked(
            'same',
            isrc: 'TEST00000010',
          ).copyWith(source: 'link-extension'),
        ],
        'near' => [
          linked(
            'near',
            isrc: 'TEST00000020',
          ).copyWith(source: 'link-extension'),
        ],
        _ => [
          albumTrack('t1', 'TEST00000001'),
          albumTrack('t2', 'TEST00000002'),
        ],
      },
      lookup: (query, limit) async {
        lookups.add(query);
        return switch (query) {
          'TEST00000001' => [
            {
              'id': 'p1',
              'provider_id': 'priority-provider',
              'name': 'Other Title',
              'artists': 'Other Artist',
              'isrc': 'TEST00000001',
              'cover_url': 'https://example.com/priority.jpg',
            },
          ],
          // The link's own provider ranks first: its cover stays.
          'TEST00000010' => [
            {
              'id': 'same',
              'provider_id': 'link-extension',
              'name': 'Linked same',
              'isrc': 'TEST00000010',
              'cover_url': 'https://example.com/other.jpg',
            },
          ],
          // Not the same recording: no cover from it.
          _ => [
            {
              'id': 'x',
              'provider_id': 'priority-provider',
              'name': 'Linked near',
              'isrc': 'TEST00000099',
              'cover_url': 'https://example.com/wrong.jpg',
            },
          ],
        };
      },
    );

    // One lookup serves both tracks of the album.
    expect(lookups, ['TEST00000001', 'TEST00000010', 'TEST00000020']);
    expect(enriched.map((track) => track.coverUrl), [
      'https://example.com/priority.jpg',
      'https://example.com/priority.jpg',
      'https://example.com/same.jpg',
      'https://example.com/near.jpg',
    ]);
    // Everything else stays the link's own metadata.
    expect(enriched.first.name, 'Linked t1');
    expect(enriched.first.id, 't1');
    expect(enriched.first.source, 'link-extension');
  });

  test('legacy id columns resolve through their track link', () async {
    const bare = '0123456789abcdefABCDEF';
    const uri = 'spotify:track:ABCDEF0123456789abcdef';
    final asked = <String>[];
    await CsvImportService.enrichTracksMetadata(
      [row(bare), row(uri), row('csv_1_3', name: 'Song', artist: 'Artist')],
      lookup: (query, limit) async => const [],
      resolveLink: (url) async {
        asked.add(url);
        return [linked('x')];
      },
    );

    expect(asked, [
      ServiceTrackLink(MusicServices.spotify, bare).webUrl,
      ServiceTrackLink(MusicServices.spotify, uri.split(':').last).webUrl,
    ]);
  });

  test('an unresolved link falls back to ISRC and text matching', () async {
    final queries = <String>[];
    final enriched = await CsvImportService.enrichTracksMetadata(
      [
        row(
          'https://example.com/track/1',
          name: 'Wanted Song',
          artist: 'Wanted Artist',
        ),
        row('https://example.com/track/2', name: 'Lost', artist: 'Nobody'),
        row('https://example.com/track/3'),
      ],
      concurrency: 1,
      resolveLink: (url) async {
        if (url.endsWith('/1')) return null;
        if (url.endsWith('/2')) throw Exception('extension failed');
        return const [];
      },
      lookup: (query, limit) async {
        queries.add(query);
        if (query != 'Wanted Artist Wanted Song') return const [];
        return [
          {
            'id': 'match',
            'provider_id': 'generic-provider',
            'name': 'Wanted Song',
            'artists': 'Wanted Artist',
            'cover_url': 'https://example.com/match.jpg',
            'comment': 'https://example.com/match',
            'album_type': 'single',
            'duration_ms': 190000,
          },
        ];
      },
    );

    // The URL-only row has no text to search for.
    expect(queries, ['Wanted Artist Wanted Song', 'Nobody Lost']);
    expect(enriched, hasLength(3));
    expect(enriched[0].id, 'match');
    expect(enriched[0].source, 'generic-provider');
    expect(enriched[0].comment, 'https://example.com/match');
    expect(enriched[0].albumType, 'single');
    expect(enriched[0].coverUrl, 'https://example.com/match.jpg');
    // Rows nothing matched keep their text, without the URL as a track id.
    expect(enriched[1].id, '');
    expect(enriched[1].name, 'Lost');
    expect(enriched[1].coverUrl, isNull);
    expect(enriched[2].id, '');
    expect(enriched[2].name, 'Unknown Track');
  });

  test('a row without a title skips the text lookup', () async {
    final enriched = await CsvImportService.enrichTracksMetadata(
      [row('custom-id')],
      lookup: noLookup,
      resolveLink: (url) async => fail('unexpected link $url'),
    );
    expect(enriched.single.id, 'custom-id');
  });

  group('text matching', () {
    Future<Track> match(
      Track track,
      List<Map<String, dynamic>> candidates,
    ) async => (await CsvImportService.enrichTracksMetadata(
      [track],
      lookup: (query, limit) async => candidates,
      resolveLink: (url) async => null,
    )).single;

    Map<String, dynamic> candidate(String name, String artists) => {
      'id': '$name|$artists',
      'name': name,
      'artists': artists,
      'cover_url': 'https://example.com/cover.jpg',
      'duration_ms': 180000,
    };

    test('a dummy row does not attach to an unrelated song', () async {
      final dummy = row('csv_1_1', name: 'any', artist: 'any');
      final enriched = await match(dummy, [
        candidate('Anything Goes', 'Many Voices'),
        candidate('Any Way You Want It', 'Some Band'),
        candidate('Company', 'Anyone'),
        candidate('Other Song', 'any'),
      ]);
      expect(enriched.id, 'csv_1_1');
      expect(enriched.coverUrl, isNull);

      final generic = row('csv_1_2', name: 'Track', artist: 'Artist');
      expect(
        (await match(generic, [candidate('Track 1', 'Some Artist')])).coverUrl,
        isNull,
      );
    });

    test('the title and the row artist must both agree', () async {
      final wanted = row('csv_1_1', name: 'Wanted Song', artist: 'Band');
      final enriched = await match(wanted, [
        candidate('Another Song', 'Band'),
        candidate('Wanted Song', 'Cover Singer'),
      ]);
      expect(enriched.coverUrl, isNull);
    });

    test('normal rows with small differences still match', () async {
      final cases = [
        (
          row('a', name: "DON'T STOP ME NOW", artist: 'QUEEN BAND'),
          candidate('Don’t Stop Me Now - Remastered 2011', 'Queen Band'),
        ),
        (
          row('b', name: 'Song Title (feat. Guest)', artist: 'Main Artist'),
          candidate('Song Title', 'Main Artist, Guest'),
        ),
        (
          row('c', name: 'Night Drive', artist: 'Main Artist feat. Guest'),
          candidate('Night Drive [feat. Guest]', 'Main Artist'),
        ),
        (
          row('d', name: 'Déjà Vu', artist: 'Artiste Été'),
          candidate('Deja Vu', 'Artiste Ete'),
        ),
        (
          row('e', name: 'Partner Song', artist: 'Second Act, First Act'),
          candidate('Partner Song!', 'First Act & Second Act'),
        ),
      ];
      for (final (track, provider) in cases) {
        final enriched = await match(track, [provider]);
        expect(
          enriched.coverUrl,
          'https://example.com/cover.jpg',
          reason: track.name,
        );
      }
    });
  });
}
