import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/music_player_service.dart';

class _CompletingMockDeck implements PlaybackDeck {
  final _completeController = StreamController<void>.broadcast();
  bool paused = false;

  @override
  PlaybackDeckState state = PlaybackDeckState.stopped;

  @override
  bool get isDirect => false;
  @override
  bool get needsSourceReload => false;
  @override
  Stream<PlaybackDeckState> get onPlayerStateChanged => const Stream.empty();
  @override
  Stream<Duration> get onPositionChanged => const Stream.empty();
  @override
  Stream<Duration> get onDurationChanged => const Stream.empty();
  @override
  Stream<void> get onPlayerComplete => _completeController.stream;

  void triggerComplete() {
    _completeController.add(null);
  }

  @override
  void startPositionUpdates(Duration interval, {bool Function()? wanted}) {}
  @override
  Future<void> configureOutput() async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> cancelPreparation() async {}
  @override
  Future<void> stop() async => state = PlaybackDeckState.stopped;
  @override
  Future<void> pause() async {
    paused = true;
    state = PlaybackDeckState.paused;
  }
  @override
  Future<void> resume() async => state = PlaybackDeckState.playing;
  @override
  Future<void> seek(Duration value) async {}
  @override
  Future<Duration?> getDuration() async => const Duration(seconds: 180);
  @override
  Future<Duration?> getCurrentPosition() async => Duration.zero;
  @override
  Future<void> dispose() async {
    await _completeController.close();
  }
  @override
  Future<void> setFileSource(
    String path, {
    bool preferBitPerfect = false,
    bool directUsb = false,
    bool allowDop = false,
    bool requiresDsd = false,
    bool allowFixedVolume = false,
    bool dapExclusive = false,
    bool gaplessAudio = false,
    Duration startPosition = Duration.zero,
  }) async {
    state = PlaybackDeckState.playing;
  }
  @override
  Future<void> setPlaybackRate(double rate) async {}
  @override
  Future<void> setNetworkSource(String url, {bool arriving = false}) async {}
  @override
  Future<bool> setNextDeck(PlaybackDeck? next) async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('setSleepTimerEndOfTrack pauses playback on player complete', () async {
    late _CompletingMockDeck mockDeck;
    final runtime = MusicPlayerRuntime(
      dependencies: PlaybackDependencies(
        createDeck: (_) {
          mockDeck = _CompletingMockDeck();
          return mockDeck;
        },
      ),
    );
    final handler = MusicPlayerHandler(runtime: runtime);
    final item1 = const PlayableMedia(
      id: '1',
      source: 'local://1',
      title: 'Song 1',
      artist: 'Artist 1',
    );
    final item2 = const PlayableMedia(
      id: '2',
      source: 'local://2',
      title: 'Song 2',
      artist: 'Artist 2',
    );

    await handler.setQueueAndPlay([item1, item2], initialIndex: 0);

    expect(handler.isSleepTimerEndOfTrack, isFalse);

    // Set sleep timer to end of track
    handler.setSleepTimerEndOfTrack();
    expect(handler.isSleepTimerEndOfTrack, isTrue);

    // Trigger song complete
    mockDeck.triggerComplete();
    await pumpEventQueue();

    // Verify playback was paused and flag was cleared
    expect(mockDeck.paused, isTrue);
    expect(handler.isSleepTimerEndOfTrack, isFalse);
  });

  test('cancelSleepTimer clears isSleepTimerEndOfTrack', () async {
    final runtime = MusicPlayerRuntime(
      dependencies: PlaybackDependencies(
        createDeck: (_) => _CompletingMockDeck(),
      ),
    );
    final handler = MusicPlayerHandler(runtime: runtime);

    handler.setSleepTimerEndOfTrack();
    expect(handler.isSleepTimerEndOfTrack, isTrue);

    handler.cancelSleepTimer();
    expect(handler.isSleepTimerEndOfTrack, isFalse);
  });
}
