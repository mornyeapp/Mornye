import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:mornye/models/equalizer_settings.dart';

/// The part of a deck volume above 1, in dB, that a deck raises through its
/// equalizer's input gain. Half-decibel steps keep a fade across it from
/// rewriting the equalizer on every step.
double normalizationBoostDb(double volume) =>
    volume <= 1 ? 0 : (40 * log(volume) / ln10 - 1e-9).ceil() / 2;

/// [settings] with up to [boostDb] more input gain, and the boost that fits
/// the input range. A switched off equalizer turns flat with its limiter on.
({EqualizerSettings settings, double boostDb}) boostEqualizer(
  EqualizerSettings settings,
  double boostDb,
) {
  final base = settings.enabled
      ? settings
      : const EqualizerSettings(enabled: true);
  final fits = min(boostDb, 12 - base.inputGain);
  if (fits <= 0) return (settings: settings, boostDb: 0);
  return (settings: base.copyWith(preamp: base.preamp + fits), boostDb: fits);
}

/// Shared by every playback deck, including AutoMix's incoming/outgoing decks.
final playbackEqualizer = ValueNotifier<EqualizerSettings>(
  const EqualizerSettings(),
);

/// A native error is surfaced in the editor rather than claiming EQ is active.
final playbackEqualizerError = ValueNotifier<String?>(null);

final _errors = <String, String>{};

void reportEqualizerError(String playerId, String? error) {
  if (error == null) {
    _errors.remove(playerId);
  } else {
    _errors[playerId] = error;
  }
  playbackEqualizerError.value = _errors.isEmpty ? null : _errors.values.first;
}
