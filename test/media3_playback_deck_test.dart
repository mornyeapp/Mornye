import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/services/media3_playback_deck.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/playback_equalizer.dart';

const _channel = MethodChannel('com.zarz.mornye/media3_player');

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// The native side of the channel contract: replies, event sinks and the
/// `superseded` rule for a source still preparing.
class _Native {
  _Native() {
    _messenger.setMockMethodCallHandler(_channel, _handle);
  }

  final calls = <MethodCall>[];
  final sinks = <String, MockStreamHandlerEventSink>{};
  final cancelled = <String>[];
  final replies = <String, Future<Object?> Function(MethodCall call)>{};
  bool holdSource = false;
  bool ignoreClear = false;
  Completer<Object?>? pendingSource;
  int position = 0;

  List<String> get methods => [for (final call in calls) call.method];
  int count(String method) => methods.where((name) => name == method).length;
  Map<Object?, Object?> last(String method) =>
      calls.lastWhere((call) => call.method == method).arguments
          as Map<Object?, Object?>;

  void _supersede() {
    final pending = pendingSource;
    pendingSource = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(PlatformException(code: 'superseded'));
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    final arguments = call.arguments as Map<Object?, Object?>;
    final id = arguments['playerId']! as String;
    final reply = replies[call.method];
    if (reply != null) return reply(call);
    switch (call.method) {
      case 'create':
        _messenger.setMockStreamHandler(
          EventChannel('com.zarz.mornye/media3_player/events/$id'),
          MockStreamHandler.inline(
            onListen: (_, sink) => sinks[id] = sink,
            onCancel: (_) => cancelled.add(id),
          ),
        );
        return {'audioSessionId': 7};
      case 'setSource':
        _supersede();
        if (!holdSource) return {'durationMs': 180000};
        return (pendingSource = Completer<Object?>()).future;
      case 'clearSource':
        if (!ignoreClear) _supersede();
        return null;
      case 'stop':
      case 'dispose':
        _supersede();
        return null;
      case 'queueNext':
        return true;
      case 'getPosition':
        return position;
      case 'getDuration':
        return 180000;
      default:
        return null;
    }
  }

  Future<void> emit(String playerId, Map<String, Object?> event) async {
    sinks[playerId]!.success(event);
    await _settle();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Native native;
  late Media3PlaybackDeck deck;

  setUp(() {
    native = _Native();
    deck = Media3PlaybackDeck(playerId: 'one');
  });

  tearDown(() async {
    await deck.dispose();
    _messenger.setMockMethodCallHandler(_channel, null);
    playbackOutputVolume.value = 1;
    playbackEqualizer.value = const EqualizerSettings();
    Media3PlaybackDeck.debugResetAvailability();
  });

  test('loads a local file and reports its duration', () async {
    final durations = <Duration>[];
    deck.onDurationChanged.listen(durations.add);
    expect(deck.canQueueNextSource, isFalse);
    await deck.configureOutput();
    await deck.setFileSource('/music/song.flac');

    expect(native.methods.first, 'create');
    expect(native.last('setSource'), {
      'playerId': 'one',
      'uri': '/music/song.flac',
      'isLocal': true,
    });
    expect(durations, [const Duration(minutes: 3)]);
    expect(await deck.getDuration(), const Duration(minutes: 3));
    expect(deck.isDirect, isFalse);
    expect(deck.needsSourceReload, isFalse);
    expect(deck.canQueueNextSource, isTrue);
    expect(await deck.setNextDeck(Media3PlaybackDeck(playerId: 'two')), false);
  });

  test('loads a stream as a remote source', () async {
    await deck.setNetworkSource('https://example.com/song.flac');
    expect(native.last('setSource'), {
      'playerId': 'one',
      'uri': 'https://example.com/song.flac',
      'isLocal': false,
    });
  });

  test('a newer source supersedes one still preparing', () async {
    native.holdSource = true;
    final first = deck.setFileSource('/first.flac');
    await _settle();
    native.holdSource = false;
    await deck.setFileSource('/second.flac');
    await expectLater(first, completes);

    expect(native.last('setSource')['uri'], '/second.flac');
    expect(deck.canQueueNextSource, isTrue);
    await deck.resume();
    expect(deck.state, PlaybackDeckState.playing);
  });

  test('cancelPreparation stops waiting for the source at once', () async {
    native
      ..holdSource = true
      ..ignoreClear = true;
    final load = deck.setFileSource('/slow.flac');
    await _settle();
    await deck.cancelPreparation();
    await expectLater(load, completes);
    expect(native.methods, contains('clearSource'));

    // A late reply for the abandoned source changes nothing.
    native.pendingSource!.complete({'durationMs': 1000});
    await _settle();
    expect(deck.canQueueNextSource, isFalse);
    await deck.resume();
    expect(native.methods, isNot(contains('play')));
  });

  test('transport follows the native player and its state events', () async {
    final states = <PlaybackDeckState>[];
    final positions = <Duration>[];
    deck.onPlayerStateChanged.listen(states.add);
    deck.onPositionChanged.listen(positions.add);
    await deck.setFileSource('/song.flac');
    await deck.setPlaybackRate(1.25);
    expect(native.last('setPlaybackParameters')['speed'], 1.25);
    expect(native.last('setPlaybackParameters')['pitch'], 1);

    await deck.resume();
    expect(native.methods.last, 'play');
    expect(deck.state, PlaybackDeckState.playing);

    native.position = 12000;
    await deck.pause();
    await _settle();
    expect(deck.state, PlaybackDeckState.paused);
    expect(positions.last, const Duration(seconds: 12));

    await deck.seek(const Duration(seconds: 30));
    await _settle();
    expect(native.last('seek')['positionMs'], 30000);
    expect(positions.last, const Duration(seconds: 30));

    await deck.stop();
    await _settle();
    expect(deck.state, PlaybackDeckState.stopped);
    expect(states, [
      PlaybackDeckState.playing,
      PlaybackDeckState.paused,
      PlaybackDeckState.stopped,
    ]);

    // Echoes of a state the deck already has are not repeated.
    await native.emit('one', {'event': 'state', 'state': 'stopped'});
    await native.emit('one', {'event': 'state', 'state': 'playing'});
    expect(states.skip(3), [PlaybackDeckState.playing]);
    expect(deck.state, PlaybackDeckState.playing);
  });

  test('volume includes the in-app output volume, live', () async {
    playbackOutputVolume.value = 0.5;
    await deck.setVolume(0.8);
    expect(native.last('setVolume')['volume'] as double, closeTo(0.4, 1e-9));

    playbackOutputVolume.value = 1;
    await _settle();
    expect(native.last('setVolume')['volume'] as double, closeTo(0.8, 1e-9));
  });

  test('a source that fails to load makes resume throw', () async {
    native.replies['setSource'] = (_) async => throw PlatformException(
      code: 'source_error',
      message: 'Android could not open this audio source.',
      details: {'errorCode': 'ERROR_CODE_IO_FILE_NOT_FOUND'},
    );
    await expectLater(
      deck.setFileSource('/missing.flac'),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'source_error'),
      ),
    );
    await expectLater(deck.resume(), throwsA(isA<PlatformException>()));
    expect(native.methods, isNot(contains('play')));
    expect(deck.canQueueNextSource, isFalse);
  });

  test('a runtime failure arrives as an error and blocks resume', () async {
    final errors = <Object>[];
    deck.onPlayerStateChanged.listen((_) {}, onError: errors.add);
    await deck.setFileSource('/song.flac');
    await deck.resume();

    await native.emit('one', {
      'event': 'error',
      'message': 'Android could not play this audio.',
      'errorCode': 'ERROR_CODE_DECODING_FAILED',
      'prepared': true,
    });
    expect(
      errors.single,
      isA<Media3PlaybackException>()
          .having((e) => e.errorCode, 'errorCode', 'ERROR_CODE_DECODING_FAILED')
          .having((e) => e.prepared, 'prepared', isTrue),
    );
    expect(deck.state, PlaybackDeckState.paused);
    expect(deck.canQueueNextSource, isFalse);
    await expectLater(deck.resume(), throwsA(isA<Media3PlaybackException>()));

    // The next source starts clean.
    await deck.setFileSource('/next.flac');
    await deck.resume();
    expect(deck.state, PlaybackDeckState.playing);
  });

  test('errors while a source prepares fail only its load', () async {
    final errors = <Object>[];
    deck.onPlayerStateChanged.listen((_) {}, onError: errors.add);
    native.holdSource = true;
    final load = deck.setFileSource('/song.flac');
    await _settle();
    await native.emit('one', {
      'event': 'error',
      'message': 'Android could not open this audio source.',
      'prepared': false,
    });
    native.pendingSource!.complete({'durationMs': 1000});
    await load;
    expect(errors, isEmpty);
  });

  test('queues the next song and starts it on transition', () async {
    playbackOutputVolume.value = 0.5;
    await deck.setFileSource('/one.flac');
    await deck.resume();
    var started = 0;
    expect(
      await deck.queueNextSource(
        '/two.flac',
        volume: 0.6,
        onStarted: () => started++,
      ),
      isTrue,
    );
    final queued = native.last('queueNext');
    expect(queued['uri'], '/two.flac');
    expect(queued['isLocal'], isTrue);
    expect(queued['volume'] as double, closeTo(0.3, 1e-9));

    await native.emit('one', {'event': 'transition'});
    expect(started, 1);
    // A transition no one expects starts nothing.
    await native.emit('one', {'event': 'transition'});
    expect(started, 1);

    expect(
      await deck.queueNextSource(
        'https://example.com/three.flac',
        volume: 1,
        onStarted: () => started++,
      ),
      isTrue,
    );
    expect(native.last('queueNext')['isLocal'], isFalse);
    await deck.clearNextSource();
    expect(native.methods.last, 'clearNext');
    await native.emit('one', {'event': 'transition'});
    expect(started, 1);

    native.replies['queueNext'] = (_) async => false;
    expect(
      await deck.queueNextSource(
        '/four.flac',
        volume: 1,
        onStarted: () => started++,
      ),
      isFalse,
    );
  });

  test('the end of the last song completes the deck', () async {
    final states = <PlaybackDeckState>[];
    var completions = 0;
    deck.onPlayerStateChanged.listen(states.add);
    deck.onPlayerComplete.listen((_) => completions++);
    await deck.setFileSource('/song.flac');
    await deck.resume();
    await native.emit('one', {'event': 'completed'});
    await native.emit('one', {'event': 'state', 'state': 'completed'});
    expect(completions, 1);
    expect(states, [PlaybackDeckState.playing, PlaybackDeckState.completed]);
  });

  test('duration events update the known duration', () async {
    final durations = <Duration>[];
    deck.onDurationChanged.listen(durations.add);
    await deck.setFileSource('/song.flac');
    await native.emit('one', {'event': 'duration', 'durationMs': 200000});
    expect(durations.last, const Duration(seconds: 200));
  });

  test('position updates run while playing and honor wanted', () async {
    final positions = <Duration>[];
    deck.onPositionChanged.listen(positions.add);
    var wanted = false;
    deck.startPositionUpdates(
      const Duration(milliseconds: 10),
      wanted: () => wanted,
    );
    await deck.setFileSource('/song.flac');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await deck.resume();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(native.count('getPosition'), 0);

    wanted = true;
    native.position = 5000;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(positions, contains(const Duration(seconds: 5)));

    await deck.pause();
    final reads = native.count('getPosition');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(native.count('getPosition'), reads);
  });

  test('applies the equalizer and reports its failures', () async {
    const settings = EqualizerSettings(enabled: true);
    playbackEqualizer.value = settings;
    await deck.setFileSource('/song.flac');
    await deck.resume();
    final methods = native.methods;
    expect(methods.indexOf('setEqualizer'), lessThan(methods.indexOf('play')));
    expect(native.last('setEqualizer')['configuration'], settings.toNative());
    expect(playbackEqualizerError.value, isNull);

    native.replies['setEqualizer'] = (_) async =>
        throw PlatformException(code: 'equalizer', message: 'Needs Android 9');
    playbackEqualizer.value = const EqualizerSettings(enabled: true, preamp: 3);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(playbackEqualizerError.value, contains('Needs Android 9'));

    await deck.dispose();
    expect(playbackEqualizerError.value, isNull);
  });

  test('skip silence reaches the player before its first source', () async {
    addTearDown(() => playbackSkipSilence.value = false);
    playbackSkipSilence.value = true;
    await deck.setFileSource('/song.flac');
    final methods = native.methods;
    expect(
      methods.indexOf('setSkipSilence'),
      lessThan(methods.indexOf('setSource')),
    );
    expect(native.last('setSkipSilence'), {'playerId': 'one', 'enabled': true});

    playbackSkipSilence.value = false;
    await _settle();
    expect(native.last('setSkipSilence')['enabled'], isFalse);
    expect(native.count('setSkipSilence'), 2);
  });

  test('skip silence is sent only when it differs from off', () async {
    addTearDown(() => playbackSkipSilence.value = false);
    await deck.setFileSource('/song.flac');
    expect(native.methods, isNot(contains('setSkipSilence')));

    playbackSkipSilence.value = true;
    await _settle();
    expect(native.last('setSkipSilence')['enabled'], isTrue);

    native.replies['setSkipSilence'] = (_) async =>
        throw MissingPluginException();
    playbackSkipSilence.value = false;
    await _settle();
    await deck.resume();
    expect(native.count('play'), 1);
  });

  test('a deck never created sends nothing for skip silence', () async {
    addTearDown(() => playbackSkipSilence.value = false);
    playbackSkipSilence.value = true;
    await _settle();
    expect(native.calls, isEmpty);
  });

  test(
    'spatial audio off reaches the player before its first source',
    () async {
      addTearDown(() => playbackSpatialAudio.value = true);
      playbackSpatialAudio.value = false;
      await deck.setFileSource('/song.flac');
      final methods = native.methods;
      expect(
        methods.indexOf('setSpatialAudio'),
        lessThan(methods.indexOf('setSource')),
      );
      expect(native.last('setSpatialAudio'), {
        'playerId': 'one',
        'enabled': false,
      });

      playbackSpatialAudio.value = true;
      await _settle();
      expect(native.last('setSpatialAudio'), {
        'playerId': 'one',
        'enabled': true,
      });
      expect(native.count('setSpatialAudio'), 2);
    },
  );

  test('spatial audio is sent only when it differs from auto', () async {
    addTearDown(() => playbackSpatialAudio.value = true);
    await deck.setFileSource('/song.flac');
    expect(native.methods, isNot(contains('setSpatialAudio')));

    playbackSpatialAudio.value = false;
    await _settle();
    expect(native.last('setSpatialAudio')['enabled'], isFalse);

    // An older native player without the method keeps playing.
    native.replies['setSpatialAudio'] = (_) async =>
        throw MissingPluginException();
    playbackSpatialAudio.value = true;
    await _settle();
    await deck.resume();
    expect(native.count('play'), 1);
  });

  test('a deck never created sends nothing for spatial audio', () async {
    addTearDown(() => playbackSpatialAudio.value = true);
    playbackSpatialAudio.value = false;
    await _settle();
    expect(native.calls, isEmpty);
  });

  test('speed and pitch reach the player before its first source', () async {
    addTearDown(() {
      playbackSpeed.value = 1;
      playbackPitch.value = PlaybackPitch.none;
    });
    playbackSpeed.value = 1.5;
    playbackPitch.value = const PlaybackPitch(semitones: 12);
    await deck.setFileSource('/song.flac');
    final methods = native.methods;
    expect(
      methods.indexOf('setPlaybackParameters'),
      lessThan(methods.indexOf('setSource')),
    );
    expect(native.last('setPlaybackParameters'), {
      'playerId': 'one',
      'speed': 1.5,
      'pitch': 2.0,
    });

    // AutoMix's rate is relative to the speed; a following pitch takes the
    // effective rate.
    playbackPitch.value = const PlaybackPitch(followsRate: true);
    await deck.setPlaybackRate(1.1);
    expect(native.last('setPlaybackParameters')['speed'], closeTo(1.65, 1e-9));
    expect(native.last('setPlaybackParameters')['pitch'], closeTo(1.65, 1e-9));

    // Live while paused, without starting playback.
    playbackSpeed.value = 0.75;
    await _settle();
    expect(native.last('setPlaybackParameters')['speed'], closeTo(0.825, 1e-9));
    expect(native.methods, isNot(contains('play')));
    expect(deck.tempoSupport, PlaybackTempoSupport.full);
  });

  test('normal speed and pitch are never sent', () async {
    await deck.setFileSource('/song.flac');
    await deck.setPlaybackRate(1);
    playbackPitch.value = const PlaybackPitch(followsRate: true);
    addTearDown(() => playbackPitch.value = PlaybackPitch.none);
    await _settle();
    expect(native.methods, isNot(contains('setPlaybackParameters')));
  });

  test('a deck never created sends nothing for speed', () async {
    addTearDown(() => playbackSpeed.value = 1);
    playbackSpeed.value = 2;
    await _settle();
    expect(native.calls, isEmpty);
  });

  test('a disabled equalizer is never sent', () async {
    await deck.setFileSource('/song.flac');
    playbackEqualizer.value = const EqualizerSettings(preamp: 2);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(native.methods, isNot(contains('setEqualizer')));
  });

  group('a volume above full', () {
    final gain = math.pow(10, 4.4 / 20).toDouble();
    final raise = math.pow(10, 4.5 / 20).toDouble();
    double volume() => (native.last('setVolume')['volume']! as num).toDouble();
    Map<Object?, Object?> configuration() =>
        native.last('setEqualizer')['configuration']! as Map<Object?, Object?>;

    test('rises through the platform stage, apart from the filters', () async {
      await deck.setFileSource('/song.flac');
      await deck.setVolume(gain);
      expect(volume(), 1);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(configuration()['enabled'], isTrue);
      expect(configuration()['limiter'], isTrue);
      expect(configuration()['inputGain'], closeTo(4.5, 1e-9));
      expect(configuration()['boostGain'], closeTo(4.5, 1e-9));
      expect(volume(), closeTo(gain / raise, 1e-9));

      await deck.setVolume(0.5);
      expect(volume(), closeTo(0.5 / raise, 1e-9));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(configuration()['enabled'], isFalse);
      expect(configuration(), isNot(contains('boostGain')));
      expect(volume(), closeTo(0.5, 1e-9));
    });

    test('a queued song plays under the raise and takes its own', () async {
      await deck.setFileSource('/one.flac');
      await deck.setVolume(gain);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      var started = false;
      expect(
        await deck.queueNextSource(
          '/two.flac',
          volume: 2,
          onStarted: () => started = true,
        ),
        isTrue,
      );
      // Queued at the raise playing now: 2 is 6.02 dB, 4.5 of them raised.
      expect(
        (native.last('queueNext')['volume']! as num).toDouble(),
        closeTo(1, 1e-9),
      );
      await native.emit('one', {'event': 'transition'});
      expect(started, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(configuration()['boostGain'], closeTo(6.5, 1e-9));
      expect(volume(), closeTo(2 / math.pow(10, 6.5 / 20), 1e-9));
    });

    test('a refused raise leaves the song at full volume', () async {
      native.replies['setEqualizer'] = (_) async =>
          throw PlatformException(code: 'equalizer', message: 'Android 9');
      await deck.setFileSource('/song.flac');
      await deck.setVolume(gain);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(playbackEqualizerError.value, isNull);
      expect(volume(), 1);
    });
  });

  test('DSD needs the USB output', () async {
    await expectLater(
      deck.setFileSource('/song.dsf', requiresDsd: true),
      throwsA(isA<UsbDsdUnavailable>()),
    );
    expect(native.methods, isNot(contains('setSource')));
  });

  test('dispose releases the player once', () async {
    await deck.setFileSource('/song.flac');
    await Future.wait([deck.dispose(), deck.dispose()]);
    expect(native.count('dispose'), 1);
    expect(native.cancelled, ['one']);
    expect(deck.state, PlaybackDeckState.disposed);

    final calls = native.calls.length;
    await deck.resume();
    await deck.setVolume(1);
    await deck.stop();
    expect(native.calls, hasLength(calls));
  });

  test('dispose during preparation ends the load quietly', () async {
    native.holdSource = true;
    final load = deck.setFileSource('/song.flac');
    await _settle();
    await deck.dispose();
    await expectLater(load, completes);
  });

  test('a deck never used releases nothing', () async {
    final unused = Media3PlaybackDeck(playerId: 'unused');
    await unused.dispose();
    expect(native.calls, isEmpty);
  });

  test('a build without the native player reports it missing', () async {
    _messenger.setMockMethodCallHandler(_channel, null);
    expect(Media3PlaybackDeck.isAvailable, isTrue);
    await expectLater(
      deck.setFileSource('/song.flac'),
      throwsA(isA<MissingPluginException>()),
    );
    expect(Media3PlaybackDeck.isAvailable, isFalse);
  });
}
