enum AutoMixEffect { auto, crossfade, muffled, echo, pitch, vinylBrake, custom }

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
  });

  /// Zero chooses a short musical overlap automatically.
  final int durationSeconds;
  final AutoMixEffect effect;
  final double speed;
  final double pitchSemitones;
  final bool echo;
  final bool lowPass;

  @override
  bool operator ==(Object other) =>
      other is AutoMixOptions &&
      (durationSeconds, effect, speed, pitchSemitones, echo, lowPass) ==
          (
            other.durationSeconds,
            other.effect,
            other.speed,
            other.pitchSemitones,
            other.echo,
            other.lowPass,
          );

  @override
  int get hashCode => Object.hash(
    durationSeconds,
    effect,
    speed,
    pitchSemitones,
    echo,
    lowPass,
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
      effectiveSpeed != 1 ||
      effectivePitch != 0 ||
      useEcho ||
      useLowPass ||
      effect == AutoMixEffect.vinylBrake;

  double outroWindowOffset(Duration duration, double windowSeconds) {
    final seconds = duration.inMicroseconds / 1e6;
    final lookback = safeDurationSeconds == 0
        ? windowSeconds
        : safeDurationSeconds + windowSeconds / 2;
    return (seconds - lookback).clamp(0, double.infinity);
  }
}
