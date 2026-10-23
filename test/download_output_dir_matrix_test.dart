import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';

const _tracks = {
  'album': Track(
    id: 'album',
    name: 'Song',
    artistName: 'Track Artist feat. Guest',
    albumArtist: 'Album Artist, Partner',
    albumName: 'Album: Name?',
    duration: 180,
    releaseDate: '2024-03-01',
    albumType: 'album',
    totalTracks: 12,
  ),
  'single': Track(
    id: 'single',
    name: 'Song',
    artistName: 'Solo x Friend',
    albumName: 'Song',
    duration: 180,
    releaseDate: '2025',
    albumType: 'single',
  ),
  'bare': Track(
    id: 'bare',
    name: 'Song',
    artistName: 'Bare Artist',
    albumArtist: ' ',
    albumName: 'Singles',
    duration: 180,
    totalTracks: 2,
  ),
  'undated': Track(
    id: 'undated',
    name: 'Song',
    artistName: 'Lead with Other',
    albumName: 'Collection',
    duration: 180,
    albumType: 'compilation',
  ),
};

void main() {
  test('relative output folders stay identical for every settings mix', () {
    final queue = DownloadQueueNotifier();
    final lines = <String>[];
    for (final track in _tracks.entries) {
      for (final organization in [
        'none',
        'artist',
        'album',
        'artist_album',
        'playlist',
        'custom',
        'unknown',
      ]) {
        for (final structure in [
          'artist_album',
          'album_only',
          'artist_year_album',
          'year_album',
          'artist_album_singles',
          'artist_album_flat',
        ]) {
          for (var flags = 0; flags < 32; flags++) {
            for (final playlist in [null, '', 'My: List']) {
              final settings = AppSettings(
                folderOrganization: organization,
                albumFolderStructure: structure,
                separateSingles: flags & 1 != 0,
                createPlaylistFolder: flags & 2 != 0,
                useAlbumArtistForFolders: flags & 4 != 0,
                usePrimaryArtistOnly: flags & 8 != 0,
                filterContributingArtistsInAlbumArtist: flags & 16 != 0,
              );
              final dir = queue.relativeOutputDirFor(
                track.value,
                settings,
                customFolderPath: organization == 'custom'
                    ? 'Template/Dir'
                    : null,
                playlistName: playlist,
              );
              lines.add(
                '${track.key}|$organization|$structure|$flags|$playlist=$dir',
              );
            }
          }
        }
      }
    }

    expect(lines, hasLength(16128));
    expect(
      lines,
      containsAll([
        'album|artist_album|artist_album|4|null=Album Artist, Partner/Album Name',
        'album|artist|artist_album|12|null=Album Artist',
        'album|none|artist_year_album|1|null=Albums/Track Artist feat. Guest/[2024] Album Name',
        'single|album|artist_album_singles|7|My: List=My List/Solo x Friend/Singles',
        'bare|playlist|artist_album|2|My: List=My List',
        'bare|custom|artist_album|2|My: List=My List/Template/Dir',
        'bare|none|artist_album_flat|1|null=Bare Artist',
        'single|unknown|year_album|9|null=Singles',
        'undated|none|artist_year_album|9|null=Albums/Lead/Collection',
      ]),
    );
    // Digest of every line, recorded before the builders took AppSettings.
    expect(
      sha256.convert(utf8.encode(lines.join('\n'))).toString(),
      'f6034428c64b50c612f25bcbc4d5208af889ac223330df5f633478bca4037f9b',
    );
  });
}
