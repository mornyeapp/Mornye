import 'dart:typed_data';

/// The layout of the vector that describes how a song sounds, as the native
/// `audio_features` job (native_audio_features.rs) returns it.
abstract final class SongFeatures {
  /// Changes with the vector's layout or meaning; stored vectors of another
  /// version are analyzed again.
  static const version = 1;
  static const length = 42;

  /// Beats per minute (60 to 180, 0 when unknown) and its confidence.
  static const tempo = 0, tempoConfidence = 1;

  /// Mean and spread of the audible frames' RMS, in dBFS.
  static const loudness = 2, loudnessSpread = 3;

  /// Spectral centroid mean and spread, and the 85% rolloff, in Hz.
  static const centroid = 4, centroidSpread = 5, rolloff = 6;

  /// Spectral flatness (noisiness), onsets per second and spectral flux.
  static const flatness = 7, onsetRate = 8, flux = 9;

  /// Energy shares below 250 Hz, up to 4 kHz and above, in three slots.
  static const bands = 10;

  /// The key's tonic (C = 0), its mode (1 major, 0 minor) and how clearly
  /// the song is in it.
  static const key = 13, mode = 14, keyStrength = 15;

  /// MFCC 1 to 13 means, then their spreads (timbre).
  static const mfcc = 16, mfccSpread = 29, mfccCount = 13;

  /// Little-endian 32-bit floats, as stored.
  static Uint8List encode(Float32List features) {
    final data = ByteData(features.length * 4);
    for (var i = 0; i < features.length; i++) {
      data.setFloat32(i * 4, features[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }

  /// The vector in [blob], or null when it does not have this layout.
  static Float32List? decode(Object? blob) {
    if (blob is! List<int> || blob.length != length * 4) return null;
    final data = ByteData.sublistView(
      blob is Uint8List ? blob : Uint8List.fromList(blob),
    );
    final features = Float32List(length);
    for (var i = 0; i < length; i++) {
      final value = data.getFloat32(i * 4, Endian.little);
      if (!value.isFinite) return null;
      features[i] = value;
    }
    return features;
  }
}
