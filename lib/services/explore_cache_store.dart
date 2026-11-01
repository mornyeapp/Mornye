import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/preference_blob_store.dart';

class ExploreCacheSnapshot {
  const ExploreCacheSnapshot({
    required this.payload,
    required this.timestampMs,
    required this.sizeBytes,
  });

  final String? payload;
  final int? timestampMs;
  final int sizeBytes;
}

class ExploreCacheStore {
  const ExploreCacheStore(this._prefs);

  static const _cacheKey = 'explore_home_feed_cache';
  static const _cacheTsKey = 'explore_home_feed_ts';
  static const _blobs = PreferenceBlobStore('explore_feed', {
    _cacheKey: String,
    _cacheTsKey: int,
  });

  final SharedPreferences _prefs;

  Future<ExploreCacheSnapshot> read() async {
    final snapshot = await _blobs.read(_prefs);
    return ExploreCacheSnapshot(
      payload: snapshot.values[_cacheKey] as String?,
      timestampMs: snapshot.values[_cacheTsKey] as int?,
      sizeBytes: snapshot.sizeBytes,
    );
  }

  Future<void> write(String payload) async {
    await _blobs.write(_prefs, {
      _cacheKey: payload,
      _cacheTsKey: DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> clear() => _blobs.clear(_prefs);
}
