import 'package:flutter/foundation.dart';
import 'package:mornye/services/media_kit_audio_filters.dart';

/// Bauer Stereophonic-to-Binaural DSP (Bauer / Chu Moy crossfeed).
///
/// Blends low frequencies (~700 Hz) across stereo channels with ~4.5 dB
/// attenuation and ~0.4 ms interaural time difference (ITD) to eliminate
/// headphone listening fatigue and produce natural, out-of-head studio imaging.
@immutable
class SpatialAudioCrossfeed {
  const SpatialAudioCrossfeed({
    this.cutoffFrequency = 700.0,
    this.crossfeedLevelDb = 4.5,
  });

  /// Standard Bauer cutoff frequency in Hz.
  final double cutoffFrequency;

  /// Crossfeed feed level in dB (typically 4.5 dB to 6.0 dB).
  final double crossfeedLevelDb;

  /// Returns libavfilter specification for libmpv / media_kit.
  /// Uses native bs2b filter when available, or a fallback stereotools matrix.
  MpvAudioFilter toMpvFilter({bool useBs2b = true}) {
    if (useBs2b) {
      return const MpvAudioFilter(
        'spatial_crossfeed',
        'bs2b',
        options: {
          'profile': 'default', // Bauer default (700Hz, 4.5dB)
        },
      );
    }
    return const MpvAudioFilter(
      'spatial_crossfeed',
      'stereotools',
      options: {'crosslevel': '0.35', 'sbal': '0.0'},
    );
  }

  /// Calculates the channel cross-blend ratio from 0 to 1.
  double get crossBlendRatio => 0.32;
}
