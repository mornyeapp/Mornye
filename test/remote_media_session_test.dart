import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/remote_media_session.dart';
import 'package:mornye/services/remote_playback.dart';

/// A remote device whose song, queue and state the test pushes.
class _Remote implements RemotePlayback {
  final items = StreamController<MediaItem?>.broadcast(sync: true);
  final states = StreamController<PlaybackState>.broadcast(sync: true);
  final queue = StreamController<List<MediaItem>>.broadcast(sync: true);
  final volume = StreamController<double>.broadcast(sync: true);
  final volumeWrites = <double>[];
  Completer<void>? volumeReply;
  final calls = <String>[];

  @override
  String get name => 'Studio PC';

  @override
  Stream<MediaItem?> get mediaItems => items.stream;

  @override
  Stream<PlaybackState> get playbackStates => states.stream;

  @override
  Stream<List<MediaItem>> get queues => queue.stream;

  @override
  Stream<double> get volumes => volume.stream;

  @override
  Future<void> setVolume(double value) async {
    volumeWrites.add(value);
    await volumeReply?.future;
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seek(Duration position) async =>
      calls.add('seek:${position.inSeconds}');

  @override
  Future<void> next() async => calls.add('next');

  @override
  Future<void> previous() async => calls.add('previous');

  @override
  Future<void> jumpTo(int index) async => calls.add('jump:$index');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  Future<void> close() async {
    await items.close();
    await states.close();
    await queue.close();
    await volume.close();
  }
}

/// This device's player, which keeps browsing and Library playback.
class _Local extends BaseAudioHandler {
  _Local() {
    androidPlaybackInfo.add(LocalAndroidPlaybackInfo());
  }

  final calls = <String>[];

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    calls.add('children:$parentMediaId');
    return const [];
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async => calls.add('playFromMediaId:$mediaId');

  @override
  Future<void> playFromSearch(
    String query, [
    Map<String, dynamic>? extras,
  ]) async => calls.add('playFromSearch:$query');
}

PlaybackState _playing(Duration position, {bool playing = true}) =>
    PlaybackState(
      processingState: AudioProcessingState.ready,
      playing: playing,
      updatePosition: position,
      queueIndex: 0,
    );

void main() {
  late _Remote remote;
  late _Local local;
  late RemoteMediaSession session;
  late int handedBack;

  setUp(() {
    remote = _Remote();
    local = _Local();
    handedBack = 0;
    session = RemoteMediaSession(
      remote,
      local: local,
      onLocal: () => handedBack++,
    );
  });

  tearDown(() async {
    session.dispose();
    await remote.close();
  });

  const song = MediaItem(id: 'desk', title: 'Desk Song');

  test('shows the remote song and queue with its own buttons', () {
    remote.items.add(song);
    remote.queue.add(const [song]);
    remote.states.add(_playing(const Duration(seconds: 30)));

    expect(session.mediaItem.value, song);
    expect(session.queue.value, [song]);
    final state = session.playbackState.value;
    expect(state.playing, isTrue);
    expect(state.position, greaterThanOrEqualTo(const Duration(seconds: 30)));
    expect(state.controls.map((control) => control.action), [
      MediaAction.skipToPrevious,
      MediaAction.pause,
      MediaAction.skipToNext,
    ]);
    expect(state.androidCompactActionIndices, [0, 1, 2]);

    remote.states.add(_playing(const Duration(seconds: 30), playing: false));
    expect(session.playbackState.value.controls[1].action, MediaAction.play);
  });

  test('passes position ticks on only when the position jumps', () {
    remote.states.add(_playing(const Duration(seconds: 30)));
    final shown = session.playbackState.value;
    remote.states.add(_playing(const Duration(milliseconds: 30500)));
    expect(identical(session.playbackState.value, shown), isTrue);
    remote.states.add(_playing(const Duration(seconds: 90)));
    expect(identical(session.playbackState.value, shown), isFalse);
  });

  test('its buttons drive the remote', () async {
    remote.states.add(_playing(Duration.zero));
    await session.click();
    await session.play();
    await session.seek(const Duration(seconds: 12));
    await session.skipToNext();
    await session.skipToPrevious();
    await session.skipToQueueItem(1);
    await session.stop();
    expect(remote.calls, [
      'pause',
      'play',
      'seek:12',
      'next',
      'previous',
      'jump:1',
      'pause',
    ]);
    expect(local.calls, isEmpty);
  });

  test('Android volume follows the desktop player', () {
    remote.volume.add(0.42);
    final info = session.androidPlaybackInfo.value as RemoteAndroidPlaybackInfo;
    expect(info.volumeControlType, AndroidVolumeControlType.absolute);
    expect(info.maxVolume, 100);
    expect(info.volume, 42);

    remote.volume.add(0.8);
    expect(
      (session.androidPlaybackInfo.value as RemoteAndroidPlaybackInfo).volume,
      80,
    );
    expect(remote.volumeWrites, isEmpty);
  });

  test('Android volume keys wait for a known desktop volume', () async {
    expect(
      (session.androidPlaybackInfo.value as RemoteAndroidPlaybackInfo)
          .volumeControlType,
      AndroidVolumeControlType.fixed,
    );
    await session.androidAdjustRemoteVolume(AndroidVolumeDirection.raise);
    await session.androidSetRemoteVolume(50);
    expect(remote.volumeWrites, isEmpty);
  });

  test(
    'rapid Android volume keys accumulate before the desktop replies',
    () async {
      remote.volume.add(0.4);
      remote.volumeReply = Completer<void>();
      final first = session.androidAdjustRemoteVolume(
        AndroidVolumeDirection.raise,
      );
      final second = session.androidAdjustRemoteVolume(
        AndroidVolumeDirection.raise,
      );
      final third = session.androidAdjustRemoteVolume(
        AndroidVolumeDirection.lower,
      );
      expect(remote.volumeWrites, [0.45, 0.5, 0.45]);
      expect(
        (session.androidPlaybackInfo.value as RemoteAndroidPlaybackInfo).volume,
        45,
      );
      remote.volumeReply!.complete();
      await Future.wait([first, second, third]);
      expect(local.calls, isEmpty);
    },
  );

  test('Android volume keys clamp at the desktop limits', () async {
    remote.volume.add(0.98);
    await session.androidAdjustRemoteVolume(AndroidVolumeDirection.raise);
    await session.androidAdjustRemoteVolume(AndroidVolumeDirection.raise);
    await session.androidAdjustRemoteVolume(AndroidVolumeDirection.same);
    expect(remote.volumeWrites, [1.0]);

    remote.volume.add(0.02);
    await session.androidAdjustRemoteVolume(AndroidVolumeDirection.lower);
    await session.androidAdjustRemoteVolume(AndroidVolumeDirection.lower);
    expect(remote.volumeWrites, [1.0, 0.0]);
  });

  test('Android volume slider sets the desktop percentage', () async {
    remote.volume.add(0.4);
    await session.androidSetRemoteVolume(83);
    await session.androidSetRemoteVolume(200);
    await session.androidSetRemoteVolume(-10);
    expect(remote.volumeWrites, [0.83, 1.0, 0.0]);
  });

  test('invalid remote volume cannot break Android volume handling', () {
    remote.volume.add(0.4);
    remote.volume.add(double.nan);
    remote.volume.add(double.infinity);
    expect(
      (session.androidPlaybackInfo.value as RemoteAndroidPlaybackInfo).volume,
      40,
    );
    remote.volume.add(1.5);
    expect(
      (session.androidPlaybackInfo.value as RemoteAndroidPlaybackInfo).volume,
      100,
    );
    remote.volume.add(-1);
    expect(
      (session.androidPlaybackInfo.value as RemoteAndroidPlaybackInfo).volume,
      0,
    );
  });

  test('switching back restores local Android volume handling', () async {
    final system = SwitchAudioHandler(local);
    expect(
      await system.androidPlaybackInfo.first,
      isA<LocalAndroidPlaybackInfo>(),
    );
    remote.volume.add(0.4);
    system.inner = session;
    expect(
      await system.androidPlaybackInfo.firstWhere(
        (info) => info is RemoteAndroidPlaybackInfo,
      ),
      isA<RemoteAndroidPlaybackInfo>(),
    );
    await system.androidAdjustRemoteVolume(AndroidVolumeDirection.raise);
    expect(remote.volumeWrites, [0.45]);

    system.inner = local;
    session.dispose();
    expect(
      await system.androidPlaybackInfo.firstWhere(
        (info) => info is LocalAndroidPlaybackInfo,
      ),
      isA<LocalAndroidPlaybackInfo>(),
    );
    remote.volume.add(0.7);
    await system.androidAdjustRemoteVolume(AndroidVolumeDirection.raise);
    await session.androidAdjustRemoteVolume(AndroidVolumeDirection.raise);
    expect(remote.volumeWrites, [0.45]);
    expect(remote.volume.hasListener, isFalse);
  });

  test('the car browses and plays Library songs here', () async {
    remote.queue.add(const [song]);
    await session.getChildren('root');
    await session.playFromMediaId('desk');
    expect(remote.calls, ['jump:0']);
    expect(handedBack, 0);

    await session.playFromMediaId('library-song');
    await session.playFromSearch('some artist');
    expect(local.calls, [
      'children:root',
      'playFromMediaId:library-song',
      'playFromSearch:some artist',
    ]);
    expect(handedBack, 2);

    await session.playFromSearch('');
    expect(remote.calls.last, 'play');
  });
}
