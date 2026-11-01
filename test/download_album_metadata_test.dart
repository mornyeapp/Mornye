import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/services/download_album_metadata.dart';

void main() {
  const solo = Track(
    id: 'solo',
    name: 'Solo',
    artistName: 'Artist',
    albumName: 'Release',
    albumArtist: 'Artist',
    albumId: 'release-1',
    source: 'example-provider',
    duration: 180,
  );
  final collaboration = solo.copyWith(
    id: 'duet',
    name: 'Duet',
    artistName: 'Artist, Guest',
    albumArtist: 'Artist, Guest',
  );

  test(
    'playlist tracks recover missing artwork from their own album',
    () async {
      final prepared = await resolveDownloadAlbumArtist(
        solo,
        'example-provider',
        loadMetadata: (_, _, id) async => {
          'album_info': {
            'id': id,
            'artists': solo.albumArtist,
            'images': 'https://example.test/albums/release-1.jpg',
          },
        },
      );
      expect(prepared.coverUrl, 'https://example.test/albums/release-1.jpg');
      expect(prepared.id, solo.id);
      expect(prepared.albumName, solo.albumName);
      expect(prepared.artistName, solo.artistName);
      final embedded = buildTrackForMetadataEmbedding(
        prepared,
        {},
        prepared.albumArtist,
      );
      expect(embedded.coverUrl, prepared.coverUrl);
    },
  );

  test('album artwork recovery preserves an existing track cover', () async {
    final selected = solo.copyWith(
      coverUrl: 'https://example.test/selected.jpg',
    );
    final prepared = await resolveDownloadAlbumArtist(
      selected,
      'example-provider',
      loadMetadata: (_, _, id) async => {
        'album_info': {'id': id, 'cover_url': 'https://example.test/album.jpg'},
      },
    );
    expect(prepared, same(selected));
  });

  test('a different release never supplies playlist track artwork', () async {
    final prepared = await resolveDownloadAlbumArtist(
      solo,
      'example-provider',
      loadMetadata: (_, _, _) async => {
        'album_info': {
          'id': 'other',
          'images': 'https://example.test/other.jpg',
        },
      },
    );
    expect(prepared, same(solo));
  });

  test('separate downloads use the same album credit as a batch', () async {
    Future<Map<String, dynamic>> metadata(
      String provider,
      String kind,
      String id,
    ) async {
      expect((provider, kind, id), ('example-provider', 'album', 'release-1'));
      return {
        'album_info': {'id': id, 'artists': 'Artist'},
      };
    }

    final batch = normalizeBatchAlbumArtists([solo, collaboration]);
    final later = await resolveDownloadAlbumArtist(
      collaboration,
      'example-provider',
      loadMetadata: metadata,
    );
    expect(later.albumArtist, batch.first.albumArtist);
    expect(later.artistName, 'Artist, Guest');
    expect(later.toJson(), {
      ...collaboration.toJson(),
      'albumArtist': 'Artist',
    });
    final embedded = buildTrackForMetadataEmbedding(later, {
      'album_artist': 'Artist, Guest',
    }, later.albumArtist);
    expect(embedded.albumArtist, 'Artist');
  });

  for (final credit in ['Artist A & Artist B', 'Various Artists']) {
    test('retains the complete album credit: $credit', () async {
      final track = await resolveDownloadAlbumArtist(
        collaboration,
        'example-provider',
        loadMetadata: (_, _, _) async => {'artists': credit},
      );
      expect(track.albumArtist, credit);
      expect(track.artistName, collaboration.artistName);
    });
  }

  for (final response in <Map<String, dynamic>>[
    {
      'album_info': {'id': 'different-release', 'artists': 'Other artist'},
    },
    {
      'album_info': {'artists': '   '},
      'track_list': [
        {'artists': 'Guest'},
      ],
    },
    {
      'album_info': {
        'artists': <String>['Artist'],
      },
    },
  ]) {
    test(
      'keeps source tags for missing or mismatched album data: $response',
      () async {
        final track = await resolveDownloadAlbumArtist(
          collaboration,
          'example-provider',
          loadMetadata: (_, _, _) async => response,
        );
        expect(track, same(collaboration));
      },
    );
  }

  test('a failed lookup does not prevent downloading', () async {
    final track = await resolveDownloadAlbumArtist(
      collaboration,
      'example-provider',
      loadMetadata: (_, _, _) async => throw StateError('Provider unavailable'),
    );
    expect(track, same(collaboration));
  });

  test('does not guess a release by its title', () async {
    final missingId = solo.copyWith(albumId: '');
    var lookups = 0;
    final track = await resolveDownloadAlbumArtist(
      missingId,
      'example-provider',
      loadMetadata: (_, _, _) async {
        lookups++;
        return {'artists': 'Different artist'};
      },
    );
    expect(track, same(missingId));
    expect(lookups, 0);
  });
}
