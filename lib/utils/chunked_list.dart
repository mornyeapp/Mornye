import 'dart:collection';

/// Immutable indexed storage for frequent sparse updates. Each update copies
/// the chunk directory and only the affected 64-element chunks, without
/// retaining a chain of previous snapshots.
class ChunkedList<T> extends ListBase<T> {
  static const _chunkSize = 64;
  final List<List<T>> _chunks;
  final int _length;
  final int _headOffset;

  ChunkedList._(this._chunks, this._length, [this._headOffset = 0]);

  factory ChunkedList.from(List<T> items) {
    if (items is ChunkedList<T>) return items;
    return ChunkedList._([
      for (var start = 0; start < items.length; start += _chunkSize)
        List<T>.unmodifiable(
          items.getRange(start, (start + _chunkSize).clamp(0, items.length)),
        ),
    ], items.length);
  }

  ChunkedList<T> updated(Map<int, T> changes) {
    if (changes.isEmpty) return this;
    final chunks = List<List<T>>.of(_chunks);
    final copied = <int>{};
    for (final entry in changes.entries) {
      RangeError.checkValidIndex(entry.key, this);
      final shifted = entry.key + _headOffset;
      final chunk = shifted ~/ _chunkSize;
      final local = chunk == 0 ? entry.key : shifted % _chunkSize;
      if (copied.add(chunk)) chunks[chunk] = List<T>.of(chunks[chunk]);
      chunks[chunk][local] = entry.value;
    }
    return ChunkedList._(chunks, _length, _headOffset);
  }

  ChunkedList<T> withoutAt(int index) {
    RangeError.checkValidIndex(index, this);
    if (_length == 1) return ChunkedList._(const [], 0, 0);
    final shifted = index + _headOffset;
    final chunk = shifted ~/ _chunkSize;
    final chunks = List<List<T>>.of(_chunks);
    if (chunk == 0) {
      final first = List<T>.of(chunks[0])..removeAt(index);
      if (chunks.length == 1) {
        return ChunkedList._([first], _length - 1, 0);
      }
      if (first.isEmpty) {
        chunks.removeAt(0);
        return ChunkedList._(chunks, _length - 1, 0);
      }
      chunks[0] = first;
      return ChunkedList._(chunks, _length - 1, _headOffset + 1);
    }
    final local = shifted % _chunkSize;
    if (chunk == chunks.length - 1) {
      final last = List<T>.of(chunks[chunk])..removeAt(local);
      if (last.isEmpty) {
        chunks.removeLast();
      } else {
        chunks[chunk] = last;
      }
      return ChunkedList._(chunks, _length - 1, _headOffset);
    }
    for (var c = chunk; c < chunks.length; c++) {
      chunks[c] = List<T>.of(chunks[c]);
    }
    chunks[chunk].removeAt(local);
    for (var c = chunk; c < chunks.length - 1; c++) {
      chunks[c].add(chunks[c + 1].removeAt(0));
    }
    if (chunks.last.isEmpty) chunks.removeLast();
    return ChunkedList._(chunks, _length - 1, _headOffset);
  }

  @override
  int get length => _length;

  @override
  set length(int value) => throw UnsupportedError('Immutable list');

  @override
  T operator [](int index) {
    RangeError.checkValidIndex(index, this);
    final shifted = index + _headOffset;
    final chunk = shifted ~/ _chunkSize;
    return _chunks[chunk][chunk == 0 ? index : shifted % _chunkSize];
  }

  @override
  void operator []=(int index, T value) =>
      throw UnsupportedError('Immutable list');
}
