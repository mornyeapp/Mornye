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
  }
}

/// This device's player, which keeps browsing and Library playback.
class _Local extends BaseAudioHandler {
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
