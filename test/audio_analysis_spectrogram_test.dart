import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/audio_analysis_widget.dart';

void main() {
  group('audio analysis codec support', () {
    test('rejects AC-4 aliases unsupported by the bundled decoder', () {
      expect(isAudioAnalysisCodecSupported('ac4'), isFalse);
      expect(isAudioAnalysisCodecSupported('AC-4'), isFalse);
      expect(isAudioAnalysisCodecSupported('Dolby Atmos (AC_4)'), isFalse);
      expect(unsupportedAudioAnalysisCodecLabel('AC-4'), 'AC-4');
    });

    test('keeps supported codecs inside MP4 analyzable', () {
      expect(isAudioAnalysisCodecSupported('aac'), isTrue);
      expect(isAudioAnalysisCodecSupported('alac'), isTrue);
      expect(isAudioAnalysisCodecSupported('eac3'), isTrue);
      expect(isAudioAnalysisCodecSupported('E-AC-3'), isTrue);
      expect(isAudioAnalysisCodecSupported('flac'), isTrue);
      expect(isAudioAnalysisCodecSupported(null), isTrue);
    });
  });

  group('audio analysis cache', () {
    test('invalidates results without bitrate source information', () {
      expect(AudioAnalysisData.cacheVersion, greaterThan(13));
    });
  });

  group('audio level analysis', () {
    test('reads peak and RMS from the final astats overall summary', () {
      const logs = '''
[Parsed_astats_0] Channel: 1
[Parsed_astats_0] Peak level dB: -0.847144
[Parsed_astats_0] RMS level dB: -12.935500
[Parsed_astats_0] Channel: 2
[Parsed_astats_0] Peak level dB: -0.861847
[Parsed_astats_0] RMS level dB: -12.752564
[Parsed_astats_0] Overall
[Parsed_astats_0] Peak level dB: -0.847144
[Parsed_astats_0] RMS level dB: -12.843069
''';

      final summary = parseAudioAstatsSummary(logs);

      expect(summary, isNotNull);
      expect(summary!.peakDb, closeTo(-0.847144, 0.000001));
      expect(summary.rmsDb, closeTo(-12.843069, 0.000001));
    });

    test('rejects logs delivered without the final RMS metric', () {
      const incompleteLogs = '''
[Parsed_astats_0] Overall
[Parsed_astats_0] Peak level dB: -0.847144
''';

      expect(parseAudioAstatsSummary(incompleteLogs), isNull);
    });

    test('reads per-session metadata without depending on FFmpeg logs', () {
      const metadata = '''
lavfi.astats.1.Peak_level=-0.847144
lavfi.astats.1.RMS_level=-12.935500
lavfi.astats.1.Peak_count=2.000000
lavfi.astats.2.Peak_level=-0.861847
lavfi.astats.2.RMS_level=-12.752564
lavfi.astats.2.Peak_count=2.000000
lavfi.astats.Overall.Peak_level=-0.847144
lavfi.astats.Overall.RMS_level=-12.843069
lavfi.r128.I=-9.708
lavfi.r128.true_peak=0.907
''';

      final summary = parseAudioAnalysisMetadata(metadata);

      expect(summary, isNotNull);
      expect(summary!.peakDb, closeTo(-0.847144, 0.000001));
      expect(summary.rmsDb, closeTo(-12.843069, 0.000001));
      expect(summary.integratedLufs, closeTo(-9.708, 0.000001));
      expect(summary.truePeakDb, closeTo(-0.8476, 0.001));
      expect(summary.channelStats, hasLength(2));
      expect(summary.channelStats.first.channel, 1);
      expect(summary.channelStats.first.peakCount, 2);
    });

    test('keeps the analyzer independent from process-global log level', () {
      final arguments = buildAudioMetricsArguments(
        inputPath: 'source.flac',
        metadataPath: '/tmp/metrics.txt',
        durationSeconds: 203.94,
      );

      expect(arguments, isNot(contains('-v')));
      expect(arguments, isNot(contains('-loglevel')));
      expect(arguments.join(' '), contains('ametadata=print'));
      expect(arguments.join(' '), contains("aselect='gte(t,201.940)'"));
    });

    test('rejects incomplete per-session metadata instead of using zero', () {
      const metadata = 'lavfi.astats.Overall.Peak_level=-0.8';

      expect(parseAudioAnalysisMetadata(metadata), isNull);
    });
  });

  group('audio spectrogram filter', () {
    test('keeps source rate and uses a full-range float pipeline', () {
      final filter = buildAudioSpectrogramFilter();

      expect(filter, contains('[0:a:0]aformat=sample_fmts=fltp'));
      expect(filter, contains('s=1600x800'));
      expect(filter, contains('scale=log'));
      expect(filter, contains('fscale=lin'));
      expect(filter, contains('win_func=hann'));
      expect(filter, contains('drange=120'));
      expect(filter, contains('limit=0'));
      expect(filter, isNot(contains('pan=')));
      expect(filter, isNot(contains('aresample')));
    });

    test('can render one source channel without app-specific branching', () {
      final filter = buildAudioSpectrogramFilter(channel: 1);

      expect(filter, contains('[0:a:0]pan=mono|c0=c1,'));
      expect(filter, contains('aformat=sample_fmts=fltp'));
    });

    test('processes the complete source without resampling or downmixing', () {
      final arguments = buildAudioSpectrogramArguments(
        inputPath: 'source.flac',
        outputPath: 'spectrum.rgba',
      );

      expect(arguments, containsAllInOrder(['-i', 'source.flac']));
      expect(arguments, containsAllInOrder(['-frames:v', '1']));
      expect(arguments, containsAllInOrder(['-pix_fmt', 'rgba']));
      expect(arguments, isNot(contains('-t')));
      expect(arguments, isNot(contains('-ss')));
      expect(arguments, isNot(contains('-ar')));
      expect(arguments, isNot(contains('-ac')));
      expect(arguments, isNot(contains('-loglevel')));
    });

    test('bounds retained audio without making splice noise persistent', () {
      final filter = buildAudioSpectrogramFilter(
        durationSeconds: 600,
        sampleRate: 192000,
        channels: 2,
      );

      // The cutoff estimator uses temporal P90. Keep window boundaries far
      // below ten percent of its 400 columns so seam energy remains an outlier.
      expect(audioSpectrogramSampleWindowCount, 16);
      expect(
        audioSpectrogramSampleWindowCount,
        lessThan(audioSpectralAnalysisWidth * 0.10),
      );
      expect(filter, contains("aselect='lt(mod(t,37.500000000),"));
      expect(filter, contains('1.365333333'));
      expect(filter, contains('asetpts=N/SR/TB'));
      expect(filter, contains('aformat=sample_fmts=fltp'));
      expect(filter, isNot(contains('aresample')));
    });

    test('keeps short files continuous', () {
      final filter = buildAudioSpectrogramFilter(
        durationSeconds: 60,
        sampleRate: 44100,
        channels: 2,
      );

      expect(filter, isNot(contains('aselect=')));
      expect(filter, isNot(contains('asetpts=')));
    });

    test('accounts for a selected mono channel in the memory bound', () {
      final combined = buildAudioSpectrogramFilter(
        durationSeconds: 60,
        sampleRate: 192000,
        channels: 8,
      );
      final mono = buildAudioSpectrogramFilter(
        channel: 3,
        durationSeconds: 60,
        sampleRate: 192000,
        channels: 8,
      );

      expect(combined, contains('aselect='));
      expect(mono, contains('pan=mono|c0=c3'));
      expect(mono, contains('aselect='));
      expect(combined, isNot(equals(mono)));
    });

    test('renders a monotonic cutoff plane beside the display image', () {
      final arguments = buildAudioSpectrogramArguments(
        inputPath: 'source.flac',
        outputPath: 'spectrum.rgba',
        cutoffOutputPath: 'cutoff.gray',
      );
      final filter = arguments[arguments.indexOf('-filter_complex') + 1];

      expect(filter, contains('asplit=2'));
      expect(filter, contains('color=intensity'));
      expect(filter, contains('s=400x800'));
      expect(filter, contains('color=green'));
      expect(filter, contains('format=gray[cutoff]'));
      expect(
        arguments,
        containsAllInOrder(['-map', '[cutoff]', '-frames:v', '1']),
      );
      expect(
        arguments,
        containsAllInOrder(['-pix_fmt', 'gray', 'cutoff.gray']),
      );
    });
  });

  group('effective spectral cutoff', () {
    const width = 200;
    const height = 800;
    const nyquist = 96000.0;

    test('preserves exact cutoffs across noisy and transient spectra', () {
      // Captured from the estimator before sharing sorted percentile windows.
      // Cover sharp/gradual limits, full-band slopes, noise and stepped bands
      // at several resolutions and Nyquist frequencies.
      const expected = <int, double>{
        3: 5290.322580645161,
        7: 5406.25,
        11: 5403.508771929824,
        15: 5395.0,
        31: 14952.65625,
        47: 16305.0,
        63: 32610.0,
        79: 65220.0,
        83: 5032.258064516129,
        87: 5156.25,
        91: 5162.907268170426,
        95: 5155.0,
        111: 14291.15625,
        127: 15585.0,
        143: 31230.0,
        159: 62340.0,
        175: 8000.0,
        191: 22050.0,
        207: 24000.0,
        223: 48000.0,
        239: 96000.0,
        255: 8000.0,
        271: 22050.0,
        287: 24000.0,
        303: 48000.0,
        319: 96000.0,
        335: 5795.0,
        351: 16055.15625,
        367: 17505.0,
        383: 35010.0,
        399: 70020.0,
      };
      for (final entry in expected.entries) {
        final spectrum = _noisySpectrum(entry.key);
        expect(
          estimateEffectiveSpectralCutoffHz(
            intensity: spectrum.intensity,
            width: spectrum.width,
            height: spectrum.height,
            maxFrequencyHz: spectrum.maxFrequencyHz,
          ),
          entry.value,
          reason: 'spectrum ${entry.key}',
        );
      }
    });

    test('ignores a narrow ultrasonic pilot above a 22 kHz music band', () {
      final intensity = _blankIntensity(width, height, value: 12);
      _paintFrequencyBand(
        intensity,
        width: width,
        height: height,
        maxFrequencyHz: nyquist,
        lowHz: 0,
        highHz: 22000,
        intensity: 220,
      );
      _paintFrequencyBand(
        intensity,
        width: width,
        height: height,
        maxFrequencyHz: nyquist,
        lowHz: 53880,
        highHz: 54120,
        intensity: 255,
      );

      final cutoff = estimateEffectiveSpectralCutoffHz(
        intensity: intensity,
        width: width,
        height: height,
        maxFrequencyHz: nyquist,
      );

      expect(cutoff, isNotNull);
      expect(cutoff!, inInclusiveRange(21000, 23500));
    });

    test('ignores sparse broadband seams below the temporal P90 budget', () {
      const sourceNyquist = 24000.0;
      final intensity = _blankIntensity(width, height, value: 12);
      _paintFrequencyBand(
        intensity,
        width: width,
        height: height,
        maxFrequencyHz: sourceNyquist,
        lowHz: 0,
        highHz: 20000,
        intensity: 100,
      );
      // Model discontinuities between distributed excerpts. Their columns are
      // bright at every frequency, but occupy only six percent of the image.
      _paintFrequencyBand(
        intensity,
        width: width,
        height: height,
        maxFrequencyHz: sourceNyquist,
        lowHz: 0,
        highHz: sourceNyquist,
        intensity: 255,
        startColumn: 0,
        endColumn: 12,
      );

      final cutoff = estimateEffectiveSpectralCutoffHz(
        intensity: intensity,
        width: width,
        height: height,
        maxFrequencyHz: sourceNyquist,
      );

      expect(cutoff, isNotNull);
      expect(cutoff!, inInclusiveRange(19400, 20600));
    });

    test('rejects a low noise floor above a 15.8 kHz bandwidth edge', () {
      const cdNyquist = 22050.0;
      final intensity = _blankIntensity(width, height, value: 42);
      _paintFrequencyBand(
        intensity,
        width: width,
        height: height,
        maxFrequencyHz: cdNyquist,
        lowHz: 0,
        highHz: 15800,
        intensity: 100,
      );
      _paintFrequencyBand(
        intensity,
        width: width,
        height: height,
        maxFrequencyHz: cdNyquist,
        lowHz: 15800,
        highHz: cdNyquist,
        intensity: 85,
        startColumn: 0,
        endColumn: 10,
      );

      final cutoff = estimateEffectiveSpectralCutoffHz(
        intensity: intensity,
        width: width,
        height: height,
        maxFrequencyHz: cdNyquist,
      );

      expect(cutoff, isNotNull);
      expect(cutoff!, inInclusiveRange(15300, 16300));
    });

    test(
      'finds a 15 kHz edge below elevated noise and a persistent 18.7 kHz line',
      () {
        const cdNyquist = 22050.0;
        final intensity = _blankIntensity(width, height, value: 30);
        _paintFrequencyBand(
          intensity,
          width: width,
          height: height,
          maxFrequencyHz: cdNyquist,
          lowHz: 0,
          highHz: 15000,
          intensity: 39,
        );
        _paintFrequencyBand(
          intensity,
          width: width,
          height: height,
          maxFrequencyHz: cdNyquist,
          lowHz: 18600,
          highHz: 18800,
          intensity: 220,
        );

        final cutoff = estimateEffectiveSpectralCutoffHz(
          intensity: intensity,
          width: width,
          height: height,
          maxFrequencyHz: cdNyquist,
        );

        expect(cutoff, isNotNull);
        expect(cutoff!, inInclusiveRange(14500, 15500));
      },
    );

    test('retains a genuine broadband cutoff around 18.7 kHz', () {
      const cdNyquist = 22050.0;
      final intensity = _blankIntensity(width, height, value: 18);
      _paintFrequencyBand(
        intensity,
        width: width,
        height: height,
        maxFrequencyHz: cdNyquist,
        lowHz: 0,
        highHz: 18700,
        intensity: 100,
      );

      final cutoff = estimateEffectiveSpectralCutoffHz(
        intensity: intensity,
        width: width,
        height: height,
        maxFrequencyHz: cdNyquist,
      );

      expect(cutoff, isNotNull);
      expect(cutoff!, inInclusiveRange(18200, 19200));
    });

    test('ignores a tonal drop before a gradual 22 kHz bandwidth limit', () {
      const hiresNyquist = 48000.0;
      final intensity = _blankIntensity(width, height, value: 46);
      _paintFrequencyBand(
        intensity,
        width: width,
        height: height,
        maxFrequencyHz: hiresNyquist,
        lowHz: 0,
        highHz: 4000,
        intensity: 120,
      );
      _paintFrequencySlope(
        intensity,
        width: width,
        height: height,
        maxFrequencyHz: hiresNyquist,
        lowHz: 4000,
        highHz: 20000,
        lowIntensity: 115,
        highIntensity: 75,
      );
      _paintFrequencySlope(
        intensity,
        width: width,
        height: height,
        maxFrequencyHz: hiresNyquist,
        lowHz: 20000,
        highHz: 23500,
        lowIntensity: 75,
        highIntensity: 46,
      );

      final cutoff = estimateEffectiveSpectralCutoffHz(
        intensity: intensity,
        width: width,
        height: height,
        maxFrequencyHz: hiresNyquist,
      );

      expect(cutoff, isNotNull);
      expect(cutoff!, inInclusiveRange(20500, 22500));
    });

    test('retains genuine broadband ultrasonic content', () {
      final intensity = _blankIntensity(width, height, value: 10);
      _paintFrequencyBand(
        intensity,
        width: width,
        height: height,
        maxFrequencyHz: nyquist,
        lowHz: 0,
        highHz: 48000,
        intensity: 180,
      );

      final cutoff = estimateEffectiveSpectralCutoffHz(
        intensity: intensity,
        width: width,
        height: height,
        maxFrequencyHz: nyquist,
      );

      expect(cutoff, isNotNull);
      expect(cutoff!, inInclusiveRange(47000, 49500));
    });

    test('reports Nyquist for full-bandwidth content', () {
      final intensity = _blankIntensity(width, height, value: 180);

      final cutoff = estimateEffectiveSpectralCutoffHz(
        intensity: intensity,
        width: width,
        height: height,
        maxFrequencyHz: nyquist,
      );

      expect(cutoff, nyquist);
    });

    test(
      'reports Nyquist for full-band music with a natural spectral tilt',
      () {
        const cdNyquist = 22050.0;
        final intensity = _blankIntensity(width, height);
        _paintNaturalSpectralTilt(
          intensity,
          width: width,
          height: height,
          lowFrequencyIntensity: 140,
          nyquistIntensity: 26,
        );

        final cutoff = estimateEffectiveSpectralCutoffHz(
          intensity: intensity,
          width: width,
          height: height,
          maxFrequencyHz: cdNyquist,
        );

        expect(cutoff, cdNyquist);
      },
    );

    test('reports Nyquist for low-contrast full-band spectral tilt', () {
      const cdNyquist = 22050.0;
      final intensity = _blankIntensity(width, height);
      _paintNaturalSpectralTilt(
        intensity,
        width: width,
        height: height,
        lowFrequencyIntensity: 39,
        nyquistIntensity: 30,
      );

      final cutoff = estimateEffectiveSpectralCutoffHz(
        intensity: intensity,
        width: width,
        height: height,
        maxFrequencyHz: cdNyquist,
      );

      expect(cutoff, cdNyquist);
    });

    test('reports Nyquist for an extended gentle high-frequency rolloff', () {
      const cdNyquist = 22050.0;
      final intensity = _blankIntensity(width, height);
      const segments = <(double, double, int, int)>[
        (0, 4000, 113, 104),
        (4000, 6000, 104, 96),
        (6000, 15000, 96, 91),
        (15000, 16000, 91, 87),
        (16000, 17000, 87, 84),
        (17000, 18500, 84, 82),
        (18500, 19000, 82, 78),
        (19000, 20000, 78, 73),
        (20000, 21000, 73, 70),
        (21000, cdNyquist, 70, 69),
      ];
      for (final segment in segments) {
        _paintFrequencySlope(
          intensity,
          width: width,
          height: height,
          maxFrequencyHz: cdNyquist,
          lowHz: segment.$1,
          highHz: segment.$2,
          lowIntensity: segment.$3,
          highIntensity: segment.$4,
        );
      }

      final cutoff = estimateEffectiveSpectralCutoffHz(
        intensity: intensity,
        width: width,
        height: height,
        maxFrequencyHz: cdNyquist,
      );

      expect(cutoff, cdNyquist);
    });

    test('does not report an isolated line as a broadband cutoff', () {
      final intensity = _blankIntensity(width, height);
      _paintFrequencyBand(
        intensity,
        width: width,
        height: height,
        maxFrequencyHz: nyquist,
        lowHz: 53880,
        highHz: 54120,
        intensity: 255,
      );

      final cutoff = estimateEffectiveSpectralCutoffHz(
        intensity: intensity,
        width: width,
        height: height,
        maxFrequencyHz: nyquist,
      );

      expect(cutoff, isNull);
    });

    test('rejects invalid or incomplete images', () {
      expect(
        estimateEffectiveSpectralCutoffHz(
          intensity: Uint8List(0),
          width: 1,
          height: 1,
          maxFrequencyHz: nyquist,
        ),
        isNull,
      );
    });
  });
}

({Uint8List intensity, int width, int height, double maxFrequencyHz})
_noisySpectrum(int seed) {
  final width = [17, 83, 200, 400][seed % 4];
  final height = [31, 128, 399, 800][(seed ~/ 4) % 4];
  final maxFrequencyHz = [
    8000.0,
    22050.0,
    24000.0,
    48000.0,
    96000.0,
  ][(seed ~/ 16) % 5];
  final intensity = Uint8List(width * height);
  var random = seed + 1;
  final mode = (seed ~/ 80) % 5;
  for (var y = 0; y < height; y++) {
    final frequency = (height - y - 1) / (height - 1);
    for (var x = 0; x < width; x++) {
      random = (1664525 * random + 1013904223) & 0xffffffff;
      final noise = (random >> 24) % 13;
      final base = switch (mode) {
        0 => frequency < 0.68 ? 120 : 24,
        1 => frequency < 0.65 ? (160 - frequency * 170).round() : 24,
        2 => (140 - frequency * 110).round(),
        3 => 16 + (random >> 20) % 170,
        _ =>
          frequency < 0.35
              ? 90
              : frequency < 0.73
              ? 64
              : 35,
      };
      // Five percent broadband transients remain below the temporal P90.
      intensity[y * width + x] = x < width ~/ 20
          ? 255
          : (base + noise).clamp(0, 255);
    }
  }
  return (
    intensity: intensity,
    width: width,
    height: height,
    maxFrequencyHz: maxFrequencyHz,
  );
}

Uint8List _blankIntensity(int width, int height, {int value = 0}) {
  final intensity = Uint8List(width * height);
  if (value > 0) intensity.fillRange(0, intensity.length, value);
  return intensity;
}

void _paintFrequencyBand(
  Uint8List values, {
  required int width,
  required int height,
  required double maxFrequencyHz,
  required double lowHz,
  required double highHz,
  required int intensity,
  int startColumn = 0,
  int? endColumn,
}) {
  final columnEnd = endColumn ?? width;
  for (var y = 0; y < height; y++) {
    final frequency = (height - y - 0.5) / height * maxFrequencyHz;
    if (frequency < lowHz || frequency > highHz) continue;
    for (var x = startColumn; x < columnEnd; x++) {
      values[y * width + x] = intensity;
    }
  }
}

void _paintNaturalSpectralTilt(
  Uint8List values, {
  required int width,
  required int height,
  required int lowFrequencyIntensity,
  required int nyquistIntensity,
}) {
  final span = lowFrequencyIntensity - nyquistIntensity;
  for (var y = 0; y < height; y++) {
    final normalizedFrequency = (height - y - 0.5) / height;
    final intensity =
        (lowFrequencyIntensity -
                span * normalizedFrequency * normalizedFrequency)
            .round()
            .clamp(0, 255);
    for (var x = 0; x < width; x++) {
      values[y * width + x] = intensity;
    }
  }
}

void _paintFrequencySlope(
  Uint8List values, {
  required int width,
  required int height,
  required double maxFrequencyHz,
  required double lowHz,
  required double highHz,
  required int lowIntensity,
  required int highIntensity,
}) {
  final frequencySpan = highHz - lowHz;
  for (var y = 0; y < height; y++) {
    final frequency = (height - y - 0.5) / height * maxFrequencyHz;
    if (frequency < lowHz || frequency > highHz) continue;
    final progress = (frequency - lowHz) / frequencySpan;
    final intensity = (lowIntensity + (highIntensity - lowIntensity) * progress)
        .round()
        .clamp(0, 255);
    for (var x = 0; x < width; x++) {
      values[y * width + x] = intensity;
    }
  }
}
