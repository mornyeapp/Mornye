import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/network_offline_saver.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/source_deletion_events.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('NetworkPlaybackCache');

/// One transfer of a network song: its identity and its whole file.
abstract interface class NetworkPlaybackTransfer {
  /// See [NetworkFileDownload.identity].
  Future<String?> identity(String source);

  /// Writes the whole file of [source] to [output]; throws when it ends
  /// early, the transfer is closed, or [progress] throws.
  Future<void> download(
    String source,
    File output, {
    required void Function() checkpoint,
    required void Function(int received, int? total) progress,
  });

  void close();
}

class _StorageTransfer implements NetworkPlaybackTransfer {
  _StorageTransfer(NetworkStorageService storage)
    : _download = NetworkFileDownload(storage);

  final NetworkFileDownload _download;

  @override
  Future<String?> identity(String source) => _download.identity(source);

  @override
  Future<void> download(
    String source,
    File output, {
    required void Function() checkpoint,
    required void Function(int received, int? total) progress,
  }) => _download.download(
    source,
    output,
    checkpoint: checkpoint,
    progress: progress,
  );

  @override
  void close() => _download.close();
}

class _Entry {
  _Entry(this.file, this.size, this.identity, this.verifiedAt);

  final String file;
  final int size;
  final String? identity;

  /// When the server last confirmed [identity]; never persisted, so a copy
  /// from an earlier run is checked once before it plays.
  DateTime? verifiedAt;

  Map<String, Object?> toJson(String source) => {
    'source': source,
    'file': file,
    'size': size,
    'identity': identity,
  };
}

class _Job {
  _Job(this.source, this.transfer);

  final String source;
  final NetworkPlaybackTransfer transfer;
  bool cancelled = false;

  void cancel() {
    cancelled = true;
    transfer.close();
  }

  void check() {
    if (cancelled) throw const _Cancelled();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class _TooLarge implements Exception {
  const _TooLarge();
}

/// Complete local copies of the network songs around the one playing, so
/// the next song opens from disk instead of waiting for the server. Songs
/// download one at a time to a temporary name and appear only once whole,
/// so a partial file never plays. The least recently played copies go
/// first once the cache holds more than [maxBytes] or [maxFiles], never a
/// song still wanted or just handed to the player.
class NetworkPlaybackCache {
  NetworkPlaybackCache({
    Future<Directory> Function()? directory,
    NetworkPlaybackTransfer Function()? transfer,
    bool Function(String source)? cacheable,
    SourceDeletionEvents? connectionRemovals,
    DateTime Function()? now,
    this.maxBytes = 1024 * 1024 * 1024,
    this.maxFiles = 32,
    this.maxFileBytes = 256 * 1024 * 1024,
    this.verifiedFor = const Duration(minutes: 10),
    this.verifyTimeout = const Duration(seconds: 3),
    this.retryAfter = const Duration(minutes: 5),
  }) : _directory = directory ?? _defaultDirectory,
       _transfer =
           transfer ?? (() => _StorageTransfer(NetworkStorageService.instance)),
       _cacheable = cacheable ?? _defaultCacheable,
       _now = now ?? DateTime.now {
    (connectionRemovals ?? NetworkStorageService.instance.connectionRemovals)
        .subscribe(_removeHost);
  }

  static final instance = NetworkPlaybackCache();

  final Future<Directory> Function() _directory;
  final NetworkPlaybackTransfer Function() _transfer;
  final bool Function(String) _cacheable;
  final DateTime Function() _now;
  final int maxBytes, maxFiles, maxFileBytes;

  /// How long a copy plays without asking the server whether it changed.
  final Duration verifiedFor;

  /// How long that question may delay a song before its copy plays as is.
  final Duration verifyTimeout;

  /// How long a song whose download failed waits before another try.
  final Duration retryAfter;

  static const _indexName = 'index.json';

  /// Copies in least recently used order.
  final _entries = <String, _Entry>{};
  final _failed = <String, DateTime>{};

  /// Songs larger than [maxFileBytes], which stream for the rest of the run.
  final _tooLarge = <String>{};
  final _waiters = <String, Completer<bool>>{};

  /// Bumped by [invalidate], so a download that started before it is
  /// discarded instead of stored.
  final _epochs = <String, int>{};
  final _recent = <String>[];
  List<String> _wanted = const [];
  _Job? _active;
  Future<void>? _loading;
  Future<void> _saving = Future.value();
  String? _root;
  bool _pumping = false;
  bool _unavailable = false;

  static Future<Directory> _defaultDirectory() async => Directory(
    p.join((await getApplicationCacheDirectory()).path, 'network_playback'),
  );

  static bool _defaultCacheable(String source) =>
      canSaveNetworkOfflineSource(source) && _extension(source).isNotEmpty;

  /// The lower-case file extension of [source] with its dot, or empty when
  /// it has none a player can use as a type hint.
  static String _extension(String source) {
    final name = Uri.tryParse(source)?.pathSegments.lastOrNull ?? '';
    final dot = name.lastIndexOf('.');
    final suffix = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,10}$').hasMatch(suffix) ? '.$suffix' : '';
  }

  /// Whether [path] is one of these copies.
  bool owns(String path) {
    final root = _root;
    return root != null && p.isWithin(root, path);
  }

  /// The complete copy of [source], or null when there is none yet or the
  /// server reports that its file changed.
  Future<String?> lookup(String source) async {
    if (_unavailable || !_cacheable(source)) return null;
    try {
      await _ensureLoaded();
    } catch (_) {
      return null;
    }
    final entry = _entries[source];
    if (entry == null) return null;
    final file = File(p.join(_root!, entry.file));
    if (!await file.exists() || await file.length() != entry.size) {
      await _drop(source, entry);
      return null;
    }
    final verifiedAt = entry.verifiedAt;
    if (verifiedAt == null || _now().difference(verifiedAt) > verifiedFor) {
      final epoch = _epochs[source] ?? 0;
      final transfer = _transfer();
      String? current;
      var known = false;
      try {
        current = await transfer.identity(source).timeout(verifyTimeout);
        known = true;
      } catch (_) {
        // A server out of reach cannot have a newer file to offer.
      } finally {
        transfer.close();
      }
      if (!identical(_entries[source], entry) ||
          (_epochs[source] ?? 0) != epoch) {
        return null;
      }
      if (known) {
        if (current == null || current != entry.identity) {
          await _drop(source, entry);
          unawaited(_pump());
          return null;
        }
        entry.verifiedAt = _now();
      } else if (entry.identity == null) {
        return null;
      }
    }
    _entries
      ..remove(source)
      ..[source] = entry;
    _recent
      ..remove(source)
      ..add(source);
    if (_recent.length > 2) _recent.removeAt(0);
    _save();
    return file.path;
  }

  /// Keeps copies of [sources], in order of priority, downloading the ones
  /// missing one at a time. A download of a song no longer listed stops.
  void want(List<String> sources) {
    if (_unavailable) return;
    final wanted = <String>[];
    for (final source in sources) {
      if (_cacheable(source) && !wanted.contains(source)) wanted.add(source);
    }
    if (wanted.isEmpty && _wanted.isEmpty && _active == null) return;
    _wanted = List.unmodifiable(wanted);
    final active = _active;
    if (active != null && !wanted.contains(active.source)) active.cancel();
    for (final source in _waiters.keys.toList()) {
      if (!wanted.contains(source)) _complete(source, false);
    }
    unawaited(_pump());
  }

  /// Whether [source] has a complete copy within [within]. False at once
  /// when it is not wanted or its download failed recently.
  Future<bool> ready(String source, Duration within) async {
    if (_unavailable) return false;
    try {
      await _ensureLoaded();
    } catch (_) {
      return false;
    }
    if (_entries.containsKey(source)) return true;
    if (!_wanted.contains(source) || _failedRecently(source)) return false;
    if (within <= Duration.zero) return false;
    final waiter = _waiters.putIfAbsent(source, Completer<bool>.new);
    return waiter.future.timeout(within, onTimeout: () => false);
  }

  /// Forgets the copy of [source], as after its file was edited or deleted.
  /// A song still wanted downloads again.
  Future<void> invalidate(String source) async {
    _epochs[source] = (_epochs[source] ?? 0) + 1;
    _failed.remove(source);
    _tooLarge.remove(source);
    final active = _active;
    if (active != null && active.source == source) active.cancel();
    if (_loading == null || _unavailable) return;
    try {
      await _ensureLoaded();
    } catch (_) {
      return;
    }
    final entry = _entries[source];
    if (entry != null) await _drop(source, entry);
    unawaited(_pump());
  }

  Future<void> _removeHost(String id) async {
    for (final source in [..._entries.keys, ?_active?.source]) {
      if (Uri.tryParse(source)?.host == id) await invalidate(source);
    }
  }

  bool _failedRecently(String source) {
    if (_tooLarge.contains(source)) return true;
    final failedAt = _failed[source];
    return failedAt != null && _now().difference(failedAt) < retryAfter;
  }

  void _complete(String source, bool ready) {
    final waiter = _waiters.remove(source);
    if (waiter != null && !waiter.isCompleted) waiter.complete(ready);
  }

  Future<void> _ensureLoaded() => _loading ??= _load();

  /// Reads the index and deletes every file it does not list, such as the
  /// temporary file of a download that stopped with the app.
  Future<void> _load() async {
    try {
      final root = await _directory();
      await root.create(recursive: true);
      _root = root.path;
      final index = File(p.join(root.path, _indexName));
      final kept = <String>{};
      if (await index.exists()) {
        try {
          final json = jsonDecode(await index.readAsString()) as Map;
          for (final row in json['entries'] as List) {
            final source = (row as Map)['source'] as String;
            final name = row['file'] as String;
            final size = (row['size'] as num).toInt();
            final file = File(p.join(root.path, name));
            if (p.basename(name) != name ||
                !await file.exists() ||
                await file.length() != size) {
              continue;
            }
            _entries.remove(source);
            _entries[source] = _Entry(
              name,
              size,
              row['identity'] as String?,
              null,
            );
            kept.add(name);
          }
        } catch (error) {
          _log.w('Network playback index was unreadable: $error');
          _entries.clear();
          kept.clear();
        }
      }
      await for (final entity in root.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name == _indexName || kept.contains(name)) continue;
        try {
          await entity.delete(recursive: true);
        } on FileSystemException {
          // Still open elsewhere; the next start removes it.
        }
      }
      _save();
    } catch (_) {
      _unavailable = true;
      for (final source in _waiters.keys.toList()) {
        _complete(source, false);
      }
      rethrow;
    }
  }

  void _save() {
    final root = _root;
    if (root == null) return;
    final rows = [
      for (final MapEntry(:key, :value) in _entries.entries) value.toJson(key),
    ];
    _saving = _saving.then((_) async {
      final temp = File(p.join(root, '$_indexName.tmp'));
      try {
        await temp.writeAsString(jsonEncode({'entries': rows}), flush: true);
        await temp.rename(p.join(root, _indexName));
      } catch (error) {
        _log.w('Network playback index was not saved: $error');
      }
    });
  }

  /// Removes [entry] from the index. A file the player still holds open on
  /// Windows stays until the next start.
  Future<void> _drop(String source, _Entry entry) async {
    if (identical(_entries[source], entry)) _entries.remove(source);
    _save();
    try {
      await File(p.join(_root!, entry.file)).delete();
    } on FileSystemException {
      // Gone already, or still open.
    }
  }

  Future<void> _pump() async {
    if (_pumping || _unavailable) return;
    _pumping = true;
    try {
      await _ensureLoaded();
      while (true) {
        final source = _wanted
            .where((s) => !_entries.containsKey(s) && !_failedRecently(s))
            .firstOrNull;
        if (source == null) break;
        await _download(source);
      }
    } catch (error) {
      _log.w('Network playback cache unavailable: $error');
    } finally {
      _pumping = false;
    }
    for (final source in _waiters.keys.toList()) {
      if (!_wanted.contains(source) ||
          _entries.containsKey(source) ||
          _failedRecently(source)) {
        _complete(source, _entries.containsKey(source));
      }
    }
  }

  Future<void> _download(String source) async {
    final job = _Job(source, _transfer());
    _active = job;
    final epoch = _epochs[source] ?? 0;
    final root = _root!;
    final temp = File(
      p.join(root, '${sha256.convert(utf8.encode(source))}.part'),
    );
    try {
      String? identity;
      try {
        identity = await job.transfer.identity(source);
      } catch (_) {
        // Some servers refuse HEAD; such a copy plays only while fresh.
        job.check();
      }
      job.check();
      // The folder may have been cleared with the app cache meanwhile.
      await Directory(root).create(recursive: true);
      await job.transfer.download(
        source,
        temp,
        checkpoint: job.check,
        progress: (received, total) {
          if ((total ?? received) > maxFileBytes) throw const _TooLarge();
        },
      );
      job.check();
      final size = await temp.length();
      job.check();
      if ((_epochs[source] ?? 0) != epoch) throw const _Cancelled();
      // A new name for each version keeps a copy the player holds open
      // from blocking its replacement.
      final version = identity ?? '${_now().microsecondsSinceEpoch}';
      final key = sha256.convert(utf8.encode('$source\n$version'));
      final name = '$key${_extension(source)}';
      await temp.rename(p.join(root, name));
      if (job.cancelled || (_epochs[source] ?? 0) != epoch) {
        await _deleteQuietly(File(p.join(root, name)));
        throw const _Cancelled();
      }
      final previous = _entries.remove(source);
      if (previous != null && previous.file != name) {
        await _deleteQuietly(File(p.join(root, previous.file)));
      }
      _entries[source] = _Entry(name, size, identity, _now());
      _failed.remove(source);
      await _evict();
      _save();
      _complete(source, true);
    } on _Cancelled {
      await _deleteQuietly(temp);
      if (!_wanted.contains(source)) _complete(source, false);
    } catch (error) {
      if (job.cancelled) {
        await _deleteQuietly(temp);
        if (!_wanted.contains(source)) _complete(source, false);
      } else {
        if (error is _TooLarge) {
          _tooLarge.add(source);
        } else {
          _log.w('Network song was not cached: ${error.runtimeType}');
          _failed[source] = _now();
        }
        await _deleteQuietly(temp);
        _complete(source, false);
      }
    } finally {
      job.transfer.close();
      if (identical(_active, job)) _active = null;
    }
  }

  /// Drops the least recently used copies over the bounds, never one that
  /// is wanted or was just handed to the player.
  Future<void> _evict() async {
    var bytes = _entries.values.fold<int>(0, (sum, entry) => sum + entry.size);
    final kept = {..._wanted, ..._recent};
    for (final source in _entries.keys.toList()) {
      if (bytes <= maxBytes && _entries.length <= maxFiles) break;
      if (kept.contains(source)) continue;
      final entry = _entries[source]!;
      try {
        await File(p.join(_root!, entry.file)).delete();
      } on FileSystemException {
        if (await File(p.join(_root!, entry.file)).exists()) continue;
      }
      _entries.remove(source);
      bytes -= entry.size;
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Never written, or already removed.
    }
  }
}
