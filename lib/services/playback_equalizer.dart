import 'package:flutter/foundation.dart';
import 'package:mornye/models/equalizer_settings.dart';

/// Shared by every playback deck, including AutoMix's incoming/outgoing decks.
final playbackEqualizer = ValueNotifier<EqualizerSettings>(
  const EqualizerSettings(),
);

/// Whether Bauer spatial audio crossfeed is active.
final playbackSpatialAudio = ValueNotifier<bool>(false);

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
