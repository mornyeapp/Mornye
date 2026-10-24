import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/link/features/link_desktop_remote.dart';
import 'package:mornye/services/link/features/link_handoff.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/services/link/features/link_track_resolver.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/remote_playback.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkRemotePlayback');

/// Whether the paired desktop plays in this phone's place, as after Play on
/// desktop. The phone takes over again after Continue on this phone, when
/// the desktop is unpaired, and when the phone's own player starts from its
/// notification, a headset or the car.
class LinkPlaysOnDesktop extends Notifier<bool> {
  @override
  bool build() {
    if (ref.watch(linkPhoneClientProvider) == null) return false;
    bool? playing;
    final subscription = ref
        .watch(musicPlayerRuntimeProvider)
        .playbackStateEvents()
        .listen((playback) {
          final was = playing;
          playing = playback.playing;
          if (was == false && playback.playing && state) state = false;
        });
    ref.onDispose(subscription.cancel);
    return false;
  }

  void set(bool onDesktop) {
    // A pairing that ended meanwhile already moved playback back here.
    if (ref.mounted) state = onDesktop;
  }
}

final linkPlaysOnDesktopProvider = NotifierProvider<LinkPlaysOnDesktop, bool>(
  LinkPlaysOnDesktop.new,
);

/// The paired desktop while it plays in this phone's place, else null. The
/// app root installs it as [activeRemotePlaybackProvider].
final linkRemotePlaybackProvider = Provider<LinkRemotePlayback?>((ref) {
  if (!ref.watch(linkPlaysOnDesktopProvider)) return null;
  final client = ref.watch(linkPhoneClientProvider);
  final handoff = ref.watch(linkHandoffProvider);
  if (client == null || handoff == null) return null;
  late final LinkRemotePlayback playback;
  // Listening keeps the desktop's state alive while it plays for the phone.
  ref.listen(linkDesktopRemoteProvider, (_, next) => playback.update(next));
  playback = LinkRemotePlayback(
    name: linkDesktopName(client),
    remote: ref.read(linkDesktopRemoteProvider.notifier),
    handoff: handoff,
    resolveArtwork: ref
        .watch(musicPlayerRuntimeProvider)
        .dependencies
        .resolveNetworkSource,
  )..update(ref.read(linkDesktopRemoteProvider));
  ref.onDispose(playback.dispose);
  return playback;
});

/// The paired desktop's player as the phone's player screens show and drive
/// it. Each desktop track shows as the phone would play it: its own file
/// when it has one, so lyrics, details and favorites work as usual, else
/// the desktop's song with its cover.
class LinkRemotePlayback implements RemotePlayback {
  LinkRemotePlayback({
    required this.name,
    required LinkDesktopRemote remote,
    required LinkHandoff handoff,
    required Future<String> Function(String source) resolveArtwork,
    Duration tick = const Duration(milliseconds: 500),
    int Function()? nowMs,
  }) : _remote = remote,
       _handoff = handoff,
       _resolveArtwork = resolveArtwork,
       _tick = tick,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  @override
  final String name;

  final LinkDesktopRemote _remote;
  final LinkHandoff _handoff;
  final Future<String> Function(String source) _resolveArtwork;
  final Duration _tick;
  final int Function() _nowMs;

  /// How many queue entries from the current one get their full item.
  static const _resolveAhead = 20;
  static const _itemLimit = 500;

  final _mediaItem = _Latest<MediaItem?>(null);
  final _playbackState = _Latest<PlaybackState>(PlaybackState());
  final _queue = _Latest<List<MediaItem>>(const []);
  final _volume = _Latest<double>(1);

  /// The best item known for each track, and the tracks whose lookup ran.
  final _items = <TrackRef, MediaItem>{};
  final _resolved = <TrackRef>{};
  final _resolving = <TrackRef>{};

  LinkPlayerState? _player;
  List<TrackRef> _queueRefs = const [];
  Timer? _ticker;
  bool _disposed = false;

  @override
  Stream<MediaItem?> get mediaItems => _mediaItem.stream;

  @override
  Stream<PlaybackState> get playbackStates => _playbackState.stream;

  @override
  Stream<List<MediaItem>> get queues => _queue.stream;

  @override
  Stream<double> get volumes => _volume.stream;

  /// Shows the desktop's [state].
  void update(LinkRemoteState state) {
    if (_disposed) return;
    final player = _player = state.player;
    if (player != null) _volume.add(player.volume.clamp(0.0, 1.0));
    _showTracks(force: false);
    _showPlayback();
    final playing = player?.playing ?? false;
    if (playing != (_ticker != null)) {
      _ticker?.cancel();
      _ticker = playing ? Timer.periodic(_tick, (_) => _showPlayback()) : null;
    }
  }

  void _showTracks({required bool force}) {
    final player = _player;
    final track = player?.track;
    final current = track == null ? null : _itemFor(track);
    if (!identical(current, _mediaItem.value)) _mediaItem.add(current);
    final refs = player?.queue ?? const <TrackRef>[];
    if (force || !listEquals(refs, _queueRefs)) {
      _queueRefs = refs;
      _queue.add(List.unmodifiable([for (final ref in refs) _itemFor(ref)]));
    }
    if (track != null) unawaited(_resolve(track));
    final start = player?.index ?? 0;
    for (final ref in refs.skip(start < 0 ? 0 : start).take(_resolveAhead)) {
      unawaited(_resolve(ref));
    }
  }

  void _showPlayback() {
    final player = _player;
    if (player == null || player.track == null) {
      _playbackState.add(PlaybackState());
      return;
    }
    final now = _nowMs();
    final index = player.index;
    _playbackState.add(
      PlaybackState(
        processingState: AudioProcessingState.ready,
        playing: player.playing,
        updatePosition: Duration(milliseconds: player.positionAt(now)),
        updateTime: DateTime.fromMillisecondsSinceEpoch(now),
        queueIndex: index >= 0 && index < player.queue.length ? index : null,
        shuffleMode: player.shuffle
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        repeatMode: switch (player.repeat) {
          LinkRepeatMode.none => AudioServiceRepeatMode.none,
          LinkRepeatMode.all => AudioServiceRepeatMode.all,
          LinkRepeatMode.one => AudioServiceRepeatMode.one,
        },
      ),
    );
  }

  /// The item for [ref]: the looked-up one, else one built from [ref].
  MediaItem _itemFor(TrackRef ref) => _items[ref] ??= _playable(
    ref,
    linkDesktopPlayable(ref, _handoff.resolver.server),
  ).toMediaItem();

  PlayableMedia _playable(TrackRef ref, PlayableMedia? media) =>
      media ??
      PlayableMedia(
        id: 'link:${ref.fileId ?? ref.isrc ?? ref.matchKey ?? ref.title}',
        source: '',
        title: ref.title,
        artist: ref.artist,
        album: ref.album ?? '',
        duration: ref.durationMs == null
            ? null
            : Duration(milliseconds: ref.durationMs!),
      );

  /// Looks [ref] up once: the phone's file for it, else the desktop's song
  /// with its cover.
  Future<void> _resolve(TrackRef ref) async {
    if (_resolved.contains(ref) || !_resolving.add(ref)) return;
    try {
      final media = _playable(ref, await _handoff.resolver.resolve(ref));
      String? artwork;
      if (media.networkArtworkSource case final source?) {
        try {
          artwork = await _resolveArtwork(source);
        } on Object {
          // The song shows without a cover.
        }
      }
      if (_disposed) return;
      if (_items.length >= _itemLimit) {
        _items.removeWhere((key, _) => !_queueRefs.contains(key));
        _resolved.removeWhere((key) => !_queueRefs.contains(key));
      }
      _items[ref] = media.toMediaItem(resolvedArtwork: artwork);
      _resolved.add(ref);
      if (ref == _player?.track || _queueRefs.contains(ref)) {
        _showTracks(force: true);
      }
    } on Object catch (error) {
      _log.w('Could not look up a song the computer plays: $error');
    } finally {
      _resolving.remove(ref);
    }
  }

  Future<void> _send(Future<void> Function() command) async {
    try {
      await command();
    } on Object catch (error) {
      _log.w('The computer did not take a command: $error');
    }
  }

  @override
  Future<void> play() => _send(_remote.play);

  @override
  Future<void> pause() => _send(_remote.pause);

  @override
  Future<void> seek(Duration position) => _send(() => _remote.seek(position));

  @override
  Future<void> next() => _send(_remote.next);

  @override
  Future<void> previous() => _send(_remote.previous);

  @override
  Future<void> jumpTo(int index) => _send(() => _remote.jump(index));

  @override
  Future<void> setShuffle(bool enabled) =>
      _send(() => _remote.setShuffle(enabled));

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode mode) => _send(
    () => _remote.setRepeat(switch (mode) {
      AudioServiceRepeatMode.none => LinkRepeatMode.none,
      AudioServiceRepeatMode.one => LinkRepeatMode.one,
      AudioServiceRepeatMode.all ||
      AudioServiceRepeatMode.group => LinkRepeatMode.all,
    }),
  );

  @override
  Future<void> setVolume(double value) => _send(() => _remote.setVolume(value));

  @override
  Future<void> playAll(List<PlayableMedia> items, {int initialIndex = 0}) =>
      _send(
        () => _handoff.playItemsOnDesktop([
          for (final item in items) item.toMediaItem(),
        ], index: initialIndex),
      );

  @override
  Future<void> enqueue(List<PlayableMedia> items, {bool playNext = false}) =>
      _send(
        () => _handoff.addToDesktopQueue([
          for (final item in items) item.toMediaItem(),
        ], playNext: playNext),
      );

  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _mediaItem.close();
    _playbackState.close();
    _queue.close();
    _volume.close();
  }
}

/// A broadcast stream that starts each listener with the latest value.
class _Latest<T> {
  _Latest(this.value);

  T value;
  final _changes = StreamController<T>.broadcast();

  Stream<T> get stream => Stream.multi((listener) {
    listener.add(value);
    final subscription = _changes.stream.listen(
      listener.add,
      onDone: listener.close,
    );
    listener.onCancel = subscription.cancel;
  });

  void add(T next) {
    value = next;
    if (!_changes.isClosed) _changes.add(next);
  }

  void close() => unawaited(_changes.close());
}
