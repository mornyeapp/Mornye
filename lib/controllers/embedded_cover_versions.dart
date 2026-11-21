import 'package:flutter/foundation.dart';

/// Tells the rows that show one file when its embedded cover changes, so a
/// new cover rebuilds those rows and no others.
class EmbeddedCoverVersions {
  EmbeddedCoverVersions({this.maxCallbacks = 1000});

  /// How many callbacks [callbackFor] remembers.
  final int maxCallbacks;

  final _listeners = <String, List<VoidCallback>>{};
  // Insertion ordered, so the first key is the one used longest ago.
  final _callbacks = <String, VoidCallback>{};
  int _version = 0;

  /// Changes when the cover of the file at [path] does. Two results for one
  /// path are equal, so a rebuilt row keeps its subscription.
  ValueListenable<int> of(String path) => _PathVersion(this, path);

  /// Rebuilds the rows of [paths], or every row when [paths] is null.
  void bump([Iterable<String>? paths]) {
    _version++;
    for (final path in paths ?? _listeners.keys.toList(growable: false)) {
      final listeners = _listeners[path];
      if (listeners == null) continue;
      for (final listener in List.of(listeners)) {
        if (listeners.contains(listener)) listener();
      }
    }
  }

  /// A callback for [path] that is the same object on every build, for a
  /// resolver that keeps its callbacks in a set.
  VoidCallback callbackFor(String path, void Function(String path) onChanged) {
    final callback = _callbacks.remove(path) ?? () => onChanged(path);
    _callbacks[path] = callback;
    if (_callbacks.length > maxCallbacks) {
      _callbacks.remove(_callbacks.keys.first);
    }
    return callback;
  }
}

class _PathVersion implements ValueListenable<int> {
  const _PathVersion(this._owner, this._path);

  final EmbeddedCoverVersions _owner;
  final String _path;

  @override
  int get value => _owner._version;

  @override
  void addListener(VoidCallback listener) =>
      (_owner._listeners[_path] ??= []).add(listener);

  @override
  void removeListener(VoidCallback listener) {
    final listeners = _owner._listeners[_path];
    if (listeners == null) return;
    listeners.remove(listener);
    if (listeners.isEmpty) _owner._listeners.remove(_path);
  }

  @override
  bool operator ==(Object other) =>
      other is _PathVersion &&
      identical(other._owner, _owner) &&
      other._path == _path;

  @override
  int get hashCode => Object.hash(_owner, _path);
}
