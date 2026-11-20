import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/utils/audio_quality_badge_policy.dart';

void main() {
  test(
    'Library history and local cards retain labels for legacy Opus rows',
    () {
      final history = UnifiedLibraryItem.fromDownloadHistory(
        DownloadHistoryItem(
          id: 'history-song',
          trackName: 'Song',
          artistName: 'Artist',
          albumName: 'Album',
          filePath: 'content://music/document/42',
          safFileName: 'Song.opus',
          quality: '16-bit/44.1kHz',
          service: 'example',
          downloadedAt: DateTime(2026),
        ),
      );
      final local = UnifiedLibraryItem.fromLocalLibrary(
        LocalLibraryItem(
          id: 'local-song',
          trackName: 'Song',
          artistName: 'Artist',
          albumName: 'Album',
          filePath: '/music/Song.opus',
          scannedAt: DateTime(2026),
        ),
      );
      for (final item in [history, local]) {
        expect(
          item.qualityForMode(AppSettings.libraryQualityLabelBitDepth),
          'OPUS',
        );
        expect(
          item.qualityForMode(AppSettings.libraryQualityLabelBitrate),
          'OPUS',
        );
      }
    },
  );

  group('Library audio quality badge color', () {
    test('keeps legacy 24-bit labels highlighted', () {
      expect(shouldHighlightAudioQualityBadge('24-bit/96kHz'), isTrue);
      expect(shouldHighlightAudioQualityBadge('FLAC 24bit-48kHz'), isTrue);
      expect(shouldHighlightAudioQualityBadge('24/192kHz'), isTrue);
    });

    test('highlights only measured bitrates above 900 kbps', () {
      expect(shouldHighlightAudioQualityBadge('900kbps'), isFalse);
      expect(shouldHighlightAudioQualityBadge('901kbps'), isTrue);
      expect(shouldHighlightAudioQualityBadge('FLAC 1760 kbps'), isTrue);
      expect(shouldHighlightAudioQualityBadge('1.76 Mbps'), isTrue);
    });

    test('leaves normal lossy bitrate labels neutral', () {
      expect(shouldHighlightAudioQualityBadge('AAC 320kbps'), isFalse);
      expect(shouldHighlightAudioQualityBadge('OPUS 256k'), isFalse);
      expect(shouldHighlightAudioQualityBadge('16-bit/44.1kHz'), isFalse);
    });
  });

  group('Library audio quality label mode', () {
    test('keeps an Opus badge when bitrate has not been backfilled', () {
      for (final mode in [
        AppSettings.libraryQualityLabelBitrate,
        AppSettings.libraryQualityLabelBitDepth,
        AppSettings.libraryQualityLabelBitDepthOnly,
        AppSettings.libraryQualityLabelBitDepthBitrate,
        AppSettings.libraryQualityLabelFileFormat,
      ]) {
        expect(
          buildLibraryAudioQualityLabel(
            mode: mode,
            format: 'opus',
            bitDepth: 16,
            sampleRate: 44100,
            storedQuality: '16-bit/44.1kHz',
          ),
          'OPUS',
          reason: mode,
        );
      }
    });

    test('uses stored Opus bitrate until measured bitrate is available', () {
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelBitDepth,
          format: 'opus',
          storedQuality: 'OPUS 320kbps',
        ),
        'OPUS 320kbps',
      );
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelBitDepth,
          format: 'opus',
          bitrateKbps: 256,
          storedQuality: 'OPUS 320kbps',
        ),
        'OPUS 256kbps',
      );
      expect(formatLibraryGridAudioQualityLabel('OPUS 320kbps'), '320k');
      expect(formatLibraryGridAudioQualityLabel('OPUS'), 'OPUS');
    });

    test('uses the path or SAF name when a legacy row has no format', () {
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelBitDepth,
          filePath: '/music/Song.opus',
          storedQuality: '16-bit/44.1kHz',
        ),
        'OPUS',
      );
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelBitrate,
          filePath: 'content://music/document/42',
          fileName: 'Song.OPUS',
        ),
        'OPUS',
      );
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelFileFormat,
          format: 'alac',
          filePath: '/music/Song.m4a',
        ),
        'ALAC',
      );
    });

    test('defaults to bit depth and keeps the bitrate mode', () {
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelBitrate,
          format: 'flac',
          bitrateKbps: 1760,
          bitDepth: 24,
          sampleRate: 48000,
        ),
        'FLAC 1760kbps',
      );
      expect(
        normalizeLibraryQualityLabelMode('unsupported'),
        AppSettings.libraryQualityLabelBitDepthOnly,
      );
      expect(
        normalizeLibraryQualityLabelMode(
          AppSettings.libraryQualityLabelBitrate,
        ),
        AppSettings.libraryQualityLabelBitrate,
      );
      expect(
        normalizeLibraryQualityLabelMode(
          AppSettings.libraryQualityLabelBitDepthBitrate,
        ),
        AppSettings.libraryQualityLabelBitDepthBitrate,
      );
      expect(
        normalizeLibraryQualityLabelMode(
          AppSettings.libraryQualityLabelBitDepthOnly,
        ),
        AppSettings.libraryQualityLabelBitDepthOnly,
      );
    });

    test('shows detected file format without quality metrics', () {
      expect(
        normalizeLibraryQualityLabelMode(
          AppSettings.libraryQualityLabelFileFormat,
        ),
        AppSettings.libraryQualityLabelFileFormat,
      );
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelFileFormat,
          format: 'flac',
          bitrateKbps: 1760,
          bitDepth: 24,
          sampleRate: 96000,
        ),
        'FLAC',
      );
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelFileFormat,
          format: 'm4a',
          bitrateKbps: 256,
        ),
        'M4A',
      );
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelFileFormat,
          format: 'mp3',
          bitrateKbps: 320,
        ),
        'MP3',
      );
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelFileFormat,
          format: 'ape',
        ),
        'APE',
      );
    });

    test('the simple mode names a tier, Dolby or the format', () {
      const mode = AppSettings.libraryQualityLabelSimple;
      expect(normalizeLibraryQualityLabelMode(mode), mode);
      String? label({
        String? format,
        String? filePath,
        int? bitrateKbps,
        int? bitDepth,
        int? sampleRate,
        String? storedQuality,
      }) => buildLibraryAudioQualityLabel(
        mode: mode,
        format: format,
        filePath: filePath,
        bitrateKbps: bitrateKbps,
        bitDepth: bitDepth,
        sampleRate: sampleRate,
        storedQuality: storedQuality,
      );

      expect(
        label(format: 'flac', bitDepth: 16, sampleRate: 44100),
        'Lossless',
      );
      expect(label(format: 'flac', bitDepth: 24, sampleRate: 96000), 'Hi-Res');
      expect(label(format: 'alac', bitDepth: 24, sampleRate: 48000), 'Hi-Res');
      // A lossless file whose bit depth was never read is still lossless.
      expect(label(filePath: '/music/song.wav'), 'Lossless');
      expect(label(format: 'flac', storedQuality: '24-bit/96kHz'), 'Hi-Res');
      expect(label(bitDepth: 16), 'Lossless');
      for (final dolby in ['eac3', 'ec-3', 'ac3', 'ac4']) {
        expect(label(format: dolby, bitrateKbps: 768), 'Dolby');
      }
      expect(label(format: 'opus', bitrateKbps: 375), 'OPUS');
      expect(label(format: 'mp3', bitrateKbps: 320), 'MP3');
      expect(label(format: 'm4a', bitrateKbps: 256), 'M4A');
      // An unknown format keeps its own name: it may be lossy.
      expect(label(format: 'wma', bitDepth: 16), 'WMA');
      expect(label(), isNull);
      expect(shouldHighlightAudioQualityBadge('Hi-Res'), isTrue);
      expect(shouldHighlightAudioQualityBadge('Lossless'), isFalse);
      expect(formatLibraryGridAudioQualityLabel('Hi-Res'), 'Hi-Res');
    });

    test('shows only bit depth when requested', () {
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelBitDepthOnly,
          format: 'flac',
          bitrateKbps: 1411,
          bitDepth: 16,
          sampleRate: 44100,
        ),
        '16-bit',
      );
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelBitDepthOnly,
          format: 'flac',
          storedQuality: '24-bit/96kHz',
        ),
        '24-bit',
      );
    });

    test('restores legacy bit depth and sample rate labels', () {
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelBitDepth,
          format: 'flac',
          bitrateKbps: 1760,
          bitDepth: 24,
          sampleRate: 48000,
        ),
        '24-bit/48kHz',
      );
    });

    test('keeps bitrate meaningful for lossy formats', () {
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelBitDepth,
          format: 'mp3',
          bitrateKbps: 320,
          bitDepth: 16,
          sampleRate: 44100,
        ),
        'MP3 320kbps',
      );
    });

    test('combines bit depth and measured bitrate for lossless audio', () {
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelBitDepthBitrate,
          format: 'flac',
          bitrateKbps: 1760,
          bitDepth: 24,
          sampleRate: 48000,
        ),
        '24-bit/1760kbps',
      );
    });

    test('keeps lossy audio on bitrate in the combined mode', () {
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelBitDepthBitrate,
          format: 'aac',
          bitrateKbps: 256,
          bitDepth: 16,
          sampleRate: 44100,
        ),
        'AAC 256kbps',
      );
    });

    test('falls back when the preferred metadata is unavailable', () {
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelBitDepth,
          format: 'flac',
          bitrateKbps: 950,
          storedQuality: 'LOSSLESS',
        ),
        'FLAC 950kbps',
      );
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelBitrate,
          storedQuality: '24-bit/96kHz',
        ),
        isNull,
      );
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelBitrate,
          format: 'flac',
          storedQuality: 'FLAC 1411kbps',
        ),
        'FLAC 1411kbps',
      );
      expect(
        buildLibraryAudioQualityLabel(
          mode: AppSettings.libraryQualityLabelBitDepthBitrate,
          format: 'flac',
          bitDepth: 24,
          storedQuality: 'FLAC 1411kbps',
        ),
        '24-bit/1411kbps',
      );
    });
  });

  group('Library grid audio quality label', () {
    test('keeps both parts of detailed bit-depth labels', () {
      expect(
        formatLibraryGridAudioQualityLabel('16-bit/44.1kHz'),
        '16-bit/44.1kHz',
      );
      expect(
        formatLibraryGridAudioQualityLabel('16-bit/1411kbps'),
        '16-bit/1411kbps',
      );
      expect(isDetailedLibraryAudioQualityLabel('16-bit/44.1kHz'), isTrue);
    });

    test('keeps bitrate-only grid labels compact', () {
      expect(formatLibraryGridAudioQualityLabel('FLAC 1760kbps'), '1760k');
      expect(formatLibraryGridAudioQualityLabel('Bitrate 1760kbps'), '1760k');
      expect(isDetailedLibraryAudioQualityLabel('FLAC 1760kbps'), isFalse);
    });
  });
}
