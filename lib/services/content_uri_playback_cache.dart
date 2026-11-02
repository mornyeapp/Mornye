import 'dart:async';
import 'dart:io';

/// Owns SAF playback copies, including copies that finish after invalidation.
/// Transport pins keep active and prepared decks alive until they release them.
class ContentUriPlaybackCache {
  bool ownsPath(String path) =>
      _entries.values.any((entry) => entry.path == path);
  ContentUriPlaybackCache({
    required Future<String?> Function(String) copy,
    required bool Function() isDisposed,
    required bool Function(String) isPinned,
    required void Function(Object) onResolveError,
    required void Function(Object) onDeleteError,
    Future<bool> Function(String)? exists,
    this.maxEntries = 3,
    this.maxBytes = 256 * 1024 * 1024,
  }) : assert(maxEntries > 0),
       assert(maxBytes > 0),
       _copy = copy,
       _isDisposed = isDisposed,
       _isPinned = isPinned,
       _onResolveError = onResolveError,
       _onDeleteError = onDeleteError,
       _exists = exists ?? ((path) => File(path).exists());

  final Future<String?> Function(String) _copy;
  final bool Function() _isDisposed;
  final bool Function(String) _isPinned;
  final void Function(Object) _onResolveError;
  final void Function(Object) _onDeleteError;
  final Future<bool> Function(String) _exists;
  final int maxEntries;
  final int maxBytes;
  final _entries = <String, ({String path, int size})>{};
  final _pending = <String, Future<String?>>{};
  final _pendingDeletes = <String>{};
  bool _closed = false;

  String? cachedPath(String source) => _entries[source]?.path;

  Future<String?> resolve(String source) async {
    if (_closed || _isDisposed()) return null;
    final cached = _entries[source];
    if (cached != null) {
      final exists = await _exists(cached.path);
      if (_closed || _isDisposed()) return null;
      // A file stat can finish after invalidation or a newer provider copy.
      if (_entries[source] != cached) return resolve(source);
      if (exists) return cached.path;
      _entries.remove(source);
    }
    final inFlight = _pending[source];
    if (inFlight != null) return inFlight;

    late final Future<String?> resolution;
    resolution = () async {
      String? path;
      try {
        path = await _copy(source);
        if (path == null || path.isEmpty) return null;
        final size = await File(path).length();
        if (_closed ||
            _isDisposed() ||
            !identical(_pending[source], resolution)) {
          await _discard(path);
          return null;
        }
        _entries.remove(source);
        _entries[source] = (path: path, size: size);
        while (_entries.length > maxEntries ||
            (_entries.length > 1 &&
                _entries.values.fold<int>(0, (sum, entry) => sum + entry.size) >
                    maxBytes)) {
          final oldest = _entries.remove(_entries.keys.first)!;
          unawaited(_discard(oldest.path));
        }
        return path;
      } catch (error) {
        if (path != null && path.isNotEmpty) await _discard(path);
        _onResolveError(error);
        return null;
      }
    }();
    _pending[source] = resolution;
    try {
      return await resolution;
    } finally {
      if (identical(_pending[source], resolution)) _pending.remove(source);
    }
  }

  /// Editing tags waits for an older copy; deleting a source retires its copy
  /// immediately so queue removal never waits for an unavailable provider.
  Future<bool> invalidate(String source, {bool waitForPending = false}) async {
    final pending = waitForPending ? _pending[source] : _pending.remove(source);
    if (waitForPending) await pending;
    final entry = _entries.remove(source);
    if (entry != null) await _discard(entry.path);
    return pending != null;
  }

  Future<void> _discard(String path) async {
    if (_isPinned(path)) {
      _pendingDeletes.add(path);
      return;
    }
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (error) {
      _onDeleteError(error);
    }
  }

  Future<void> releaseUnpinned() async {
    final paths = _pendingDeletes.where((path) => !_isPinned(path)).toList();
    for (final path in paths) {
      _pendingDeletes.remove(path);
      await _discard(path);
    }
  }

  Future<void> dispose() async {
    _closed = true;
    final paths = {
      ..._entries.values.map((entry) => entry.path),
      ..._pendingDeletes,
    };
    _entries.clear();
    _pendingDeletes.clear();
    for (final path in paths) {
      await _discard(path);
    }
    // Pending copies discard their own result when the provider returns.
  }
}
