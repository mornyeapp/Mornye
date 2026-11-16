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
    test('Smart resolves per source and only dithers a known reduction', () {
      const smart = LosslessConversionProcessing(resampler: 'soxr');
      expect(smart.normalizedDither, 'auto');
      expect(smart.hasDither, isFalse);
      for (final (source, target, expected) in <(int?, int?, String)>[
        (24, 16, 'triangular'),
        (32, 24, 'triangular'),
        (16, 16, 'none'),
        (24, 24, 'none'),
        (16, 24, 'none'),
        (24, null, 'none'),
        (null, 16, 'none'),
        (0, 16, 'none'),
        (24, 0, 'none'),
      ]) {
        final resolved = smart.resolveDither(
          sourceBitDepth: source,
          targetBitDepth: target,
        );
        expect(
          resolved.normalizedDither,
          expected,
          reason: '$source -> $target',
        );
        expect(resolved.normalizedResampler, 'soxr');
      }
    });

    test('Smart high-pass uses TPDF HP only for a known reduction', () {
      const smart = LosslessConversionProcessing(highPass: true);
      for (final (source, target, expected) in <(int?, int?, String)>[
        (24, 16, 'triangular_hp'),
        (32, 24, 'triangular_hp'),
        (16, 16, 'none'),
        (16, 24, 'none'),
        (null, 16, 'none'),
      ]) {
        expect(
          smart
              .resolveDither(sourceBitDepth: source, targetBitDepth: target)
              .normalizedDither,
          expected,
          reason: '$source -> $target',
        );
      }
      // The switch belongs to Smart; explicit choices keep their method.
      expect(
        const LosslessConversionProcessing(dither: 'triangular', highPass: true)
            .resolveDither(sourceBitDepth: 24, targetBitDepth: 16)
            .normalizedDither,
        'triangular',
      );
    });

    test('explicit dither choices override Smart behavior', () {
      for (final mode in ['none', 'triangular', 'triangular_hp']) {
        final explicit = LosslessConversionProcessing(dither: mode);
        for (final depth in [16, 24]) {
          expect(
            explicit
                .resolveDither(sourceBitDepth: depth, targetBitDepth: 16)
                .normalizedDither,
            mode,
          );
        }
      }
    });

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

    test('uses the highest SoXR settings only for SoXR', () {
      const soxr = LosslessConversionProcessing(resampler: 'soxr');
      const swr = LosslessConversionProcessing(resampler: 'swr');

      expect(losslessResamplerFilterOptions(soxr), [
        'resampler=soxr',
        'precision=33',
        'cutoff=0.95',
        'cheby=1',
      ]);
      expect(losslessResamplerFilterOptions(swr), ['resampler=swr']);
    });

    test('each resampler offers its own quality levels', () {
      List<String> options(String resampler, String? quality) =>
          losslessResamplerFilterOptions(
            LosslessConversionProcessing(
              resampler: resampler,
              resamplerQuality: quality,
            ),
          );

      expect(losslessResamplerQualityOptionsFor('swr'), [
        'fast',
        'medium',
        'high',
        'very_high',
        'best',
      ]);
      expect(options('swr', 'fast'), ['resampler=swr', 'filter_size=16']);
      // Medium is the library's own filter, as before the choice existed.
      expect(options('swr', 'medium'), ['resampler=swr']);
      expect(options('swr', null), ['resampler=swr']);
      expect(options('swr', 'high'), ['resampler=swr', 'filter_size=64']);
      expect(options('swr', 'very_high'), [
        'resampler=swr',
        'filter_size=128',
        'kaiser_beta=12',
      ]);
      expect(options('swr', 'best'), [
        'resampler=swr',
        'filter_size=256',
        'kaiser_beta=16',
      ]);

      expect(losslessResamplerQualityOptionsFor('soxr'), [
        'medium',
        'high',
        'very_high',
        'best',
      ]);
      expect(options('soxr', 'medium'), ['resampler=soxr', 'precision=16']);
      // SoX's High Quality and Very High Quality recipes.
      expect(options('soxr', 'high'), ['resampler=soxr', 'precision=20']);
      expect(options('soxr', 'very_high'), ['resampler=soxr', 'precision=28']);
      expect(options('soxr', 'best'), options('soxr', null));
    });

    test('an unknown quality level falls back to the default', () {
      const soxrFast = LosslessConversionProcessing(
        resampler: 'soxr',
        resamplerQuality: 'fast',
      );
      expect(soxrFast.normalizedResamplerQuality, 'best');
      expect(soxrFast.hasDefaultResamplerQuality, isTrue);
      const other = LosslessConversionProcessing(resamplerQuality: 'other');
      expect(other.normalizedResamplerQuality, 'medium');
      const high = LosslessConversionProcessing(
        dither: 'auto',
        resamplerQuality: ' High ',
      );
      expect(high.normalizedResamplerQuality, 'high');
      expect(high.hasDefaultResamplerQuality, isFalse);
      // Resolving Smart dither keeps the level.
      expect(
        high
            .resolveDither(sourceBitDepth: 24, targetBitDepth: 16)
            .normalizedResamplerQuality,
        'high',
      );
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

    test('accepts ALAC as a lossless target in an M4A file', () {
      expect(autoConvertFormats, contains('alac'));
      expect(normalizeAutoConvertFormat(' ALAC '), 'alac');
      expect(autoConvertFormatLabel('alac'), 'M4A (ALAC)');
      expect(isLosslessAutoConvertFormat('alac'), isTrue);
      expect(isLosslessAutoConvertFormat('flac'), isTrue);
      for (final lossy in ['mp3', 'aac', 'm4a', 'opus']) {
        expect(isLosslessAutoConvertFormat(lossy), isFalse);
      }
      expect(
        convertedOutputFileName(
          originalFileName: 'Artist - Song.flac',
          targetFormat: 'alac',
        ),
        'Artist - Song.m4a',
      );
    });

    test('an ALAC M4A matches ALAC only by its codec and caps', () {
      bool satisfied(String? codec, int depth, int rate) =>
          autoConversionAlreadySatisfied(
            filePath: '/music/Track.m4a',
            targetFormat: 'alac',
            targetBitrate: '320k',
            codec: codec,
            bitDepth: depth,
            sampleRate: rate,
            maxBitDepth: 16,
            maxSampleRate: 48000,
          );
      expect(satisfied('alac', 16, 44100), isTrue);
      expect(satisfied('alac', 24, 96000), isFalse);
      // The .m4a name alone never proves ALAC: AAC uses the same container.
      expect(satisfied('aac', 16, 44100), isFalse);
      expect(satisfied(null, 16, 44100), isFalse);
      expect(satisfied('flac', 16, 44100), isFalse);
      // FLAC keeps its path-based rule.
      expect(
        autoConversionAlreadySatisfied(
          filePath: '/music/Track.flac',
          targetFormat: 'flac',
          targetBitrate: '320k',
          bitDepth: 16,
          sampleRate: 44100,
          maxBitDepth: 16,
          maxSampleRate: 48000,
        ),
        isTrue,
      );
    });
  });
}
