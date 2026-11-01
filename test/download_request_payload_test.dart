import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/utils/artist_utils.dart';

void main() {
  group('DownloadRequestPayload', () {
    test('serializes all backend field names', () {
      const payload = DownloadRequestPayload(
        isrc: 'ISRC123',
        service: 'source-provider',
        downloadProvider: 'download-provider',
        providerTrackId: '123456789',
        spotifyId: 'source-track-1',
        trackName: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        albumArtist: 'Album Artist',
        coverUrl: 'https://example.test/cover.jpg',
        coverMaxDimension: 1000,
        outputDir: '/downloads',
        filenameFormat: '{artist} - {title}',
        quality: 'HI_RES',
        embedMetadata: false,
        artistTagMode: artistTagModeSplitVorbis,
        embedLyrics: false,
        embedReplayGain: true,
        postProcessingEnabled: true,
        autoConvertDownloads: true,
        autoConvertFormat: 'opus',
        autoConvertBitrate: '192k',
        autoConvertMaxBitDepth: 24,
        autoConvertMaxSampleRate: 48000,
        trackNumber: 7,
        playlistPosition: 3,
        discNumber: 2,
        totalTracks: 12,
        totalDiscs: 2,
        releaseDate: '2026-05-04',
        itemId: 'item-1',
        durationMs: 250000,
        source: 'extension.example',
        genre: 'Pop',
        label: 'Label',
        copyright: 'Copyright',
        composer: 'Composer',
        comment: 'https://example.test/album/1',
        explicit: true,
        albumType: 'compilation',
        upc: '0012345678901',
        tidalId: 'alternate-id-a',
        qobuzId: 'alternate-id-b',
        deezerId: 'alternate-id-c',
        lyricsMode: 'sidecar',
        useExtensions: true,
        useFallback: true,
        storageMode: 'saf',
        safTreeUri: 'content://tree/music',
        safRelativeDir: 'Album',
        safFileName: 'Song.flac',
        safOutputExt: 'flac',
        outputExt: '.flac',
        allowQualityVariant: true,
        qualityVariant: 'qv_12345678',
        qualityVariantCollisionOnly: true,
        songLinkRegion: 'ID',
        networkConcurrencyLimit: 2,
      );

      expect(payload.toJson(), {
        'contract_version': DownloadRequestPayload.nativeWorkerContractVersion,
        'isrc': 'ISRC123',
        'service': 'source-provider',
        'download_provider': 'download-provider',
        'provider_track_id': '123456789',
        'spotify_id': 'source-track-1',
        'track_name': 'Song',
        'artist_name': 'Artist',
        'album_name': 'Album',
        'album_artist': 'Album Artist',
        'cover_url': 'https://example.test/cover.jpg',
        'cover_max_dimension': 1000,
        'output_dir': '/downloads',
        'filename_format': '{artist} - {title}',
        'quality': 'HI_RES',
        'embed_metadata': false,
        'artist_tag_mode': artistTagModeSplitVorbis,
        'embed_lyrics': false,
        'embed_replaygain': true,
        'post_processing_enabled': true,
        'auto_convert_downloads': true,
        'auto_convert_format': 'opus',
        'auto_convert_bitrate': '192k',
        'auto_convert_max_bit_depth': 24,
        'auto_convert_max_sample_rate': 48000,
        'track_number': 7,
        'playlist_position': 3,
        'disc_number': 2,
        'total_tracks': 12,
        'total_discs': 2,
        'release_date': '2026-05-04',
        'item_id': 'item-1',
        'duration_ms': 250000,
        'source': 'extension.example',
        'genre': 'Pop',
        'label': 'Label',
        'copyright': 'Copyright',
        'composer': 'Composer',
        'comment': 'https://example.test/album/1',
        'explicit': true,
        'album_type': 'compilation',
        'upc': '0012345678901',
        'tidal_id': 'alternate-id-a',
        'qobuz_id': 'alternate-id-b',
        'deezer_id': 'alternate-id-c',
        'lyrics_mode': 'sidecar',
        'use_extensions': true,
        'use_fallback': true,
        'storage_mode': 'saf',
        'saf_tree_uri': 'content://tree/music',
        'saf_relative_dir': 'Album',
        'saf_file_name': 'Song.flac',
        'saf_output_ext': 'flac',
        'output_ext': '.flac',
        'stage_saf_output': false,
        'defer_saf_publish': false,
        'requires_container_conversion': false,
        'allow_quality_variant': true,
        'quality_variant': 'qv_12345678',
        'quality_variant_collision_only': true,
        'songlink_region': 'ID',
        'network_concurrency_limit': 2,
      });
    });

    test('withStrategy only changes requested strategy flags', () {
      const payload = DownloadRequestPayload(
        trackName: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        outputDir: '/downloads',
        albumFolderTemplate: '[2024] {album}',
        filenameFormat: '{title}',
        useExtensions: false,
        useFallback: true,
      );

      final updated = payload.withStrategy(useExtensions: true);

      expect(updated.useExtensions, isTrue);
      expect(updated.useFallback, isTrue);
      expect(updated.trackName, payload.trackName);
      expect(updated.albumFolderTemplate, payload.albumFolderTemplate);
      expect(updated.toJson()['album_folder_template'], '[2024] {album}');
      expect(updated.filenameFormat, payload.filenameFormat);
      expect(updated.downloadProvider, payload.downloadProvider);
      expect(updated.providerTrackId, payload.providerTrackId);
      expect(updated.allowQualityVariant, payload.allowQualityVariant);
      expect(updated.qualityVariant, payload.qualityVariant);
      expect(updated.autoConvertDownloads, payload.autoConvertDownloads);
      expect(updated.autoConvertFormat, payload.autoConvertFormat);
      expect(updated.autoConvertBitrate, payload.autoConvertBitrate);
      expect(updated.autoConvertMaxBitDepth, payload.autoConvertMaxBitDepth);
      expect(
        updated.autoConvertMaxSampleRate,
        payload.autoConvertMaxSampleRate,
      );
      expect(updated.explicit, payload.explicit);
      expect(updated.albumType, payload.albumType);
      expect(updated.upc, payload.upc);
      expect(
        updated.qualityVariantCollisionOnly,
        payload.qualityVariantCollisionOnly,
      );
    });
  });

  group('extension download transfer policy', () {
    test('parses and bounds the generic manifest capability', () {
      final extension = Extension.fromJson({
        'id': 'provider',
        'name': 'provider',
        'capabilities': {
          'downloadTransfer': {
            'maxAttempts': 99,
            'resumePolicy': 'validated',
            'persistentCheckpoint': true,
            'maxParallelSegments': 99,
            'maxConcurrentDownloads': 99,
          },
        },
      });

      final policy = extension.downloadTransferPolicy;
      expect(policy.maxAttempts, 8);
      expect(policy.resumePolicy, 'validated');
      expect(policy.persistentCheckpoint, isTrue);
      expect(policy.maxParallelSegments, 8);
      expect(policy.maxConcurrentDownloads, 3);
    });

    test('disables checkpoints unless validated resume is selected', () {
      final extension = Extension.fromJson({
        'id': 'provider',
        'name': 'provider',
        'capabilities': {
          'downloadTransfer': {'persistentCheckpoint': true},
        },
      });

      expect(extension.downloadTransferPolicy.resumePolicy, 'none');
      expect(extension.downloadTransferPolicy.persistentCheckpoint, isFalse);
    });
  });
}
