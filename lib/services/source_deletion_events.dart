import 'package:mornye/utils/logger.dart';

final _log = AppLogger('SourceDeletionEvents');

/// Coordinates file release before deletion and cleanup after confirmed removal.
/// Owners unsubscribe when their lifetime ends.
class SourceDeletionEvents {
  static final instance = SourceDeletionEvents();

  final _listeners = <Object, Future<void> Function(String)>{};
  final _preparations = <Object, Future<void> Function(String)>{};
  final _deletions = <String, Future<bool>>{};

  void Function() subscribe(
    Future<void> Function(String) listener, {
    Future<void> Function(String)? beforeDelete,
  }) {
    final token = Object();
    _listeners[token] = listener;
    if (beforeDelete != null) _preparations[token] = beforeDelete;
    return () {
      _listeners.remove(token);
      _preparations.remove(token);
    };
  }

  bool isDeleting(String source) => _deletions.containsKey(source);

  /// A failed release prevents storage deletion. Only post-delete cleanup may
  /// fail without changing the result of a confirmed removal.
  Future<bool> delete(String source, Future<bool> Function() remove) =>
      _deletions[source] ??=
          Future<bool>(() async {
            for (final entry in Map.of(_preparations).entries) {
              if (_preparations.containsKey(entry.key)) {
                await entry.value(source);
              }
            }
            final deleted = await remove();
            if (deleted) await publish(source);
            return deleted;
          }).whenComplete(() {
            _deletions.remove(source);
          });

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
