import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/subsonic_playback_deck.dart';

class _Deck implements PlaybackDeck {
  final positions = StreamController<Duration>.broadcast();
  final durations = StreamController<Duration>.broadcast();
  final states = StreamController<PlaybackDeckState>.broadcast();
  final completions = StreamController<void>.broadcast();
  final sources = <String>[];
  final seeks = <Duration>[];
  final volumes = <double>[];
  final rates = <double>[];
  Duration position = Duration.zero;
  Completer<void>? holdSource;
  Completer<Duration?>? holdPosition;
  int resumes = 0;
  bool emitDurationOnLoad = false;
  @override
  PlaybackDeckState state = PlaybackDeckState.paused;
  @override
  Stream<Duration> get onPositionChanged => positions.stream;
  @override
  Stream<Duration> get onDurationChanged => durations.stream;
  @override
  Stream<PlaybackDeckState> get onPlayerStateChanged => states.stream;
  @override
  Stream<void> get onPlayerComplete => completions.stream;
  @override
  Future<void> setNetworkSource(String url, {bool arriving = false}) async {
    sources.add(url);
    if (emitDurationOnLoad) durations.add(const Duration(seconds: 10));
    await holdSource?.future;
    position = Duration.zero;
  }

  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    position = value;
  }

  @override
  Future<Duration?> getCurrentPosition() async =>
      holdPosition == null ? position : holdPosition!.future;
  @override
  Future<Duration?> getDuration() async => const Duration(seconds: 10);
  @override
  Future<void> setVolume(double value) async => volumes.add(value);
  @override
  Future<void> setPlaybackRate(double value) async => rates.add(value);
  @override
  Future<void> resume() async {
    resumes++;
    state = PlaybackDeckState.playing;
  }

  @override
  Future<void> pause() async => state = PlaybackDeckState.paused;
  @override
  Future<void> stop() async => state = PlaybackDeckState.stopped;
  @override
  Future<void> cancelPreparation() async {}
  @override
  Future<void> dispose() async {
    await positions.close();
    await durations.close();
    await states.close();
    await completions.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QueuedDeck extends _Deck implements QueuedPlaybackDeck {
  void Function()? startQueued;
  @override
  bool get canQueueNextSource => true;
  @override
  Future<bool> queueNextSource(
    String source, {
    required double volume,
    required void Function() onStarted,
  }) async {
    startQueued = onStarted;
    return true;
  }

  @override
  Future<void> clearNextSource() async => startQueued = null;
}

void main() {
  late _Deck engine;
  late SubsonicPlaybackDeck deck;
  var needsOffset = true;
  const url = 'http://127.0.0.1:1234/private-route.flac';
  const duration = Duration(seconds: 240);
  setUp(() {
    engine = _Deck();
    needsOffset = true;
    deck = SubsonicPlaybackDeck(
      inner: engine,
      lookup: (source) async => source == url
          ? SubsonicPlaybackStream(
              url: url,
              duration: duration,
              requiresOffset: (_) => needsOffset,
            )
          : null,
    );
  });
  tearDown(() => deck.dispose());

  test(
    'forward/backward seeks reopen at absolute offsets and keep full timing',
    () async {
      await deck.setNetworkSource(url);
      await deck.setVolume(.4);
      await deck.setPlaybackRate(1.5);
      await deck.resume();
      final positions = <Duration>[];
      final lengths = <Duration>[];
      final positionSub = deck.onPositionChanged.listen(positions.add);
      final durationSub = deck.onDurationChanged.listen(lengths.add);
      for (final seconds in [90, 30, 120, 0]) {
        await deck.seek(Duration(seconds: seconds));
        expect(
          Uri.parse(engine.sources.last).queryParameters['timeOffset'],
          '$seconds',
        );
        expect(engine.state, PlaybackDeckState.playing);
        engine.position = const Duration(seconds: 2);
        engine.positions.add(engine.position);
        engine.durations.add(const Duration(seconds: 10));
        await Future<void>.delayed(Duration.zero);
        expect(await deck.getCurrentPosition(), Duration(seconds: seconds + 2));
        expect(positions.last, Duration(seconds: seconds + 2));
        expect(lengths.last, duration);
        expect(await deck.getDuration(), duration);
      }
      expect(engine.seeks, isEmpty);
      expect(engine.volumes.last, .4);
      expect(engine.rates.last, 1.5);
      await positionSub.cancel();
      await durationSub.cancel();
    },
  );

  test('offsets stay within playable whole seconds', () async {
    await deck.setNetworkSource(url);
    await deck.seek(const Duration(seconds: -5));
    expect(engine.sources.last, '$url?timeOffset=0');
    await deck.seek(const Duration(seconds: 999));
    expect(engine.sources.last, '$url?timeOffset=239');
  });

  test('seeking while paused does not start audio', () async {
    await deck.setNetworkSource(url);
    await deck.seek(const Duration(seconds: 90));
    expect(engine.resumes, 0);
    expect(await deck.getCurrentPosition(), const Duration(seconds: 90));
    await deck.resume();
    expect(engine.resumes, 1);
  });

  test('pause during stream preparation cancels the pending resume', () async {
    await deck.setNetworkSource(url);
    await deck.resume();
    engine.holdSource = Completer<void>();
    final seek = deck.seek(const Duration(seconds: 60));
    await Future<void>.delayed(Duration.zero);
    await deck.pause();
    engine.holdSource!.complete();
    await seek;
    expect(engine.resumes, 1);
    expect(engine.state, PlaybackDeckState.paused);
  });

  test(
    'stop during seek does not resume or publish the abandoned offset',
    () async {
      await deck.setNetworkSource(url);
      await deck.resume();
      engine.holdSource = Completer<void>();
      final seek = deck.seek(const Duration(seconds: 60));
      await Future<void>.delayed(Duration.zero);
      await deck.stop();
      engine.holdSource!.complete();
      await seek;
      expect(engine.resumes, 1);
      expect(await deck.getCurrentPosition(), Duration.zero);
    },
  );

  test('stale position reads cannot acquire a newer segment offset', () async {
    await deck.setNetworkSource(url);
    engine.holdPosition = Completer<Duration?>();
    final old = deck.getCurrentPosition();
    await deck.seek(const Duration(seconds: 60));
    engine.holdPosition!.complete(const Duration(seconds: 5));
    expect(await old, isNull);
  });

  test('ranged streams and unsupported sources keep native seeking', () async {
    needsOffset = false;
    await deck.setNetworkSource(url);
    await deck.seek(const Duration(seconds: 70));
    expect(engine.sources, [url]);
    expect(engine.seeks.last, const Duration(seconds: 70));
    await deck.setNetworkSource('https://example.com/audio.mp3');
    await deck.seek(const Duration(seconds: 20));
    expect(engine.seeks.last, const Duration(seconds: 20));
    expect(await deck.getCurrentPosition(), const Duration(seconds: 20));
    expect(await deck.getDuration(), const Duration(seconds: 10));
  });

  test('changing tracks resets the previous offset', () async {
    await deck.setNetworkSource(url);
    await deck.seek(const Duration(seconds: 90));
    await deck.setNetworkSource(url);
    expect(await deck.getCurrentPosition(), Duration.zero);
  });

  test(
    'ordinary network sources retain initial native duration events',
    () async {
      final lengths = <Duration>[];
      final sub = deck.onDurationChanged.listen(lengths.add);
      engine.emitDurationOnLoad = true;
      await deck.setNetworkSource('https://example.com/audio.mp3');
      await Future<void>.delayed(Duration.zero);
      expect(lengths, [const Duration(seconds: 10)]);
      await sub.cancel();
    },
  );

  test(
    'queued handoff resets offsets and uses the next song metadata',
    () async {
      final queued = _QueuedDeck();
      const nextUrl = 'http://127.0.0.1:1234/next.flac';
      final other = SubsonicPlaybackDeck(
        inner: queued,
        lookup: (source) async => SubsonicPlaybackStream(
          url: source,
          duration: source == url ? duration : const Duration(seconds: 300),
          requiresOffset: (_) => true,
        ),
      );
      await other.setNetworkSource(url);
      await other.seek(const Duration(seconds: 90));
      expect(other.canQueueNextSource, isTrue);
      var started = false;
      expect(
        await other.queueNextSource(
          nextUrl,
          volume: .5,
          onStarted: () => started = true,
        ),
        isTrue,
      );
      queued.startQueued!();
      expect(started, isTrue);
      expect(await other.getCurrentPosition(), Duration.zero);
      expect(await other.getDuration(), const Duration(seconds: 300));
      await other.seek(const Duration(seconds: 30));
      expect(queued.sources.last, '$nextUrl?timeOffset=30');
      await other.dispose();
    },
  );

  test('discovery cancelled by stop never opens or resumes a source', () async {
    final discovery = Completer<SubsonicPlaybackStream?>();
    final otherEngine = _Deck();
    final other = SubsonicPlaybackDeck(
      inner: otherEngine,
      lookup: (_) => discovery.future,
    );
    final load = other.setNetworkSource(url);
    await other.stop();
    discovery.complete(null);
    await load;
    expect(otherEngine.sources, isEmpty);
    expect(otherEngine.resumes, 0);
    await other.dispose();
  });
}
