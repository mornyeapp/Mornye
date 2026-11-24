import 'dart:async';

import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/together/link_together_deck.dart';
import 'package:mornye/services/link/together/link_together_follower.dart';
import 'package:mornye/services/link/together/link_together_protocol.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkTogether');

int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

/// The computer's side of Play together: it answers the phone's
/// `together/*` ops, carries out its cues while it follows, tells the phone
/// at once about its own player's changes, and turns its own controls into
/// actions for the queue's owner. One phone at a time.
class LinkTogetherHost {
  LinkTogetherHost({
    required LinkTogetherDeck deck,
    required Future<int> Function(Map<String, dynamic> message, String deviceId)
    send,
    void Function(String deviceId)? onStarted,
    void Function()? onChanged,
    int Function()? nowMs,
    LinkTogetherFollower? follower,
    this.ownActionMs = 1500,
    this.transitionMs = 2500,
  }) : _deck = deck,
       _send = send,
       _onStarted = onStarted,
       _onChanged = onChanged,
       _nowMs = nowMs ?? _wallClockMs {
    _follower = follower ?? LinkTogetherFollower(deck: deck, nowMs: _nowMs);
  }

  final LinkTogetherDeck _deck;
  final Future<int> Function(Map<String, dynamic> message, String deviceId)
  _send;
  final void Function(String deviceId)? _onStarted;

  /// Runs when a session starts or ends, after [deviceId] changed.
  final void Function()? _onChanged;
  final int Function() _nowMs;
  late final LinkTogetherFollower _follower;

  /// Player changes this soon after a cue are the cue's own.
  final int ownActionMs;

  /// Near a song's end a change of song is the song ending.
  final int transitionMs;

  String? _session;
  String? _deviceId;
  LinkTogetherRole? _role;
  StreamSubscription<void>? _changes;
  LinkTogetherReport? _lastSeen;
  LinkTogetherReport? _lastSent;
  bool _disposed = false;

  /// The phone in a session, if any.
  String? get deviceId => _deviceId;

  bool get active => _session != null;

  /// Registers the `together/*` ops on [router].
  void register(LinkHostRouter router) {
    router
      ..register(LinkTogetherOps.time, (_) async => report().toJson())
      ..register(LinkTogetherOps.start, _start)
      ..register(LinkTogetherOps.align, _align)
      ..register(LinkTogetherOps.stop, _stop);
  }

  /// The computer's player now, as the phone reads it.
  LinkTogetherReport report() => _deck.read().copyWith(
    session: _session,
    silent: _follower.silent,
    busy: _follower.busy,
    canNudge: _deck.canNudge,
  );

  String _sessionArg(LinkRequest request) {
    final session = request.args['session'];
    if (session is! String || session.isEmpty) {
      throw const LinkException('invalid', 'Missing session');
    }
    return session;
  }

  void _checkSession(LinkRequest request) {
    if (_sessionArg(request) != _session || request.deviceId != _deviceId) {
      throw const LinkException('invalid', 'Not playing together now');
    }
  }

  Future<Object?> _start(LinkRequest request) async {
    final session = _sessionArg(request);
    final role = LinkTogetherRole.values.asNameMap()[request.args['role']];
    if (role == null) throw const LinkException('invalid', 'Unknown role');
    if (_session != null) _end(pause: false);
    _session = session;
    _deviceId = request.deviceId;
    _role = role;
    _deck.begin(follower: role == LinkTogetherRole.follower);
    _lastSeen = report();
    _lastSent = null;
    _changes = _deck.changes.listen((_) => _onChange());
    _onStarted?.call(request.deviceId);
    _onChanged?.call();
    _log.i(
      'Link: together started, this computer '
      '${role == LinkTogetherRole.leader ? 'leads' : 'follows'}',
    );
    return report().toJson();
  }

  Future<Object?> _align(LinkRequest request) async {
    _checkSession(request);
    final nudge = request.args['nudge'];
    if (nudge is Map) {
      final factor = nudge['factor'];
      final duration = nudge['durationMs'];
      if (factor is! num || duration is! num) {
        throw const LinkException('invalid', 'Missing nudge');
      }
      _follower.nudge(
        factor.toDouble().clamp(0.9, 1.1),
        duration.toInt().clamp(0, 30000),
      );
      return const {'ok': true};
    }
    final cue = LinkTogetherCue.fromJson(request.args['rejoin']);
    if (cue == null) throw const LinkException('invalid', 'Missing cue');
    final found = await _follower.rejoin(cue);
    return {'found': found};
  }

  Future<Object?> _stop(LinkRequest request) async {
    _checkSession(request);
    final pause = request.args['pause'] == true;
    _end(pause: pause);
    return const {'ok': true};
  }

  /// The connected phones changed: a session whose phone is not in [ids]
  /// ends, and the computer keeps playing what it has.
  void keepConnected(Set<String> ids) {
    final deviceId = _deviceId;
    if (deviceId != null && !ids.contains(deviceId)) {
      _log.i('Link: together ended, the phone left');
      _end(pause: false);
    }
  }

  void _end({required bool pause}) {
    if (_session == null) return;
    _session = _deviceId = _role = null;
    unawaited(_changes?.cancel());
    _changes = null;
    // A start it waited for happens now, so the music goes on.
    _follower.cancel(resume: !pause);
    _deck.end();
    if (pause) unawaited(_deck.pause());
    if (!_disposed) _onChanged?.call();
  }

  /// Ends Play together from this computer's Devices choices. With
  /// [keepHere] this computer plays on alone and the phone stops; otherwise
  /// the phone plays on and ends the session, which pauses this computer.
  /// False when no session runs or the phone could not be told.
  Future<bool> leave({required bool keepHere}) async {
    final deviceId = _deviceId;
    final session = _session;
    if (deviceId == null || session == null) return false;
    final delivered = await _send({
      'type': LinkTogetherMessages.action,
      'session': session,
      'action': keepHere
          ? LinkTogetherActions.left
          : LinkTogetherActions.leftForPhone,
    }, deviceId);
    if (delivered == 0) return false;
    _log.i(
      'Link: together, ${keepHere ? 'this computer' : 'the phone'} was '
      'chosen here',
    );
    if (keepHere && _session == session) _end(pause: false);
    return true;
  }

  void _onChange() {
    final deviceId = _deviceId;
    final session = _session;
    if (deviceId == null || session == null) return;
    final now = report();
    final seen = _lastSeen;
    _lastSeen = now;
    if (seen != null && _role == LinkTogetherRole.follower) {
      final action = _ownAction(seen, now);
      if (action != null) {
        _log.i('Link: together, this computer\'s controls asked for $action');
        unawaited(
          _send({
            'type': LinkTogetherMessages.action,
            'session': session,
            'action': action,
          }, deviceId),
        );
        if (action == LinkTogetherActions.left) {
          _end(pause: false);
          return;
        }
      }
    }
    final sent = _lastSent;
    if (sent != null && !_differs(sent, now)) return;
    _lastSent = now;
    unawaited(
      _send({
        'type': LinkTogetherMessages.state,
        'session': session,
        'report': now.toJson(),
      }, deviceId),
    );
  }

  bool _differs(LinkTogetherReport before, LinkTogetherReport after) =>
      !linkTogetherSameTrack(before.track, after.track) ||
      before.index != after.index ||
      before.playing != after.playing ||
      before.ready != after.ready ||
      before.silent != after.silent ||
      before.busy != after.busy ||
      before.repeat != after.repeat ||
      (before.positionAt(after.nowMs) - after.positionMs).abs() > 300;

  /// What this computer's own controls did between [before] and [after]
  /// while it follows, or null for a change of its own cues or a song end.
  String? _ownAction(LinkTogetherReport before, LinkTogetherReport after) {
    if (_follower.busy ||
        _follower.silent ||
        after.nowMs - _follower.lastActionMs < ownActionMs) {
      return null;
    }
    if (linkTogetherSameTrack(before.track, after.track)) {
      if (before.playing && !after.playing && after.ready) {
        return LinkTogetherActions.pause;
      }
      if (!before.playing && after.playing) return LinkTogetherActions.play;
      return null;
    }
    if (after.track == null) return null;
    // Where the song before would be by now: a song that ran out moves on
    // by itself.
    final remaining = before.remainingAt(after.nowMs);
    if (remaining == null || remaining < transitionMs) return null;
    // A step through the same queue, which still holds the song before.
    final sameQueue = linkTogetherSameTrack(
      _deck.refAt(before.index),
      before.track,
    );
    if (sameQueue && after.index == before.index + 1) {
      return LinkTogetherActions.next;
    }
    if (sameQueue && after.index == before.index - 1) {
      return LinkTogetherActions.previous;
    }
    return LinkTogetherActions.left;
  }

  void dispose() {
    _disposed = true;
    _end(pause: false);
  }
}
