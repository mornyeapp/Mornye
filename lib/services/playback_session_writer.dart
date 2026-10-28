import 'package:mornye/services/app_state_database.dart';

/// Owns ordered session writes and the revision of the persisted queue.
/// Position updates serialize the queue only when it changed or the stored
/// row disappeared; transport and queue ordering remain with the player.
class PlaybackSessionWriter {
  PlaybackSessionWriter({
    required AppStateDatabase database,
    required void Function(Object) onError,
  }) : _database = database,
       _onError = onError;

  final AppStateDatabase _database;
  final void Function(Object) _onError;
  Future<void> _tail = Future<void>.value();
  int _queueRevision = 0;
  int _scheduledRevision = -1;
  int _persistedRevision = -1;

  int get queueRevision => _queueRevision;

  void queueChanged() => _queueRevision++;

  void queueRestored({required bool needsRewrite}) {
    queueChanged();
    _scheduledRevision = _persistedRevision = needsRewrite
        ? -1
        : _queueRevision;
  }

  Future<void> clear({Map<String, dynamic>? resumeMedia}) {
    _scheduledRevision = _persistedRevision = -1;
    return _enqueue(
      resumeMedia == null
          ? _database.clearPlaybackSession
          : () => _database.archivePlaybackSession(resumeMedia),
    );
  }

  Future<void> persist({
    required List<Map<String, dynamic>> Function() serializeQueue,
    required int index,
    required Duration position,
    required bool shuffle,
    required String repeatMode,
  }) {
    final revision = _queueRevision;
    final positionMs = position.inMilliseconds;
    Map<String, dynamic> snapshot(List<Map<String, dynamic>> media) => {
      'version': 2,
      'media': media,
      'index': index,
      'positionMs': positionMs,
      'shuffle': shuffle,
      'repeat': repeatMode,
    };

    if (_scheduledRevision != revision) {
      // Capture before enqueueing: the live queue may change while an older
      // write is pending, but its matching index must never change with it.
      final session = snapshot(serializeQueue());
      _scheduledRevision = revision;
      return _enqueue(() async {
        try {
          await _database.savePlaybackSession(session);
          _persistedRevision = revision;
        } catch (_) {
          if (_scheduledRevision == revision) {
            _scheduledRevision = _persistedRevision;
          }
          rethrow;
        }
      });
    }

    return _enqueue(() async {
      final updated = await _database.updatePlaybackSessionState(
        index: index,
        positionMs: positionMs,
        shuffle: shuffle,
        repeatMode: repeatMode,
      );
      if (updated || _queueRevision != revision) return;

      // Recreate a missing row only while this scalar snapshot still belongs
      // to the live queue. A newer full write owns recovery after a change.
      await _database.savePlaybackSession(snapshot(serializeQueue()));
      _persistedRevision = revision;
    });
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    return _tail = _tail.then((_) async {
      try {
        await operation();
      } catch (error) {
        _onError(error);
      }
    });
  }
}
