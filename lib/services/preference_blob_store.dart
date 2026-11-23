import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

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
  final Future<void> Function(File, List<int>) persist;
  static final _pending = <String, Future<void>>{};
  static final _failedRemovals = <String, Set<String>>{};
  static int _sequence = 0;

  /// Blobs this large are encoded and decoded off the calling isolate.
  static const workerThresholdBytes = 64 * 1024;

  /// The exact file bytes [write] stores for [values].
  static Uint8List encode(Map<String, Object?> values) =>
      utf8.encode(jsonEncode(values));

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

  bool _valid(Map<String, Object?> values) => _validFor(keys, values);

  static bool _validFor(Map<String, Type> keys, Map<String, Object?> values) =>
      values.entries.every((entry) {
        final type = keys[entry.key];
        return (type == String && entry.value is String) ||
            (type == int && entry.value is int);
      });

  static Map<String, Object?>? _decode(String text, Map<String, Type> keys) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        final candidate = Map<String, Object?>.from(decoded);
        if (_validFor(keys, candidate)) return candidate;
      }
    } on FormatException {
      // An interrupted or malformed file may still have a legacy value.
    }
    return null;
  }

  static (Map<String, Object?>?, R?) _decodeText<R>(
    String text,
    Map<String, Type> keys,
    R Function(Map<String, Object?>)? convert,
  ) {
    final values = _decode(text, keys);
    return (values, values == null ? null : convert?.call(values));
  }

  static Future<(Map<String, Object?>?, R?)> _decodeFile<R>(
    File file,
    Map<String, Type> keys,
    R Function(Map<String, Object?>)? convert,
  ) async {
    if (await file.length() < workerThresholdBytes) {
      return _decodeText(await file.readAsString(), keys, convert);
    }
    final path = file.path;
    return Isolate.run(
      () => _decodeText(File(path).readAsStringSync(), keys, convert),
    );
  }

  static Future<bool> _validFile(String path, Map<String, Type> keys) =>
      Isolate.run(() => _decode(File(path).readAsStringSync(), keys) != null);

  static Future<Uint8List> _encode(Map<String, Object?> values) {
    var size = 0;
    for (final value in values.values) {
      if (value is String) size += value.length;
    }
    if (size < workerThresholdBytes) return Future.value(encode(values));
    final copy = Map<String, Object?>.of(values);
    return Isolate.run(() => encode(copy));
  }

  bool _hasLegacy(SharedPreferences prefs) =>
      keys.keys.any(prefs.containsKey) ||
      (_failedRemovals[name]?.isNotEmpty ?? false);

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

  Future<PreferenceBlobSnapshot> read(SharedPreferences prefs) async =>
      (await _run(() => _read<Object?>(prefs))).$1;

  /// Reads like [read], then applies [convert] in the same worker as the
  /// decode. [convert] must be a static or top-level function.
  Future<R?> readAs<R>(
    SharedPreferences prefs,
    R Function(Map<String, Object?>) convert,
  ) async => (await _run(() => _read(prefs, convert))).$2;

  /// The [PreferenceBlobSnapshot.sizeBytes] that [read] reports. A large
  /// file is only validated in a worker; legacy values take the full read.
  Future<int> sizeBytes(SharedPreferences prefs) => _run(() async {
    if (!_hasLegacy(prefs)) {
      try {
        final file = await _file();
        if (await file.exists() &&
            await file.length() >= workerThresholdBytes) {
          return await _validFile(file.path, keys) ? await file.length() : 0;
        }
      } catch (error) {
        _log.w('Could not read or migrate blob $name: $error');
        return 0;
      }
    }
    return (await _read<Object?>(prefs)).$1.sizeBytes;
  });

  Future<(PreferenceBlobSnapshot, R?)> _read<R>(
    SharedPreferences prefs, [
    R Function(Map<String, Object?>)? convert,
  ]) async {
    final legacy = _legacy(prefs);
    try {
      final file = await _file();
      Map<String, Object?>? values;
      R? converted;
      if (await file.exists()) {
        (values, converted) = await _decodeFile(file, keys, convert);
      }
      if (values == null) {
        if (legacy.isEmpty) {
          return (const PreferenceBlobSnapshot({}, 0), convert?.call(const {}));
        }
        await persist(file, await _encode(legacy));
        values = legacy;
        converted = convert?.call(legacy);
      }
      final size = values.isEmpty ? 0 : await file.length();
      try {
        await _removeLegacy(prefs);
        if (values.isEmpty && await file.exists()) await file.delete();
      } catch (error) {
        _log.w('Could not finish blob migration for $name: $error');
      }
      return (PreferenceBlobSnapshot(values, size), converted);
    } catch (error) {
      _log.w('Could not read or migrate blob $name: $error');
      return (
        PreferenceBlobSnapshot(
          legacy,
          legacy.isEmpty ? 0 : utf8.encode(jsonEncode(legacy)).length,
        ),
        convert?.call(legacy),
      );
    }
  }

  Future<void> write(SharedPreferences prefs, Map<String, Object?> values) {
    if (!_valid(values)) throw ArgumentError.value(values, 'values');
    return writeEncoded(prefs, _encode(values));
  }

  /// Stores [payload], bytes from [encode], in call order with other saves.
  Future<void> writeEncoded(
    SharedPreferences prefs,
    Future<Uint8List> payload,
  ) {
    // The queued save reports a failure; this only keeps it from going
    // unhandled while earlier operations run.
    unawaited(payload.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    return _run(() async => _write(prefs, await payload));
  }

  Future<void> update(
    SharedPreferences prefs,
    Map<String, Object?> Function(Map<String, Object?>) change,
  ) => _run(() async {
    final values = change((await _read<Object?>(prefs)).$1.values);
    if (!_valid(values)) throw ArgumentError.value(values, 'values');
    await _write(prefs, await _encode(values));
  });

  Future<void> _write(SharedPreferences prefs, List<int> encoded) async {
    await persist(await _file(), encoded);
    await _removeLegacy(prefs);
  }

  Future<void> clear(SharedPreferences prefs) => _run(() async {
    final file = await _file();
    if (!await file.exists() && !keys.keys.any(prefs.containsKey)) return;
    // A committed tombstone prevents an old preference from reviving on retry.
    await persist(file, utf8.encode('{}'));
    await _removeLegacy(prefs);
    await file.delete();
  });

  static Future<void> _atomicWrite(File file, List<int> contents) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp-$pid-${_sequence++}');
    try {
      await temporary.writeAsBytes(contents, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
