import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/music_player_service.dart';

class _MockDeck implements PlaybackDeck {
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
  Stream<void> get onPlayerComplete => const Stream.empty();

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
  Future<void> pause() async => state = PlaybackDeckState.paused;
  @override
  Future<void> resume() async => state = PlaybackDeckState.playing;
  @override
  Future<void> seek(Duration value) async {}
  @override
  Future<Duration?> getDuration() async => const Duration(seconds: 180);
  @override
  Future<Duration?> getCurrentPosition() async => Duration.zero;
  @override
  Future<void> dispose() async {}
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

  test(
    'updateQueuePreservingCurrent updates queue without stopping current playback',
    () async {
      final runtime = MusicPlayerRuntime(
        dependencies: PlaybackDependencies(createDeck: (_) => _MockDeck()),
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
      final item3 = const PlayableMedia(
        id: '3',
        source: 'local://3',
        title: 'Song 3',
        artist: 'Artist 3',
      );

      // Initial play with only item2
      await handler.setQueueAndPlay([item2], initialIndex: 0);
      expect(handler.queue.value.length, equals(1));
      expect(handler.queue.value.first.title, equals('Song 2'));

      // Now update queue preserving current item2 at index 1
      handler.updateQueuePreservingCurrent([item1, item2, item3], 1);

      expect(handler.queue.value.length, equals(3));
      expect(handler.queue.value[0].title, equals('Song 1'));
      expect(handler.queue.value[1].title, equals('Song 2'));
      expect(handler.queue.value[2].title, equals('Song 3'));
    },
  );
}
