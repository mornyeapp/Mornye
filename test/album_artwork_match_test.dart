import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/album_artwork_match.dart';

ArtworkCandidate _candidate(
  String name,
  String artists, {
  int tracks = 0,
  int? year,
  String id = 'a1',
}) => ArtworkCandidate(
  providerId: 'provider',
  albumId: id,
  name: name,
  artists: artists,
  totalTracks: tracks,
  year: year,
);

void main() {
  const album = ArtworkAlbum(
    key: 'first light|example band',
    album: 'First Light',
    artist: 'Example Band',
    trackCount: 10,
    year: 2019,
  );

  test('normalizes punctuation, case and ampersands', () {
    expect(artworkMatchText('  Tom & Jerry!  '), 'tom and jerry');
    expect(artworkMatchText('Café: Ünïcode'), 'café ünïcode');
  });

  test('strips the edition an album title ends with', () {
    expect(artworkBaseTitle('First Light (Deluxe Edition)'), 'first light');
    expect(artworkBaseTitle('First Light [Remastered 2011]'), 'first light');
    expect(artworkBaseTitle('First Light - EP'), 'first light');
    expect(
      artworkBaseTitle('First Light (Live) [Bonus Tracks]'),
      'first light',
    );
    expect(artworkBaseTitle('(Untitled)'), 'untitled');
  });

  test('needs both the artist and the title', () {
    expect(
      artworkMatchScore(album, _candidate('First Light', 'Example Band')),
      100,
    );
    expect(
      artworkMatchScore(album, _candidate('First Light', 'Other Band')),
      isNull,
    );
    expect(
      artworkMatchScore(album, _candidate('Last Light', 'Example Band')),
      isNull,
    );
    // A featured or joint artist still names the album artist.
    expect(
      artworkMatchScore(
        album,
        _candidate('First Light', 'Example Band, Guest Singer'),
      ),
      100,
    );
  });

  test('accepts another edition only when nothing speaks against it', () {
    final deluxe = _candidate('First Light (Deluxe)', 'Example Band');
    expect(artworkMatchScore(album, deluxe), artworkMatchThreshold);
    expect(
      pickArtworkCandidate(album, [
        _candidate('First Light (Deluxe)', 'Example Band', year: 2023),
      ]),
      isNull,
      reason: 'A deluxe release four years later is another album',
    );
    expect(
      pickArtworkCandidate(album, [
        _candidate('First Light', 'Example Band', tracks: 4),
      ]),
      isNull,
      reason: 'A single often shares the title of its album',
    );
    expect(
      pickArtworkCandidate(album, [
        _candidate('First Light', 'Example Band', tracks: 9),
      ]),
      isNotNull,
      reason: 'One song more locally, such as a bonus track',
    );
    expect(
      pickArtworkCandidate(album, [
        _candidate('First Light (Live)', 'Example Band', tracks: 4),
      ]),
      isNull,
      reason: 'Another edition with fewer songs than the local album',
    );
  });

  test('prefers the closest release and keeps the first on a tie', () {
    final picked = pickArtworkCandidate(album, [
      _candidate('First Light', 'Example Band', id: 'reissue', year: 2024),
      _candidate('First Light', 'Example Band', id: 'original', year: 2019),
      _candidate('First Light', 'Example Band', id: 'copy', year: 2019),
    ]);
    expect(picked?.albumId, 'original');
  });

  test('reads album results and the album of song results', () {
    final fromAlbum = ArtworkCandidate.fromSearchResult('provider', {
      'item_type': 'album',
      'id': 'provider:7',
      'name': 'First Light',
      'artists': 'Example Band',
      'total_tracks': '10',
      'release_date': '2019-03-01',
      'cover_url': 'https://example.com/cover.jpg',
    });
    expect(fromAlbum?.albumId, '7');
    expect(fromAlbum?.totalTracks, 10);
    expect(fromAlbum?.year, 2019);
    expect(fromAlbum?.coverUrl, 'https://example.com/cover.jpg');

    final fromSong = ArtworkCandidate.fromSearchResult('provider', {
      'item_type': 'track',
      'id': 't1',
      'name': 'Opening',
      'artists': 'Example Band, Guest',
      'album_name': 'First Light',
      'album_id': '7',
      'album_artist': 'Example Band',
      'images': 'https://example.com/small.jpg',
    });
    expect(fromSong?.name, 'First Light');
    expect(fromSong?.artists, 'Example Band');
    expect(fromSong?.albumId, '7');

    expect(
      ArtworkCandidate.fromSearchResult('provider', {
        'item_type': 'artist',
        'id': 'x',
        'name': 'Example Band',
      }),
      isNull,
    );
    expect(
      ArtworkCandidate.fromSearchResult('provider', {
        'item_type': 'track',
        'name': 'No album',
      }),
      isNull,
    );
  });
}
