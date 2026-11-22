import 'dart:math' as math;

enum EqualizerFilterType {
  peak('peak'),
  lowShelf('lowshelf'),
  highShelf('highshelf');

  const EqualizerFilterType(this.nativeName);

  /// The name in saved settings and in the native configuration.
  final String nativeName;
}

/// One filter of the parametric equalizer: a second order section from the
/// Audio EQ Cookbook (https://www.w3.org/TR/audio-eq-cookbook/).
class EqualizerFilter {
  const EqualizerFilter({
    this.type = EqualizerFilterType.peak,
    this.frequency = 1000,
    this.gain = 0,
    this.q = 1,
    this.enabled = true,
  });

  static const minFrequency = 20.0, maxFrequency = 20000.0;
  static const maxGain = 24.0;
  static const minQ = 0.1, maxQ = 20.0;

  /// The Q of a shelf that names none: the steepest without overshoot.
  static const shelfQ = 0.707;

  final EqualizerFilterType type;
  final double frequency, gain, q;
  final bool enabled;

  /// Gain in dB at [hz], from the analog prototype. The digital filter
  /// differs only close to half the sample rate.
  double responseAt(double hz) {
    if (!enabled || gain == 0) return 0;
    final a = math.pow(10, gain / 40).toDouble();
    final w = hz / frequency, w2 = w * w;
    switch (type) {
      case EqualizerFilterType.peak:
        final pass = (1 - w2) * (1 - w2);
        return 10 *
            math.log(
              (pass + math.pow(a * w / q, 2)) /
                  (pass + math.pow(w / (a * q), 2)),
            ) /
            math.ln10;
      case EqualizerFilterType.lowShelf:
      case EqualizerFilterType.highShelf:
        final damping = a * w2 / (q * q);
        final low = math.pow(a - w2, 2) + damping;
        final high = math.pow(1 - a * w2, 2) + damping;
        final ratio = type == EqualizerFilterType.lowShelf
            ? low / high
            : high / low;
        return 10 * math.log(a * a * ratio) / math.ln10;
    }
  }

  EqualizerFilter copyWith({
    EqualizerFilterType? type,
    double? frequency,
    double? gain,
    double? q,
    bool? enabled,
  }) => EqualizerFilter(
    type: type ?? this.type,
    frequency: frequency ?? this.frequency,
    gain: gain ?? this.gain,
    q: q ?? this.q,
    enabled: enabled ?? this.enabled,
  );

  Map<String, dynamic> toJson() => {
    'type': type.nativeName,
    'frequency': frequency,
    'gain': gain,
    'q': q,
    'enabled': enabled,
  };

  /// Null for an entry that is not a filter. Values are brought into range.
  static EqualizerFilter? fromJson(Object? json) {
    if (json is! Map) return null;
    final frequency = json['frequency'], gain = json['gain'], q = json['q'];
    if (frequency is! num || gain is! num || q is! num) return null;
    if (!frequency.isFinite || !gain.isFinite || !q.isFinite) return null;
    return EqualizerFilter(
      type: EqualizerFilterType.values.firstWhere(
        (type) => type.nativeName == json['type'],
        orElse: () => EqualizerFilterType.peak,
      ),
      frequency: frequency.toDouble().clamp(minFrequency, maxFrequency),
      gain: gain.toDouble().clamp(-maxGain, maxGain),
      q: q.toDouble().clamp(minQ, maxQ),
      enabled: json['enabled'] != false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is EqualizerFilter &&
      other.type == type &&
      other.frequency == frequency &&
      other.gain == gain &&
      other.q == q &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(type, frequency, gain, q, enabled);
}

/// Portable EQ settings: a graphic equalizer of fixed bands, or the
/// [filters] of a parametric one while [parametric] is set. Gains are
/// independent of the system volume.
class EqualizerSettings {
  const EqualizerSettings({
    this.enabled = false,
    this.parametric = false,
    this.filters = const [],
    this.gains = const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    this.preamp = 0,
    this.bass = 0,
    this.treble = 0,
    this.balance = 0,
    this.autoHeadroom = true,
    this.limiter = true,
    this.compressor = false,
    this.threshold = -18,
    this.ratio = 3,
    this.attack = 10,
    this.release = 150,
  });

  static const bandCounts = [5, 10, 15, 31];

  /// The most parametric filters kept.
  static const maxFilters = 20;

  final bool enabled, autoHeadroom, limiter, compressor;

  /// Whether [filters] shape the sound in place of [gains], [bass] and
  /// [treble], which are kept for the way back.
  final bool parametric;
  final List<EqualizerFilter> filters;
  final List<double> gains;
  final double preamp, bass, treble, balance;
  final double threshold, ratio, attack, release;

  static const _centers = <int, List<double>>{
    5: [63, 250, 1000, 4000, 16000],
    10: [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000],
    15: [
      25,
      40,
      63,
      100,
      160,
      250,
      400,
      630,
      1000,
      1600,
      2500,
      4000,
      6300,
      10000,
      16000,
    ],
    31: [
      20,
      25,
      31.5,
      40,
      50,
      63,
      80,
      100,
      125,
      160,
      200,
      250,
      315,
      400,
      500,
      630,
      800,
      1000,
      1250,
      1600,
      2000,
      2500,
      3150,
      4000,
      5000,
      6300,
      8000,
      10000,
      12500,
      16000,
      20000,
    ],
  };

  List<double> get frequencies => _centers[gains.length]!;

  /// Tone controls merge into the graphic curve, identically on both OSes.
  List<double> get effectiveGains => [
    for (var i = 0; i < gains.length; i++)
      (gains[i] +
              bass / (1 + math.pow(frequencies[i] / 180, 2)) +
              treble / (1 + math.pow(5000 / frequencies[i], 2)))
          .clamp(-24.0, 24.0),
  ];

  /// Gain in dB at [hz] of the curve that plays: the filters together, or
  /// the bands with the tone controls.
  double responseAt(double hz) => parametric
      ? filters.fold(0.0, (sum, filter) => sum + filter.responseAt(hz))
      : gainAt(hz, includeTone: true);

  /// The highest point of the parametric curve, looked for on a grid of 24
  /// points an octave and at every filter's own frequency.
  double get _filterPeak {
    var peak = 0.0;
    for (var step = 0; step <= 240; step++) {
      peak = math.max(peak, responseAt(20 * math.pow(2, step / 24).toDouble()));
    }
    for (final filter in filters) {
      peak = math.max(peak, responseAt(filter.frequency));
    }
    return peak;
  }

  double get headroom => !autoHeadroom
      ? 0
      : (parametric ? _filterPeak : effectiveGains.fold(0.0, math.max)).clamp(
          0.0,
          24.0,
        );
  double get inputGain => (preamp - headroom).clamp(-48.0, 12.0);

  EqualizerSettings copyWith({
    bool? enabled,
    bool? parametric,
    List<EqualizerFilter>? filters,
    List<double>? gains,
    double? preamp,
    double? bass,
    double? treble,
    double? balance,
    bool? autoHeadroom,
    bool? limiter,
    bool? compressor,
    double? threshold,
    double? ratio,
    double? attack,
    double? release,
  }) => EqualizerSettings(
    enabled: enabled ?? this.enabled,
    parametric: parametric ?? this.parametric,
    filters: filters == null
        ? this.filters
        : List.unmodifiable(filters.take(maxFilters)),
    gains: gains == null ? this.gains : List.unmodifiable(gains),
    preamp: preamp ?? this.preamp,
    bass: bass ?? this.bass,
    treble: treble ?? this.treble,
    balance: balance ?? this.balance,
    autoHeadroom: autoHeadroom ?? this.autoHeadroom,
    limiter: limiter ?? this.limiter,
    compressor: compressor ?? this.compressor,
    threshold: threshold ?? this.threshold,
    ratio: ratio ?? this.ratio,
    attack: attack ?? this.attack,
    release: release ?? this.release,
  );

  EqualizerSettings withBandCount(int count) {
    if (!bandCounts.contains(count)) throw const FormatException('Band count');
    final next = EqualizerSettings(gains: List.filled(count, 0));
    return copyWith(gains: [for (final hz in next.frequencies) gainAt(hz)]);
  }

  /// A preset carries a sound; headroom, limiting, compression and balance
  /// stay as the listener set them.
  EqualizerSettings withToneOf(EqualizerSettings preset) => copyWith(
    parametric: preset.parametric,
    // A graphic preset leaves the listener's filters for the way back.
    filters: preset.parametric ? preset.filters : null,
    gains: preset.gains,
    preamp: preset.preamp,
    bass: preset.bass,
    treble: preset.treble,
  );

  double gainAt(double hz, {bool includeTone = false}) {
    final values = includeTone ? effectiveGains : gains;
    final centers = frequencies;
    if (hz <= centers.first) return values.first;
    for (var index = 1; index < centers.length; index++) {
      if (hz <= centers[index]) {
        final fraction =
            math.log(hz / centers[index - 1]) /
            math.log(centers[index] / centers[index - 1]);
        return values[index - 1] +
            (values[index] - values[index - 1]) * fraction;
      }
    }
    return values.last;
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'parametric': parametric,
    'filters': [for (final filter in filters) filter.toJson()],
    'gains': gains,
    'preamp': preamp,
    'bass': bass,
    'treble': treble,
    'balance': balance,
    'autoHeadroom': autoHeadroom,
    'limiter': limiter,
    'compressor': compressor,
    'threshold': threshold,
    'ratio': ratio,
    'attack': attack,
    'release': release,
  };

  /// The configuration a native equalizer takes. With `filters` set it plays
  /// those in place of the bands, which are then sent flat.
  Map<String, dynamic> toNative() => {
    ...toJson(),
    'frequencies': parametric ? _centers[10] : frequencies,
    'gains': parametric ? List.filled(10, 0.0) : effectiveGains,
    'inputGain': inputGain,
    'filters': parametric
        ? [
            for (final filter in filters)
              if (filter.enabled && filter.gain != 0)
                {
                  'type': filter.type.nativeName,
                  'frequency': filter.frequency,
                  'gain': filter.gain,
                  'q': filter.q,
                },
          ]
        : null,
  };

  factory EqualizerSettings.fromJson(Map<String, dynamic> json) {
    double number(String key, double fallback, double min, double max) {
      final value = json[key];
      if (value is! num || !value.isFinite) return fallback;
      return value.toDouble().clamp(min, max);
    }

    final raw = json['gains'];
    if (raw is! List ||
        !bandCounts.contains(raw.length) ||
        raw.any((v) => v is! num || !v.isFinite)) {
      throw const FormatException('Invalid equalizer bands');
    }
    final filters = json['filters'];
    return EqualizerSettings(
      enabled: json['enabled'] == true,
      parametric: json['parametric'] == true,
      filters: List.unmodifiable(
        (filters is List ? filters : const <Object?>[])
            .map(EqualizerFilter.fromJson)
            .nonNulls
            .take(maxFilters),
      ),
      gains: List.unmodifiable(
        raw.map((v) => (v as num).toDouble().clamp(-15.0, 15.0)),
      ),
      preamp: number('preamp', 0, -24, 12),
      bass: number('bass', 0, -12, 12),
      treble: number('treble', 0, -12, 12),
      balance: number('balance', 0, -1, 1),
      autoHeadroom: json['autoHeadroom'] != false,
      limiter: json['limiter'] != false,
      compressor: json['compressor'] == true,
      threshold: number('threshold', -18, -60, 0),
      ratio: number('ratio', 3, 1, 20),
      attack: number('attack', 10, 1, 100),
      release: number('release', 150, 20, 1000),
    );
  }
}

class EqualizerPreset {
  const EqualizerPreset(this.name, this.settings);
  final String name;
  final EqualizerSettings settings;

  Map<String, dynamic> toJson() => {
    'name': name,
    'settings': settings.toJson(),
  };

  factory EqualizerPreset.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final settings = json['settings'];
    if (name is! String ||
        name.trim().isEmpty ||
        name.length > 80 ||
        settings is! Map) {
      throw const FormatException('Invalid equalizer preset');
    }
    return EqualizerPreset(
      name.trim(),
      EqualizerSettings.fromJson(Map<String, dynamic>.from(settings)),
    );
  }

  static final builtIn = <EqualizerPreset>[
    const EqualizerPreset('Flat', EqualizerSettings()),
    for (final entry in <String, List<double>>{
      'Bass boost': [6, 5, 3, 1, 0, 0, 0, 0, 0, 0],
      'Treble boost': [0, 0, 0, 0, 0, 1, 2, 3, 4, 5],
      'Vocal': [-2, -2, -1, 0, 2, 3, 3, 2, 0, -1],
      'Rock': [4, 3, 1, -1, -2, 0, 2, 3, 4, 4],
      'Pop': [-1, 1, 3, 4, 3, 1, -1, -1, 1, 2],
      'Jazz': [3, 2, 1, 1, -1, -1, 0, 1, 2, 3],
      'Classical': [3, 2, 1, 0, -1, -1, 0, 1, 2, 3],
      'Electronic': [5, 4, 1, -1, -2, 0, 1, 3, 4, 4],
      'Acoustic': [3, 2, 1, 2, 2, 2, 3, 2, 1, 2],
    }.entries)
      EqualizerPreset(
        entry.key,
        EqualizerSettings(gains: List.unmodifiable(entry.value)),
      ),
  ];
}
