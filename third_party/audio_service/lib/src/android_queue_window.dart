import 'dart:math' as math;

/// A stable slice of the full queue, with extra room for forward playback.
class AndroidQueueWindow<T> {
  static const capacity = 500;
  static const _before = 100;
  static const _edge = 50;

  List<T> _queue = [];
  int _start = 0;

  int get start => _start;

  List<T> get items =>
      _queue.sublist(_start, math.min(_start + capacity, _queue.length));

  void updateQueue(List<T> queue, int? index) {
    _queue = queue;
    moveTo(index);
  }

  bool moveTo(int? index) {
    final previous = _start;
    final maximum = math.max(0, _queue.length - capacity);
    _start = _start.clamp(0, maximum);
    if (index != null && index >= 0 && index < _queue.length) {
      if ((_start > 0 && index < _start + _edge) ||
          (_start < maximum && index >= _start + capacity - _edge)) {
        _start = (index - _before).clamp(0, maximum);
      }
    }
    return previous != _start;
  }
}
