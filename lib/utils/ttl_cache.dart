import 'dart:collection';

/// Bounded in-memory LRU cache where each entry expires after [ttl].
class TtlCache<T> {
  final Duration ttl;
  final int maxEntries;
  final LinkedHashMap<String, _TtlEntry<T>> _entries =
      LinkedHashMap<String, _TtlEntry<T>>();

  TtlCache(this.ttl, {this.maxEntries = 100}) {
    if (maxEntries <= 0) {
      throw ArgumentError.value(
        maxEntries,
        'maxEntries',
        'must be greater than zero',
      );
    }
  }

  T? get(String key) {
    _removeExpired();
    final entry = _entries[key];
    if (entry == null) return null;
    // LinkedHashMap preserves insertion order, so reinserting makes this the
    // most recently used entry.
    _entries
      ..remove(key)
      ..[key] = entry;
    return entry.value;
  }

  void set(String key, T value) {
    _removeExpired();
    _entries.remove(key);
    _entries[key] = _TtlEntry(value, DateTime.now().add(ttl));
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  int get length {
    _removeExpired();
    return _entries.length;
  }

  void _removeExpired() {
    if (_entries.isEmpty) return;
    final now = DateTime.now();
    _entries.removeWhere((_, entry) => !now.isBefore(entry.expiresAt));
  }
}

class _TtlEntry<T> {
  final T value;
  final DateTime expiresAt;
  _TtlEntry(this.value, this.expiresAt);
}
