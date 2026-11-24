// Pure signal math for the "Compare with another file" null test. FFmpeg
// decodes and subtracts whole songs; this file aligns short excerpts, picks
// the gain, and turns per-window levels into the summary the sheet shows.
import 'dart:math' as math;
import 'dart:typed_data';

/// Sample rate of the decimated excerpts used by the wide alignment search.
/// The band below 2 kHz survives every lossy encoder, so it lines up a lossy
/// copy as reliably as the full band while keeping the search cheap.
const int audioCompareCoarseRate = 4000;

/// How far the other file may start earlier or later than the reference.
const double audioCompareSearchSeconds = 3.0;

/// Length of the reference stretch decoded for the wide search; the loudest
/// [audioCompareMatchSeconds] of it are correlated.
const double audioCompareScanSeconds = 30.0;
const double audioCompareMatchSeconds = 10.0;

/// Full-rate window used to refine the offset and to estimate the gain.
const double audioCompareFineSeconds = 3.0;

/// The comparison runs at the reference's sample rate up to this rate.
const int audioCompareMaxSampleRate = 96000;

/// About this many points describe the whole song on the timeline.
const int audioCompareTargetPoints = 1000;

/// Shortest window for very short files, in seconds.
const double audioCompareMinWindowSeconds = 0.005;

/// Lowest value on the timeline: the files cancel completely.
const double audioCompareFloorDb = -120;

/// Highest value kept for a window (the residual can exceed the reference
/// when the files are unrelated).
const double audioCompareCeilingDb = 20;

/// A reference window quieter than this is treated as silence: its relative
/// level would only magnify noise, so it is measured against this level and
/// left out of the median and the peak.
const double audioCompareSilenceDb = -80;

// Thresholds below were chosen from synthetic experiments: a 40 s tone and
// pink-noise mix encoded with FFmpeg 9 (LAME MP3 at 32/64/128 kbps, the
// native AAC encoder at 128 kbps, an 8 kHz low-pass, a treble cut, a bass
// boost plus compression as a "remaster", a 0.01% speed change as drift, and
// unrelated white noise). Measured on 5 s excerpts:
//
//   case                   correlation   residual
//   AAC 128 kbps           0.9999        -37 dB
//   MP3 128 kbps           0.9996        -31 dB
//   MP3 32 kbps            0.996         -21 dB
//   8 kHz low-pass         0.998         -24 dB
//   remaster (EQ + comp.)  0.991         -17 dB
//   0.01% drift            0.879         -6 dB
//   unrelated noise        0.006         0 dB
//
// The gaps between same-source copies and the rest are wide, so the
// thresholds sit in the middle of them rather than at the edges. Whole-song
// runs of the engine on a 90 s mix (test/audio_compare_engine_test.dart)
// agree: lossy copies -32 to -38 dB overall at correlation 0.999 or more, a
// 48 kHz resample -53 dB, a 3 dB quieter 24-bit copy -99 dB, the drifting
// copy +2.5 dB at 0.92 with 16 ms of drift, unrelated noise 0 dB at 0.01.

/// Below this normalized correlation peak the files did not line up clearly.
const double audioCompareMinCorrelation = 0.5;

/// A whole-song or median residual above this level means the files are not
/// the same source (or are misaligned), so the null test is not meaningful.
const double audioCompareNotSameSourceDb = -10;

/// Lengths that differ by more than this after the offset suggest an edit.
const double audioCompareDurationToleranceSeconds = 3;

/// Offsets measured near the start and near the end of the song that differ
/// by more than this many coarse samples (0.5 ms) mean the timing drifts.
const int audioCompareDriftToleranceCoarse = 2;

/// Boundary between the low and high bands of the plain-language reading.
const double audioCompareBandSplitHz = 8000;

/// One band's relative residual this much above the other's makes the
/// differences "concentrated" there; within [audioCompareBandEvenDb] they
/// cover the whole spectrum.
const double audioCompareBandConcentrationDb = 10;
const double audioCompareBandEvenDb = 3;

/// Window length, in frames, that gives about [audioCompareTargetPoints]
/// points for [totalFrames].
int audioCompareWindowFrames(int totalFrames, int sampleRate) {
  final minimum = math.max(
    1,
    (sampleRate * audioCompareMinWindowSeconds).round(),
  );
  if (totalFrames <= 0) return minimum;
  return math.max(minimum, (totalFrames / audioCompareTargetPoints).ceil());
}

/// Power (mean square) to dB, with [audioCompareFloorDb] for silence.
double audioComparePowerDb(double power) {
  if (!power.isFinite || power <= 0) return audioCompareFloorDb;
  return math.max(audioCompareFloorDb, 10 * math.log(power) / math.ln10);
}

/// Mean square from an FFmpeg `RMS_level` value in dBFS.
double audioCompareDbToPower(double db) {
  if (db.isNaN || db == double.negativeInfinity) return 0;
  if (db == double.infinity) return double.maxFinite;
  return math.pow(10, db / 10).toDouble();
}

final double _silencePower = audioCompareDbToPower(audioCompareSilenceDb);

/// The residual of one window relative to the reference, in dB.
double audioCompareRelativeDb(double residual, double reference) {
  if (!residual.isFinite || residual <= 0) return audioCompareFloorDb;
  if (reference < _silencePower && residual < _silencePower) {
    return audioCompareFloorDb;
  }
  final db =
      10 * math.log(residual / math.max(reference, _silencePower)) / math.ln10;
  return db.clamp(audioCompareFloorDb, audioCompareCeilingDb).toDouble();
}

enum AudioCompareChannel { combined, left, right }

/// Levels of one timeline window, as mean squares per channel.
class AudioCompareWindow {
  const AudioCompareWindow({
    required this.startSeconds,
    required this.frames,
    required this.residual,
    required this.reference,
    required this.residualHigh,
    required this.referenceHigh,
  });

  final double startSeconds;
  final int frames;
  final Float64List residual;
  final Float64List reference;

  /// The same levels above [audioCompareBandSplitHz].
  final Float64List residualHigh;
  final Float64List referenceHigh;

  static double _pick(Float64List values, AudioCompareChannel channel) {
    if (values.isEmpty) return 0;
    switch (channel) {
      case AudioCompareChannel.left:
        return values[0];
      case AudioCompareChannel.right:
        return values.length > 1 ? values[1] : values[0];
      case AudioCompareChannel.combined:
        var sum = 0.0;
        for (final value in values) {
          sum += value;
        }
        return sum / values.length;
    }
  }

  double residualPower(AudioCompareChannel channel) => _pick(residual, channel);
  double referencePower(AudioCompareChannel channel) =>
      _pick(reference, channel);

  double relativeDb(AudioCompareChannel channel) =>
      audioCompareRelativeDb(residualPower(channel), referencePower(channel));

  bool isSilent(AudioCompareChannel channel) =>
      referencePower(channel) < _silencePower;
}

/// The timeline values of [windows] for [channel], in dB.
List<double> audioCompareSeries(
  List<AudioCompareWindow> windows,
  AudioCompareChannel channel,
) => [for (final window in windows) window.relativeDb(channel)];

/// The whole-song residual relative to the reference, in dB.
double audioCompareOverallDb(
  List<AudioCompareWindow> windows, [
  AudioCompareChannel channel = AudioCompareChannel.combined,
]) {
  var residual = 0.0;
  var reference = 0.0;
  for (final window in windows) {
    residual += window.residualPower(channel) * window.frames;
    reference += window.referencePower(channel) * window.frames;
  }
  if (residual <= 0) return audioCompareFloorDb;
  if (reference <= 0) return audioCompareCeilingDb;
  return (10 * math.log(residual / reference) / math.ln10)
      .clamp(audioCompareFloorDb, audioCompareCeilingDb)
      .toDouble();
}

// Alignment

class AudioCompareLagMatch {
  const AudioCompareLagMatch(this.lag, this.correlation);

  /// Index in the searched excerpt where the reference excerpt starts.
  final int lag;

  /// Normalized correlation at [lag], -1 to 1; negative for inverted
  /// polarity.
  final double correlation;
}

/// In-place radix-2 FFT of `re + i*im`; the length must be a power of two.
void audioCompareFft(Float64List re, Float64List im, {bool inverse = false}) {
  final n = re.length;
  if (n <= 1) return;
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      final ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }
  // One twiddle table for every stage keeps rounding error flat.
  final half = n >> 1;
  final cosTable = Float64List(half);
  final sinTable = Float64List(half);
  final sign = inverse ? 1.0 : -1.0;
  for (var k = 0; k < half; k++) {
    final angle = 2 * math.pi * k / n;
    cosTable[k] = math.cos(angle);
    sinTable[k] = sign * math.sin(angle);
  }
  for (var size = 2; size <= n; size <<= 1) {
    final halfSize = size >> 1;
    final step = n ~/ size;
    for (var start = 0; start < n; start += size) {
      for (var k = 0; k < halfSize; k++) {
        final wr = cosTable[k * step];
        final wi = sinTable[k * step];
        final a = start + k;
        final b = a + halfSize;
        final xr = re[b] * wr - im[b] * wi;
        final xi = re[b] * wi + im[b] * wr;
        re[b] = re[a] - xr;
        im[b] = im[a] - xi;
        re[a] += xr;
        im[a] += xi;
      }
    }
  }
  if (inverse) {
    final scale = 1 / n;
    for (var i = 0; i < n; i++) {
      re[i] *= scale;
      im[i] *= scale;
    }
  }
}

/// `c[k] = sum(a[n] * b[n + k])` for every k with `a` inside `b`.
Float64List audioCompareCrossCorrelation(
  Float32List a,
  Float32List b, {
  bool? useFft,
}) {
  final lags = b.length - a.length + 1;
  if (lags <= 0 || a.isEmpty) return Float64List(0);
  final fft = useFft ?? a.length.toDouble() * lags > 2e7;
  final result = Float64List(lags);
  if (!fft) {
    for (var k = 0; k < lags; k++) {
      var sum = 0.0;
      for (var n = 0; n < a.length; n++) {
        sum += a[n] * b[n + k];
      }
      result[k] = sum;
    }
    return result;
  }
  // Circular correlation is exact for these lags once the size covers b.
  var size = 1;
  while (size < b.length) {
    size <<= 1;
  }
  final aRe = Float64List(size)..setRange(0, a.length, a);
  final aIm = Float64List(size);
  final bRe = Float64List(size)..setRange(0, b.length, b);
  final bIm = Float64List(size);
  audioCompareFft(aRe, aIm);
  audioCompareFft(bRe, bIm);
  for (var i = 0; i < size; i++) {
    // conj(A) * B
    final re = aRe[i] * bRe[i] + aIm[i] * bIm[i];
    final im = aRe[i] * bIm[i] - aIm[i] * bRe[i];
    bRe[i] = re;
    bIm[i] = im;
  }
  audioCompareFft(bRe, bIm, inverse: true);
  result.setRange(0, lags, bRe);
  return result;
}

/// Finds where [reference] best matches inside [searched], by normalized
/// cross-correlation. Polarity is ignored for the search and reported in
/// the sign of the correlation.
AudioCompareLagMatch audioCompareFindLag(
  Float32List reference,
  Float32List searched, {
  bool? useFft,
}) {
  final candidates = audioCompareLagCandidates(
    reference,
    searched,
    count: 1,
    useFft: useFft,
  );
  return candidates.isEmpty
      ? const AudioCompareLagMatch(0, 0)
      : candidates.first;
}

/// The [count] strongest separate correlation peaks, strongest first, at
/// least [separation] lags apart. Music that nearly repeats (a held chord,
/// a loop) has several peaks of almost the same height; the full-rate step
/// decides between them.
List<AudioCompareLagMatch> audioCompareLagCandidates(
  Float32List reference,
  Float32List searched, {
  int count = 5,
  int separation = 8,
  bool? useFft,
}) {
  final lags = searched.length - reference.length + 1;
  if (reference.isEmpty || lags <= 0) return const [];
  var referenceEnergy = 0.0;
  for (final value in reference) {
    referenceEnergy += value * value;
  }
  if (referenceEnergy <= 0) return const [];
  final correlation = audioCompareCrossCorrelation(
    reference,
    searched,
    useFft: useFft,
  );
  final energy = Float64List(searched.length + 1);
  for (var i = 0; i < searched.length; i++) {
    energy[i + 1] = energy[i] + searched[i] * searched[i];
  }
  final normalized = Float64List(lags);
  for (var k = 0; k < lags; k++) {
    final searchedEnergy = energy[k + reference.length] - energy[k];
    // Running sums can leave a tiny residue over digital silence.
    if (searchedEnergy <= referenceEnergy * 1e-12) continue;
    normalized[k] =
        (correlation[k] / math.sqrt(referenceEnergy * searchedEnergy))
            .clamp(-1.0, 1.0)
            .toDouble();
  }
  final peaks = <int>[];
  for (var k = 0; k < lags; k++) {
    final value = normalized[k].abs();
    if (value == 0) continue;
    if (k > 0 && normalized[k - 1].abs() > value) continue;
    if (k < lags - 1 && normalized[k + 1].abs() > value) continue;
    peaks.add(k);
  }
  peaks.sort((a, b) => normalized[b].abs().compareTo(normalized[a].abs()));
  // Rank the leading peaks by their height between samples: at a low rate
  // the true lag usually falls between two samples, and a near-repeat that
  // happens to land on a sample would otherwise outrank it.
  final ranked = peaks.take(math.max(count * 8, 32)).toList();
  final heights = {
    for (final k in ranked) k: _interpolatedPeakHeight(normalized, k),
  };
  ranked.sort((a, b) => heights[b]!.compareTo(heights[a]!));
  peaks
    ..removeRange(0, ranked.length)
    ..insertAll(0, ranked);
  final chosen = <AudioCompareLagMatch>[];
  for (final k in peaks) {
    if (chosen.length >= count) break;
    if (chosen.any((match) => (match.lag - k).abs() < separation)) continue;
    chosen.add(AudioCompareLagMatch(k, normalized[k]));
  }
  return chosen;
}

/// The largest absolute value of a band-limited [values] near index [k],
/// found by windowed-sinc interpolation at tenth-sample steps.
double _interpolatedPeakHeight(Float64List values, int k) {
  const taps = 16;
  var best = values[k].abs();
  for (var step = -5; step <= 5; step++) {
    if (step == 0) continue;
    final position = step / 10;
    var sum = 0.0;
    for (var j = -taps; j <= taps; j++) {
      final index = k + j;
      if (index < 0 || index >= values.length) continue;
      final x = position - j;
      final window = 0.5 * (1 + math.cos(math.pi * x / (taps + 1)));
      final sinc = math.sin(math.pi * x) / (math.pi * x);
      sum += values[index] * sinc * window;
    }
    best = math.max(best, sum.abs());
  }
  return math.min(best, 1.0);
}

/// Start of the loudest [length]-sample stretch of [samples], tried every
/// [step] samples.
int audioCompareLoudestStart(Float32List samples, int length, int step) {
  if (samples.length <= length) return 0;
  final energy = Float64List(samples.length + 1);
  for (var i = 0; i < samples.length; i++) {
    energy[i + 1] = energy[i] + samples[i] * samples[i];
  }
  var best = 0;
  var bestEnergy = -1.0;
  for (var start = 0; start + length <= samples.length; start += step) {
    final value = energy[start + length] - energy[start];
    if (value > bestEnergy) {
      bestEnergy = value;
      best = start;
    }
  }
  return best;
}

Float32List audioCompareMixToMono(Float32List interleaved, int channels) {
  if (channels <= 1) return interleaved;
  final frames = interleaved.length ~/ channels;
  final mono = Float32List(frames);
  for (var frame = 0; frame < frames; frame++) {
    var sum = 0.0;
    for (var channel = 0; channel < channels; channel++) {
      sum += interleaved[frame * channels + channel];
    }
    mono[frame] = sum / channels;
  }
  return mono;
}

/// The single gain `g` that minimizes `sum((reference - g * other)^2)`.
double audioCompareLeastSquaresGain(Float32List reference, Float32List other) {
  final length = math.min(reference.length, other.length);
  var cross = 0.0;
  var otherEnergy = 0.0;
  for (var i = 0; i < length; i++) {
    cross += reference[i] * other[i];
    otherEnergy += other[i] * other[i];
  }
  if (otherEnergy <= 0) return 1;
  return cross / otherEnergy;
}

/// Inputs of the wide search, all at [audioCompareCoarseRate] in mono.
class AudioCompareCoarseInput {
  const AudioCompareCoarseInput({
    required this.reference,
    required this.referenceStart,
    required this.other,
    required this.otherStart,
  });

  /// Reference scan excerpt and its first sample's index in the song.
  final Float32List reference;
  final int referenceStart;

  /// Other file's excerpt, covering the scan plus the search margin.
  final Float32List other;
  final int otherStart;
}

class AudioCompareCoarseMatch {
  const AudioCompareCoarseMatch({
    required this.candidates,
    required this.fineCenter,
  });

  /// Lags (other-file index minus reference index of the same sound, in
  /// coarse samples) of the strongest correlation peaks, strongest first.
  final List<AudioCompareLagMatch> candidates;

  int get lag => candidates.isEmpty ? 0 : candidates.first.lag;
  double get correlation =>
      candidates.isEmpty ? 0 : candidates.first.correlation;

  /// The candidate lag nearest to [lag] among the peaks almost as strong as
  /// the best one, so a near-repeat does not pass for timing drift.
  int lagNearest(int lag) {
    final strongest = correlation.abs();
    var best = this.lag;
    for (final candidate in candidates) {
      if (candidate.correlation.abs() < strongest - 0.02) continue;
      if ((candidate.lag - lag).abs() < (best - lag).abs()) {
        best = candidate.lag;
      }
    }
    return best;
  }

  /// Reference index (coarse) at the middle of the loudest second of the
  /// matched stretch, where the full-rate refinement looks.
  final int fineCenter;
}

/// Correlates the loudest [audioCompareMatchSeconds] of the reference scan
/// against the other excerpt, within [audioCompareSearchSeconds] each way.
AudioCompareCoarseMatch audioCompareCoarseAlign(AudioCompareCoarseInput input) {
  const rate = audioCompareCoarseRate;
  final radius = (audioCompareSearchSeconds * rate).round();
  // Keep the matched stretch where the other excerpt covers the whole search
  // range around it; a file that ends one sample early must not hide the
  // true lag. Very short excerpts fall back to the whole scan.
  var regionStart = 0;
  var regionEnd = input.reference.length;
  final coveredStart = input.otherStart + radius - input.referenceStart;
  final coveredEnd =
      input.otherStart + input.other.length - radius - input.referenceStart;
  if (coveredEnd - coveredStart >= 2 * rate) {
    regionStart = coveredStart.clamp(0, regionEnd);
    regionEnd = coveredEnd.clamp(regionStart, regionEnd);
  }
  final region = Float32List.sublistView(
    input.reference,
    regionStart,
    regionEnd,
  );
  final matchLength = math.min(
    region.length,
    (audioCompareMatchSeconds * rate).round(),
  );
  final start =
      regionStart + audioCompareLoudestStart(region, matchLength, rate ~/ 4);
  final matched = Float32List.sublistView(
    input.reference,
    start,
    start + matchLength,
  );
  final referenceIndex = input.referenceStart + start;
  final secondLength = math.min(rate, matchLength);
  final loudSecond = audioCompareLoudestStart(
    matched,
    secondLength,
    rate ~/ 10,
  );
  final fineCenter = referenceIndex + loudSecond + secondLength ~/ 2;
  final from = (referenceIndex - radius - input.otherStart).clamp(
    0,
    input.other.length,
  );
  final to = (referenceIndex + matchLength + radius - input.otherStart).clamp(
    from,
    input.other.length,
  );
  if (matchLength == 0 || to - from < matchLength) {
    return AudioCompareCoarseMatch(
      candidates: const [],
      fineCenter: fineCenter,
    );
  }
  final matches = audioCompareLagCandidates(
    matched,
    Float32List.sublistView(input.other, from, to),
    count: 8,
  );
  final strongest = matches.fold(
    0.0,
    (best, match) => math.max(best, match.correlation.abs()),
  );
  return AudioCompareCoarseMatch(
    candidates: [
      for (final match in matches)
        // Peaks far below the best one are not worth a full-rate look.
        if (match.correlation.abs() >= strongest * 0.9)
          AudioCompareLagMatch(
            input.otherStart + from + match.lag - referenceIndex,
            match.correlation,
          ),
    ],
    fineCenter: fineCenter,
  );
}

class AudioCompareFineCandidate {
  const AudioCompareFineCandidate({
    required this.other,
    required this.otherStart,
    required this.predictedLag,
  });

  /// Interleaved other-file excerpt and its first frame's index.
  final Float32List other;
  final int otherStart;

  /// A coarse lag scaled to the comparison rate.
  final int predictedLag;
}

/// Inputs of the full-rate refinement: interleaved excerpts at the
/// comparison rate.
class AudioCompareFineInput {
  const AudioCompareFineInput({
    required this.reference,
    required this.referenceStart,
    required this.candidates,
    required this.channels,
    required this.sampleRate,
    required this.radius,
  });

  final Float32List reference;
  final int referenceStart;
  final List<AudioCompareFineCandidate> candidates;
  final int channels;
  final int sampleRate;

  /// How far the refinement may move from each predicted lag.
  final int radius;
}

class AudioCompareFineMatch {
  const AudioCompareFineMatch({
    required this.lag,
    required this.correlation,
    required this.gain,
    required this.excerptResidualDb,
  });

  /// Other-file frame minus reference frame of the same sound.
  final int lag;
  final double correlation;
  final double gain;

  /// Residual of the aligned, gain-matched excerpt relative to the
  /// reference.
  final double excerptResidualDb;
}

/// Refines the offset on the loudest second of the reference window, then
/// fits the gain on the whole window.
AudioCompareFineMatch audioCompareFineAlign(AudioCompareFineInput input) {
  final channels = math.max(1, input.channels);
  final referenceMono = audioCompareMixToMono(input.reference, channels);
  final frames = referenceMono.length;
  final length = math.min(frames, input.sampleRate);
  final start = audioCompareLoudestStart(
    referenceMono,
    length,
    math.max(1, length ~/ 10),
  );
  final loudest = Float32List.sublistView(referenceMono, start, start + length);
  var lag = input.candidates.isEmpty ? 0 : input.candidates.first.predictedLag;
  var correlation = 0.0;
  AudioCompareFineCandidate? chosen = input.candidates.isEmpty
      ? null
      : input.candidates.first;
  for (final candidate in input.candidates) {
    final otherMono = audioCompareMixToMono(candidate.other, channels);
    // Other-file index of reference index `start` at the predicted lag.
    final expected =
        input.referenceStart +
        start +
        candidate.predictedLag -
        candidate.otherStart;
    final from = (expected - input.radius).clamp(0, otherMono.length);
    final to = (expected + input.radius + length).clamp(from, otherMono.length);
    if (length == 0 || to - from < length) continue;
    final match = audioCompareFindLag(
      loudest,
      Float32List.sublistView(otherMono, from, to),
    );
    if (match.correlation.abs() > correlation.abs()) {
      lag =
          candidate.otherStart +
          from +
          match.lag -
          (input.referenceStart + start);
      correlation = match.correlation;
      chosen = candidate;
    }
  }
  final reference = input.reference;
  final aligned = Float32List(reference.length);
  if (chosen != null) {
    final other = chosen.other;
    final otherFrames = other.length ~/ channels;
    final otherFrame = lag + input.referenceStart - chosen.otherStart;
    for (var frame = 0; frame < frames; frame++) {
      final source = otherFrame + frame;
      if (source < 0 || source >= otherFrames) continue;
      for (var channel = 0; channel < channels; channel++) {
        aligned[frame * channels + channel] =
            other[source * channels + channel];
      }
    }
  }
  final gain = audioCompareLeastSquaresGain(reference, aligned);
  var residual = 0.0;
  var energy = 0.0;
  for (var i = 0; i < reference.length; i++) {
    final difference = reference[i] - gain * aligned[i];
    residual += difference * difference;
    energy += reference[i] * reference[i];
  }
  return AudioCompareFineMatch(
    lag: lag,
    correlation: correlation,
    gain: gain,
    excerptResidualDb: energy <= 0
        ? audioCompareFloorDb
        : audioComparePowerDb(residual / energy),
  );
}

// Reference residual measurement

/// A second-order high-pass (RBJ cookbook, Q = 1/sqrt(2)), the filter FFmpeg
/// runs for `highpass=poles=2`.
class _HighPass {
  _HighPass(double cutoff, int sampleRate) {
    final w0 = 2 * math.pi * math.min(cutoff, sampleRate * 0.49) / sampleRate;
    final alpha = math.sin(w0) / (2 * math.sqrt1_2);
    final cosW0 = math.cos(w0);
    final a0 = 1 + alpha;
    _b0 = (1 + cosW0) / 2 / a0;
    _b1 = -(1 + cosW0) / a0;
    _b2 = _b0;
    _a1 = -2 * cosW0 / a0;
    _a2 = (1 - alpha) / a0;
  }

  late final double _b0, _b1, _b2, _a1, _a2;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  double process(double x) {
    final y = _b0 * x + _b1 * _x1 + _b2 * _x2 - _a1 * _y1 - _a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }
}

/// Measures the residual windows directly from decoded samples, as the
/// FFmpeg pass does for whole songs: `reference - gain * other`, with the
/// other file shifted by [offsetFrames] and silent outside its length.
/// Only tests call it, as the reference the FFmpeg pass is checked against.
List<AudioCompareWindow> audioCompareMeasureWindows({
  required Float32List reference,
  required Float32List other,
  required int channels,
  required int sampleRate,
  required int offsetFrames,
  required double gain,
  required int windowFrames,
  double bandSplitHz = audioCompareBandSplitHz,
}) {
  final frames = reference.length ~/ channels;
  final otherFrames = other.length ~/ channels;
  final residualFilters = [
    for (var c = 0; c < channels; c++)
      [_HighPass(bandSplitHz, sampleRate), _HighPass(bandSplitHz, sampleRate)],
  ];
  final referenceFilters = [
    for (var c = 0; c < channels; c++)
      [_HighPass(bandSplitHz, sampleRate), _HighPass(bandSplitHz, sampleRate)],
  ];
  final windows = <AudioCompareWindow>[];
  for (var start = 0; start < frames; start += windowFrames) {
    final end = math.min(frames, start + windowFrames);
    final residual = Float64List(channels);
    final referencePower = Float64List(channels);
    final residualHigh = Float64List(channels);
    final referenceHigh = Float64List(channels);
    for (var frame = start; frame < end; frame++) {
      final source = frame + offsetFrames;
      for (var c = 0; c < channels; c++) {
        final r = reference[frame * channels + c];
        final o = source >= 0 && source < otherFrames
            ? other[source * channels + c]
            : 0.0;
        final d = r - gain * o;
        residual[c] += d * d;
        referencePower[c] += r * r;
        final dh = residualFilters[c][1].process(
          residualFilters[c][0].process(d),
        );
        final rh = referenceFilters[c][1].process(
          referenceFilters[c][0].process(r),
        );
        residualHigh[c] += dh * dh;
        referenceHigh[c] += rh * rh;
      }
    }
    final count = end - start;
    for (var c = 0; c < channels; c++) {
      residual[c] /= count;
      referencePower[c] /= count;
      residualHigh[c] /= count;
      referenceHigh[c] /= count;
    }
    windows.add(
      AudioCompareWindow(
        startSeconds: start / sampleRate,
        frames: count,
        residual: residual,
        reference: referencePower,
        residualHigh: residualHigh,
        referenceHigh: referenceHigh,
      ),
    );
  }
  return windows;
}

// Summary

enum AudioCompareLevel {
  identical,
  nearlyIdentical,
  mostlyIdentical,
  moderate,
  large,
}

enum AudioCompareBand { none, high, low, broadband }

/// Why the null test is probably not meaningful.
enum AudioCompareNotice { weakAlignment, residualHigh, drift, durationMismatch }

AudioCompareLevel audioCompareLevelFor(double overallDb) {
  if (overallDb <= -110) return AudioCompareLevel.identical;
  if (overallDb <= -70) return AudioCompareLevel.nearlyIdentical;
  if (overallDb <= -40) return AudioCompareLevel.mostlyIdentical;
  if (overallDb <= -20) return AudioCompareLevel.moderate;
  return AudioCompareLevel.large;
}

/// Compares the residual relative to the reference above and below
/// [audioCompareBandSplitHz] over the whole song.
AudioCompareBand audioCompareBandFor(List<AudioCompareWindow> windows) {
  var residual = 0.0;
  var reference = 0.0;
  var residualHigh = 0.0;
  var referenceHigh = 0.0;
  for (final window in windows) {
    final n = window.frames.toDouble();
    for (var c = 0; c < window.residual.length; c++) {
      residual += window.residual[c] * n;
      reference += window.reference[c] * n;
      residualHigh += window.residualHigh[c] * n;
      referenceHigh += window.referenceHigh[c] * n;
    }
  }
  if (reference <= 0 || residual <= 0) return AudioCompareBand.none;
  if (audioComparePowerDb(residual / reference) <= -90) {
    return AudioCompareBand.none;
  }
  // Without real high-frequency content there is nothing to compare.
  if (referenceHigh / reference < 1e-4) return AudioCompareBand.none;
  final residualLow = math.max(0.0, residual - residualHigh);
  final referenceLow = math.max(reference * 1e-9, reference - referenceHigh);
  final highRelative = residualHigh / referenceHigh;
  final lowRelative = residualLow / referenceLow;
  if (highRelative <= 0 && lowRelative <= 0) return AudioCompareBand.none;
  if (lowRelative <= 0) return AudioCompareBand.high;
  if (highRelative <= 0) return AudioCompareBand.low;
  final difference = 10 * math.log(highRelative / lowRelative) / math.ln10;
  if (difference >= audioCompareBandConcentrationDb) {
    return AudioCompareBand.high;
  }
  if (difference <= -audioCompareBandConcentrationDb) {
    return AudioCompareBand.low;
  }
  if (difference.abs() <= audioCompareBandEvenDb) {
    return AudioCompareBand.broadband;
  }
  return AudioCompareBand.none;
}

/// The loudest window of a series, ignoring silent reference windows.
class AudioComparePeak {
  const AudioComparePeak(this.seconds, this.db);

  final double seconds;
  final double db;
}

AudioComparePeak? audioComparePeakFor(
  List<AudioCompareWindow> windows, [
  AudioCompareChannel channel = AudioCompareChannel.combined,
]) {
  AudioComparePeak? peak;
  for (final window in windows) {
    if (window.isSilent(channel)) continue;
    final db = window.relativeDb(channel);
    if (db <= audioCompareFloorDb) continue;
    if (peak == null || db > peak.db) {
      peak = AudioComparePeak(window.startSeconds, db);
    }
  }
  return peak;
}

/// Median relative level of the non-silent windows.
double audioCompareMedianDb(
  List<AudioCompareWindow> windows, [
  AudioCompareChannel channel = AudioCompareChannel.combined,
]) {
  final values = [
    for (final window in windows)
      if (!window.isSilent(channel)) window.relativeDb(channel),
  ]..sort();
  if (values.isEmpty) return audioCompareFloorDb;
  return values[values.length ~/ 2];
}

Set<AudioCompareNotice> audioCompareNoticesFor({
  required double correlation,
  required double overallDb,
  required double medianDb,
  int? driftCoarse,
  required double referenceSeconds,
  required double otherSeconds,
  required double offsetSeconds,
}) {
  return {
    if (correlation.abs() < audioCompareMinCorrelation)
      AudioCompareNotice.weakAlignment,
    if (overallDb > audioCompareNotSameSourceDb ||
        medianDb > audioCompareNotSameSourceDb)
      AudioCompareNotice.residualHigh,
    if (driftCoarse != null &&
        driftCoarse.abs() > audioCompareDriftToleranceCoarse)
      AudioCompareNotice.drift,
    if (referenceSeconds > 0 &&
        otherSeconds > 0 &&
        ((otherSeconds - offsetSeconds) - referenceSeconds).abs() >
            audioCompareDurationToleranceSeconds)
      AudioCompareNotice.durationMismatch,
  };
}
