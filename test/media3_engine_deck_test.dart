import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/media3_playback_deck.dart';
import 'package:mornye/services/playback_deck.dart';

class _Deck implements PlaybackDeck, QueuedPlaybackDeck {
  _Deck(this.name);

  final String name;
  final calls = <String>[];
  final states = StreamController<PlaybackDeckState>.broadcast();
  final durations = StreamController<Duration>.broadcast();
  final positions = StreamController<Duration>.broadcast();
  final completions = StreamController<void>.broadcast();
  bool disposed = false;
  PlaybackDeck? nextDeck;

  @override
  bool get canQueueNextSource => name == 'media3';

  @override
  Future<bool> queueNextSource(
    String source, {
    required double volume,
    required void Function() onStarted,
  }) async {
    calls.add('queue $source');
    return true;
  }

  @override
  Future<void> clearNextSource() async => calls.add('clear next');

  @override
  PlaybackDeckState state = PlaybackDeckState.stopped;
  @override
  bool get isDirect => false;
  @override
  PlaybackTempoSupport tempoSupport = PlaybackTempoSupport.full;
  @override
  bool get needsSourceReload => false;
  @override
  Stream<PlaybackDeckState> get onPlayerStateChanged => states.stream;
  @override
  Stream<Duration> get onDurationChanged => durations.stream;
  @override
  Stream<Duration> get onPositionChanged => positions.stream;
  @override
  Stream<void> get onPlayerComplete => completions.stream;

  @override
  void startPositionUpdates(Duration interval, {bool Function()? wanted}) =>
      calls.add('positions ${interval.inMilliseconds}');

  @override
  Future<void> configureOutput() async => calls.add('configure');
  @override
  Future<void> setVolume(double volume) async => calls.add('volume $volume');
  @override
  Future<void> setPlaybackRate(double rate) async => calls.add('rate $rate');
  @override
  Future<void> setNetworkSource(String url, {bool arriving = false}) async =>
      calls.add('url $url');
  @override
  Future<void> setFileSource(
    String path, {
    bool preferBitPerfect = false,
    bool directUsb = false,
    bool allowDop = false,
    bool requiresDsd = false,
    bool allowFixedVolume = false,
    bool dapExclusive = false,
    int usbMaxSampleRate = 0,
    bool usbDitherHighPass = false,
  }) async {
    final flags = [
      if (preferBitPerfect) 'bit-perfect',
      if (directUsb) 'usb',
      if (allowDop) 'dop',
      if (requiresDsd) 'dsd',
      if (allowFixedVolume) 'fixed',
      if (dapExclusive) 'aaudio',
    ];
    calls.add(['file $path', ...flags].join(' '));
  }

  @override
  Future<void> cancelPreparation() async {}
  @override
  Future<void> resume() async {
    calls.add('resume');
    state = PlaybackDeckState.playing;
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    state = PlaybackDeckState.paused;
  }

  @override
  Future<void> seek(Duration position) async =>
      calls.add('seek ${position.inSeconds}');
  @override
  Future<void> stop() async {
    calls.add('stop');
    state = PlaybackDeckState.stopped;
  }

  @override
  Future<bool> setNextDeck(PlaybackDeck? next) async {
    nextDeck = next;
    return true;
  }

  @override
  Future<Duration?> getCurrentPosition() async => const Duration(seconds: 30);
  @override
  Future<Duration?> getDuration() async => const Duration(minutes: 3);
  @override
  Future<void> dispose() async {
    disposed = true;
    await states.close();
    await durations.close();
    await positions.close();
    await completions.close();
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Deck audioplayers;
  late List<_Deck> media3;
  late Media3EngineDeck deck;

  Media3EngineDeck create(_Deck primary, List<_Deck> created) =>
      Media3EngineDeck(
        audioplayers: primary,
        createMedia3: () {
          final deck = _Deck('media3');
          created.add(deck);
          return deck;
        },
      );

  setUp(() {
    audioplayers = _Deck('audioplayers');
    media3 = [];
    deck = create(audioplayers, media3);
  });

  tearDown(() async {
    await deck.dispose();
    playbackMedia3Engine.value = false;
    Media3PlaybackDeck.debugResetAvailability();
  });

  test('while off every source plays through audioplayers', () async {
    await deck.configureOutput();
    await deck.setFileSource('/song.flac');
    await deck.resume();
    await deck.setNetworkSource('https://example.com/song.flac');
    expect(audioplayers.calls, [
      'configure',
      'file /song.flac',
      'resume',
      'url https://example.com/song.flac',
    ]);
    expect(media3, isEmpty);
    expect(deck.activeDeck, same(audioplayers));
    expect(deck.canQueueNextSource, isFalse);
  });

  test('reports what the deck playing now does with speed and pitch', () async {
    var notices = 0;
    void counted() => notices++;
    playbackTempoSupportRevision.addListener(counted);
    addTearDown(() => playbackTempoSupportRevision.removeListener(counted));
    audioplayers.tempoSupport = PlaybackTempoSupport.none;
    expect(deck.tempoSupport, PlaybackTempoSupport.none);
    playbackMedia3Engine.value = true;
    await deck.configureOutput();
    await deck.setFileSource('/song.flac');
    expect(deck.activeDeck, same(media3.single));
    expect(deck.tempoSupport, PlaybackTempoSupport.full);
    expect(notices, 1);
    await deck.setPlaybackRate(1.05);
    expect(media3.single.calls, contains('rate 1.05'));
  });

  test(
    'while on a source plays through media3 with the settings so far',
    () async {
      await deck.setVolume(0.5);
      deck.startPositionUpdates(const Duration(milliseconds: 200));
      playbackMedia3Engine.value = true;
      await deck.configureOutput();
      await deck.setFileSource('/song.flac');
      await deck.resume();

      expect(media3.single.calls, [
        'volume 0.5',
        'rate 1.0',
        'positions 200',
        'configure',
        'file /song.flac',
        'resume',
      ]);
      expect(audioplayers.calls, [
        'volume 0.5',
        'positions 200',
        'configure',
        'stop',
      ]);
      expect(deck.state, PlaybackDeckState.playing);
      expect(deck.activeDeck, same(media3.single));
    },
  );

  test('sources for the native outputs stay on audioplayers', () async {
    playbackMedia3Engine.value = true;
    await deck.setFileSource('/one.flac');
    expect(media3, hasLength(1));

    await deck.setFileSource(
      '/two.flac',
      preferBitPerfect: true,
      directUsb: true,
      allowDop: true,
      allowFixedVolume: true,
    );
    expect(audioplayers.calls.last, 'file /two.flac bit-perfect usb dop fixed');
    // Leaving media3 releases its player.
    expect(media3.single.disposed, isTrue);

    await deck.setFileSource(
      '/three.flac',
      preferBitPerfect: true,
      dapExclusive: true,
    );
    await deck.setFileSource('/four.dsf', requiresDsd: true);
    expect(audioplayers.calls.skip(audioplayers.calls.length - 2), [
      'file /three.flac bit-perfect aaudio',
      'file /four.dsf dsd',
    ]);
    expect(media3, hasLength(1));

    // Without bit-perfect output the native options change nothing.
    await deck.setFileSource('/five.flac', dapExclusive: true, allowDop: true);
    await deck.setNetworkSource('https://example.com/six.flac');
    expect(media3, hasLength(2));
    expect(
      media3.last.calls,
      containsAllInOrder([
        'configure',
        'file /five.flac dop aaudio',
        'url https://example.com/six.flac',
      ]),
    );
  });

  test('a change mid-song applies from the next song', () async {
    final states = <PlaybackDeckState>[];
    deck.onPlayerStateChanged.listen(states.add);
    await deck.setFileSource('/one.flac');
    await deck.resume();

    playbackMedia3Engine.value = true;
    await _settle();
    await _settle();
    expect(media3, isEmpty);
    expect(audioplayers.calls, ['file /one.flac', 'resume']);
    expect(deck.state, PlaybackDeckState.playing);

    await deck.configureOutput();
    await deck.setFileSource('/two.flac');
    await deck.resume();
    expect(
      media3.single.calls,
      containsAllInOrder(['file /two.flac', 'resume']),
    );

    // The deck left behind no longer reports.
    audioplayers.states.add(PlaybackDeckState.stopped);
    media3.single.states.add(PlaybackDeckState.playing);
    await _settle();
    expect(states, [PlaybackDeckState.playing]);

    playbackMedia3Engine.value = false;
    await _settle();
    expect(media3.single.disposed, isFalse);
    expect(deck.activeDeck, same(media3.single));

    await deck.configureOutput();
    await deck.setFileSource('/three.flac');
    expect(media3.single.disposed, isTrue);
    expect(audioplayers.calls.last, 'file /three.flac');
    expect(deck.activeDeck, same(audioplayers));
  });

  test('gapless queues only on media3 and links audioplayers decks', () async {
    playbackMedia3Engine.value = true;
    await deck.setFileSource('/one.flac');
    expect(deck.canQueueNextSource, isTrue);
    var started = 0;
    expect(
      await deck.queueNextSource(
        '/two.flac',
        volume: 1,
        onStarted: () => started++,
      ),
      isTrue,
    );
    expect(media3.single.calls.last, 'queue /two.flac');
    await deck.clearNextSource();
    expect(media3.single.calls.last, 'clear next');

    playbackMedia3Engine.value = false;
    await deck.setFileSource('/three.flac');
    expect(deck.canQueueNextSource, isFalse);

    final nextPrimary = _Deck('audioplayers');
    final next = create(nextPrimary, []);
    addTearDown(next.dispose);
    await next.setFileSource('/four.flac');
    expect(await deck.setNextDeck(next), isTrue);
    expect(audioplayers.nextDeck, same(nextPrimary));
  });

  test('a build without media3 plays through audioplayers', () async {
    var created = 0;
    await deck.dispose();
    audioplayers = _Deck('audioplayers');
    deck = Media3EngineDeck(
      audioplayers: audioplayers,
      createMedia3: () {
        created++;
        // No channel handler: the native player is missing.
        return Media3PlaybackDeck(playerId: 'missing');
      },
    );
    playbackMedia3Engine.value = true;
    await deck.setFileSource('/one.flac');
    expect(audioplayers.calls.last, 'file /one.flac');
    expect(deck.activeDeck, same(audioplayers));
    expect(Media3PlaybackDeck.isAvailable, isFalse);

    await deck.setFileSource('/two.flac');
    expect(audioplayers.calls.last, 'file /two.flac');
    expect(created, 1);
  });

  test('a newer source during a switch wins', () async {
    playbackMedia3Engine.value = true;
    final first = deck.setFileSource('/one.flac');
    playbackMedia3Engine.value = false;
    final second = deck.setFileSource('/two.flac');
    await Future.wait([first, second]);
    expect(audioplayers.calls.last, 'file /two.flac');
    expect([
      for (final deck in media3) ...deck.calls,
    ], isNot(contains('file /one.flac')));
    expect(deck.activeDeck, same(audioplayers));
  });

  group('cleartext streams', () {
    setUp(() => playbackMedia3Engine.value = true);

    for (final url in [
      'http://192.168.1.20:4533/rest/stream?id=1',
      'http://nas.example.com/song.flac',
      'HTTP://Media.Example.com/song.flac',
      // The security config allows these loopback names only.
      'http://[::1]:8080/song.flac',
      'http://127.0.0.2:8080/song.flac',
    ]) {
      test('a stream from another host stays on audioplayers ($url)', () async {
        await deck.setNetworkSource(url);
        expect(audioplayers.calls.last, 'url $url');
        expect(media3, isEmpty);
        expect(deck.activeDeck, same(audioplayers));
      });
    }

    for (final url in [
      'http://127.0.0.1:8080/song.flac',
      'http://localhost:8080/song.flac',
      'https://192.168.1.20/song.flac',
      'https://example.com/song.flac',
    ]) {
      test('loopback http and https play through media3 ($url)', () async {
        await deck.setNetworkSource(url);
        expect(media3.single.calls.last, 'url $url');
        expect(deck.activeDeck, same(media3.single));
      });
    }

    test('a LAN stream is not queued on media3', () async {
      await deck.setFileSource('/one.flac');
      expect(deck.canQueueNextSource, isTrue);
      expect(
        await deck.queueNextSource(
          'http://192.168.1.20/next.flac',
          volume: 1,
          onStarted: () {},
        ),
        isFalse,
      );
      expect(media3.single.calls, isNot(contains(startsWith('queue'))));

      expect(
        await deck.queueNextSource(
          'http://127.0.0.1:8080/next.flac',
          volume: 1,
          onStarted: () {},
        ),
        isTrue,
      );
      expect(media3.single.calls.last, 'queue http://127.0.0.1:8080/next.flac');

      // The ordinary handoff then opens the LAN stream on audioplayers.
      await deck.setNetworkSource('http://192.168.1.20/next.flac');
      expect(audioplayers.calls.last, 'url http://192.168.1.20/next.flac');
      expect(media3.single.disposed, isTrue);
    });
  });
}
