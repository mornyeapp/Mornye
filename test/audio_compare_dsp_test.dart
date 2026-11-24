import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/audio_compare_dsp.dart';

/// A deterministic music-like signal: drifting tones, an envelope and a
/// little seeded noise, so no lag repeats exactly.
Float32List _music(int frames, int rate, {int channels = 1, int seed = 7}) {
  final random = math.Random(seed);
  final out = Float32List(frames * channels);
  for (var n = 0; n < frames; n++) {
    final t = n / rate;
    final envelope = 0.6 + 0.4 * math.sin(2 * math.pi * 0.7 * t);
    for (var c = 0; c < channels; c++) {
      final tone =
          0.3 * math.sin(2 * math.pi * (220 + 30 * c) * t + math.sin(t * 3)) +
          0.15 * math.sin(2 * math.pi * 659.3 * t) +
          0.08 * math.sin(2 * math.pi * 1530 * t * (1 + 0.01 * t));
      out[n * channels + c] =
          envelope * tone + 0.05 * (random.nextDouble() * 2 - 1);
    }
  }
  return out;
}

/// The other file of a test: [source] starting [lag] frames later (silence
/// before it) or, for a negative lag, with its first frames cut.
Float32List _shift(Float32List source, int lag, {int channels = 1}) {
  final frames = source.length ~/ channels;
  final out = Float32List((frames + lag) * channels);
  for (var n = 0; n < frames; n++) {
    final target = n + lag;
    if (target < 0 || target >= frames + lag) continue;
    for (var c = 0; c < channels; c++) {
      out[target * channels + c] = source[n * channels + c];
    }
  }
  return out;
}

/// Crude decimation by an integer factor, standing in for FFmpeg's
/// resampler in the wide search.
Float32List _decimate(Float32List mono, int factor) {
  final out = Float32List(mono.length ~/ factor);
  for (var i = 0; i < out.length; i++) {
    var sum = 0.0;
    for (var k = 0; k < factor; k++) {
      sum += mono[i * factor + k];
    }
    out[i] = sum / factor;
  }
  return out;
}

/// Zero-phase brick-wall low-pass through the FFT; the length must be a
/// power of two.
Float32List _lowPass(Float32List mono, int rate, double cutoffHz) {
  final re = Float64List.fromList(mono);
  final im = Float64List(mono.length);
  audioCompareFft(re, im);
  final n = mono.length;
  for (var k = 0; k < n; k++) {
    final bin = k <= n ~/ 2 ? k : n - k;
    if (bin * rate / n > cutoffHz) {
      re[k] = 0;
      im[k] = 0;
    }
  }
  audioCompareFft(re, im, inverse: true);
  return Float32List.fromList(re);
}

/// Runs the same two-step alignment as the engine on in-memory signals at
/// 48 kHz (the coarse step decimates by 12 to 4 kHz).
({int lag, double correlation, double gain}) _align(
  Float32List reference,
  Float32List other, {
  int channels = 1,
}) {
  const rate = 48000;
  const factor = rate ~/ audioCompareCoarseRate;
  final referenceMono = audioCompareMixToMono(reference, channels);
  final otherMono = audioCompareMixToMono(other, channels);
  final coarseReference = _decimate(referenceMono, factor);
  final coarseOther = _decimate(otherMono, factor);
  // Like the engine, scan the reference after the search margin so an other
  // file that starts earlier still holds the matched stretch.
  final scanStart = (audioCompareSearchSeconds * audioCompareCoarseRate)
      .round();
  final coarse = audioCompareCoarseAlign(
    AudioCompareCoarseInput(
      reference: Float32List.sublistView(coarseReference, scanStart),
      referenceStart: scanStart,
      other: coarseOther,
      otherStart: 0,
    ),
  );
  const radius = 4 * factor + 64;
  const fineFrames = 3 * rate;
  final referenceStart = (coarse.fineCenter * factor - fineFrames ~/ 2)
      .clamp(0, referenceMono.length - fineFrames)
      .toInt();
  final fine = audioCompareFineAlign(
    AudioCompareFineInput(
      reference: Float32List.sublistView(
        reference,
        referenceStart * channels,
        (referenceStart + fineFrames) * channels,
      ),
      referenceStart: referenceStart,
      candidates: [
        for (final candidate in coarse.candidates)
          () {
            final predicted = candidate.lag * factor;
            final otherStart = math.max(0, referenceStart + predicted - radius);
            final otherEnd = math.min(
              otherMono.length,
              referenceStart + fineFrames + predicted + radius,
            );
            return AudioCompareFineCandidate(
              other: Float32List.sublistView(
                other,
                otherStart * channels,
                math.max(otherStart, otherEnd) * channels,
              ),
              otherStart: otherStart,
              predictedLag: predicted,
            );
          }(),
      ],
      channels: channels,
      sampleRate: rate,
      radius: radius,
    ),
  );
  return (lag: fine.lag, correlation: fine.correlation, gain: fine.gain);
}

void main() {
  group('alignment', () {
    final reference = _music(48000 * 12, 48000);

    // MP3 decoders add about 576 to 1105 samples, AAC priming is 2112; the
    // larger values cover files that start up to 2.5 s apart.
    for (final lag in [
      0,
      1,
      576,
      1105,
      2112,
      12345,
      120000,
      -1,
      -576,
      -1105,
      -2112,
      -72000,
    ]) {
      test('recovers an offset of $lag samples exactly', () {
        final result = _align(reference, _shift(reference, lag));
        expect(result.lag, lag);
        expect(result.correlation, greaterThan(0.999));
        expect(result.gain, closeTo(1, 1e-6));
      });
    }

    test('recovers the offset and gain of a stereo copy', () {
      final stereo = _music(48000 * 10, 48000, channels: 2);
      final quieter = _shift(stereo, 1105, channels: 2);
      for (var i = 0; i < quieter.length; i++) {
        quieter[i] *= 0.7;
      }
      final result = _align(stereo, quieter, channels: 2);
      expect(result.lag, 1105);
      // reference = gain * other, so the gain undoes the 0.7.
      expect(result.gain, closeTo(1 / 0.7, 1e-4));
      expect(20 * math.log(result.gain) / math.ln10, closeTo(3.098, 0.001));
    });

    test('reports inverted polarity through the gain sign', () {
      final inverted = Float32List.fromList([for (final v in reference) -v]);
      final result = _align(reference, inverted);
      expect(result.lag, 0);
      expect(result.correlation, lessThan(-0.999));
      expect(result.gain, closeTo(-1, 1e-6));
    });

    test('the FFT and direct correlations agree', () {
      final a = Float32List.sublistView(reference, 1000, 1400);
      final b = Float32List.sublistView(reference, 900, 2100);
      final direct = audioCompareCrossCorrelation(a, b, useFft: false);
      final fft = audioCompareCrossCorrelation(a, b, useFft: true);
      expect(fft.length, direct.length);
      for (var k = 0; k < direct.length; k++) {
        expect(fft[k], closeTo(direct[k], 1e-6));
      }
      expect(audioCompareFindLag(a, b, useFft: true).lag, 100);
      expect(audioCompareFindLag(a, b, useFft: false).lag, 100);
    });

    test('unrelated signals give a weak correlation peak', () {
      final unrelated = _music(48000 * 12, 48000, seed: 99);
      final noise = Float32List.fromList([
        for (final (i, v) in unrelated.indexed)
          v * math.sin(i * 0.37) + math.sin(i * 0.0021),
      ]);
      final result = _align(reference, noise);
      expect(result.correlation.abs(), lessThan(audioCompareMinCorrelation));
    });
  });

  group('residual', () {
    const rate = 48000;

    test('identical files cancel to the floor', () {
      final stereo = _music(rate * 4, rate, channels: 2);
      final windows = audioCompareMeasureWindows(
        reference: stereo,
        other: Float32List.fromList(stereo),
        channels: 2,
        sampleRate: rate,
        offsetFrames: 0,
        gain: 1,
        windowFrames: audioCompareWindowFrames(rate * 4, rate),
      );
      expect(
        audioCompareSeries(windows, AudioCompareChannel.combined),
        everyElement(audioCompareFloorDb),
      );
      expect(audioCompareOverallDb(windows), audioCompareFloorDb);
      expect(
        audioCompareLevelFor(audioCompareOverallDb(windows)),
        AudioCompareLevel.identical,
      );
      expect(audioCompareBandFor(windows), AudioCompareBand.none);
      expect(audioComparePeakFor(windows), isNull);
    });

    test('a shifted copy cancels once the offset is applied', () {
      final mono = _music(rate * 4, rate);
      final windows = audioCompareMeasureWindows(
        reference: mono,
        other: _shift(mono, 2112),
        channels: 1,
        sampleRate: rate,
        offsetFrames: 2112,
        gain: 1,
        windowFrames: 4800,
      );
      expect(audioCompareOverallDb(windows), audioCompareFloorDb);
    });

    test('a low-passed copy differs only where there are highs', () {
      const frames = 1 << 18; // about 5.5 s
      final random = math.Random(3);
      final mono = Float32List(frames);
      for (var n = 0; n < frames; n++) {
        final t = n / rate;
        var value =
            0.3 * math.sin(2 * math.pi * 220 * t) +
            0.2 * math.sin(2 * math.pi * 523.25 * t) +
            0.1 * math.sin(2 * math.pi * 1760 * t);
        // Highs only in the middle third, like a dense chorus.
        if (n >= frames ~/ 3 && n < frames * 2 ~/ 3) {
          value +=
              0.1 * math.sin(2 * math.pi * 12000 * t) +
              0.05 * (random.nextDouble() * 2 - 1);
        }
        mono[n] = value;
      }
      final lowPassed = _lowPass(mono, rate, 8000);
      final gain = audioCompareLeastSquaresGain(mono, lowPassed);
      final windows = audioCompareMeasureWindows(
        reference: mono,
        other: lowPassed,
        channels: 1,
        sampleRate: rate,
        offsetFrames: 0,
        gain: gain,
        windowFrames: 4096,
      );
      final series = audioCompareSeries(windows, AudioCompareChannel.combined);
      double median(Iterable<double> values) {
        final sorted = values.toList()..sort();
        return sorted[sorted.length ~/ 2];
      }

      final third = series.length ~/ 3;
      final middle = median(series.sublist(third + 2, 2 * third - 2));
      final outside = median([
        ...series.sublist(2, third - 2),
        ...series.sublist(2 * third + 2, series.length - 2),
      ]);
      expect(middle, greaterThan(-25));
      expect(middle - outside, greaterThan(40));
      expect(audioCompareBandFor(windows), AudioCompareBand.high);
      final peak = audioComparePeakFor(windows)!;
      expect(peak.seconds, greaterThan(frames / 3 / rate - 0.1));
      expect(peak.seconds, lessThan(frames * 2 / 3 / rate));
    });

    test('unrelated signals stay near 0 dB and raise the notice', () {
      final a = _music(rate * 4, rate);
      final b = Float32List.fromList([
        for (final (i, v) in _music(rate * 4, rate, seed: 42).indexed)
          v * math.cos(i * 0.011),
      ]);
      final gain = audioCompareLeastSquaresGain(a, b);
      final windows = audioCompareMeasureWindows(
        reference: a,
        other: b,
        channels: 1,
        sampleRate: rate,
        offsetFrames: 0,
        gain: gain,
        windowFrames: 4800,
      );
      final overall = audioCompareOverallDb(windows);
      expect(overall, greaterThan(audioCompareNotSameSourceDb));
      final notices = audioCompareNoticesFor(
        correlation: 0.05,
        overallDb: overall,
        medianDb: audioCompareMedianDb(windows),
        referenceSeconds: 4,
        otherSeconds: 4,
        offsetSeconds: 0,
      );
      expect(
        notices,
        containsAll([
          AudioCompareNotice.weakAlignment,
          AudioCompareNotice.residualHigh,
        ]),
      );
    });
  });

  group('windows and levels', () {
    test('a song becomes a few hundred to 2000 points', () {
      for (final seconds in [3, 30, 200, 600, 3600]) {
        for (final rate in [44100, 48000, 96000]) {
          final total = seconds * rate;
          final window = audioCompareWindowFrames(total, rate);
          final points = (total / window).ceil();
          expect(points, inInclusiveRange(300, 2000), reason: '$seconds s');
        }
      }
      expect(audioCompareWindowFrames(0, 48000), 240);
    });

    test('dB math', () {
      expect(audioCompareDbToPower(-20), closeTo(0.01, 1e-12));
      expect(audioCompareDbToPower(double.negativeInfinity), 0);
      expect(audioCompareDbToPower(double.nan), 0);
      expect(audioComparePowerDb(0.01), closeTo(-20, 1e-9));
      expect(audioComparePowerDb(0), audioCompareFloorDb);
      expect(audioCompareRelativeDb(0.001, 0.1), closeTo(-20, 1e-9));
      expect(audioCompareRelativeDb(0, 0.1), audioCompareFloorDb);
      expect(audioCompareRelativeDb(1e-20, 0.1), audioCompareFloorDb);
      expect(audioCompareRelativeDb(1000, 0.1), audioCompareCeilingDb);
      // Silence in both stays on the floor instead of magnifying noise.
      expect(audioCompareRelativeDb(1e-10, 1e-12), audioCompareFloorDb);
      // A residual where the reference is silent is measured against the
      // silence level.
      expect(audioCompareRelativeDb(1e-6, 0), closeTo(20, 1e-9));
    });

    AudioCompareWindow window(
      double start,
      int frames,
      List<double> residual,
      List<double> reference,
    ) => AudioCompareWindow(
      startSeconds: start,
      frames: frames,
      residual: Float64List.fromList(residual),
      reference: Float64List.fromList(reference),
      residualHigh: Float64List(residual.length),
      referenceHigh: Float64List(residual.length),
    );

    test('overall level weights windows by length and channel', () {
      final windows = [
        window(0, 300, [0.001, 0.0], [0.1, 0.1]),
        window(1, 100, [0.0, 0.0], [0.1, 0.1]),
      ];
      // 0.001 * 300 / 2 channels over 0.1 * 400.
      expect(audioCompareOverallDb(windows), closeTo(-24.26, 0.01));
      expect(
        audioCompareOverallDb(windows, AudioCompareChannel.left),
        closeTo(-21.25, 0.01),
      );
      expect(
        audioCompareOverallDb(windows, AudioCompareChannel.right),
        audioCompareFloorDb,
      );
      expect(
        audioCompareSeries(windows, AudioCompareChannel.left).first,
        closeTo(-20, 1e-9),
      );
      expect(audioComparePeakFor(windows)!.seconds, 0);
    });

    test('notices for drift and different lengths', () {
      Set<AudioCompareNotice> notices({
        int? drift,
        double other = 200,
        double offset = 0,
      }) => audioCompareNoticesFor(
        correlation: 0.99,
        overallDb: -30,
        medianDb: -32,
        driftCoarse: drift,
        referenceSeconds: 200,
        otherSeconds: other,
        offsetSeconds: offset,
      );
      expect(notices(), isEmpty);
      expect(notices(drift: 2), isEmpty);
      expect(notices(drift: -3), {AudioCompareNotice.drift});
      // An MP3 that starts 0.05 s later and is that much longer is fine.
      expect(notices(other: 200.05, offset: 0.05), isEmpty);
      expect(notices(other: 195), {AudioCompareNotice.durationMismatch});
      expect(notices(other: 204, offset: 0.5), {
        AudioCompareNotice.durationMismatch,
      });
    });

    test('level reading boundaries', () {
      expect(audioCompareLevelFor(-120), AudioCompareLevel.identical);
      expect(audioCompareLevelFor(-90), AudioCompareLevel.nearlyIdentical);
      expect(audioCompareLevelFor(-45), AudioCompareLevel.mostlyIdentical);
      expect(audioCompareLevelFor(-31), AudioCompareLevel.moderate);
      expect(audioCompareLevelFor(-12), AudioCompareLevel.large);
    });
  });
}
