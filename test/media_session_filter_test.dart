import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/media_session_filter.dart';
import 'package:mornye/services/remote_media_session.dart';
import 'package:mornye/services/remote_playback.dart';

final _start = DateTime.utc(2026, 10, 30, 12);

Duration _seconds(num seconds) =>
    Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());

/// The iOS lock screen asking audio_service to republish Now Playing, as
/// the player does when the app returns to the foreground.
class _Refresh {
  const _Refresh();
}

/// The OS end of the session: each request in the order it arrived, at the
/// test's time in seconds.
class _Os extends AudioServicePlatform {
  final requests = <({double at, Object request})>[];
  double now = 0;
  Object? failure;
  Completer<void>? reply;

  List<PlaybackStateMessage> get states => [
    for (final entry in requests)
      if (entry.request case SetStateRequest(:final state)) state,
  ];

  void _receive(Object request) => requests.add((at: now, request: request));

  void refresh() => _receive(const _Refresh());

  @override
  Future<void> setState(SetStateRequest request) async {
    _receive(request);
    await reply?.future;
    final error = failure;
    failure = null;
    if (error != null) throw error;
  }

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async =>
      _receive(request);

  @override
  Future<void> stopService(StopServiceRequest request) async =>
      _receive(request);

  @override
  Future<void> configure(ConfigureRequest request) async => _receive(request);

  @override
  Future<void> setQueue(SetQueueRequest request) async => _receive(request);

  @override
  Future<void> setAndroidPlaybackInfo(
    SetAndroidPlaybackInfoRequest request,
  ) async => _receive(request);

  @override
  Future<void> androidForceEnableMediaButtons(
    AndroidForceEnableMediaButtonsRequest request,
  ) async => _receive(request);

  @override
  Future<void> notifyChildrenChanged(
    NotifyChildrenChangedRequest request,
  ) async => _receive(request);

  @override
  void setHandlerCallbacks(AudioHandlerCallbacks callbacks) =>
      _receive(callbacks);
}

/// What Android's session shows at [at] (notification, lock screen,
/// Bluetooth, Android Auto, watches): the last state's position, advanced
/// at its speed while it plays and is ready.
Duration _android(_Os os, double at) {
  final state = os.states.last;
  if (!state.playing ||
      state.processingState != AudioProcessingStateMessage.ready) {
    return state.updatePosition;
  }
  return state.updatePosition +
      _start.add(_seconds(at)).difference(state.updateTime) * state.speed;
}

/// What Apple's Now Playing shows at [at] on iOS and macOS, as audio_service's
/// Darwin plugin publishes it: the last state's position as it arrived,
/// published again when playing, speed or position change and with each media
/// item, then advanced at the playing rate. A refresh, which only iOS asks
/// for, advances it to its update time.
Duration _apple(_Os os, double at, {bool refreshes = true}) {
  PlaybackStateMessage? state;
  var elapsed = Duration.zero;
  var rate = 0.0;
  var since = 0.0;
  void publish(double time, Duration position) {
    final current = state!;
    elapsed = position;
    rate = current.playing ? current.speed : 0;
    since = time;
  }

  for (final entry in os.requests) {
    final request = entry.request;
    if (request is SetStateRequest) {
      final previous = state;
      final next = state = request.state;
      if (previous == null ||
          previous.playing != next.playing ||
          previous.speed != next.speed ||
          previous.updatePosition != next.updatePosition) {
        publish(entry.at, next.updatePosition);
      }
    } else if (request is SetMediaItemRequest && state != null) {
      publish(entry.at, state.updatePosition);
    } else if (request is _Refresh && refreshes && state != null) {
      var position = state.updatePosition;
      if (state.playing &&
          state.processingState == AudioProcessingStateMessage.ready) {
        position +=
            _start.add(_seconds(entry.at)).difference(state.updateTime) *
            state.speed;
      }
      publish(entry.at, position);
    }
  }
  return elapsed + _seconds(at - since) * rate;
}

Duration _mac(_Os os, double at) => _apple(os, at, refreshes: false);

List<MediaControlMessage> _controls({bool playing = true, bool loved = false}) {
  return [
    MediaControlMessage(
      androidIcon: loved
          ? 'drawable/ic_notification_star_filled'
          : 'drawable/ic_notification_star',
      label: loved ? 'Remove from Loved' : 'Add to Loved',
      action: MediaActionMessage.custom,
      customAction: CustomMediaActionMessage(name: 'favorite'),
    ),
    const MediaControlMessage(
      androidIcon: 'drawable/ic_widget_previous',
      label: 'Previous',
      action: MediaActionMessage.skipToPrevious,
    ),
    MediaControlMessage(
      androidIcon: playing
          ? 'drawable/ic_widget_pause'
          : 'drawable/ic_widget_play',
      label: playing ? 'Pause' : 'Play',
      action: playing ? MediaActionMessage.pause : MediaActionMessage.play,
    ),
    const MediaControlMessage(
      androidIcon: 'drawable/ic_widget_next',
      label: 'Next',
      action: MediaActionMessage.skipToNext,
    ),
  ];
}

const _systemActions = {
  MediaActionMessage.seek,
  MediaActionMessage.seekForward,
  MediaActionMessage.seekBackward,
  MediaActionMessage.skipToPrevious,
  MediaActionMessage.skipToNext,
};

/// A state as the player publishes it: [position] seconds at [at] seconds.
PlaybackStateMessage _state(
  num position, {
  num at = 0,
  bool playing = true,
  AudioProcessingStateMessage processingState =
      AudioProcessingStateMessage.ready,
  double speed = 1,
  int? queueIndex = 0,
  List<MediaControlMessage>? controls,
  List<int> compactIndices = const [1, 2, 3],
  Set<MediaActionMessage> systemActions = _systemActions,
  Duration bufferedPosition = Duration.zero,
  int? errorCode,
  String? errorMessage,
  AudioServiceRepeatModeMessage repeatMode = AudioServiceRepeatModeMessage.none,
  AudioServiceShuffleModeMessage shuffleMode =
      AudioServiceShuffleModeMessage.none,
  bool captioningEnabled = false,
}) => PlaybackStateMessage(
  processingState: processingState,
  playing: playing,
  controls: controls ?? _controls(playing: playing),
  androidCompactActionIndices: compactIndices,
  systemActions: systemActions,
  updatePosition: _seconds(position),
  bufferedPosition: bufferedPosition,
  speed: speed,
  updateTime: _start.add(_seconds(at)),
  errorCode: errorCode,
  errorMessage: errorMessage,
  repeatMode: repeatMode,
  shuffleMode: shuffleMode,
  captioningEnabled: captioningEnabled,
  queueIndex: queueIndex,
);

SetStateRequest _request(PlaybackStateMessage state) =>
    SetStateRequest(state: state);

SetMediaItemRequest _item(String id) => SetMediaItemRequest(
  mediaItem: MediaItemMessage(id: id, title: id),
);

/// A player publishing what `MusicPlayerHandler` publishes, to the OS
/// [filtered] through a [MediaSessionFilter] and to the OS [today] directly,
/// with the engine's true position.
class _Player {
  final today = _Os();
  final filtered = _Os();
  late final filter = MediaSessionFilter(filtered);
  double now = 0;
  final checks = <String>[];

  bool playing = false;
  AudioProcessingStateMessage processing = AudioProcessingStateMessage.idle;
  double speed = 1;
  int queueIndex = 0;
  bool loved = false;
  PlaybackStateMessage? published;
  int ticks = 0;

  // The engine: [_anchor] at [_anchorAt] seconds, advancing at [_rate].
  double _anchor = 0, _anchorAt = 0, _rate = 0;

  double truth([double? at]) => _anchor + ((at ?? now) - _anchorAt) * _rate;

  void _engine(double position, double rate) {
    _anchor = position;
    _anchorAt = now;
    _rate = rate;
  }

  /// The position the player shows, extrapolated from its last state.
  double get shown {
    final state = published!;
    var position = state.updatePosition.inMicroseconds / 1e6;
    if (state.playing &&
        state.processingState == AudioProcessingStateMessage.ready) {
      final elapsed = _start.add(_seconds(now)).difference(state.updateTime);
      position += elapsed.inMicroseconds / 1e6 * state.speed;
    }
    return position;
  }

  void publish([double? position]) {
    final state = _state(
      position ?? (published == null ? 0 : shown),
      at: now,
      playing: playing,
      processingState: processing,
      speed: speed,
      queueIndex: queueIndex,
      controls: _controls(playing: playing, loved: loved),
    );
    published = state;
    today.now = filtered.now = now;
    unawaited(today.setState(_request(state)));
    unawaited(filter.setState(_request(state)));
    check('state');
  }

  void mediaItem(String id) {
    today.now = filtered.now = now;
    unawaited(today.setMediaItem(_item(id)));
    unawaited(filter.setMediaItem(_item(id)));
    check('media item $id');
  }

  void refresh() {
    today.now = filtered.now = now;
    today.refresh();
    filtered.refresh();
    check('refresh');
  }

  /// Engine position updates every 600 ms while it plays, read 0 to 30 ms
  /// late, as `_broadcastPosition` publishes them.
  void play(double until) {
    while (now + 0.6 <= until + 1e-9) {
      now += 0.6;
      if (!playing || processing != AudioProcessingStateMessage.ready) continue;
      publish(truth(now - const [0.0, 0.01, 0.03][ticks++ % 3]));
    }
    now = until;
  }

  /// Every OS view behind the filter stays within [MediaSessionFilter.tolerance]
  /// of the same view fed every state, and matches it exactly while paused.
  void check(String event) {
    final tolerance = MediaSessionFilter.tolerance.inMicroseconds / 1e6 - 1e-6;
    for (final (name, view) in [
      ('Android', _android),
      ('iOS', _apple),
      ('macOS', _mac),
    ]) {
      final expected = view(today, now).inMicroseconds / 1e6;
      final actual = view(filtered, now).inMicroseconds / 1e6;
      final error = (actual - expected).abs();
      final paused = !playing;
      if (paused ? error > 1e-6 : error >= tolerance) {
        checks.add(
          '$name at ${now.toStringAsFixed(2)} s after $event: '
          '$actual s instead of $expected s',
        );
      }
    }
  }

  void load(int index, {required double loading}) {
    queueIndex = index;
    playing = true;
    processing = AudioProcessingStateMessage.loading;
    _engine(0, 0);
    publish(0);
    mediaItem('song $index');
    now += loading;
    processing = AudioProcessingStateMessage.ready;
    _engine(0, speed);
    publish();
  }

  void pause() {
    playing = false;
    _engine(truth(), 0);
    publish();
  }

  void resume({double loading = 0.2}) {
    playing = true;
    processing = AudioProcessingStateMessage.loading;
    publish();
    now += loading;
    processing = AudioProcessingStateMessage.ready;
    _engine(shown, speed);
    publish();
  }

  void seek(double position) {
    _engine(position, playing ? speed : 0);
    publish(position);
  }

  void setSpeed(double value) {
    speed = value;
    _engine(truth(), playing ? value : 0);
  }

  void stall(double seconds) {
    final rate = _rate;
    _engine(truth(), 0);
    play(now + seconds);
    _engine(truth(), rate);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('holds back position updates the OS advances itself', () {
    final os = _Os();
    final filter = MediaSessionFilter(os);
    for (var tick = 0; tick <= 100; tick++) {
      // Polled up to 30 ms late, as the deck reports.
      final late = const [0.0, 0.03, 0.01][tick % 3];
      unawaited(
        filter.setState(_request(_state(tick * 0.6 - late, at: tick * 0.6))),
      );
    }
    expect(os.states, hasLength(1));
  });

  test('passes on every change the OS cannot work out', () {
    final changes = <String, PlaybackStateMessage>{
      'pause': _state(10, at: 10, playing: false),
      'loading': _state(
        10,
        at: 10,
        processingState: AudioProcessingStateMessage.loading,
      ),
      'buffering': _state(
        10,
        at: 10,
        processingState: AudioProcessingStateMessage.buffering,
      ),
      'completed': _state(
        10,
        at: 10,
        processingState: AudioProcessingStateMessage.completed,
      ),
      'speed': _state(10, at: 10, speed: 1.04),
      'track': _state(10, at: 10, queueIndex: 1),
      'repeat': _state(
        10,
        at: 10,
        repeatMode: AudioServiceRepeatModeMessage.all,
      ),
      'shuffle': _state(
        10,
        at: 10,
        shuffleMode: AudioServiceShuffleModeMessage.all,
      ),
      'error': _state(10, at: 10, errorCode: 1, errorMessage: 'failed'),
      'buffered': _state(10, at: 10, bufferedPosition: _seconds(30)),
      'captions': _state(10, at: 10, captioningEnabled: true),
      'system actions': _state(10, at: 10, systemActions: const {}),
      'compact controls': _state(10, at: 10, compactIndices: const [0, 1, 2]),
      'favorite control': _state(10, at: 10, controls: _controls(loved: true)),
      'custom action': _state(
        10,
        at: 10,
        controls: [
          MediaControlMessage(
            androidIcon: 'drawable/ic_notification_star',
            label: 'Add to Loved',
            action: MediaActionMessage.custom,
            customAction: CustomMediaActionMessage(
              name: 'favorite',
              extras: const {'song': 'two'},
            ),
          ),
          ..._controls().skip(1),
        ],
      ),
    };
    for (final MapEntry(key: change, value: state) in changes.entries) {
      final os = _Os();
      final filter = MediaSessionFilter(os);
      unawaited(filter.setState(_request(_state(0))));
      unawaited(filter.setState(_request(_state(9.4, at: 9.4))));
      unawaited(filter.setState(_request(state)));
      expect(os.states.last, same(state), reason: change);
      expect(os.states, hasLength(2), reason: change);
    }
  });

  test('passes on a position that leaves the advancing one', () {
    final os = _Os();
    final filter = MediaSessionFilter(os);
    unawaited(filter.setState(_request(_state(30, at: 0))));
    // A seek of less than the tolerance stays within it.
    unawaited(filter.setState(_request(_state(40.4, at: 10))));
    expect(os.states, hasLength(1));
    final seek = _state(90, at: 11);
    unawaited(filter.setState(_request(seek)));
    expect(os.states.last, same(seek));

    // A stall that keeps playing: the position stops while time goes on,
    // so each update corrects the OS, as each one did before.
    unawaited(filter.setState(_request(_state(91, at: 12))));
    final ticks = [
      for (var tick = 1; tick <= 3; tick++) _state(91, at: 12 + tick * 0.6),
    ];
    for (final tick in ticks) {
      unawaited(filter.setState(_request(tick)));
    }
    expect(os.states.skip(2), ticks);
  });

  test('passes on any new position while paused', () {
    final os = _Os();
    final filter = MediaSessionFilter(os);
    unawaited(filter.setState(_request(_state(34, at: 0, playing: false))));
    unawaited(filter.setState(_request(_state(34, at: 5, playing: false))));
    expect(os.states, hasLength(1));
    final seek = _state(34.1, at: 6, playing: false);
    unawaited(filter.setState(_request(seek)));
    expect(os.states.last, same(seek));
  });

  test('sends the newest state before a media item, and the next after', () {
    final os = _Os();
    final filter = MediaSessionFilter(os);
    final first = _state(0);
    final newest = _state(9.6, at: 9.6);
    unawaited(filter.setState(_request(first)));
    unawaited(filter.setState(_request(_state(9, at: 9))));
    unawaited(filter.setState(_request(newest)));
    unawaited(filter.setMediaItem(_item('cover')));
    unawaited(filter.setMediaItem(_item('duration')));
    final next = _state(10.2, at: 10.2);
    unawaited(filter.setState(_request(next)));
    unawaited(filter.setState(_request(_state(10.8, at: 10.8))));
    expect(os.requests.map((entry) => entry.request), [
      isA<SetStateRequest>().having((r) => r.state, 'state', same(first)),
      isA<SetStateRequest>().having((r) => r.state, 'state', same(newest)),
      isA<SetMediaItemRequest>(),
      isA<SetMediaItemRequest>(),
      isA<SetStateRequest>().having((r) => r.state, 'state', same(next)),
    ]);
  });

  test('sends the state after a playing one turns ready', () {
    final os = _Os();
    final filter = MediaSessionFilter(os);
    unawaited(
      filter.setState(
        _request(
          _state(0, processingState: AudioProcessingStateMessage.loading),
        ),
      ),
    );
    unawaited(filter.setState(_request(_state(0, at: 2))));
    final first = _state(0.6, at: 2.6);
    unawaited(filter.setState(_request(first)));
    unawaited(filter.setState(_request(_state(1.2, at: 3.2))));
    expect(os.states, hasLength(3));
    expect(os.states.last, same(first));
  });

  test('a failed update or a stopped session sends the next state', () async {
    final os = _Os();
    final filter = MediaSessionFilter(os);
    os.failure = StateError('detached');
    await expectLater(
      filter.setState(_request(_state(0))),
      throwsA(isA<StateError>()),
    );
    await filter.setState(_request(_state(0.6, at: 0.6)));
    expect(os.states, hasLength(2));

    await filter.stopService(const StopServiceRequest());
    await filter.setMediaItem(_item('next'));
    await filter.setState(_request(_state(1.2, at: 1.2)));
    expect(os.requests.map((entry) => entry.request).skip(2), [
      isA<StopServiceRequest>(),
      isA<SetMediaItemRequest>(),
      isA<SetStateRequest>(),
    ]);
  });

  test('passes every other request through', () async {
    final os = _Os();
    final filter = MediaSessionFilter(os);
    final callbacks = _Callbacks();
    final requests = <Object>[
      ConfigureRequest(config: AudioServiceConfigMessage()),
      const SetQueueRequest(queue: []),
      const SetAndroidPlaybackInfoRequest(
        playbackInfo: LocalAndroidPlaybackInfoMessage(),
      ),
      const AndroidForceEnableMediaButtonsRequest(),
      const NotifyChildrenChangedRequest(parentMediaId: 'root'),
    ];
    await filter.configure(requests[0] as ConfigureRequest);
    await filter.setQueue(requests[1] as SetQueueRequest);
    await filter.setAndroidPlaybackInfo(
      requests[2] as SetAndroidPlaybackInfoRequest,
    );
    await filter.androidForceEnableMediaButtons(
      requests[3] as AndroidForceEnableMediaButtonsRequest,
    );
    await filter.notifyChildrenChanged(
      requests[4] as NotifyChildrenChangedRequest,
    );
    filter.setHandlerCallbacks(callbacks);
    expect(os.requests.map((entry) => entry.request), [
      ...requests,
      same(callbacks),
    ]);
  });

  group('install', () {
    late AudioServicePlatform original;

    setUp(() => original = AudioServicePlatform.instance);

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      AudioServicePlatform.instance = original;
    });

    test('filters the Android and Apple sessions only', () {
      for (final platform in TargetPlatform.values) {
        final os = _Os();
        AudioServicePlatform.instance = os;
        debugDefaultTargetPlatformOverride = platform;
        installMediaSessionFilter();
        installMediaSessionFilter();
        final installed = AudioServicePlatform.instance;
        if (platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS ||
            platform == TargetPlatform.macOS) {
          expect(
            installed,
            isA<MediaSessionFilter>().having(
              (filter) => filter.platform,
              'platform',
              same(os),
            ),
            reason: platform.name,
          );
        } else {
          expect(installed, same(os), reason: platform.name);
        }
      }
    });
  });

  test(
    'every OS view shows the position it shows today, within the tolerance',
    () {
      final player = _Player();
      // A local song: loading, then the embedded cover and the engine's
      // duration arrive as media items.
      player.load(0, loading: 0.25);
      player.play(1.2);
      player.mediaItem('song 0 cover');
      player.play(2);
      player.mediaItem('song 0 duration');
      player.play(30);
      player.pause();
      player.now = 40;
      player.seek(12);
      player.now = 45;
      player.resume();
      player.play(60);
      // AutoMix tempo matching, carried by the next position update.
      player.setSpeed(1.04);
      player.play(70);
      player.setSpeed(1);
      player.play(80);
      // Network buffering that keeps the player playing.
      player.stall(3);
      player.play(100);
      player.seek(150);
      player.play(120);
      // A network song: a slow start and its downloaded cover.
      player.load(1, loading: 2);
      player.play(123.5);
      player.mediaItem('song 1 cover');
      // Ten minutes with the screen off and the app in the background, its
      // tags edited on the way, then the app comes back.
      player.play(425);
      player.mediaItem('song 1 edited');
      player.play(725);
      player.refresh();
      player.play(735);
      // The notification's star.
      player.loved = true;
      player.publish();
      player.play(740);
      player.pause();

      expect(player.checks, isEmpty);
      expect(player.today.states, hasLength(greaterThan(1200)));
      expect(player.filtered.states, hasLength(lessThan(30)));
    },
  );

  test('audio_service waits for the OS only on the states it sends', () async {
    final original = AudioServicePlatform.instance;
    addTearDown(() => AudioServicePlatform.instance = original);
    final os = _Os();
    AudioServicePlatform.instance = os;
    installMediaSessionFilter();
    final handler = BaseAudioHandler();
    final session = await AudioService.init(
      builder: () => SwitchAudioHandler(handler),
      cacheManager: _NoCovers(),
    );
    addTearDown(() async {
      await handler.playbackState.close();
      await handler.queue.close();
      await handler.mediaItem.close();
      await handler.androidPlaybackInfo.close();
    });
    // As the player waits: the switch takes each state a microtask later.
    Future<void> synchronize() async {
      await Future<void>.delayed(Duration.zero);
      await AudioService.synchronizePlaybackState();
    }

    await synchronize();
    final sent = os.states.length;

    PlaybackState playing(double seconds, {bool playing = true}) =>
        PlaybackState(
          playing: playing,
          processingState: AudioProcessingState.ready,
          updatePosition: _seconds(seconds),
          updateTime: _start.add(_seconds(seconds)),
        );

    handler.playbackState.add(playing(0));
    await synchronize();
    // Held back states complete at once, without the OS.
    for (var tick = 1; tick <= 100; tick++) {
      handler.playbackState.add(playing(tick * 0.6));
    }
    os.reply = Completer<void>();
    await synchronize();
    expect(os.states, hasLength(sent + 1));

    handler.mediaItem.add(const MediaItem(id: 'one', title: 'One'));
    await pumpEventQueue();
    expect(
      os.requests.reversed.take(2).map((entry) => entry.request).toList(),
      [
        isA<SetMediaItemRequest>(),
        isA<SetStateRequest>().having(
          (request) => request.state.updatePosition,
          'position',
          _seconds(60),
        ),
      ],
    );
    os.reply!.complete();

    os.reply = Completer<void>();
    handler.playbackState.add(playing(61, playing: false));
    var paused = false;
    final synchronized = synchronize().then((_) => paused = true);
    await pumpEventQueue();
    expect(paused, isFalse);
    os.reply!.complete();
    await synchronized;
    expect(os.states.last.playing, isFalse);

    // A paired computer playing in this device's place keeps its own
    // filter, and each state that passes it reaches the OS.
    os.reply = null;
    final remote = _Remote();
    addTearDown(remote.close);
    final remoteSession = RemoteMediaSession(
      remote,
      local: handler,
      onLocal: () {},
    );
    addTearDown(remoteSession.dispose);
    final shown = <PlaybackState>[];
    final watch = remoteSession.playbackState.skip(1).listen(shown.add);
    addTearDown(watch.cancel);
    // The remote's states arrive now, as they do over the network.
    PlaybackState remoteState(double seconds, {bool playing = true}) =>
        PlaybackState(
          playing: playing,
          processingState: AudioProcessingState.ready,
          updatePosition: _seconds(seconds),
        );
    remote.states.add(remoteState(30));
    session.inner = remoteSession;
    for (final seconds in const [30.5, 31.0, 90.0, 90.6]) {
      remote.states.add(remoteState(seconds));
    }
    remote.states.add(remoteState(91, playing: false));
    await pumpEventQueue();
    expect(shown, hasLength(3));
    expect(
      os.states.reversed
          .take(3)
          .toList()
          .reversed
          .map((state) => (state.updatePosition.inSeconds, state.playing)),
      shown.map((state) => (state.updatePosition.inSeconds, state.playing)),
    );

    // Back on this device, the OS shows its player again at once.
    session.inner = handler;
    await pumpEventQueue();
    expect(os.states.last.updatePosition, _seconds(61));
    expect(os.states.last.playing, isFalse);
  });
}

/// A paired device whose song and state the test pushes.
class _Remote implements RemotePlayback {
  final states = StreamController<PlaybackState>.broadcast(sync: true);

  @override
  Stream<PlaybackState> get playbackStates => states.stream;

  @override
  Stream<MediaItem?> get mediaItems => const Stream.empty();

  @override
  Stream<List<MediaItem>> get queues => const Stream.empty();

  @override
  Stream<double> get volumes => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  Future<void> close() => states.close();
}

class _Callbacks implements AudioHandlerCallbacks {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoCovers implements BaseCacheManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
