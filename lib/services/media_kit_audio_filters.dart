import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/services/playback_deck.dart' show PlaybackPitch;

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
///
/// [withTempo] adds the pitch shift of an [MpvTempo] to the same `af` value,
/// after the equalizer.
@immutable
class MpvAudioFilterChain {
  const MpvAudioFilterChain(
    this.filters, {
    this.volumeGainDb = 0,
    this.tempoScale,
  });

  static const empty = MpvAudioFilterChain([]);

  /// Filters a libmpv build may lack. Every build has `equalizer`.
  static const optionalFilters = {
    'volume',
    'stereotools',
    'acompressor',
    'alimiter',
  };

  /// Sample rate assumed before the decoder reports one. Bands above 45% of
  /// the real rate are rebuilt once it is known.
  static const defaultSampleRate = 44100;

  final List<MpvAudioFilter> filters;

  /// Input gain that could not be placed in the graph.
  final double volumeGainDb;

  /// The `scale` of mpv's own `scaletempo` filter after the graph, or null
  /// for none (see [MpvTempo.tempoScale]).
  final double? tempoScale;

  factory MpvAudioFilterChain.fromEqualizer(
    EqualizerSettings settings, {
    int? sampleRate,
    Set<String> unavailable = const {},
  }) {
    if (!settings.enabled) return empty;
    bool has(String name) => !unavailable.contains(name);
    final rate = (sampleRate == null || sampleRate <= 0)
        ? defaultSampleRate
        : sampleRate;
    final frequencies = settings.frequencies;
    final gains = settings.effectiveGains;
    final step = math.pow(
      frequencies.last / frequencies.first,
      1 / (frequencies.length - 1),
    );
    final q = math.sqrt(step) / (step - 1);
    return MpvAudioFilterChain(
      volumeGainDb: has('volume') ? 0 : settings.inputGain,
      [
        if (has('volume'))
          MpvAudioFilter(
            'pre',
            'volume',
            options: {
              'precision': 'float',
              'volume': '${_number(settings.inputGain)}dB',
            },
          ),
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

  MpvAudioFilterChain withTempo(MpvTempo tempo) => MpvAudioFilterChain(
    [...filters, ...tempo.filters],
    volumeGainDb: volumeGainDb,
    tempoScale: tempo.tempoScale,
  );

  /// The value of mpv's `af` property.
  String get spec {
    final scale = tempoScale;
    return [
      if (filters.isNotEmpty) ...[
        '@mornye_format:format=format=floatp',
        '@mornye_dsp:lavfi=[${filters.map((filter) => filter.spec).join(',')}]',
      ],
      if (scale != null)
        '@mornye_tempo:scaletempo=scale=${_number(scale, digits: 6)}',
    ].join(',');
  }

  bool get isEmpty => filters.isEmpty && tempoScale == null;

  static String _number(num value, {int digits = 4}) {
    final text = value.toStringAsFixed(digits);
    final trimmed = text.contains('.')
        ? text.replaceFirst(RegExp(r'\.?0+$'), '')
        : text;
    return trimmed == '-0' ? '0' : trimmed;
  }
}

/// How a libmpv deck plays at an effective speed with a [PlaybackPitch].
///
/// Without a semitone shift this is mpv's `speed` and
/// `audio-pitch-correction` alone: correction on keeps the pitch while the
/// speed changes (mpv's automatic `scaletempo2`), off lets it follow.
///
/// A shift is a libavfilter `rubberband` filter in the equalizer's graph
/// where the build has one (distribution builds on Linux). media_kit's own
/// libmpv builds have no `rubberband`, `asetrate` or `atempo`, so elsewhere
/// mpv resamples by the whole frequency factor (`speed` at that factor,
/// correction off) and its built-in `scaletempo` filter, present in every
/// build, stretches the tempo back to the effective speed.
@immutable
class MpvTempo {
  const MpvTempo({
    required this.speed,
    required this.pitchCorrection,
    this.filters = const [],
    this.tempoScale,
  });

  /// mpv's defaults: normal speed, pitch kept.
  static const normal = MpvTempo(speed: 1, pitchCorrection: true);

  /// Optional filters a shift prefers, probed like
  /// [MpvAudioFilterChain.optionalFilters].
  static const optionalFilters = {'rubberband'};

  factory MpvTempo.of(
    double speed,
    PlaybackPitch pitch, {
    Set<String> unavailable = const {},
  }) {
    if (pitch.semitones == 0) {
      return MpvTempo(speed: speed, pitchCorrection: !pitch.followsRate);
    }
    final shift = math.pow(2, pitch.semitones / 12).toDouble();
    if (!unavailable.contains('rubberband')) {
      return MpvTempo(
        speed: speed,
        pitchCorrection: !pitch.followsRate,
        filters: [
          MpvAudioFilter(
            'pitch',
            'rubberband',
            options: {
              'pitch': MpvAudioFilterChain._number(shift, digits: 6),
              'pitchq': 'quality',
            },
          ),
        ],
      );
    }
    final factor = pitch.factorAt(speed);
    return MpvTempo(
      speed: factor,
      pitchCorrection: false,
      tempoScale: speed / factor,
    );
  }

  /// mpv's `speed` property.
  final double speed;

  /// mpv's `audio-pitch-correction` property.
  final bool pitchCorrection;

  /// Filters after the equalizer in its graph.
  final List<MpvAudioFilter> filters;

  /// The `scale` of a `scaletempo` filter after the graph, which brings the
  /// tempo of audio mpv resampled by [speed] back to the effective speed.
  final double? tempoScale;
}
