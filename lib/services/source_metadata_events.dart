import 'package:mornye/utils/logger.dart';

/// Confirmed tag changes, shared by playback and already-open details.
/// A failed reader must not turn a successful file edit into a failed job.
class SourceMetadataEvents {
  static final instance = SourceMetadataEvents();
  final _listeners = <Object, Future<void> Function(String)>{};

  void Function() subscribe(Future<void> Function(String) listener) {
    final token = Object();
    _listeners[token] = listener;
    return () => _listeners.remove(token);
  }

  Future<void> publish(String source) async {
    for (final entry in Map.of(_listeners).entries) {
      if (!_listeners.containsKey(entry.key)) continue;
      try {
        await entry.value(source);
      } catch (error) {
        AppLogger('SourceMetadata').w('Could not refresh changed tags: $error');
      }
    }
  }
}
