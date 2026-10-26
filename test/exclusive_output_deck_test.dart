import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/exclusive_output_deck.dart';
import 'package:mornye/services/playback_deck.dart';

class _Deck implements PlaybackDeck {
  _Deck(this.name);

  final String name;
  final calls = <String>[];
  final states = StreamController<PlaybackDeckState>.broadcast();
  final durations = StreamController<Duration>.broadcast();
  final positions = StreamController<Duration>.broadcast();
  final completions = StreamController<void>.broadcast();
  Duration position = Duration.zero;
  bool disposed = false;

  @override
  PlaybackDeckState state = PlaybackDeckState.stopped;
  @override
  bool get isDirect => false;
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
  void startPositionUpdates(Duration interval) =>
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
  }) async => calls.add('file $path');
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
  Future<bool> setNextDeck(PlaybackDeck? next) async => false;
  @override
  Future<Duration?> getCurrentPosition() async => position;
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
  late _Deck shared;
  late List<_Deck> exclusives;
  late bool available;
  late ExclusiveOutputDeck deck;

  setUp(() {
    shared = _Deck('shared');
    exclusives = [];
    available = true;
    deck = ExclusiveOutputDeck(
      shared: shared,
      createExclusive: () {
        final created = _Deck('mpv');
        exclusives.add(created);
        return created;
      },
      exclusiveAvailable: () => available,
    );
  });

  tearDown(() async {
    await deck.dispose();
    playbackExclusiveOutput.value = false;
    playbackExclusiveStatus.value = ExclusiveOutputStatus.pending;
  });

  test('plays through the shared deck while exclusive output is off', () async {
    await deck.configureOutput();
    await deck.setFileSource('/song.flac');
    await deck.resume();
    expect(shared.calls, ['configure', 'file /song.flac', 'resume']);
    expect(exclusives, isEmpty);
  });

  test('the next source opens on libmpv once it is on', () async {
    await deck.setVolume(0.5);
    deck.startPositionUpdates(const Duration(milliseconds: 200));
    playbackExclusiveOutput.value = true;
    await _settle();
    await deck.configureOutput();
    await deck.setFileSource('/song.flac');
    expect(exclusives, hasLength(1));
    expect(exclusives.single.calls, [
      'volume 0.5',
      'rate 1.0',
      'positions 200',
      'configure',
      'file /song.flac',
    ]);
    expect(shared.calls.last, 'stop');
  });

  test('a change mid-track reopens the song where it was', () async {
    final forwarded = <PlaybackDeckState>[];
    deck.onPlayerStateChanged.listen(forwarded.add);
    await deck.setFileSource('/song.flac');
    await deck.resume();
    shared.position = const Duration(seconds: 30);

    playbackExclusiveOutput.value = true;
    await _settle();
    await _settle();
    final mpv = exclusives.single;
    expect(mpv.calls.skip(2), [
      'configure',
      'file /song.flac',
      'seek 30',
      'resume',
    ]);
    expect(deck.state, PlaybackDeckState.playing);

    // The deck left behind no longer reports.
    shared.states.add(PlaybackDeckState.stopped);
    mpv.states.add(PlaybackDeckState.playing);
    await _settle();
    expect(forwarded, [PlaybackDeckState.playing]);

    // Turning it off gives the device back and resumes on the shared deck.
    mpv.position = const Duration(seconds: 42);
    playbackExclusiveOutput.value = false;
    for (var i = 0; i < 5; i++) {
      await _settle();
    }
    expect(mpv.disposed, isTrue);
    expect(shared.calls.skip(shared.calls.lastIndexOf('stop') + 1), [
      'volume 1.0',
      'rate 1.0',
      'configure',
      'file /song.flac',
      'seek 42',
      'resume',
    ]);
  });

  test('without libmpv the song stays on the shared deck', () async {
    available = false;
    playbackExclusiveOutput.value = true;
    await deck.configureOutput();
    await deck.setFileSource('/song.flac');
    expect(exclusives, isEmpty);
    expect(shared.calls, ['configure', 'file /song.flac']);
    expect(playbackExclusiveStatus.value, ExclusiveOutputStatus.unavailable);
  });
}
