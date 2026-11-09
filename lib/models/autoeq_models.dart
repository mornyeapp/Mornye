import 'package:mornye/models/equalizer_settings.dart';

/// Representation of an AutoEq / Wavelet headphone compensation profile.
class AutoEqProfile {
  final String id;
  final String brand;
  final String model;
  final String type; // 'Over-Ear', 'In-Ear', 'Earbuds'
  final double preamp; // in dB
  final List<double> gains; // 10 bands: 31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 Hz

  const AutoEqProfile({
    required this.id,
    required this.brand,
    required this.model,
    required this.type,
    required this.preamp,
    required this.gains,
  });

  String get displayName => '$brand $model';

  EqualizerPreset toEqualizerPreset() {
    return EqualizerPreset(
      displayName,
      EqualizerSettings(
        enabled: true,
        gains: List.unmodifiable(gains),
        preamp: preamp,
        autoHeadroom: true,
        limiter: true,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'brand': brand,
    'model': model,
    'type': type,
    'preamp': preamp,
    'gains': gains,
  };

  factory AutoEqProfile.fromJson(Map<String, dynamic> json) => AutoEqProfile(
    id: json['id'] as String,
    brand: json['brand'] as String,
    model: json['model'] as String,
    type: json['type'] as String? ?? 'Headphones',
    preamp: (json['preamp'] as num?)?.toDouble() ?? 0.0,
    gains: (json['gains'] as List).map((g) => (g as num).toDouble()).toList(),
  );
}
