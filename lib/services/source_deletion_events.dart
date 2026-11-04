import 'package:mornye/utils/logger.dart';

final _log = AppLogger('SourceDeletionEvents');

/// Coordinates storage deletion with active playback before the file is
/// removed. Owners unsubscribe when their lifetime ends.
class SourceDeletionEvents {
  static final instance = SourceDeletionEvents();

  final _beforeDeleteListeners = <Object, Future<void> Function(String)>{};
  final _cancelledListeners = <Object, Future<void> Function(String)>{};
  final _listeners = <Object, Future<void> Function(String)>{};

  void Function() subscribeBeforeDeletion(
    Future<void> Function(String) listener,
  ) {
    final token = Object();
    _beforeDeleteListeners[token] = listener;
    return () {
      _beforeDeleteListeners.remove(token);
    };
  }

  void Function() subscribeDeletionCancelled(
    Future<void> Function(String) listener,
  ) {
    final token = Object();
    _cancelledListeners[token] = listener;
    return () {
      _cancelledListeners.remove(token);
    };
  }

  /// Lets active playback release a source before storage removes it.
  ///
  /// Preparation errors propagate so a file is never deleted while a player
  /// that owns it could not be detached.
  Future<void> prepareDeletion(String source) async {
    for (final entry in Map.of(_beforeDeleteListeners).entries) {
      if (!_beforeDeleteListeners.containsKey(entry.key)) continue;
      await entry.value(source);
    }
  }

  /// Restores playback participants when storage rejects or cannot complete
  /// a deletion.
  Future<void> cancelDeletion(String source) async {
    for (final entry in Map.of(_cancelledListeners).entries) {
      if (!_cancelledListeners.containsKey(entry.key)) continue;
      try {
        await entry.value(source);
      } catch (error) {
        _log.w('Could not restore playback after cancelled deletion: $error');
      }
    }
  }

  void Function() subscribe(Future<void> Function(String) listener) {
    final token = Object();
    _listeners[token] = listener;
    return () {
      _listeners.remove(token);
    };
  }

  Future<void> publish(String source) async {
    for (final entry in Map.of(_listeners).entries) {
      if (!_listeners.containsKey(entry.key)) continue;
      try {
        await entry.value(source);
      } catch (error) {
        _log.w('Could not clean up a deleted source: $error');
      }
    }
  }
}
