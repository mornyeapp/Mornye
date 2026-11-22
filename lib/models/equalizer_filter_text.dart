import 'package:mornye/models/equalizer_settings.dart';

/// The plain text list of parametric filters that measurement and tuning
/// tools exchange, one filter a line:
///
/// ```
/// Preamp: -6.2 dB
/// Filter 1: ON PK Fc 105 Hz Gain -2.1 dB Q 0.70
/// Filter 2: ON LSC Fc 80 Hz Gain 4 dB Q 0.71
/// ```
class EqualizerFilterText {
  const EqualizerFilterText({
    required this.filters,
    this.preamp,
    this.skipped = 0,
  });

  final List<EqualizerFilter> filters;

  /// The file's own gain before the filters, when it names one.
  final double? preamp;

  /// Filters of a kind the equalizer has none of (pass, notch, all-pass).
  final int skipped;

  static final _preamp = RegExp(
    r'^\s*Preamp\s*:\s*([-+]?[0-9.,]+)\s*dB',
    caseSensitive: false,
  );
  static final _filter = RegExp(
    r'^\s*Filter\s*\d*\s*:\s*(ON|OFF)\s+([A-Za-z]+)\b(.*)$',
    caseSensitive: false,
  );
  static final _frequency = RegExp(
    r'\bFc\s+([0-9.,]+)\s*Hz',
    caseSensitive: false,
  );
  static final _gain = RegExp(
    r'\bGain\s+([-+]?[0-9.,]+)\s*dB',
    caseSensitive: false,
  );
  static final _q = RegExp(r'\bQ\s+([0-9.,]+)', caseSensitive: false);

  static double? _number(RegExpMatch? match) => match == null
      ? null
      : double.tryParse(match.group(1)!.replaceAll(',', '.'));

  /// Throws a [FormatException] when [source] holds no usable filter.
  factory EqualizerFilterText.parse(String source) {
    double? preamp;
    var skipped = 0;
    final filters = <EqualizerFilter>[];
    for (final line in source.split(RegExp(r'\r?\n'))) {
      preamp ??= _number(_preamp.firstMatch(line));
      final match = _filter.firstMatch(line);
      if (match == null) continue;
      final type = switch (match.group(2)!.toUpperCase()) {
        'PK' || 'PEQ' || 'MODAL' => EqualizerFilterType.peak,
        'LS' || 'LSC' || 'LSQ' => EqualizerFilterType.lowShelf,
        'HS' || 'HSC' || 'HSQ' => EqualizerFilterType.highShelf,
        _ => null,
      };
      final rest = match.group(3)!;
      final frequency = _number(_frequency.firstMatch(rest));
      final gain = _number(_gain.firstMatch(rest));
      if (type == null || frequency == null || gain == null) {
        // An empty slot ("None") is not a filter that was left out.
        if (match.group(2)!.toUpperCase() != 'NONE') skipped++;
        continue;
      }
      if (!frequency.isFinite || !gain.isFinite) continue;
      final q = _number(_q.firstMatch(rest));
      if (filters.length >= EqualizerSettings.maxFilters) {
        skipped++;
        continue;
      }
      filters.add(
        EqualizerFilter(
          type: type,
          frequency: frequency.clamp(
            EqualizerFilter.minFrequency,
            EqualizerFilter.maxFrequency,
          ),
          gain: gain.clamp(-EqualizerFilter.maxGain, EqualizerFilter.maxGain),
          q: (q != null && q.isFinite && q > 0 ? q : EqualizerFilter.shelfQ)
              .clamp(EqualizerFilter.minQ, EqualizerFilter.maxQ),
          enabled: match.group(1)!.toUpperCase() == 'ON',
        ),
      );
    }
    if (filters.isEmpty) throw const FormatException('No filters found');
    return EqualizerFilterText(
      filters: filters,
      preamp: preamp != null && preamp.isFinite ? preamp : null,
      skipped: skipped,
    );
  }

  /// The filters of [settings] with the gain they play at, so the text
  /// sounds the same in a tool without automatic headroom.
  static String format(EqualizerSettings settings) {
    String number(double value, int digits) {
      final text = value.toStringAsFixed(digits);
      return double.parse(text) == 0 ? 0.toStringAsFixed(digits) : text;
    }

    final lines = ['Preamp: ${number(settings.inputGain, 1)} dB'];
    for (final (index, filter) in settings.filters.indexed) {
      final type = switch (filter.type) {
        EqualizerFilterType.peak => 'PK',
        EqualizerFilterType.lowShelf => 'LSC',
        EqualizerFilterType.highShelf => 'HSC',
      };
      lines.add(
        'Filter ${index + 1}: ${filter.enabled ? 'ON' : 'OFF'} $type '
        'Fc ${number(filter.frequency, filter.frequency % 1 == 0 ? 0 : 1)} Hz '
        'Gain ${number(filter.gain, 1)} dB Q ${number(filter.q, 2)}',
      );
    }
    return '${lines.join('\n')}\n';
  }
}
