import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/link/features/link_desktop_remote.dart';
import 'package:mornye/services/link/features/link_handoff.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/services/link/features/link_phone_options.dart';
import 'package:mornye/services/link/features/link_playback_preferences.dart';
import 'package:mornye/services/link/features/link_track_resolver.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/remote_playback.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkRemotePlayback');

/// Whether the paired desktop plays in this phone's place, as after Play on
/// desktop or, with [LinkPhoneOptions.followDesktop], when the desktop
/// starts playing while this phone does not. The phone takes over again
/// after Continue on this phone, when the desktop is unpaired, and when the
/// phone's own player starts, such as for a Library song picked in the car.
/// It also takes over when the desktop cannot be reached, so songs picked
/// then play here instead of waiting for it. The notification and headset
/// drive the desktop meanwhile.
class LinkPlaysOnDesktop extends Notifier<bool> {
  @override
  bool build() {
    final client = ref.watch(linkPhoneClientProvider);
    if (client == null) return false;
    bool? playing;
    // Whether the desktop played when last heard from on this connection.
    bool? desktopPlaying;
    void heard(LinkPlayerState? desktop) {
      final was = desktopPlaying;
      final now = desktopPlaying =
          desktop != null && desktop.playing && desktop.track != null;
      // The desktop starting to play takes over the player screens, as
      // choosing it in Devices does, unless this phone plays meanwhile.
      if (was == true || !now || playing == true || state) return;
      final options = ref.read(linkPhoneOptionsProvider);
      if (options.loaded && options.followDesktop) state = true;
    }

    // A failed attempt goes from connecting to disconnected. The session
    // pausing in the background disconnects a connected one instead, which
    // keeps the desktop.
    var connection = client.connectionState;
    var connects = 0;
    Future<void> readDesktop() async {
      final attempt = ++connects;
      try {
        final desktop = LinkPlayerState.fromJson(
          await client.get(LinkOps.state),
        );
        if (ref.mounted &&
            attempt == connects &&
            connection == LinkConnectionState.connected) {
          heard(desktop);
        }
      } on Object {
        // Its next push tells.
      }
    }

    final connections = client.connectionStates.listen((next) {
      final was = connection;
      connection = next;
      if (next != LinkConnectionState.connected) {
        connects++;
        desktopPlaying = null;
      } else if (was != next) {
        unawaited(readDesktop());
      }
      if (was == LinkConnectionState.connecting &&
          next == LinkConnectionState.disconnected &&
          state) {
        state = false;
      }
    });
    ref.onDispose(connections.cancel);
    final messages = client.messages.listen((message) {
      if (message['type'] != LinkMessageTypes.playerState) return;
      heard(LinkPlayerState.fromJson(message['state']));
    });
    ref.onDispose(messages.cancel);
    if (connection == LinkConnectionState.connected) {
      unawaited(readDesktop());
    }
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
  final remote = ref.read(linkDesktopRemoteProvider.notifier);
  final preferences = LinkPlaybackPreferencesSync(
    readAutoplay: () => ref.read(settingsProvider).autoplay,
    readAutoMix: () => ref.read(settingsProvider).autoMix,
    writeAutoplay: (enabled) =>
        ref.read(settingsProvider.notifier).setAutoplay(enabled),
    writeAutoMix: (enabled) =>
        ref.read(settingsProvider.notifier).setAutoMix(enabled),
    sendAutoplay: remote.setAutoplay,
    sendAutoMix: remote.setAutoMix,
  );
  var revision = 0;
  void update(LinkRemoteState state) {
    playback.update(state);
    final current = ++revision;
    scheduleMicrotask(() {
      if (ref.mounted && current == revision) {
        preferences.updateRemote(state.player);
      }
    });
  }

  // Listening keeps the desktop's state alive while it plays for the phone.
  ref.listen(linkDesktopRemoteProvider, (_, next) => update(next));
  ref.listen(settingsProvider.select((s) => (s.autoplay, s.autoMix)), (_, _) {
    unawaited(
      preferences.updateLocal().catchError((Object error) {
        _log.w('Could not update the computer playback preferences: $error');
      }),
    );
  });
  playback = LinkRemotePlayback(
    name: linkDesktopName(client),
    remote: remote,
    handoff: handoff,
    resolveArtwork: ref
        .watch(musicPlayerRuntimeProvider)
        .dependencies
        .resolveNetworkSource,
    initialItem: ref.read(localMediaItemProvider).value,
  );
  update(ref.read(linkDesktopRemoteProvider));
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
    MediaItem? initialItem,
    Duration tick = const Duration(milliseconds: 500),
    int Function()? nowMs,
  }) : _remote = remote,
       _handoff = handoff,
       _resolveArtwork = resolveArtwork,
       _mediaItem = _Latest(initialItem),
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

  /// Starts with [LinkRemotePlayback.new]'s `initialItem`, the song just
  /// sent there, so the player does not empty out until the desktop's state
  /// arrives.
  final _Latest<MediaItem?> _mediaItem;
  final _playbackState = _Latest<PlaybackState>(PlaybackState());
  final _queue = _Latest<List<MediaItem>>(const []);
  final _volume = _Latest<double>(1);
  final _transfer = _Latest<RemoteTransfer?>(null);

  /// The item each entry of [_queue] copies. Every entry is its own object,
  /// as in the local queue, so a repeated song keeps distinct rows.
  List<MediaItem> _queueBases = const [];

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

  @override
  Stream<RemoteTransfer?> get transfers => _transfer.stream;

  /// Shows the desktop's [state].
  void update(LinkRemoteState state) {
    if (_disposed || (state.loading && state.player == null)) return;
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
      _showQueue([for (final ref in refs) _itemFor(ref)]);
    }
    if (track != null) unawaited(_resolve(track));
    final start = player?.index ?? 0;
    for (final ref in refs.skip(start < 0 ? 0 : start).take(_resolveAhead)) {
      unawaited(_resolve(ref));
    }
  }

  /// Shows a queue of [bases], keeping the entry objects of the songs it
  /// already showed, so moved rows keep their identity.
  void _showQueue(List<MediaItem> bases) {
    final spare = Map<MediaItem, List<MediaItem>>.identity();
    final shown = _queue.value;
    for (var i = 0; i < _queueBases.length && i < shown.length; i++) {
      spare.putIfAbsent(_queueBases[i], () => []).add(shown[i]);
    }
    _queueBases = bases;
    final entries = <MediaItem>[];
    for (final base in bases) {
      final reused = spare[base];
      entries.add(
        reused != null && reused.isNotEmpty
            ? reused.removeAt(0)
            : base.copyWith(),
      );
    }
    _queue.add(List.unmodifiable(entries));
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
  Future<void> moveQueueItem(int from, int to) =>
      _send(() => _remote.move(from, to));

  @override
  Future<void> removeQueueItem(MediaItem item) async {
    final index = _queue.value.indexWhere((entry) => identical(entry, item));
    if (index >= 0) await _send(() => _remote.remove(index));
  }

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
      _sending(
        (onSending) => _handoff.playItemsOnDesktop(
          [for (final item in items) item.toMediaItem()],
          index: initialIndex,
          modes: _player,
          onSending: onSending,
        ),
      );

  @override
  Future<void> enqueue(List<PlayableMedia> items, {bool playNext = false}) =>
      _sending(
        (onSending) => _handoff.addToDesktopQueue(
          [for (final item in items) item.toMediaItem()],
          playNext: playNext,
          onSending: onSending,
        ),
      );

  /// Runs [command], reporting the song files it sends as [transfers].
  Future<void> _sending(
    Future<void> Function(void Function(int sent, int total) onSending) command,
  ) async {
    try {
      await _send(
        () => command((sent, total) {
          if (!_disposed) {
            _transfer.add(RemoteTransfer(sent: sent, total: total));
          }
        }),
      );
    } finally {
      if (!_disposed && _transfer.value != null) _transfer.add(null);
    }
  }

  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _mediaItem.close();
    _playbackState.close();
    _queue.close();
    _volume.close();
    _transfer.close();
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
