import 'dart:async';

import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/lyrics_translation_sharing.dart';
import 'package:mornye/utils/logger.dart';

/// Exchanges completed lyric overlays in both Link directions. Reconnecting
/// asks for the lyrics being viewed, including a result made while offline.
class LinkLyricsTranslations {
  LinkLyricsTranslations({
    required this.sharing,
    required this.send,
    this.peers,
  });

  final LyricsTranslationSharing sharing;
  final FutureOr<void> Function(Map<String, dynamic> message, String? deviceId)
  send;

  /// Desktop only: other phones receive an incoming phone's update too.
  final Iterable<String> Function()? peers;
  final _subscriptions = <StreamSubscription<Object?>>[];
  bool _disposed = false;

  void start() {
    _subscriptions.addAll([
      sharing.outgoing.listen((update) => _send(_message(update))),
      sharing.requests.listen((hash) => _request(hash)),
    ]);
  }

  void connected([String? deviceId]) {
    final hash = sharing.requestedSourceHash;
    if (hash != null) _request(hash, deviceId);
  }

  Map<String, dynamic> _message(SharedLyricsTranslation update) => {
    'type': LinkMessageTypes.lyricsTranslation,
    'translation': update.toJson(),
  };

  void _request(String hash, [String? deviceId]) => _send({
    'type': LinkMessageTypes.lyricsTranslationRequest,
    'sourceHash': hash,
  }, deviceId);

  bool handle(Map<String, dynamic> message, {String? deviceId}) {
    if (_disposed) return false;
    switch (message['type']) {
      case LinkMessageTypes.lyricsTranslationRequest:
        final hash = message['sourceHash'];
        if (isLyricsTranslationHash(hash)) {
          final update = sharing.lookup(hash as String);
          if (update != null) _send(_message(update), deviceId);
        }
        return true;
      case LinkMessageTypes.lyricsTranslation:
        final update = SharedLyricsTranslation.fromJson(message['translation']);
        if (update != null && sharing.receive(update)) {
          for (final peer in peers?.call() ?? const <String>[]) {
            if (peer != deviceId) _send(_message(update), peer);
          }
        }
        return true;
      default:
        return false;
    }
  }

  void _send(Map<String, dynamic> message, [String? deviceId]) {
    if (_disposed) return;
    unawaited(() async {
      try {
        await send(message, deviceId);
      } on Object catch (error) {
        AppLogger('LinkLyrics').w('Could not share translated lyrics: $error');
      }
    }());
  }

  void dispose() {
    _disposed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }
}
