import 'dart:async';

/// Releases retry delays immediately when their queue item stops waiting.
class DownloadRetryBackoff {
  final Map<String, ({Timer timer, Completer<bool> finished})> _waiters = {};

  Future<bool> wait(String itemId, Duration delay) {
    cancelItem(itemId);
    final finished = Completer<bool>();
    final timer = Timer(delay, () {
      _waiters.remove(itemId);
      finished.complete(true);
    });
    _waiters[itemId] = (timer: timer, finished: finished);
    return finished.future;
  }

  void cancelItem(String itemId) {
    final waiter = _waiters.remove(itemId);
    if (waiter == null) return;
    waiter.timer.cancel();
    waiter.finished.complete(false);
  }

  void cancelAll() {
    for (final itemId in _waiters.keys.toList()) {
      cancelItem(itemId);
    }
  }
}
