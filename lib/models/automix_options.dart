enum AutoMixEffect { auto, crossfade, muffled, echo, pitch, custom }

/// How readily two songs are mixed on their beats instead of crossfaded.
///
/// One analysis window is trusted from a confidence of 0.55. Below that a
/// second window of the song must repeat its tempo and beats; the levels
/// differ in how uncertain that second window may be and in how far the
/// incoming song's tempo may move. Measured over 64 songs in every order,
/// [standard] mixed 0.8% of the pairs, [more] 3.7% and [most] 6.2%.
enum AutoMixMatching {
  standard(confirmedConfidence: 0.55, maxTempoChange: 0.08),
  more(confirmedConfidence: 0.4, maxTempoChange: 0.1),
  most(confirmedConfidence: 0.3, maxTempoChange: 0.12);

  const AutoMixMatching({
    required this.confirmedConfidence,
    required this.maxTempoChange,
  });

  /// The least confidence, 0 to 1, of the window that repeats the beats.
  final double confirmedConfidence;

  /// The most the incoming song's tempo may change, as a share of it.
  final double maxTempoChange;
}

int autoMixDurationFromJson(Object? value) =>
    value is num && value.isFinite && value > 0
    ? value.round().clamp(3, 60)
    : 0;

double autoMixSpeedFromJson(Object? value) =>
    value is num && value.isFinite ? value.toDouble().clamp(0.8, 1.2) : 1;

double autoMixPitchFromJson(Object? value) =>
    value is num && value.isFinite ? value.toDouble().clamp(-6, 6) : 0;

class AutoMixOptions {
  const AutoMixOptions({
    this.durationSeconds = 0,
    this.effect = AutoMixEffect.auto,
    this.speed = 1,
    this.pitchSemitones = 0,
    this.echo = false,
    this.lowPass = false,
    this.matching = AutoMixMatching.standard,
  });

  /// Zero chooses a short musical overlap automatically.
  final int durationSeconds;
  final AutoMixEffect effect;
  final AutoMixMatching matching;
  final double speed;
  final double pitchSemitones;
  final bool echo;
  final bool lowPass;

  @override
  bool operator ==(Object other) =>
      other is AutoMixOptions &&
      (
            durationSeconds,
            effect,
            speed,
            pitchSemitones,
            echo,
            lowPass,
            matching,
          ) ==
          (
            other.durationSeconds,
            other.effect,
            other.speed,
            other.pitchSemitones,
            other.echo,
            other.lowPass,
            other.matching,
          );

  @override
  int get hashCode => Object.hash(
    durationSeconds,
    effect,
    speed,
    pitchSemitones,
    echo,
    lowPass,
    matching,
  );

  int get safeDurationSeconds => autoMixDurationFromJson(durationSeconds);
  double get effectiveSpeed =>
      effect == AutoMixEffect.custom ? autoMixSpeedFromJson(speed) : 1;
  double get effectivePitch =>
      effect == AutoMixEffect.custom || effect == AutoMixEffect.pitch
      ? autoMixPitchFromJson(pitchSemitones)
      : 0;
  bool get useEcho =>
      effect == AutoMixEffect.echo || effect == AutoMixEffect.custom && echo;
  bool get useLowPass =>
      effect == AutoMixEffect.muffled ||
      effect == AutoMixEffect.custom && lowPass;
  bool get hasEffects =>
      effectiveSpeed != 1 || effectivePitch != 0 || useEcho || useLowPass;

  double outroWindowOffset(Duration duration, double windowSeconds) {
    final seconds = duration.inMicroseconds / 1e6;
    final lookback = safeDurationSeconds == 0
        ? windowSeconds
        : safeDurationSeconds + windowSeconds / 2;
    return (seconds - lookback).clamp(0, double.infinity);
  }
}
