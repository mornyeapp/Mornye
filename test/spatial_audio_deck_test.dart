import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/playback_deck.dart';

/// The audioplayers deck sends the Spatial audio setting to both forks
/// (Android's MediaPlayer wrapper and the Darwin AVPlayer wrapper).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  List<String> methods() => [for (final call in calls) call.method];
  List<Object?> spatial() => [
    for (final call in calls)
      if (call.method == 'setSpatialAudio') call.arguments,
  ];

  setUp(() {
    calls.clear();
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
        }
        return null;
      },
    );
  });

  tearDown(() => playbackSpatialAudio.value = true);

  test('the default sends nothing', () async {
    final deck = AudioplayersPlaybackDeck(
      playerId: 'spatial-default',
      spatialAudioAvailable: true,
    );
    await deck.setFileSource('/song.flac');
    expect(methods(), isNot(contains('setSpatialAudio')));
    await deck.dispose();
  });

  test('off reaches the player before the source it applies to', () async {
    playbackSpatialAudio.value = false;
    final deck = AudioplayersPlaybackDeck(
      playerId: 'spatial-off',
      spatialAudioAvailable: true,
    );
    await deck.setFileSource('/song.flac');
    expect(spatial(), [
      {'playerId': 'spatial-off', 'enabled': false},
    ]);
    expect(
      methods().indexOf('setSpatialAudio'),
      lessThan(methods().indexOf('setSourceUrl')),
    );
    // The next song needs nothing new.
    await deck.setFileSource('/next.flac');
    expect(spatial(), hasLength(1));
    await deck.dispose();
  });

  test('a change is sent at once, for each value', () async {
    final deck = AudioplayersPlaybackDeck(
      playerId: 'spatial-live',
      spatialAudioAvailable: true,
    );
    await deck.setFileSource('/song.flac');
    playbackSpatialAudio.value = false;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    playbackSpatialAudio.value = true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(spatial(), [
      {'playerId': 'spatial-live', 'enabled': false},
      {'playerId': 'spatial-live', 'enabled': true},
    ]);
    await deck.dispose();
    playbackSpatialAudio.value = false;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(spatial(), hasLength(2));
  });

  test('a platform without the fork method sends nothing', () async {
    playbackSpatialAudio.value = false;
    final deck = AudioplayersPlaybackDeck(
      playerId: 'spatial-none',
      spatialAudioAvailable: false,
    );
    await deck.setFileSource('/song.flac');
    expect(methods(), isNot(contains('setSpatialAudio')));
    await deck.dispose();
  });
}
