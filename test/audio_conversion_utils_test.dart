import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/audio_conversion_utils.dart';
import 'package:mornye/utils/audio_format_utils.dart';

void main() {
  group('same-format lossless conversion', () {
    test('allows FLAC re-encoding for quality processing', () {
      expect(
        canConvertAudioFormat(sourceFormat: 'FLAC', targetFormat: 'FLAC'),
        isTrue,
      );
      expect(
        canConvertAudioFormat(sourceFormat: 'flac', targetFormat: ' flac '),
        isTrue,
      );
    });

    test('keeps same-format lossy conversion disabled', () {
      expect(
        canConvertAudioFormat(sourceFormat: 'MP3', targetFormat: 'MP3'),
        isFalse,
      );
      expect(
        canConvertAudioFormat(sourceFormat: 'Opus', targetFormat: 'Opus'),
        isFalse,
      );
    });
  });

  group('lossless processing options', () {
    test('preserves both resamplers and both dither methods', () {
      const soxrTpdf = LosslessConversionProcessing(
        dither: 'triangular',
        resampler: 'soxr',
      );
      const swrHighPass = LosslessConversionProcessing(
        dither: 'triangular_hp',
        resampler: 'swr',
      );

      expect(soxrTpdf.normalizedResampler, 'soxr');
      expect(soxrTpdf.normalizedDither, 'triangular');
      expect(soxrTpdf.hasDither, isTrue);
      expect(swrHighPass.normalizedResampler, 'swr');
      expect(swrHighPass.normalizedDither, 'triangular_hp');
      expect(swrHighPass.hasDither, isTrue);
    });

    test('uses VHQ and a 95 percent passband only for SoXR', () {
      const soxr = LosslessConversionProcessing(resampler: 'soxr');
      const swr = LosslessConversionProcessing(resampler: 'swr');

      expect(losslessResamplerFilterOptions(soxr), [
        'resampler=soxr',
        'precision=28',
        'cutoff=0.95',
      ]);
      expect(losslessResamplerFilterOptions(swr), ['resampler=swr']);
    });
  });

  group('kept conversion output identity', () {
    test('keeps the original base name and only changes the extension', () {
      expect(
        convertedOutputFileName(
          originalFileName: 'Track.flac',
          targetFormat: 'FLAC',
        ),
        'Track.flac',
      );
      expect(
        convertedOutputFileName(
          originalFileName: 'Track.flac',
          targetFormat: 'MP3',
        ),
        'Track.mp3',
      );
    });

    test('derives stable but path-specific converted item IDs', () {
      final first = convertedLibraryItemId('source', '/music/Track.flac');
      final repeated = convertedLibraryItemId('source', '/music/Track.flac');
      final other = convertedLibraryItemId('source', '/music/Track.m4a');

      expect(first, repeated);
      expect(first, isNot(other));
    });
  });

  group('automatic download conversion settings', () {
    test('batch caps use the highest source and retain unknown options', () {
      expect(conversionSourceMaximum([44100, 96000]), 96000);
      expect(conversionSourceMaximum([16, 24]), 24);
      expect(conversionSourceMaximum([44100, null]), isNull);
      expect(conversionSourceMaximum([]), isNull);
      expect(normalizeAutoConvertBitDepth(0), 0);
      expect(normalizeAutoConvertBitDepth(32), 16);
      expect(normalizeAutoConvertSampleRate(0), 0);
      expect(normalizeAutoConvertSampleRate(12345), 48000);
    });

    test('normalizes supported formats and bitrates', () {
      expect(normalizeAutoConvertFormat('M4A'), 'aac');
      expect(normalizeAutoConvertFormat('unexpected'), 'mp3');
      expect(normalizeAutoConvertBitrate('256 kbps'), '256k');
      expect(normalizeAutoConvertBitrate('160 kbps'), '160k');
      expect(normalizeAutoConvertBitrate('999k'), '320k');
    });

    test('skips only an output that already matches format and bitrate', () {
      expect(
        autoConversionAlreadySatisfied(
          filePath: '/music/Track.mp3',
          targetFormat: 'mp3',
          targetBitrate: '320k',
          quality: 'MP3 320kbps',
        ),
        isTrue,
      );
      expect(
        autoConversionAlreadySatisfied(
          filePath: '/music/Track.m4a',
          targetFormat: 'aac',
          targetBitrate: '128k',
          bitrateKbps: 256,
        ),
        isFalse,
      );
    });
  });
}
