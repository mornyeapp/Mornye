import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/preference_blob_store.dart';
import 'package:mornye/services/sqlite_helpers.dart' show normalizeLookupText;
import 'package:mornye/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _key = 'autoplay_rotation_v1';
const _store = PreferenceBlobStore(_key, {_key: String});
final _log = AppLogger('AutoplayHistory');

/// Rotation is independent of preference learning. Persist only fingerprints,
/// never file paths, signed URLs or song metadata.
class AutoplayHistory {
  AutoplayHistory({
    Future<String?> Function()? read,
    Future<void> Function(String)? write,
  }) : _read = read ?? _readStore,
       _write = write ?? _writeStore;

  static const limit = 4096;
  final Future<String?> Function() _read;
  final Future<void> Function(String) _write;
  final Map<String, String> _entries = {};
  Future<void>? _loading, _saving;
  int _revision = 0, _savedRevision = 0;

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static String sourceKey(PlayableMedia media) =>
      _hash('source:${media.source}');

  static String songKey(PlayableMedia media) => _hash(
    'song:${normalizeLookupText(media.artist)}|${normalizeLookupText(media.title)}',
  );

  static Future<String?> _readStore() async =>
      (await _store.read(await SharedPreferences.getInstance())).values[_key]
          as String?;

  static Future<void> _writeStore(String value) async =>
      _store.write(await SharedPreferences.getInstance(), {_key: value});

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final stored = await _read();
      if (stored == null) return;
      final decoded = jsonDecode(stored);
      if (decoded is! Map<String, dynamic>) return;
      final pending = Map.of(_entries);
      final fingerprint = RegExp(r'^[0-9a-f]{64}$');
      _entries.clear();
      for (final entry in decoded.entries) {
        if (fingerprint.hasMatch(entry.key) &&
            entry.value is String &&
            fingerprint.hasMatch(entry.value as String)) {
          _entries[entry.key] = entry.value as String;
        }
      }
      // Plays that happened during disk I/O remain newer than stored history.
      for (final entry in pending.entries) {
        _entries.remove(entry.key);
        _entries[entry.key] = entry.value;
      }
      _trim();
    } catch (error) {
      _log.w('Could not restore Autoplay rotation: $error');
    }
  }

  void remember(PlayableMedia media) {
    final source = sourceKey(media);
    _entries.remove(source);
    _entries[source] = songKey(media);
    _trim();
    _revision++;
  }

  void _trim() {
    while (_entries.length > limit) {
      _entries.remove(_entries.keys.first);
    }
  }

  Map<String, int> snapshot() {
    var order = 0;
    return {
      for (final entry in _entries.entries) ...{
        entry.key: order,
        entry.value: order++,
      },
    };
  }

  Future<void> flush() =>
      _saving ??= _flush().whenComplete(() => _saving = null);

  Future<void> _flush() async {
    await load();
    try {
      while (_savedRevision != _revision) {
        final revision = _revision;
        await _write(jsonEncode(_entries));
        _savedRevision = revision;
      }
    } catch (error) {
      _log.w('Could not save Autoplay rotation: $error');
    }
  }
}
