import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mornye/models/equalizer_settings.dart';

/// One filter in the equalizer's libavfilter graph.
@immutable
class MpvAudioFilter {
  const MpvAudioFilter(this.id, this.name, {this.options = const {}});

  /// Instance name in the graph (`name@id`).
  final String id;

  /// libavfilter filter name.
  final String name;

  final Map<String, String> options;

  String get spec {
    final values = [
      for (final entry in options.entries) '${entry.key}=${entry.value}',
    ];
    return '$name@$id=${values.join(':')}';
  }
}

/// The mpv audio filter chain that reproduces the Darwin and Android
/// equalizer (`EqualizerDSP.swift`): input gain, peaking bands, balance,
/// compressor, then a -0.5 dBFS limiter.
///
/// The filters form one libavfilter graph behind mpv's `lavfi` filter,
/// after mpv converts the audio to planar float. Separate `lavfi-*` filters
/// fail from the third one on with mpv 0.36 and FFmpeg 6 ("Layout indicates
/// a different number of channels"), and media_kit's builds have no
/// `aresample` to convert formats inside a graph.
///
/// Changes set the `af` property again. `af-command` on a graph reaches
/// every filter but reports the result of the graph's last one, the input
/// buffer, which rejects every command, so success cannot be told apart
/// from failure.
///
/// media_kit's Windows and macOS libmpv builds also include few filters
/// (`equalizer`, not `volume` or the dynamics filters), while Linux uses the
/// distribution's full build. Filters listed in `unavailable` are left out;
/// without `volume` the input gain moves to [volumeGainDb], which the deck
/// applies through mpv's volume.
@immutable
class MpvAudioFilterChain {
  const MpvAudioFilterChain(this.filters, {this.volumeGainDb = 0});

  static const empty = MpvAudioFilterChain([]);

  /// Filters a libmpv build may lack. Every build has `equalizer`.
  static const optionalFilters = {
    'volume',
    'stereotools',
    'acompressor',
    'alimiter',
    'bs2b',
  };

  /// Sample rate assumed before the decoder reports one. Bands above 45% of
  /// the real rate are rebuilt once it is known.
  static const defaultSampleRate = 44100;

  final List<MpvAudioFilter> filters;

  /// Input gain that could not be placed in the graph.
  final double volumeGainDb;

  factory MpvAudioFilterChain.fromEqualizer(
    EqualizerSettings settings, {
    int? sampleRate,
    Set<String> unavailable = const {},
    bool spatialAudio = false,
  }) {
    if (!settings.enabled && !spatialAudio) return empty;
    bool has(String name) => !unavailable.contains(name);
    final rate = (sampleRate == null || sampleRate <= 0)
        ? defaultSampleRate
        : sampleRate;
    final frequencies = settings.frequencies;
    final gains = settings.effectiveGains;
    final step = frequencies.length > 1
        ? math.pow(
            frequencies.last / frequencies.first,
            1 / (frequencies.length - 1),
          )
        : 2.0;
    final q = math.sqrt(step) / (step - 1);
    return MpvAudioFilterChain(
      volumeGainDb: has('volume') ? 0 : settings.inputGain,
      [
        if (has('volume') && settings.inputGain != 0)
          MpvAudioFilter(
            'pre',
            'volume',
            options: {
              'precision': 'float',
              'volume': '${_number(settings.inputGain)}dB',
            },
          ),
        if (settings.enabled)
          for (var i = 0; i < gains.length; i++)
            MpvAudioFilter(
              'band$i',
              'equalizer',
              options: {
                'f': _number(math.min(frequencies[i], rate * 0.45)),
                't': 'q',
                'w': _number(q),
                'g': _number(gains[i]),
              },
            ),
        if (spatialAudio && has('bs2b'))
          const MpvAudioFilter(
            'spatial_crossfeed',
            'bs2b',
            options: {'profile': 'default'},
          )
        else if (spatialAudio && has('stereotools'))
          const MpvAudioFilter(
            'spatial_crossfeed',
            'stereotools',
            options: {'crosslevel': '0.35'},
          ),
        // Applied only when set: the filter converts its input to stereo.
        if (settings.balance != 0 && has('stereotools'))
          MpvAudioFilter(
            'balance',
            'stereotools',
            options: {
              'balance_out': _number(settings.balance.clamp(-1.0, 1.0)),
            },
          ),
        if (settings.compressor && has('acompressor'))
          MpvAudioFilter(
            'compressor',
            'acompressor',
            options: {
              'detection': 'peak',
              'link': 'maximum',
              'knee': '1',
              'makeup': '1',
              'threshold': _number(
                math.pow(10, settings.threshold.clamp(-60.0, 0.0) / 20),
              ),
              'ratio': _number(settings.ratio.clamp(1.0, 20.0)),
              'attack': _number(settings.attack.clamp(1.0, 100.0)),
              'release': _number(settings.release.clamp(20.0, 1000.0)),
            },
          ),
        if (settings.limiter && has('alimiter'))
          MpvAudioFilter(
            'limiter',
            'alimiter',
            options: {
              'limit': _number(math.pow(10, -0.5 / 20)),
              'attack': '5',
              'release': '60',
              // Automatic level would raise quiet output, unlike the other OSes.
              'level': '0',
            },
          ),
      ],
    );
  }

  /// The value of mpv's `af` property.
  String get spec => filters.isEmpty
      ? ''
      : '@mornye_format:format=format=floatp,'
            '@mornye_dsp:lavfi=[${filters.map((filter) => filter.spec).join(',')}]';

  bool get isEmpty => filters.isEmpty;

  static String _number(num value) {
    final text = value.toStringAsFixed(4);
    final trimmed = text.contains('.')
        ? text.replaceFirst(RegExp(r'\.?0+$'), '')
        : text;
    return trimmed == '-0' ? '0' : trimmed;
  }
}
