import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/link/features/link_downloads.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';

/// What the phone knows about the paired desktop: its connection, its
/// player and its download queue.
class LinkRemoteState {
  const LinkRemoteState({
    this.connection = LinkConnectionState.disconnected,
    this.player,
    this.downloads = const [],
    this.loading = false,
    this.error,
  });

  final LinkConnectionState connection;

  /// The desktop's player, with [LinkPlayerState.updatedMs] on the phone's
  /// clock.
  final LinkPlayerState? player;
  final List<LinkDesktopDownload> downloads;

  /// The first `GET state` is still running.
  final bool loading;

  /// The last refresh failed with this error.
  final Object? error;

  LinkRemoteState copyWith({
    LinkConnectionState? connection,
    LinkPlayerState? player,
    List<LinkDesktopDownload>? downloads,
    bool? loading,
    Object? error,
    bool clearError = false,
  }) => LinkRemoteState(
    connection: connection ?? this.connection,
    player: player ?? this.player,
    downloads: downloads ?? this.downloads,
    loading: loading ?? this.loading,
    error: clearError ? null : error ?? this.error,
  );
}

/// [state] with its position read at [updatedMs], and the given fields
/// replaced.
LinkPlayerState linkPlayerStateWith(
  LinkPlayerState state, {
  required int positionMs,
  required int updatedMs,
  TrackRef? track,
  bool? playing,
  List<TrackRef>? queue,
  int? index,
  bool? shuffle,
  LinkRepeatMode? repeat,
  double? volume,
  bool? autoplay,
  bool? autoMix,
}) => LinkPlayerState(
  track: track ?? state.track,
  playing: playing ?? state.playing,
  positionMs: positionMs,
  durationMs: track == null ? state.durationMs : track.durationMs,
  updatedMs: updatedMs,
  queue: queue ?? state.queue,
  index: index ?? state.index,
  shuffle: shuffle ?? state.shuffle,
  repeat: repeat ?? state.repeat,
  volume: volume ?? state.volume,
  autoplay: autoplay ?? state.autoplay,
  autoMix: autoMix ?? state.autoMix,
);

/// The desktop player as the phone's Devices sheet shows and controls it:
/// `GET state` and `GET downloads` first, then the `player.state` and
/// `downloads.changed` pushes; commands go out as `POST command`.
class LinkDesktopRemote extends Notifier<LinkRemoteState> {
  LinkDesktopRemote({int Function()? nowMs})
    : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _nowMs;
  LinkClientApi? _client;

  @override
  LinkRemoteState build() {
    final client = _client = ref.watch(linkPhoneClientProvider);
    if (client == null) return const LinkRemoteState();
    final messages = client.messages.listen(_onMessage);
    final connections = client.connectionStates.listen((connection) {
      if (!ref.mounted || _client != client) return;
      state = state.copyWith(connection: connection);
      if (connection == LinkConnectionState.connected) unawaited(refresh());
    });
    ref.onDispose(() {
      unawaited(messages.cancel());
      unawaited(connections.cancel());
    });
    Future.microtask(refresh);
    return LinkRemoteState(connection: client.connectionState, loading: true);
  }

  /// Receivers extrapolate from [LinkPlayerState.updatedMs]. The desktop
  /// stamps it with its own clock, so the phone restamps the position with
  /// the time it arrived; another device's clock may run seconds apart.
  LinkPlayerState _received(LinkPlayerState player) => linkPlayerStateWith(
    player,
    positionMs: player.positionMs,
    updatedMs: _nowMs(),
  );

  void _onMessage(Map<String, dynamic> message) {
    if (!ref.mounted) return;
    switch (message['type']) {
      case LinkMessageTypes.playerState:
        final player = LinkPlayerState.fromJson(message['state']);
        if (player != null) state = state.copyWith(player: _received(player));
      case LinkMessageTypes.downloadsChanged:
        state = state.copyWith(downloads: linkParseDownloads(message));
    }
  }

  /// Reads the desktop's player and download queue again.
  Future<void> refresh() async {
    final client = _client;
    if (client == null || !ref.mounted) return;
    try {
      final player = LinkPlayerState.fromJson(await client.get(LinkOps.state));
      if (!ref.mounted || _client != client) return;
      state = LinkRemoteState(
        connection: state.connection,
        player: player == null ? null : _received(player),
        downloads: state.downloads,
      );
    } on Object catch (error) {
      if (!ref.mounted || _client != client) return;
      state = state.copyWith(loading: false, error: error);
    }
    try {
      final downloads = linkParseDownloads(await client.get(LinkOps.downloads));
      if (!ref.mounted || _client != client) return;
      state = state.copyWith(downloads: downloads);
    } on Object {
      // The player stays usable when the download queue is unavailable.
    }
  }

  /// Sends [command] to the desktop and shows its expected result until the
  /// desktop's next state arrives.
  Future<void> command(LinkCommand command) async {
    final client = _client;
    if (client == null) return;
    final before = state.player;
    _applyLocally(command);
    try {
      await client.post(LinkOps.command, command.toJson());
    } on Object {
      if (ref.mounted && _client == client && before != null) {
        state = state.copyWith(player: before);
      }
      rethrow;
    }
  }

  void _applyLocally(LinkCommand command) {
    final player = state.player;
    if (player == null) return;
    final now = _nowMs();
    final position = player.positionAt(now);
    LinkPlayerState? next;
    switch (command.action) {
      case LinkActions.play:
      case LinkActions.pause:
      case LinkActions.toggle:
        final playing = switch (command.action) {
          LinkActions.play => true,
          LinkActions.pause => false,
          _ => !player.playing,
        };
        next = linkPlayerStateWith(
          player,
          positionMs: position,
          updatedMs: now,
          playing: playing,
        );
      case LinkActions.seek:
        final target = command.args['positionMs'];
        if (target is num) {
          next = linkPlayerStateWith(
            player,
            positionMs: target.toInt(),
            updatedMs: now,
          );
        }
      case LinkActions.volume:
        final value = command.args['value'];
        if (value is num) {
          next = linkPlayerStateWith(
            player,
            positionMs: position,
            updatedMs: now,
            volume: value.toDouble().clamp(0, 1),
          );
        }
      case LinkActions.shuffle:
        next = linkPlayerStateWith(
          player,
          positionMs: position,
          updatedMs: now,
          shuffle: command.args['enabled'] == true,
        );
      case LinkActions.repeat:
        final mode = LinkRepeatMode.values.asNameMap()[command.args['mode']];
        if (mode != null) {
          next = linkPlayerStateWith(
            player,
            positionMs: position,
            updatedMs: now,
            repeat: mode,
          );
        }
      case LinkActions.autoplay:
      case LinkActions.autoMix:
        final enabled = command.args['enabled'];
        if (enabled is bool) {
          next = linkPlayerStateWith(
            player,
            positionMs: position,
            updatedMs: now,
            autoplay: command.action == LinkActions.autoplay ? enabled : null,
            autoMix: command.action == LinkActions.autoMix ? enabled : null,
          );
        }
      case LinkActions.jump:
        final index = command.args['index'];
        if (index is num && index >= 0 && index < player.queue.length) {
          next = linkPlayerStateWith(
            player,
            positionMs: 0,
            updatedMs: now,
            index: index.toInt(),
            track: player.queue[index.toInt()],
          );
        }
      case LinkActions.move:
        final from = command.args['from'];
        final to = command.args['to'];
        final length = player.queue.length;
        if (from is int &&
            to is int &&
            from != to &&
            from >= 0 &&
            from < length &&
            to >= 0 &&
            to < length) {
          final queue = [...player.queue];
          queue.insert(to, queue.removeAt(from));
          final current = player.index;
          next = linkPlayerStateWith(
            player,
            positionMs: position,
            updatedMs: now,
            queue: queue,
            index: current == from
                ? to
                : from < current && to >= current
                ? current - 1
                : from > current && to <= current
                ? current + 1
                : current,
          );
        }
      case LinkActions.remove:
        final at = command.args['index'];
        if (at is int &&
            at >= 0 &&
            at < player.queue.length &&
            at != player.index) {
          next = linkPlayerStateWith(
            player,
            positionMs: position,
            updatedMs: now,
            queue: [...player.queue]..removeAt(at),
            index: at < player.index ? player.index - 1 : player.index,
          );
        }
    }
    if (next != null) state = state.copyWith(player: next);
  }

  Future<void> play() => command(const LinkCommand(LinkActions.play));
  Future<void> pause() => command(const LinkCommand(LinkActions.pause));
  Future<void> toggle() => command(const LinkCommand(LinkActions.toggle));
  Future<void> next() => command(const LinkCommand(LinkActions.next));
  Future<void> previous() => command(const LinkCommand(LinkActions.previous));

  Future<void> seek(Duration position) => command(
    LinkCommand(LinkActions.seek, {'positionMs': position.inMilliseconds}),
  );

  Future<void> setVolume(double value) => command(
    LinkCommand(LinkActions.volume, {'value': value.clamp(0, 1).toDouble()}),
  );

  Future<void> setShuffle(bool enabled) =>
      command(LinkCommand(LinkActions.shuffle, {'enabled': enabled}));

  Future<void> setRepeat(LinkRepeatMode mode) =>
      command(LinkCommand(LinkActions.repeat, {'mode': mode.name}));

  Future<void> setAutoplay(bool enabled) =>
      command(LinkCommand(LinkActions.autoplay, {'enabled': enabled}));

  Future<void> setAutoMix(bool enabled) =>
      command(LinkCommand(LinkActions.autoMix, {'enabled': enabled}));

  /// Plays the item at [index] of the desktop's [LinkPlayerState.queue].
  Future<void> jump(int index) =>
      command(LinkCommand(LinkActions.jump, {'index': index}));

  /// Moves entry [from] of the desktop's [LinkPlayerState.queue] to [to].
  Future<void> move(int from, int to) =>
      command(LinkCommand(LinkActions.move, {'from': from, 'to': to}));

  /// Removes entry [index] of the desktop's [LinkPlayerState.queue].
  Future<void> remove(int index) =>
      command(LinkCommand(LinkActions.remove, {'index': index}));
}

final linkDesktopRemoteProvider =
    NotifierProvider.autoDispose<LinkDesktopRemote, LinkRemoteState>(
      LinkDesktopRemote.new,
    );
