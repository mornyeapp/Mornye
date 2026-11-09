import 'dart:math' as math;
import 'dart:typed_data';
import 'package:mornye/models/automix_options.dart';

/// A local beat grid, measured in seconds within the decoded audio window.
class AutoMixBeatGrid {
  const AutoMixBeatGrid({
    required this.bpm,
    required this.phase,
    required this.confidence,
    required this.firstSound,
    this.lastSound = 0,
  });

  final double bpm;
  final double phase;
  final double confidence;
  final double firstSound;
  final double lastSound;

  bool get reliable => confidence >= 0.55 && bpm >= 60 && bpm <= 180;
  double get period => 60 / bpm;
  double beatAtOrAfter(double seconds) =>
      phase + ((seconds - phase) / period).ceil() * period;
  double beatAtOrBefore(double seconds) =>
      phase + ((seconds - phase) / period).floor() * period;
}

/// Bounded, original onset/autocorrelation detector. Runs in an isolate on
/// 24-second mono PCM windows, not on the UI isolate or an entire music file.
/// The onset -> autocorrelation -> phase approach is described in DAFx-09,
/// "Real-time beat-synchronous analysis of musical audio":
/// https://www.dafx.de/paper-archive/2009/papers/paper_65.pdf
AutoMixBeatGrid analyzeAutoMixPcm(Uint8List pcm) {
  const sampleRate = 11025;
  const hop = 128;
  const framesPerSecond = sampleRate / hop;
  final samples = ByteData.sublistView(pcm);
  final frames = pcm.length ~/ (2 * hop);
  const unknown = AutoMixBeatGrid(
    bpm: 0,
    phase: 0,
    confidence: 0,
    firstSound: 0,
  );
  if (frames < framesPerSecond * 6) return unknown;
  final onset = Float64List(frames);
  final energy = Float64List(frames);
  var low = 0.0;
  var mid = 0.0;
  var previousLow = 0.0;
  var previousMid = 0.0;
  var previousHigh = 0.0;
  for (var frame = 0; frame < frames; frame++) {
    var loEnergy = 0.0;
    var midEnergy = 0.0;
    var hiEnergy = 0.0;
    for (var i = 0; i < hop; i++) {
      final value =
          samples.getInt16((frame * hop + i) * 2, Endian.little) / 32768;
      low += 0.075 * (value - low);
      mid += 0.45 * (value - mid);
      loEnergy += low * low;
      midEnergy += (mid - low) * (mid - low);
      hiEnergy += (value - mid) * (value - mid);
      energy[frame] += value * value / hop;
    }
    final lo = math.log(1 + loEnergy * 100 / hop);
    final mi = math.log(1 + midEnergy * 100 / hop);
    final hi = math.log(1 + hiEnergy * 100 / hop);
    onset[frame] =
        math.max(0, lo - previousLow) +
        math.max(0, mi - previousMid) +
        0.5 * math.max(0, hi - previousHigh);
    previousLow = lo;
    previousMid = mi;
    previousHigh = hi;
  }
  final peakEnergy = energy.reduce(math.max);
  if (peakEnergy < 0.00001) return unknown;
  final firstAudible = energy.indexWhere(
    (e) => e > math.max(0.00001, peakEnergy * 0.0001),
  );
  final firstSound = math.max(0, firstAudible) / framesPerSecond;
  final lastAudible = energy.lastIndexWhere(
    (e) => e > math.max(0.00001, peakEnergy * 0.002),
  );
  final lastSound = lastAudible >= 0 ? lastAudible / framesPerSecond : frames / framesPerSecond;
  // Suppress slow volume changes and constant noise before finding the pulse.
  final prefix = Float64List(frames + 1);
  for (var i = 0; i < frames; i++) {
    prefix[i + 1] = prefix[i] + onset[i];
  }
  var total = 0.0;
  for (var i = 0; i < frames; i++) {
    final begin = math.max(0, i - 8);
    final end = math.min(frames, i + 9);
    onset[i] = math.max(
      0,
      onset[i] - (prefix[end] - prefix[begin]) / (end - begin),
    );
    total += onset[i] * onset[i];
  }
  if (total < 0.000001) {
    return AutoMixBeatGrid(
      bpm: 0,
      phase: 0,
      confidence: 0,
      firstSound: firstSound,
      lastSound: lastSound,
    );
  }

  // A fade, a loud fill, or a quieter verse must not dominate the pulse
  // correlation. Normalize against nearby onset energy with a global floor
  // so silence and low-level noise cannot acquire arbitrary gain.
  final power = Float64List(frames + 1);
  for (var i = 0; i < frames; i++) {
    power[i + 1] = power[i] + onset[i] * onset[i];
  }
  final floor = total / frames * 0.01;
  for (var i = 0; i < frames; i++) {
    final begin = math.max(0, i - 43);
    final end = math.min(frames, i + 44);
    final local = (power[end] - power[begin]) / (end - begin);
    onset[i] = math.min(6, onset[i] / math.sqrt(math.max(floor, local)));
  }

  double correlation(double lag) {
    var dot = 0.0;
    var left = 0.0;
    var right = 0.0;
    for (var i = lag.ceil(); i < frames; i++) {
      final source = i - lag;
      final j = source.floor();
      final fraction = source - j;
      final delayed =
          onset[j] * (1 - fraction) +
          onset[math.min(j + 1, frames - 1)] * fraction;
      dot += onset[i] * delayed;
      left += onset[i] * onset[i];
      right += delayed * delayed;
    }
    return dot / math.sqrt(math.max(0.000000001, left * right));
  }

  var bestBpm = 0.0;
  var bestScore = 0.0;
  for (var bpm = 60.0; bpm <= 180; bpm += 0.25) {
    final score = correlation(framesPerSecond * 60 / bpm);
    // Resolve equally strong half-time candidates toward common musical tempi.
    final weighted =
        score * (0.96 + 0.04 * math.exp(-math.pow((bpm - 120) / 45, 2)));
    if (weighted > bestScore) {
      bestScore = weighted;
      bestBpm = bpm;
    }
  }
  if (bestBpm == 0) return unknown;
  final coarseBpm = bestBpm;
  for (var step = -25; step <= 25; step++) {
    final bpm = coarseBpm + step * 0.01;
    if (bpm < 60 || bpm > 180) continue;
    final score = correlation(framesPerSecond * 60 / bpm);
    final weighted =
        score * (0.96 + 0.04 * math.exp(-math.pow((bpm - 120) / 45, 2)));
    if (weighted > bestScore) {
      bestScore = weighted;
      bestBpm = bpm;
    }
  }
  final period = framesPerSecond * 60 / bestBpm;
  var bestPhase = 0.0;
  var phaseScore = 0.0;
  for (var phase = 0.0; phase < period; phase += 0.5) {
    var score = 0.0;
    var count = 0;
    for (var beat = phase; beat < frames - 1; beat += period) {
      final i = beat.round();
      score += onset[i];
      count++;
    }
    score /= math.max(1, count);
    if (score > phaseScore) {
      phaseScore = score;
      bestPhase = phase;
    }
  }
  var hits = 0;
  var beats = 0;
  for (var beat = bestPhase; beat < frames - 2; beat += period) {
    final i = beat.round();
    final peak = math.max(
      onset[i],
      math.max(onset[math.max(0, i - 1)], onset[i + 1]),
    );
    if (peak >= phaseScore * 0.3) hits++;
    beats++;
  }
  final coverage = hits / math.max(1, beats);
  return AutoMixBeatGrid(
    bpm: bestBpm,
    phase: bestPhase / framesPerSecond,
    confidence: math.min(bestScore, coverage),
    firstSound: firstSound,
    lastSound: lastSound,
  );
}

enum AutoMixFallbackReason {
  crossfadePreset,
  analysisUnavailable,
  unreliableBeats,
  incompatibleTempo,
  longIntro,
  alignmentUnverified,
  effectTempo,
}

class AutoMixPlan {
  const AutoMixPlan({
    required this.start,
    required this.incomingStart,
    required this.duration,
    required this.rate,
    required this.beatMatched,
    this.fallbackReason,
    this.assisted = false,
    this.beatPeriod = Duration.zero,
  });

  final Duration start;
  final Duration incomingStart;
  final Duration duration;
  final double rate;
  final bool beatMatched;
  final AutoMixFallbackReason? fallbackReason;
  final bool assisted;
  final Duration beatPeriod;

  AutoMixPlan withoutBeatMatching() => AutoMixPlan(
    start: start,
    incomingStart: incomingStart,
    duration: duration,
    rate: 1,
    beatMatched: false,
    fallbackReason: AutoMixFallbackReason.alignmentUnverified,
  );

  static AutoMixPlan? create({
    required Duration outgoingDuration,
    required Duration incomingDuration,
    AutoMixBeatGrid? outro,
    AutoMixBeatGrid? intro,
    double outroOffset = 0,
    AutoMixOptions options = const AutoMixOptions(),
  }) {
    final end = outgoingDuration.inMicroseconds / 1e6;
    final nextLength = incomingDuration.inMicroseconds / 1e6;
    if (end < 20 || nextLength < 20) return null;
    final manualDuration = options.safeDurationSeconds;
    final maximum = math.min(60.0, math.min(end / 2, nextLength / 2));
    var fade = (manualDuration == 0 ? 8.0 : manualDuration.toDouble()).clamp(
      3.0,
      maximum,
    );
    final audibleEnd = outro != null && outro.lastSound > 0
        ? (outroOffset + outro.lastSound).clamp(end - 15.0, end)
        : end;
    var start = audibleEnd - fade;
    var incomingStart = 0.0;
    var rate = 1.0;
    var matched = false;
    AutoMixFallbackReason? fallbackReason;
    if (options.effect == AutoMixEffect.crossfade) {
      fallbackReason = AutoMixFallbackReason.crossfadePreset;
    } else if (options.effectiveSpeed != 1) {
      fallbackReason = AutoMixFallbackReason.effectTempo;
    } else if (outro == null || intro == null) {
      fallbackReason = AutoMixFallbackReason.analysisUnavailable;
    } else if (!outro.reliable || !intro.reliable) {
      fallbackReason = AutoMixFallbackReason.unreliableBeats;
    } else {
      final outgoing = outro;
      final incoming = intro;
      final candidates =
          [
              0.5,
              1.0,
              2.0,
            ].map((factor) => outgoing.bpm / (incoming.bpm * factor)).toList()
            ..sort((a, b) => (a - 1).abs().compareTo((b - 1).abs()));
      final candidate = candidates.first;
      final firstBeat = incoming.beatAtOrAfter(incoming.firstSound);
      // The detector measures leading silence, not the length of a musical
      // intro. A quiet lead-in should not disable an otherwise reliable mix.
      // Bound the trim so an uncertain/very late onset still uses crossfade.
      if ((candidate - 1).abs() > 0.08) {
        fallbackReason = AutoMixFallbackReason.incompatibleTempo;
      } else if (firstBeat > math.min(12, nextLength * 0.1)) {
        fallbackReason = AutoMixFallbackReason.longIntro;
      } else {
        rate = candidate;
        if (manualDuration == 0) {
          // 16 beats = 4 full bars in 4/4 time: standard Apple Music DJ phrase transition.
          fade = (16 * outgoing.period).clamp(5.0, math.min(12.0, maximum));
        }
        final phase = outroOffset + outgoing.phase;
        start =
            phase +
            ((audibleEnd - fade - phase) / outgoing.period).floor() * outgoing.period;
        incomingStart = firstBeat;
        matched = true;
      }
    }
    return AutoMixPlan(
      start: Duration(microseconds: (start * 1e6).round()),
      incomingStart: Duration(microseconds: (incomingStart * 1e6).round()),
      duration: Duration(microseconds: (fade * 1e6).round()),
      rate: rate,
      beatMatched: matched,
      fallbackReason: fallbackReason,
      // A measured but uncertain pulse can support a tonal handoff without
      // authorizing a tempo change or claiming that the beats are aligned.
      assisted:
          !matched &&
          options.effect == AutoMixEffect.auto &&
          outro != null &&
          intro != null &&
          outro.bpm >= 60 &&
          outro.bpm <= 180 &&
          intro.bpm >= 60 &&
          intro.bpm <= 180 &&
          outro.confidence >= 0.25 &&
          intro.confidence >= 0.25,
      beatPeriod: matched
          ? Duration(microseconds: (outro!.period * 1e6).round())
          : Duration.zero,
    );
  }
}

/// Equal-power gain ramps; tempo returns gradually after the outgoing song ends.
({double outgoing, double incoming, double rate, bool complete})
autoMixEnvelope(Duration elapsed, AutoMixPlan plan, {Duration? fadeDuration}) {
  final duration = fadeDuration ?? plan.duration;
  final t = (elapsed.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0);
  final recovery = ((elapsed - duration).inMicroseconds / 8000000).clamp(
    0.0,
    1.0,
  );
  final smooth = recovery * recovery * (3 - 2 * recovery);
  return (
    outgoing: math.cos(t * math.pi / 2),
    incoming: math.sin(t * math.pi / 2),
    rate: plan.rate + (1 - plan.rate) * smooth,
    complete: recovery >= 1 || (t >= 1 && plan.rate == 1),
  );
}
