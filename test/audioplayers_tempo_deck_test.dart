import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/playback_deck.dart';

/// The audioplayers deck applies the speed setting through the playback
/// rate and sends the pitch to both forks (`setPitch`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  var refusePitch = false;

  List<String> methods() => [for (final call in calls) call.method];
  List<Object?> pitches() => [
    for (final call in calls)
      if (call.method == 'setPitch') call.arguments,
  ];
  List<double> rates() => [
    for (final call in calls)
      if (call.method == 'setPlaybackRate')
        ((call.arguments as Map<Object?, Object?>)['playbackRate']! as num)
            .toDouble(),
  ];

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  setUp(() {
    calls.clear();
    refusePitch = false;
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        calls.add(call);
        final args = call.arguments as Map<Object?, Object?>;
        final id = args['playerId']! as String;
        if (call.method == 'create') {
          messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null,
          );
        } else if (call.method == 'setSourceUrl') {
          unawaited(
            messenger.handlePlatformMessage(
              'xyz.luan/audioplayers/events/$id',
              const StandardMethodCodec().encodeSuccessEnvelope({
                'event': 'audio.onPrepared',
                'value': true,
              }),
              (_) {},
            ),
          );
        } else if (call.method == 'getDuration') {
          return 60000;
        } else if (call.method == 'setPitch' && refusePitch) {
          throw PlatformException(
            code: 'DarwinAudioError',
            message: 'Pitch is unavailable for protected audio',
          );
        }
        return null;
      },
    );
  });

  tearDown(() {
    playbackSpeed.value = 1;
    playbackPitch.value = PlaybackPitch.none;
  });

  test('the defaults send no pitch and play at the given rate', () async {
    final deck = AudioplayersPlaybackDeck(
      playerId: 'tempo-default',
      pitchAvailable: true,
    );
    await deck.setFileSource('/song.flac');
    await deck.setPlaybackRate(1.04);
    expect(methods(), isNot(contains('setPitch')));
    expect(rates().last, 1.04);
    expect(deck.tempoSupport, PlaybackTempoSupport.full);
    await deck.dispose();
  });

  test('the speed multiplies every rate, also a later change', () async {
    playbackSpeed.value = 1.5;
    final deck = AudioplayersPlaybackDeck(
      playerId: 'tempo-speed',
      pitchAvailable: true,
    );
    await deck.setFileSource('/song.flac');
    expect(rates().last, 1.5);
    await deck.setPlaybackRate(1.1);
    expect(rates().last, closeTo(1.65, 1e-9));
    playbackSpeed.value = 0.5;
    await settle();
    expect(rates().last, closeTo(0.55, 1e-9));
    // A paused player is only told the rate; nothing starts it.
    expect(methods(), isNot(contains('resume')));
    await deck.dispose();
  });

  test('a pitch reaches the player and each later source', () async {
    playbackPitch.value = const PlaybackPitch(semitones: 2);
    final deck = AudioplayersPlaybackDeck(
      playerId: 'tempo-pitch',
      pitchAvailable: true,
    );
    await deck.setFileSource('/song.flac');
    expect(pitches(), [
      {'playerId': 'tempo-pitch', 'semitones': 2.0, 'followsRate': false},
    ]);
    playbackPitch.value = const PlaybackPitch(semitones: 2, followsRate: true);
    await settle();
    expect(pitches().last, {
      'playerId': 'tempo-pitch',
      'semitones': 2.0,
      'followsRate': true,
    });
    await deck.setFileSource('/next.flac');
    // Sent again, so the fork can answer for this source.
    expect(pitches(), hasLength(3));
    await deck.dispose();
    playbackPitch.value = PlaybackPitch.none;
    await settle();
    expect(pitches(), hasLength(3));
  });

  test('a refused pitch reports speed only for that source', () async {
    playbackPitch.value = const PlaybackPitch(semitones: -3);
    refusePitch = true;
    var notices = 0;
    void counted() => notices++;
    playbackTempoSupportRevision.addListener(counted);
    addTearDown(() => playbackTempoSupportRevision.removeListener(counted));
    final deck = AudioplayersPlaybackDeck(
      playerId: 'tempo-refused',
      pitchAvailable: true,
    );
    await deck.setFileSource('/protected.m4p');
    expect(deck.tempoSupport, PlaybackTempoSupport.speedOnly);
    expect(notices, 1);
    refusePitch = false;
    await deck.setFileSource('/song.flac');
    expect(deck.tempoSupport, PlaybackTempoSupport.full);
    expect(notices, 2);
    await deck.dispose();
  });

  test('Windows and Linux change only the speed', () async {
    playbackSpeed.value = 1.25;
    playbackPitch.value = const PlaybackPitch(semitones: 1);
    final deck = AudioplayersPlaybackDeck(
      playerId: 'tempo-desktop',
      pitchAvailable: false,
    );
    await deck.setFileSource('/song.flac');
    expect(methods(), isNot(contains('setPitch')));
    expect(rates().last, 1.25);
    expect(deck.tempoSupport, PlaybackTempoSupport.speedOnly);
    await deck.dispose();
  });
}
