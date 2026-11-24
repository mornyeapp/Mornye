import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/together/link_together_protocol.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/playback_deck.dart';

/// This device's own player as Play together drives it. Only what every
/// engine offers through the app's player: play, pause, seek, loading a
/// queue entry paused, and the playback speed every deck applies. Tests
/// fake it.
abstract interface class LinkTogetherDeck {
  /// The player now, on this device's clock.
  LinkTogetherReport read();

  /// Fires after a change of the song, the queue or the transport state.
  Stream<void> get changes;

  /// How many entries the queue holds.
  int get length;

  /// The song at [index] of the queue, as other devices match it.
  TrackRef? refAt(int index);

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> next();
  Future<void> previous();
  Future<void> setRepeat(LinkRepeatMode mode);

  /// Loads queue entry [index] at [position] without a sound.
  Future<void> prepare(int index, Duration position);

  /// Whether [setRate] can close a small gap here: the engine changes its
  /// rate and the pitch does not follow it.
  bool get canNudge;

  /// Plays at [factor] times the normal rate (1 is normal).
  void setRate(double factor);

  /// Switches off for the session what cannot stay in step, without saving
  /// it: AutoMix, silence skipping, a speed other than 1x, and autoplay
  /// while following (the leader's queue feeds the follower).
  void begin({required bool follower});

  /// Restores what [begin] switched off.
  void end();
}

int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

/// [LinkTogetherDeck] over the app's [MusicPlayerRuntime], on the phone and
/// on the computer. [refFor] names a queue item as other devices match it.
class LinkRuntimeTogetherDeck implements LinkTogetherDeck {
  LinkRuntimeTogetherDeck({
    required MusicPlayerRuntime runtime,
    required TrackRef Function(MediaItem item) refFor,
    int Function()? nowMs,
  }) : _runtime = runtime,
       _refFor = refFor,
       _nowMs = nowMs ?? _wallClockMs;

  final MusicPlayerRuntime _runtime;
  final TrackRef Function(MediaItem item) _refFor;
  final int Function() _nowMs;
  double _rate = 1;
  bool _begun = false;

  static LinkRepeatMode _repeat(AudioServiceRepeatMode mode) => switch (mode) {
    AudioServiceRepeatMode.one => LinkRepeatMode.one,
    AudioServiceRepeatMode.all ||
    AudioServiceRepeatMode.group => LinkRepeatMode.all,
    AudioServiceRepeatMode.none => LinkRepeatMode.none,
  };

  @override
  LinkTogetherReport read() {
    final now = _nowMs();
    final handler = _runtime.handler;
    if (handler == null) return LinkTogetherReport(nowMs: now);
    return reportOf(
      state: handler.playbackState.value,
      queue: handler.queue.value,
      current: handler.mediaItem.value,
      nowMs: now,
      refFor: _refFor,
    );
  }

  /// The report for a player in [state] on [current] of [queue].
  static LinkTogetherReport reportOf({
    required PlaybackState state,
    required List<MediaItem> queue,
    required MediaItem? current,
    required int nowMs,
    required TrackRef Function(MediaItem item) refFor,
  }) {
    var index = state.queueIndex ?? -1;
    if (current != null &&
        (index < 0 || index >= queue.length || queue[index].id != current.id)) {
      index = queue.indexWhere((item) => item.id == current.id);
    }
    // Buffering holds the position still, so it says nothing of drift.
    final ready = state.processingState == AudioProcessingState.ready;
    final duration = current?.duration?.inMilliseconds;
    // A song that ran out stands at its end. Its state still carries the
    // last position read while it played, which can lie well before the
    // listed length, and a song change read from there looks like one
    // picked by hand.
    final ended =
        state.processingState == AudioProcessingState.completed &&
        duration != null &&
        duration > 0;
    return LinkTogetherReport(
      nowMs: nowMs,
      track: current == null ? null : refFor(current),
      index: current == null ? -1 : index,
      playing: state.playing,
      ready: ready && current != null,
      // Extrapolated at the session's rate, nudges included.
      positionMs: ended ? duration : state.position.inMilliseconds,
      durationMs: duration,
      repeat: _repeat(state.repeatMode),
      rate: state.speed,
    );
  }

  @override
  Stream<void> get changes => Stream<void>.multi((listener) {
    final subscriptions = <StreamSubscription<Object?>>[
      _runtime.playbackStateEvents().listen((_) => listener.add(null)),
      _runtime.mediaItemEvents().listen((_) => listener.add(null)),
      _runtime.queueEvents().listen((_) => listener.add(null)),
    ];
    listener.onCancel = () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    };
  });

  @override
  int get length => _runtime.handler?.queue.value.length ?? 0;

  @override
  TrackRef? refAt(int index) {
    final queue = _runtime.handler?.queue.value ?? const <MediaItem>[];
    return index >= 0 && index < queue.length ? _refFor(queue[index]) : null;
  }

  @override
  Future<void> play() async => (await _runtime.initialize()).play();

  @override
  Future<void> pause() async => _runtime.handler?.pause();

  @override
  Future<void> seek(Duration position) async =>
      _runtime.handler?.seek(position);

  @override
  Future<void> next() async => _runtime.handler?.skipToNext();

  @override
  Future<void> previous() async => _runtime.handler?.skipToPrevious();

  @override
  Future<void> setRepeat(LinkRepeatMode mode) async =>
      (await _runtime.initialize()).setRepeatMode(switch (mode) {
        LinkRepeatMode.none => AudioServiceRepeatMode.none,
        LinkRepeatMode.one => AudioServiceRepeatMode.one,
        LinkRepeatMode.all => AudioServiceRepeatMode.all,
      });

  @override
  Future<void> prepare(int index, Duration position) async =>
      (await _runtime.initialize()).prepareQueueItem(index, position: position);

  @override
  bool get canNudge =>
      playbackTempoSupport.value != PlaybackTempoSupport.none &&
      !playbackPitch.value.followsRate;

  @override
  void setRate(double factor) {
    _rate = factor;
    // Under [begin] the session plays at 1x, so the factor is the speed.
    // A settings change resets it to 1x; the next check nudges again.
    if (_begun) playbackSpeed.value = factor;
  }

  @override
  void begin({required bool follower}) {
    _begun = true;
    _runtime.overrideSettings(
      (settings) => settings.copyWith(
        autoMix: false,
        skipSilence: false,
        playbackSpeed: 1,
        autoplay: follower ? false : null,
      ),
    );
    if (_rate != 1) playbackSpeed.value = _rate;
  }

  @override
  void end() {
    if (!_begun) return;
    _begun = false;
    _rate = 1;
    _runtime.overrideSettings(null);
  }
}
