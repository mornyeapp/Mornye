import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/playable_media.dart';

/// The phone player at one moment, as the link features read it.
class LinkPhoneSnapshot {
  const LinkPhoneSnapshot({
    this.queue = const [],
    this.index = -1,
    this.playing = false,
    this.positionMs = 0,
    this.durationMs,
    this.shuffle = false,
    this.repeat = LinkRepeatMode.none,
    this.volume = 1,
    this.autoplay = false,
    this.autoMix = false,
  });

  /// The queue in play order.
  final List<MediaItem> queue;

  /// The current item in [queue], or -1.
  final int index;
  final bool playing;
  final int positionMs;
  final int? durationMs;
  final bool shuffle;
  final LinkRepeatMode repeat;

  /// 0 to 1.
  final double volume;
  final bool autoplay;
  final bool autoMix;

  MediaItem? get current =>
      index >= 0 && index < queue.length ? queue[index] : null;
}

/// The phone's player as the link features drive it. The app adapter wraps
/// [MusicPlayerRuntime]; tests fake it.
abstract interface class LinkPhonePlayer {
  LinkPhoneSnapshot get snapshot;

  /// Fires whenever the track, queue, transport or volume may have changed,
  /// including position ticks.
  Stream<void> get changes;

  /// Replaces the queue with [items] in this order and starts [index] at
  /// [position], paused unless [playing].
  Future<void> playQueue(
    List<PlayableMedia> items, {
    required int index,
    required Duration position,
    required bool playing,
    bool? shuffle,
  });

  Future<void> play();
  Future<void> pause();
  Future<void> next();
  Future<void> previous();
  Future<void> seek(Duration position);

  /// Plays the item at [index] of [LinkPhoneSnapshot.queue].
  Future<void> jump(int index);
  Future<void> setShuffle(bool enabled);
  Future<void> setRepeat(LinkRepeatMode mode);
  Future<void> setAutoplay(bool enabled);
  Future<void> setAutoMix(bool enabled);

  /// Sets the volume the phone's player slider controls, 0 to 1.
  Future<void> setVolume(double value);
}

/// [LinkPhonePlayer] over the app's playback runtime and the volume the
/// player slider drives.
class LinkMusicPhonePlayer implements LinkPhonePlayer {
  LinkMusicPhonePlayer({
    required MusicPlayerRuntime runtime,
    required MusicPlayerController controller,
    required Future<void> Function(double) writeVolume,
    Stream<double>? volumeChanges,
    void Function(bool)? writeAutoplay,
    void Function(bool)? writeAutoMix,
  }) : _runtime = runtime,
       _controller = controller,
       _writeVolume = writeVolume,
       _writeAutoplay = writeAutoplay,
       _writeAutoMix = writeAutoMix,
       _volumeChanges = volumeChanges ?? const Stream.empty();

  final MusicPlayerRuntime _runtime;
  final MusicPlayerController _controller;
  final Future<void> Function(double) _writeVolume;
  final Stream<double> _volumeChanges;
  final void Function(bool)? _writeAutoplay;
  final void Function(bool)? _writeAutoMix;
  double _volume = 1;

  static LinkRepeatMode _repeat(AudioServiceRepeatMode mode) => switch (mode) {
    AudioServiceRepeatMode.one => LinkRepeatMode.one,
    AudioServiceRepeatMode.all ||
    AudioServiceRepeatMode.group => LinkRepeatMode.all,
    AudioServiceRepeatMode.none => LinkRepeatMode.none,
  };

  @override
  LinkPhoneSnapshot get snapshot {
    final handler = _runtime.handler;
    if (handler == null) {
      return LinkPhoneSnapshot(
        volume: _volume,
        autoplay: _runtime.settings.autoplay,
        autoMix: _runtime.settings.autoMix,
      );
    }
    final state = handler.playbackState.value;
    final queue = handler.queue.value;
    final current = handler.mediaItem.value;
    var index = state.queueIndex ?? -1;
    if (index < 0 ||
        index >= queue.length ||
        (current != null && queue[index].id != current.id)) {
      index = current == null
          ? -1
          : queue.indexWhere((item) => item.id == current.id);
    }
    return LinkPhoneSnapshot(
      queue: queue,
      index: index,
      playing: state.playing,
      positionMs: state.position.inMilliseconds,
      durationMs: current?.duration?.inMilliseconds,
      shuffle: state.shuffleMode != AudioServiceShuffleMode.none,
      repeat: _repeat(state.repeatMode),
      volume: _volume,
      autoplay: _runtime.settings.autoplay,
      autoMix: _runtime.settings.autoMix,
    );
  }

  @override
  Stream<void> get changes => Stream<void>.multi((listener) {
    final subscriptions = <StreamSubscription<Object?>>[
      _runtime.playbackStateEvents().listen((_) => listener.add(null)),
      _runtime.queueEvents().listen((_) => listener.add(null)),
      _runtime.mediaItemEvents().listen((_) => listener.add(null)),
      _volumeChanges.listen((value) {
        _volume = value.clamp(0, 1).toDouble();
        listener.add(null);
      }),
    ];
    listener.onCancel = () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    };
  });

  @override
  Future<void> playQueue(
    List<PlayableMedia> items, {
    required int index,
    required Duration position,
    required bool playing,
    bool? shuffle,
  }) async {
    if (items.isEmpty) return;
    final handler = await _runtime.initialize();
    await handler.setQueueAndPlay(
      items,
      initialIndex: index,
      shuffle: shuffle ?? false,
    );
    if (position > Duration.zero) await handler.seek(position);
    if (!playing) await handler.pause();
  }

  @override
  Future<void> play() async => _runtime.handler?.play();

  @override
  Future<void> pause() async => _runtime.handler?.pause();

  @override
  Future<void> next() => _controller.next();

  @override
  Future<void> previous() => _controller.previous();

  @override
  Future<void> seek(Duration position) => _controller.seek(position);

  @override
  Future<void> jump(int index) => _controller.jumpTo(index);

  @override
  Future<void> setShuffle(bool enabled) => _controller.setShuffle(enabled);

  @override
  Future<void> setRepeat(LinkRepeatMode mode) async {
    final handler = await _runtime.initialize();
    await handler.setRepeatMode(switch (mode) {
      LinkRepeatMode.none => AudioServiceRepeatMode.none,
      LinkRepeatMode.one => AudioServiceRepeatMode.one,
      LinkRepeatMode.all => AudioServiceRepeatMode.all,
    });
  }

  @override
  Future<void> setAutoplay(bool enabled) async {
    if (_writeAutoplay case final write?) {
      write(enabled);
    } else {
      _runtime.configure(_runtime.settings.copyWith(autoplay: enabled));
    }
  }

  @override
  Future<void> setAutoMix(bool enabled) async {
    if (_writeAutoMix case final write?) {
      write(enabled);
    } else {
      _runtime.configure(_runtime.settings.copyWith(autoMix: enabled));
    }
  }

  @override
  Future<void> setVolume(double value) {
    _volume = value.clamp(0, 1).toDouble();
    return _writeVolume(_volume);
  }
}
