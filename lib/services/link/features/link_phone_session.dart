import 'dart:async';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/foundation.dart';
import 'package:mornye/services/link/features/link_handoff.dart';
import 'package:mornye/services/link/features/link_phone_player.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/features/link_track_resolver.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkPhoneSession');

/// Opens a link on the phone the way a link shared to the app opens.
typedef LinkOpenUrl = void Function(String url);

/// The phone's side of a session with the paired desktop while it lasts:
/// it reports this phone's player as `player.state` (250 ms after a change
/// and every 15 s), and obeys the desktop's `command` and `open` messages.
class LinkPhoneSession {
  LinkPhoneSession({
    required this.client,
    required this.player,
    required this.refs,
    required this.handoff,
    required this.openUrl,
    int Function()? nowMs,
    this.debounce = const Duration(milliseconds: 250),
    this.heartbeat = const Duration(seconds: 15),
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final LinkClientApi client;
  final LinkPhonePlayer player;
  final LinkTrackRefCache refs;
  final LinkHandoff handoff;
  final LinkOpenUrl openUrl;
  final Duration debounce;
  final Duration heartbeat;
  final int Function() _nowMs;

  final _subscriptions = <StreamSubscription<Object?>>[];
  Timer? _debounceTimer;
  Timer? _heartbeatTimer;
  bool _disposed = false;
  bool _resolving = false;

  /// The queue offset of the last state sent, which `jump` indexes count
  /// from.
  int _windowStart = 0;
  List<MediaItem>? _sentQueue;
  LinkPlayerState? _lastSent;

  @visibleForTesting
  LinkPlayerState? get lastSent => _lastSent;

  void start() {
    _subscriptions
      ..add(client.messages.listen((message) => unawaited(handle(message))))
      ..add(player.changes.listen((_) => _onPlayerChanged()))
      ..add(
        client.connectionStates.listen((connection) {
          if (connection == LinkConnectionState.connected) {
            _lastSent = null;
            _schedule();
          }
        }),
      );
    if (client.connectionState == LinkConnectionState.connected) _schedule();
    _restartHeartbeat();
  }

  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _heartbeatTimer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  void _restartHeartbeat() {
    _heartbeatTimer?.cancel();
    if (_disposed) return;
    _heartbeatTimer = Timer.periodic(heartbeat, (_) => pushState());
  }

  void _schedule() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, pushState);
  }

  void _onPlayerChanged() {
    if (_disposed) return;
    final last = _lastSent;
    final snapshot = player.snapshot;
    if (last == null ||
        !identical(snapshot.queue, _sentQueue) ||
        _differs(last, snapshot)) {
      _schedule();
    }
  }

  /// Whether [next] says something [last] did not, apart from the position
  /// moving on while playing; a seek counts. Position ticks arrive often,
  /// so the queue itself is compared by identity in [_onPlayerChanged].
  bool _differs(LinkPlayerState last, LinkPhoneSnapshot next) {
    final current = next.current;
    final lastIndex = last.index < 0 ? -1 : _windowStart + last.index;
    if (last.track != (current == null ? null : refs.refFor(current)) ||
        lastIndex != (current == null ? -1 : next.index) ||
        last.playing != next.playing ||
        last.shuffle != next.shuffle ||
        last.repeat != next.repeat ||
        last.durationMs != next.durationMs ||
        (last.volume - next.volume).abs() > 0.005) {
      return true;
    }
    return (last.positionAt(_nowMs()) - next.positionMs).abs() > 1500;
  }

  ({LinkPlayerState state, int start}) _build(LinkPhoneSnapshot snapshot) {
    final window = linkQueueWindow(snapshot.queue.length, snapshot.index);
    final queue = [
      for (final item in snapshot.queue.sublist(window.start, window.end))
        refs.refFor(item),
    ];
    final current = snapshot.current;
    return (
      start: window.start,
      state: LinkPlayerState(
        track: current == null ? null : refs.refFor(current),
        playing: snapshot.playing,
        positionMs: snapshot.positionMs,
        durationMs: snapshot.durationMs,
        updatedMs: _nowMs(),
        queue: queue,
        index: current == null ? -1 : snapshot.index - window.start,
        shuffle: snapshot.shuffle,
        repeat: snapshot.repeat,
        volume: snapshot.volume,
      ),
    );
  }

  /// Sends this phone's player now.
  void pushState() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    final snapshot = player.snapshot;
    final built = _build(snapshot);
    _windowStart = built.start;
    _sentQueue = snapshot.queue;
    _lastSent = built.state;
    client.send({
      'type': LinkMessageTypes.playerState,
      'state': built.state.toJson(),
    });
    _restartHeartbeat();
    unawaited(_resolveRefs());
  }

  /// Looks up the ISRCs of the queue sent last; sends again when any of
  /// them changed a ref.
  Future<void> _resolveRefs() async {
    if (_resolving) return;
    _resolving = true;
    try {
      final snapshot = player.snapshot;
      final window = linkQueueWindow(snapshot.queue.length, snapshot.index);
      final changed = await refs.resolveAll(
        snapshot.queue.sublist(window.start, window.end),
      );
      if (changed && !_disposed) _schedule();
    } on Object catch (error) {
      _log.w('Could not look up queue identities: $error');
    } finally {
      _resolving = false;
    }
  }

  /// Applies one message the desktop pushed.
  Future<void> handle(Map<String, dynamic> message) async {
    if (_disposed) return;
    try {
      switch (message['type']) {
        case LinkMessageTypes.command:
          final command = LinkCommand.fromJson(message);
          if (command != null) await apply(command);
        case LinkMessageTypes.open:
          final url = message['url'];
          if (url is String && url.trim().isNotEmpty) openUrl(url.trim());
      }
    } on Object catch (error) {
      _log.w('Could not apply a desktop message: $error');
    }
  }

  /// Runs [command] on the phone's player, as `POST command` does on the
  /// desktop.
  Future<void> apply(LinkCommand command) async {
    final args = command.args;
    switch (command.action) {
      case LinkActions.play:
        await player.play();
      case LinkActions.pause:
        await player.pause();
      case LinkActions.toggle:
        await (player.snapshot.playing ? player.pause() : player.play());
      case LinkActions.next:
        await player.next();
      case LinkActions.previous:
        await player.previous();
      case LinkActions.seek:
        final position = args['positionMs'];
        if (position is num) {
          await player.seek(Duration(milliseconds: position.toInt()));
        }
      case LinkActions.volume:
        final value = args['value'];
        if (value is num) await player.setVolume(value.toDouble().clamp(0, 1));
      case LinkActions.shuffle:
        await player.setShuffle(args['enabled'] == true);
      case LinkActions.repeat:
        final mode = LinkRepeatMode.values.asNameMap()[args['mode']];
        if (mode != null) await player.setRepeat(mode);
      case LinkActions.jump:
        final index = args['index'];
        final length = player.snapshot.queue.length;
        if (index is num) {
          final target = _windowStart + index.toInt();
          if (target >= 0 && target < length) await player.jump(target);
        }
      case LinkActions.playQueue:
        final result = await handoff.play(LinkHandoffQueue.fromJson(args));
        if (result.skipped.isNotEmpty) {
          _log.i(
            'Desktop queue: ${result.skipped.length} tracks are not on this '
            'phone',
          );
        }
      default:
        _log.w('Unknown desktop command ${command.action}');
        return;
    }
    _schedule();
  }
}
