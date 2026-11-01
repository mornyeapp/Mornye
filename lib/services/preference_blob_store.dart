import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('PreferenceBlobStore');

class PreferenceBlobSnapshot {
  const PreferenceBlobSnapshot(this.values, this.sizeBytes);

  final Map<String, Object?> values;
  final int sizeBytes;
}

/// Serializes file replacement and legacy-key removal across store instances.
class PreferenceBlobStore {
  const PreferenceBlobStore(
    this.name,
    this.keys, {
    this.directory = getApplicationSupportDirectory,
    this.persist = _atomicWrite,
  });

  final String name;
  final Map<String, Type> keys;
  final Future<Directory> Function() directory;
  final Future<void> Function(File, String) persist;
  static final _pending = <String, Future<void>>{};
  static final _failedRemovals = <String, Set<String>>{};
  static int _sequence = 0;

  Future<T> _run<T>(Future<T> Function() operation) {
    final result = (_pending[name] ?? Future<void>.value()).then(
      (_) => operation(),
    );
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pending[name] = tail;
    return result.whenComplete(() {
      if (identical(_pending[name], tail)) _pending.remove(name);
    });
  }

  Future<File> _file() async =>
      File('${(await directory()).path}/preference_blobs/$name.json');

  bool _valid(Map<String, Object?> values) => values.entries.every((entry) {
    final type = keys[entry.key];
    return (type == String && entry.value is String) ||
        (type == int && entry.value is int);
  });

  Map<String, Object?> _legacy(SharedPreferences prefs) => {
    for (final entry in keys.entries)
      if (prefs.get(entry.key) case final Object value)
        if ((entry.value == String && value is String) ||
            (entry.value == int && value is int))
          entry.key: value,
  };

  Future<void> _removeLegacy(SharedPreferences prefs) async {
    final retry = _failedRemovals.putIfAbsent(name, () => <String>{});
    for (final key in keys.keys) {
      if (prefs.containsKey(key) || retry.contains(key)) {
        retry.add(key);
        if (!await prefs.remove(key)) {
          throw StateError('Could not remove legacy blob key $key');
        }
        retry.remove(key);
      }
    }
    if (retry.isEmpty) _failedRemovals.remove(name);
  }

  Future<PreferenceBlobSnapshot> read(SharedPreferences prefs) =>
      _run(() => _read(prefs));

  Future<PreferenceBlobSnapshot> _read(SharedPreferences prefs) async {
    final legacy = _legacy(prefs);
    try {
      final file = await _file();
      Map<String, Object?>? values;
      if (await file.exists()) {
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map<String, dynamic>) {
            final candidate = Map<String, Object?>.from(decoded);
            if (_valid(candidate)) values = candidate;
          }
        } on FormatException {
          // An interrupted or malformed file may still have a legacy value.
        }
      }
      if (values == null) {
        if (legacy.isEmpty) return const PreferenceBlobSnapshot({}, 0);
        await persist(file, jsonEncode(legacy));
        values = legacy;
      }
      final size = values.isEmpty ? 0 : await file.length();
      try {
        await _removeLegacy(prefs);
        if (values.isEmpty && await file.exists()) await file.delete();
      } catch (error) {
        _log.w('Could not finish blob migration for $name: $error');
      }
      return PreferenceBlobSnapshot(values, size);
    } catch (error) {
      _log.w('Could not read or migrate blob $name: $error');
      return PreferenceBlobSnapshot(
        legacy,
        legacy.isEmpty ? 0 : utf8.encode(jsonEncode(legacy)).length,
      );
    }
  }

  Future<void> write(SharedPreferences prefs, Map<String, Object?> values) {
    if (!_valid(values)) throw ArgumentError.value(values, 'values');
    final encoded = jsonEncode(values);
    return _run(() => _write(prefs, encoded));
  }

  Future<void> update(
    SharedPreferences prefs,
    Map<String, Object?> Function(Map<String, Object?>) change,
  ) => _run(() async {
    final values = change((await _read(prefs)).values);
    if (!_valid(values)) throw ArgumentError.value(values, 'values');
    await _write(prefs, jsonEncode(values));
  });

  Future<void> _write(SharedPreferences prefs, String encoded) async {
    await persist(await _file(), encoded);
    await _removeLegacy(prefs);
  }

  Future<void> clear(SharedPreferences prefs) => _run(() async {
    final file = await _file();
    if (!await file.exists() && !keys.keys.any(prefs.containsKey)) return;
    // A committed tombstone prevents an old preference from reviving on retry.
    await persist(file, '{}');
    await _removeLegacy(prefs);
    await file.delete();
  });

  static Future<void> _atomicWrite(File file, String contents) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp-$pid-${_sequence++}');
    try {
      await temporary.writeAsString(contents, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
