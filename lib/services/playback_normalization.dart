import 'dart:math';

/// Caches successful tag reads by stable media identity. Descriptor paths are
/// short-lived and require their display-name hint to select the audio parser.
class PlaybackNormalizationCache {
  final Future<Map<String, dynamic>> Function(String, {String? displayName})
  readMetadata;
  final void Function(Object)? onReadError;
  final Map<String, ({double? track, double? album})> _gains = {};
  int _generation = 0;
  static final _gainNumber = RegExp(r'-?\d+(\.\d+)?');

  PlaybackNormalizationCache({required this.readMetadata, this.onReadError});

  void invalidate(String source) {
    _gains.remove(source);
    _generation++;
  }

  /// The player volume for [path]. [preampDb] shifts the -18 LUFS reference
  /// the tags were written against, so -7 dB targets -25 LUFS. Volume stays
  /// at or below 1.0 unless [boost] lets quiet songs rise, up to +12 dB.
  Future<double> volumeFor(
    String path, {
    String? cacheKey,
    String? displayName,
    double preampDb = 0,
    bool preferAlbumGain = false,
    bool boost = false,
  }) async {
    final gains = await _gainsFor(
      path,
      cacheKey: cacheKey,
      displayName: displayName,
    );
    final gain = gains == null
        ? null
        : preferAlbumGain
        ? gains.album ?? gains.track
        : gains.track ?? gains.album;
    if (gain == null) return 1.0;
    return pow(
      10.0,
      (gain + preampDb) / 20.0,
    ).toDouble().clamp(0.0, boost ? maxBoostVolume : 1.0);
  }

  /// The highest volume [boost] allows: +12 dB, the equalizer's input range.
  static final maxBoostVolume = pow(10.0, 12 / 20.0).toDouble();

  Future<({double? track, double? album})?> _gainsFor(
    String path, {
    String? cacheKey,
    String? displayName,
  }) async {
    final key = cacheKey ?? path;
    final cached = _gains[key];
    if (cached != null) return cached;
    final generation = _generation;
    try {
      final metadata = await readMetadata(path, displayName: displayName);
      if (metadata['error'] != null) {
        onReadError?.call(metadata['error'] as Object);
        return null;
      }
      final gains = (
        track: _gain(metadata['replaygain_track_gain']),
        album: _gain(metadata['replaygain_album_gain']),
      );
      if (generation == _generation) {
        if (_gains.length >= 128) _gains.remove(_gains.keys.first);
        _gains[key] = gains;
      }
      return gains;
    } catch (error) {
      onReadError?.call(error);
      return null;
    }
  }

  static double? _gain(Object? value) {
    final match = _gainNumber.firstMatch(value?.toString() ?? '');
    return match == null ? null : double.tryParse(match.group(0)!);
  }
}
