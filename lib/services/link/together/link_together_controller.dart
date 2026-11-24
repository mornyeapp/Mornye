import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/link/features/link_handoff.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/services/link/features/link_remote_playback.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/together/link_together_coordinator.dart';
import 'package:mornye/services/link/together/link_together_deck.dart';
import 'package:mornye/services/link/together/link_together_protocol.dart';
import 'package:mornye/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('LinkTogether');

enum LinkTogetherPhase { idle, starting, active }

/// How a start of Play together went.
enum LinkTogetherStart { started, nothingPlaying, needsUpdate, failed }

/// Play together on this phone: whether it runs, which device owns the
/// queue, and the timing adjustment for the paired computer.
@immutable
class LinkTogetherState {
  const LinkTogetherState({
    this.phase = LinkTogetherPhase.idle,
    this.phoneLeads = true,
    this.shiftMs = 0,
  });

  final LinkTogetherPhase phase;

  /// The phone owns the queue and the computer follows it.
  final bool phoneLeads;

  /// How much later this phone plays than the computer, in milliseconds;
  /// negative plays it earlier, as for Bluetooth headphones.
  final int shiftMs;

  /// Starting or running: both devices play, and the "one player at a
  /// time" rules leave them alone.
  bool get active => phase != LinkTogetherPhase.idle;

  LinkTogetherState copyWith({
    LinkTogetherPhase? phase,
    bool? phoneLeads,
    int? shiftMs,
  }) => LinkTogetherState(
    phase: phase ?? this.phase,
    phoneLeads: phoneLeads ?? this.phoneLeads,
    shiftMs: shiftMs ?? this.shiftMs,
  );
}

/// Starts and ends Play together with the paired computer, and keeps its
/// timing adjustment per computer. The coordinator does the timing; this
/// wires it to the Link session, the player and the Devices choices.
class LinkPlayTogether extends Notifier<LinkTogetherState> {
  static const maxShiftMs = 1000;

  static String shiftKey(String serverId) => 'link_together_shift_$serverId';

  LinkClientApi? _client;
  LinkTogetherCoordinator? _coordinator;
  LinkTogetherDeck? _deck;
  String? _session;
  final _subscriptions = <StreamSubscription<Object?>>[];
  int _generation = 0;

  @override
  LinkTogetherState build() {
    final client = _client = ref.watch(linkPhoneClientProvider);
    ref.onDispose(() => _teardown(resume: true));
    if (client != null) unawaited(_restoreShift(client.server.serverId));
    return const LinkTogetherState();
  }

  Future<void> _restoreShift(String serverId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt(shiftKey(serverId));
      if (saved != null &&
          ref.mounted &&
          _client?.server.serverId == serverId) {
        state = state.copyWith(shiftMs: saved.clamp(-maxShiftMs, maxShiftMs));
      }
    } on Object catch (error) {
      _log.w('Could not read the Play together timing: $error');
    }
  }

  /// Sets the timing adjustment and remembers it for this computer.
  Future<void> setShift(int shiftMs) async {
    final value = shiftMs.clamp(-maxShiftMs, maxShiftMs);
    if (value == state.shiftMs) return;
    state = state.copyWith(shiftMs: value);
    _log.i('Link: together, timing set to ${value}ms');
    _coordinator?.shiftChanged();
    final serverId = _client?.server.serverId;
    if (serverId == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(shiftKey(serverId), value);
    } on Object catch (error) {
      _log.w('Could not save the Play together timing: $error');
    }
  }

  /// Which device owns the queue: the one playing, else the one the player
  /// screens show, else whichever has a song. Null when neither has one.
  @visibleForTesting
  static bool? phoneLeadsFor({
    required LinkTogetherReport phone,
    required LinkTogetherReport desktop,
    required bool onDesktop,
  }) {
    final phonePlays = phone.playing && phone.track != null;
    final desktopPlays = desktop.playing && desktop.track != null;
    if (phonePlays != desktopPlays) return phonePlays;
    final shown = onDesktop ? desktop : phone;
    if (shown.track != null) return !onDesktop;
    final other = onDesktop ? phone : desktop;
    if (other.track != null) return onDesktop;
    return null;
  }

  static String _newSession() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// Starts playing on this phone and the paired computer at once.
  Future<LinkTogetherStart> start() async {
    final client = _client;
    final handoff = ref.read(linkHandoffProvider);
    if (client == null ||
        handoff == null ||
        state.active ||
        client.connectionState != LinkConnectionState.connected) {
      return LinkTogetherStart.failed;
    }
    final generation = ++_generation;
    final session = _newSession();
    final peer = LinkClientTogetherPeer(client, session);
    final clock = LinkTogetherCoordinator.linkTogetherClock();
    final deck = ref.read(linkTogetherPhoneDeckProvider);
    var started = false;
    state = state.copyWith(phase: LinkTogetherPhase.starting);
    _log.i('Link: together, starting');
    Future<LinkTogetherStart> abort(LinkTogetherStart outcome) async {
      if (generation != _generation) return LinkTogetherStart.failed;
      _log.i('Link: together did not start (${outcome.name})');
      _teardown();
      if (ref.mounted) state = state.copyWith(phase: LinkTogetherPhase.idle);
      if (started) await _post(client, session, pause: false);
      return outcome;
    }

    try {
      final desktop = await linkTogetherMeasureClock(peer, clock);
      if (generation != _generation) return LinkTogetherStart.failed;
      if (desktop == null) return await abort(LinkTogetherStart.failed);
      final phoneLeads = phoneLeadsFor(
        phone: deck.read(),
        desktop: desktop,
        onDesktop: ref.read(linkPlaysOnDesktopProvider),
      );
      if (phoneLeads == null) {
        return await abort(LinkTogetherStart.nothingPlaying);
      }
      _log.i(
        'Link: together, the ${phoneLeads ? 'phone' : 'computer'} owns '
        'the queue',
      );
      if (phoneLeads) {
        // The computer loads the phone's queue paused at its position; the
        // first cue then starts it in step. Done before the session starts,
        // so the computer does not take the new queue for its own pick.
        final shared = await handoff.shareQueueWithDesktop();
        if (generation != _generation) return LinkTogetherStart.failed;
        if (shared == null) {
          return await abort(LinkTogetherStart.nothingPlaying);
        }
        if (!shared.started) return await abort(LinkTogetherStart.failed);
      }
      final reply = LinkTogetherReport.fromJson(
        await client.post(LinkTogetherOps.start, {
          'session': session,
          'role':
              (phoneLeads ? LinkTogetherRole.follower : LinkTogetherRole.leader)
                  .name,
        }),
      );
      started = true;
      if (generation != _generation) {
        // Ended while the computer started its side.
        await _post(client, session, pause: false);
        return LinkTogetherStart.failed;
      }
      _session = session;
      _deck = deck..begin(follower: !phoneLeads);
      _listen(client, session);
      state = state.copyWith(phoneLeads: phoneLeads);
      if (!phoneLeads) {
        if (!await _loadDesktopQueue(client, handoff)) {
          return await abort(LinkTogetherStart.failed);
        }
        if (generation != _generation) return LinkTogetherStart.failed;
        ref.read(linkPlaysOnDesktopProvider.notifier).set(true);
      }
      _coordinator = LinkTogetherCoordinator(
        phoneLeads: phoneLeads,
        phone: deck,
        desktop: peer,
        clock: clock,
        shiftMs: () => ref.mounted ? state.shiftMs : 0,
        onEnded: _onEnded,
        onMissing: (_) => _resend(phoneLeads),
      )..start(reply);
      state = state.copyWith(phase: LinkTogetherPhase.active);
      _log.i('Link: together started');
      return LinkTogetherStart.started;
    } on LinkException catch (error) {
      _log.w('Link: together could not start: $error');
      return abort(
        error.code == 'not_found'
            ? LinkTogetherStart.needsUpdate
            : LinkTogetherStart.failed,
      );
    } on Object catch (error) {
      _log.w('Link: together could not start: $error');
      return abort(LinkTogetherStart.failed);
    }
  }

  /// Ends Play together by choosing one device: [onPhone] keeps this phone
  /// playing and pauses the computer, otherwise the computer goes on and
  /// this phone pauses and shows it.
  Future<void> stop({required bool onPhone}) async {
    if (!state.active) return;
    final client = _client;
    final session = _session;
    final deck = _deck;
    _teardown();
    state = state.copyWith(phase: LinkTogetherPhase.idle);
    _log.i(
      'Link: together ended on ${onPhone ? 'this phone' : 'the computer'}',
    );
    if (client != null && session != null) {
      await _post(client, session, pause: onPhone);
    }
    if (!ref.mounted) return;
    if (!onPhone) await deck?.pause();
    if (ref.mounted) {
      ref.read(linkPlaysOnDesktopProvider.notifier).set(!onPhone);
    }
  }

  void _onEnded(LinkTogetherEnd end) {
    final client = _client;
    final session = _session;
    final deck = _deck;
    _teardown(resume: end == LinkTogetherEnd.disconnected);
    if (!ref.mounted) return;
    state = state.copyWith(phase: LinkTogetherPhase.idle);
    final playsOnDesktop = ref.read(linkPlaysOnDesktopProvider.notifier);
    switch (end) {
      case LinkTogetherEnd.disconnected:
        // Both go on alone; this phone shows its own player again.
        playsOnDesktop.set(false);
      case LinkTogetherEnd.leftOnPhone:
        if (client != null && session != null) {
          unawaited(_post(client, session, pause: true));
        }
        playsOnDesktop.set(false);
      case LinkTogetherEnd.leftOnDesktop:
        unawaited(deck?.pause());
        playsOnDesktop.set(true);
    }
  }

  void _listen(LinkClientApi client, String session) {
    _subscriptions
      ..add(
        client.messages.listen((message) {
          if (message['session'] != session) return;
          final coordinator = _coordinator;
          if (coordinator == null) return;
          switch (message['type']) {
            case LinkTogetherMessages.state:
              final report = LinkTogetherReport.fromJson(message['report']);
              if (report != null) coordinator.onDesktopReport(report);
            case LinkTogetherMessages.action:
              final action = message['action'];
              if (action is String) {
                unawaited(coordinator.onDesktopAction(action));
              }
          }
        }),
      )
      ..add(
        client.connectionStates.listen((connection) {
          if (connection != LinkConnectionState.connected) {
            _coordinator?.disconnected();
          }
        }),
      );
  }

  /// Gives the follower the leader's queue again, as after songs were added
  /// to the leader's queue.
  Future<bool> _resend(bool phoneLeads) async {
    final client = _client;
    final handoff = ref.mounted ? ref.read(linkHandoffProvider) : null;
    if (client == null || handoff == null) return false;
    try {
      if (phoneLeads) {
        return (await handoff.shareQueueWithDesktop())?.started ?? false;
      }
      return await _loadDesktopQueue(client, handoff);
    } on Object catch (error) {
      _log.w('Link: together could not send the queue again: $error');
      return false;
    }
  }

  /// Loads the computer's queue on this phone, paused, without its saved
  /// choices; songs this phone can neither find nor stream stay out.
  static Future<bool> _loadDesktopQueue(
    LinkClientApi client,
    LinkHandoff handoff,
  ) async {
    final current = LinkHandoffQueue.fromJson(
      await client.get(LinkOps.handoffCurrent),
    );
    if (current.queue.isEmpty) return false;
    final result = await handoff.play(
      LinkHandoffQueue(
        queue: current.queue,
        index: current.index,
        positionMs: current.positionMs,
        playing: false,
        shuffle: current.shuffle,
        repeat: current.repeat,
      ),
    );
    return result.started;
  }

  static Future<void> _post(
    LinkClientApi client,
    String session, {
    required bool pause,
  }) async {
    try {
      await client.post(LinkTogetherOps.stop, {
        'session': session,
        'pause': pause,
      });
    } on Object catch (error) {
      _log.w('Link: together, could not tell the computer it ended: $error');
    }
  }

  void _teardown({bool resume = false}) {
    _generation++;
    _coordinator?.stop(resume: resume);
    _coordinator = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _deck?.end();
    _deck = null;
    _session = null;
  }
}

final linkPlayTogetherProvider =
    NotifierProvider<LinkPlayTogether, LinkTogetherState>(LinkPlayTogether.new);

/// This phone's player as Play together drives it; tests replace it.
final linkTogetherPhoneDeckProvider = Provider<LinkTogetherDeck>(
  (ref) => LinkRuntimeTogetherDeck(
    runtime: ref.watch(musicPlayerRuntimeProvider),
    refFor: ref.watch(linkTrackRefCacheProvider).refFor,
  ),
);
