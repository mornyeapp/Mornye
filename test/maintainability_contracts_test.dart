import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_state.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/controllers/home_search_logic.dart';
import 'package:mornye/services/audio_metadata_mapper.dart';
import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/services/id3v23_lyrics.dart';
import 'package:mornye/utils/artist_utils.dart';

void main() {
  Track track({
    required String id,
    required String name,
    String artist = 'Artist',
    int duration = 180,
    String? releaseDate,
    String? itemType,
  }) {
    return Track(
      id: id,
      name: name,
      artistName: artist,
      albumName: 'Album',
      duration: duration,
      releaseDate: releaseDate,
      itemType: itemType,
    );
  }

  group('home search logic', () {
    test('separates playable tracks from collection result types', () {
      final results = [
        track(id: 'track', name: 'Track'),
        track(id: 'album', name: 'Album', itemType: 'album'),
        track(id: 'playlist', name: 'Playlist', itemType: 'playlist'),
        track(id: 'artist', name: 'Artist', itemType: 'artist'),
      ];

      final buckets = bucketHomeSearchResults(results);

      expect(buckets.realTracks.map((item) => item.id), ['track']);
      expect(buckets.realTrackIndexes, [0]);
      expect(buckets.albumItems.single.id, 'album');
      expect(buckets.playlistItems.single.id, 'playlist');
      expect(buckets.artistItems.single.id, 'artist');
    });

    test('sorts a copy and preserves default result identity', () {
      final results = [
        track(
          id: 'later',
          name: 'Zulu',
          artist: 'Beta',
          duration: 220,
          releaseDate: '2026-02-01',
        ),
        track(
          id: 'earlier',
          name: 'Alpha',
          artist: 'Alpha',
          duration: 120,
          releaseDate: '2025-01-01',
        ),
      ];

      final unchanged = sortHomeSearchItems(
        items: results,
        option: HomeSearchSortOption.defaultOrder,
        nameOf: (item) => item.name,
        artistOf: (item) => item.artistName,
        durationOf: (item) => item.duration,
        dateOf: (item) => item.releaseDate,
      );
      final sorted = sortHomeSearchItems(
        items: results,
        option: HomeSearchSortOption.titleAsc,
        nameOf: (item) => item.name,
        artistOf: (item) => item.artistName,
        durationOf: (item) => item.duration,
        dateOf: (item) => item.releaseDate,
      );

      expect(identical(unchanged, results), isTrue);
      expect(identical(sorted, results), isFalse);
      expect(sorted.map((item) => item.id), ['earlier', 'later']);
      expect(results.first.id, 'later');
    });

    test('recognizes URLs and Spotify URIs without treating text as a URL', () {
      expect(looksLikeUrlOrSpotifyUri('https://example.test/track'), isTrue);
      expect(looksLikeUrlOrSpotifyUri('spotify:track:123'), isTrue);
      expect(looksLikeUrlOrSpotifyUri('artist track title'), isFalse);
    });

    test('uses the primary enabled extension as the provider fallback', () {
      final secondary = _searchExtension(id: 'secondary');
      final primary = _searchExtension(id: 'primary', primary: true);
      final disabled = _searchExtension(id: 'disabled', enabled: false);
      final extensions = [secondary, primary, disabled];

      expect(
        HomeSearchProviderPolicy.resolveProvider(null, extensions),
        'primary',
      );
      expect(
        HomeSearchProviderPolicy.resolveProvider('secondary', extensions),
        'secondary',
      );
      expect(
        HomeSearchProviderPolicy.resolveProvider('disabled', extensions),
        'primary',
      );
      expect(
        HomeSearchProviderPolicy.hasProvider('missing', extensions),
        isTrue,
      );
    });

    test('canonicalizes built-in and extension search filters', () {
      final extension = _searchExtension(
        id: 'provider',
        filters: const [
          SearchFilter(id: 'songs', label: 'Tracks', icon: 'music'),
          SearchFilter(id: 'records', label: 'Albums', icon: 'album'),
        ],
      );

      expect(
        HomeSearchProviderPolicy.sanitizeFilter('Music', null, const []),
        'track',
      );
      expect(
        HomeSearchProviderPolicy.sanitizeFilter('track', 'provider', [
          extension,
        ]),
        'songs',
      );
      expect(extension.searchBehavior?.filterIdForKind('track'), 'songs');
      expect(extension.searchBehavior?.filterIdForKind('album'), 'records');
      expect(
        HomeSearchProviderPolicy.displayFilterSelection(
          null,
          'album',
          'provider',
          [extension],
        ),
        'records',
      );
      expect(
        HomeSearchProviderPolicy.sanitizeFilter('podcast', 'provider', [
          extension,
        ]),
        isNull,
      );
    });
  });

  group('FFmpeg value models', () {
    test('normalizes structured and legacy decryption descriptors', () {
      final structured = DownloadDecryptionDescriptor.fromDownloadResult({
        'output_extension': 'M4A',
        'decryption': {
          'strategy': 'ffmpeg_mov_key',
          'key': ' secret ',
          'options': {'repair_ac4': true},
        },
      });
      final legacy = DownloadDecryptionDescriptor.fromDownloadResult({
        'decryption_key': 'legacy',
        'output_extension': '.flac',
      });

      expect(structured, isNotNull);
      expect(structured!.normalizedStrategy, 'ffmpeg.mov_key');
      expect(structured.normalizedOutputExtension, '.m4a');
      expect(structured.key, 'secret');
      expect(legacy!.inputFormat, 'mov');
      expect(legacy.normalizedOutputExtension, '.flac');
    });

    test('rejects empty or unsupported structured decryption requests', () {
      expect(
        DownloadDecryptionDescriptor.fromDownloadResult({
          'decryption': {'strategy': 'custom', 'key': 'secret'},
        }),
        isNull,
      );
      expect(
        DownloadDecryptionDescriptor.fromDownloadResult({
          'decryption': {'strategy': 'ffmpeg.mov_key', 'key': ' '},
        }),
        isNull,
      );
    });
  });

  group('audio metadata modules', () {
    test('maps shared tags consistently for native, M4A, and ID3 writers', () {
      final metadata = {
        'TITLE': 'Track',
        'ARTIST': 'Artist',
        'ALBUM': 'Album',
        'ALBUM_ARTIST': 'Album Artist',
        'TRACKNUMBER': '3/12',
        'DISCNUMBER': '1/2',
        'DATE': '2026-08-01',
        'GENRE': 'Pop',
        'ISRC': 'TEST12345678',
        'UNSYNCEDLYRICS': 'Lyrics',
        'ORGANIZATION': 'Label',
        'COPYRIGHT': 'Copyright',
        'COMPOSER': 'Composer',
        'COMMENT': 'Comment',
        'ITUNESADVISORY': '1',
        'REPLAYGAIN_TRACK_GAIN': '-5.00 dB',
        'BIT_DEPTH': '24',
      };

      final native = AudioMetadataMapper.vorbisToNativeChunkFields(metadata);
      final m4a = AudioMetadataMapper.convertToM4aTags(metadata);
      final m4aIdentity = AudioMetadataMapper.m4aReleaseIdentityFields(
        metadata,
      );
      final id3 = AudioMetadataMapper.convertToId3Tags(metadata);

      expect(native['title'], 'Track');
      expect(native['artist'], 'Artist');
      expect(native['album'], 'Album');
      expect(native['album_artist'], 'Album Artist');
      expect(native['track_number'], '3');
      expect(native['track_total'], '12');
      expect(native['disc_number'], '1');
      expect(native['disc_total'], '2');
      expect(native['replaygain_track_gain'], '-5.00 dB');
      expect(native['date'], '2026-08-01');
      expect(native['genre'], 'Pop');
      expect(native['label'], 'Label');
      expect(native['copyright'], 'Copyright');
      expect(native['composer'], 'Composer');
      expect(native['comment'], 'Comment');
      expect(native['explicit'], '1');
      expect(m4a['isrc'], 'TEST12345678');
      expect(m4a['lyrics'], 'Lyrics');
      expect(m4aIdentity['explicit'], '1');
      expect(id3['TSRC'], 'TEST12345678');
      expect(id3['ITUNESADVISORY'], '1');
      expect(id3['REPLAYGAIN_TRACK_GAIN'], '-5.00 dB');
      expect(id3['title'], 'Track');
      expect(id3['artist'], 'Artist');
      expect(id3['album'], 'Album');
      expect(id3['track'], '3/12');
      expect(id3['disc'], '1/2');
      expect(native, isNot(contains('bit_depth')));
    });

    test('builds split Vorbis artist entries without losing other tags', () {
      final entries = AudioMetadataMapper.buildVorbisMetadataEntries({
        'ARTIST': 'First & Second',
        'TITLE': 'Track',
      }, artistTagMode: artistTagModeSplitVorbis);

      expect(
        entries.where((entry) => entry.key == 'ARTIST').map((e) => e.value),
        ['First', 'Second'],
      );
      expect(
        entries.where((entry) => entry.key == 'TITLE').single.value,
        'Track',
      );
      final primary = AudioMetadataMapper.buildVorbisMetadataEntries({
        'ARTIST': 'First & Second',
        'ALBUMARTIST': 'First, Second',
        'TITLE': 'Track',
      }, artistTagMode: artistTagModePrimary);
      expect(
        primary.where((entry) => entry.key == 'ARTIST').map((e) => e.value),
        ['First'],
      );
      expect(
        primary
            .where((entry) => entry.key == 'ALBUMARTIST')
            .map((e) => e.value),
        ['First'],
      );
      final advisory = AudioMetadataMapper.buildVorbisMetadataEntries({
        'EXPLICIT': 'true',
      }).single;
      expect(advisory.key, 'ITUNESADVISORY');
      expect(advisory.value, '1');
    });

    test('writes one ID3v2.3 USLT frame and replaces it on update', () {
      final audio = Uint8List.fromList([0xff, 0xfb, 0x90, 0x64]);
      final first = Id3v23Lyrics.writeUnsyncedLyrics(audio, 'First lyrics');
      final second = Id3v23Lyrics.writeUnsyncedLyrics(
        first!,
        'Replacement lyrics',
      );

      expect(second, isNotNull);
      expect(second!.sublist(0, 4), [0x49, 0x44, 0x33, 0x03]);
      expect(_sequenceCount(second, ascii.encode('USLT')), 1);
      expect(second.sublist(second.length - audio.length), audio);
    });

    test('leaves unsupported ID3 versions unchanged', () {
      final id3v24 = Uint8List.fromList([
        0x49,
        0x44,
        0x33,
        0x04,
        0,
        0,
        0,
        0,
        0,
        0,
      ]);

      expect(Id3v23Lyrics.writeUnsyncedLyrics(id3v24, 'Lyrics'), isNull);
    });
  });

  test('queue state owns lookup rebuilding independently of notifier', () {
    final queued = DownloadItem(
      id: 'one',
      track: track(id: 'track-one', name: 'One'),
      service: 'extension.test',
      createdAt: DateTime.utc(2026),
    );
    final completed = queued.copyWith(status: DownloadStatus.completed);

    final initial = const DownloadQueueState().copyWith(items: [queued]);
    final next = initial.copyWith(
      items: [completed],
      currentDownload: completed,
    );
    final cleared = next.copyWith(currentDownload: null);

    expect(initial.queuedCount, 1);
    expect(next.completedCount, 1);
    expect(next.lookup.byItemId['one']?.status, DownloadStatus.completed);
    expect(next.currentDownload, completed);
    expect(cleared.currentDownload, isNull);
  });
}

int _sequenceCount(Uint8List bytes, List<int> sequence) {
  var count = 0;
  for (var index = 0; index <= bytes.length - sequence.length; index++) {
    var matches = true;
    for (var offset = 0; offset < sequence.length; offset++) {
      if (bytes[index + offset] != sequence[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) count++;
  }
  return count;
}

Extension _searchExtension({
  required String id,
  bool enabled = true,
  bool primary = false,
  List<SearchFilter> filters = const [],
}) {
  return Extension(
    id: id,
    name: id,
    displayName: id,
    version: '1.0.0',
    description: 'test',
    enabled: enabled,
    status: 'loaded',
    searchBehavior: SearchBehavior(
      enabled: true,
      primary: primary,
      filters: filters,
    ),
  );
}
