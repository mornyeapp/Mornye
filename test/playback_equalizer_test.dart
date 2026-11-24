import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/playback_equalizer.dart';
import 'package:mornye/utils/desktop_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  bool reject = false;
  Completer<void>? effectGate;

  setUp(() {
    calls.clear();
    reject = false;
    effectGate = null;
    playbackEqualizer.value = const EqualizerSettings();
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
      'com.zarz.mornye/usb_pcm/events',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.zarz.mornye/usb_pcm'),
      (call) async => call.method == 'prepare'
          ? {
              'ready': true,
              'duration': 60000,
              'bitDepth': 24,
              'sampleRate': 96000,
            }
          : null,
    );
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
        } else if (call.method == 'setEqualizer') {
          await effectGate?.future;
          if (reject) {
            throw PlatformException(
              code: 'effect_unavailable',
              message: 'Unsupported output',
            );
          }
        }
        return null;
      },
    );
  });

  test(
    'all AutoMix decks receive live EQ and recreated sources restore it',
    () async {
      final outgoing = AudioplayersPlaybackDeck(
        playerId: 'eq-outgoing',
        equalizerAvailable: true,
      );
      final incoming = AudioplayersPlaybackDeck(
        playerId: 'eq-incoming',
        equalizerAvailable: true,
      );
      await outgoing.setFileSource('/outgoing.flac');
      await incoming.setFileSource('/incoming.flac');
      expect(calls.where((c) => c.method == 'setEqualizer'), isEmpty);
      playbackEqualizer.value = const EqualizerSettings(enabled: true, bass: 3);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final effects = calls.where((c) => c.method == 'setEqualizer').toList();
      expect(effects.length, 2);
      expect(effects.map((c) => (c.arguments as Map)['playerId']).toSet(), {
        'eq-outgoing',
        'eq-incoming',
      });
      final beforeDragging = calls
          .where((c) => c.method == 'setEqualizer')
          .length;
      for (var i = 1; i <= 6; i++) {
        playbackEqualizer.value = EqualizerSettings(
          enabled: true,
          bass: i.toDouble(),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        calls.where((c) => c.method == 'setEqualizer').length,
        greaterThan(beforeDragging + 2),
      );
      await outgoing.setFileSource('/next.flac');
      expect(
        (calls.last.arguments as Map)['configuration'],
        containsPair('enabled', true),
      );
      playbackEqualizer.value = const EqualizerSettings();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      for (final id in ['eq-outgoing', 'eq-incoming']) {
        final update = calls.lastWhere(
          (c) =>
              c.method == 'setEqualizer' &&
              (c.arguments as Map)['playerId'] == id,
        );
        expect(
          (update.arguments as Map)['configuration'],
          containsPair('enabled', false),
        );
      }
      await outgoing.dispose();
      await incoming.dispose();
    },
  );

  test(
    'bit-perfect PCM bypasses EQ and returns to EQ on ordinary playback',
    () async {
      final deck = AudioplayersPlaybackDeck(
        playerId: 'eq-usb',
        nativeAvailable: true,
        equalizerAvailable: true,
      );
      playbackEqualizer.value = const EqualizerSettings(enabled: true);
      await deck.setFileSource(
        '/usb.flac',
        preferBitPerfect: true,
        directUsb: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      for (final call in calls.where((c) => c.method == 'setEqualizer')) {
        expect(
          (call.arguments as Map)['configuration'],
          containsPair('enabled', false),
        );
      }
      await deck.setFileSource('/ordinary.flac');
      expect(
        (calls.last.arguments as Map)['configuration'],
        containsPair('enabled', true),
      );
      await deck.dispose();
    },
  );

  test('a late native error cannot outlive a disposed deck', () async {
    final deck = AudioplayersPlaybackDeck(
      playerId: 'eq-disposed',
      equalizerAvailable: true,
    );
    effectGate = Completer<void>();
    reject = true;
    playbackEqualizer.value = const EqualizerSettings(enabled: true);
    final preparing = deck.setFileSource('/song.flac');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(calls.where((c) => c.method == 'setEqualizer'), isNotEmpty);
    await deck.dispose();
    effectGate!.complete();
    await preparing;
    expect(playbackEqualizerError.value, isNull);
  });

  test('a desktop deck without the tap reports EQ as unavailable', () async {
    debugDesktopPlatformOverride = true;
    addTearDown(() => debugDesktopPlatformOverride = null);
    final deck = AudioplayersPlaybackDeck(
      playerId: 'eq-desktop',
      equalizerAvailable: false,
    );
    await deck.setFileSource('/song.flac');
    playbackEqualizer.value = const EqualizerSettings(enabled: true);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(calls.where((c) => c.method == 'setEqualizer'), isEmpty);
    expect(playbackEqualizerError.value, isNotNull);
    playbackEqualizer.value = const EqualizerSettings();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(playbackEqualizerError.value, isNull);
    await deck.dispose();
  });

  test('in-app output volume scales the gain of every deck', () async {
    addTearDown(() => playbackOutputVolume.value = 1);
    final deck = AudioplayersPlaybackDeck(playerId: 'output-gain');
    await deck.setFileSource('/song.flac');
    await deck.setVolume(0.8);
    playbackOutputVolume.value = 0.5;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final volumes = [
      for (final call in calls)
        if (call.method == 'setVolume') (call.arguments as Map)['volume'],
    ];
    expect(volumes, [0.8, 0.4]);
    await deck.dispose();
  });

  test(
    'unsupported effects report an error without breaking playback',
    () async {
      final deck = AudioplayersPlaybackDeck(
        playerId: 'eq-error',
        equalizerAvailable: true,
      );
      reject = true;
      playbackEqualizer.value = const EqualizerSettings(enabled: true);
      await deck.setFileSource('/song.flac');
      expect(playbackEqualizerError.value, contains('Unsupported output'));
      await deck.resume();
      expect(calls.last.method, 'resume');
      await deck.dispose();
      expect(playbackEqualizerError.value, isNull);
      final count = calls.length;
      playbackEqualizer.value = const EqualizerSettings(bass: 6);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(calls.length, count);
    },
  );

  group('a volume above full', () {
    List<double> volumes() => [
      for (final call in calls)
        if (call.method == 'setVolume')
          ((call.arguments as Map)['volume'] as num).toDouble(),
    ];
    Map<Object?, Object?> lastEffect() =>
        calls.lastWhere((c) => c.method == 'setEqualizer').arguments
            as Map<Object?, Object?>;
    Map<Object?, Object?> configuration(Map<Object?, Object?> call) =>
        call['configuration']! as Map<Object?, Object?>;
    final gain = math.pow(10, 4.4 / 20).toDouble();
    final raise = math.pow(10, 4.5 / 20).toDouble();

    test('rises through a flat equalizer with its limiter', () async {
      final deck = AudioplayersPlaybackDeck(
        playerId: 'boost',
        equalizerAvailable: true,
      );
      await deck.setFileSource('/song.flac');
      await deck.setVolume(gain);
      // The player waits at full volume until the equalizer takes the raise,
      // which rounds up to the next half decibel.
      expect(volumes().last, 1);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final raised = configuration(lastEffect());
      expect(raised['enabled'], isTrue);
      expect(raised['limiter'], isTrue);
      expect(raised['inputGain'], closeTo(4.5, 1e-9));
      expect(raised['gains'], everyElement(0.0));
      expect(volumes().last, closeTo(gain / raise, 1e-9));
      // The player is lowered before the equalizer raises.
      final methods = [for (final call in calls) call.method];
      expect(
        methods.lastIndexOf('setVolume'),
        lessThan(methods.lastIndexOf('setEqualizer')),
      );

      // Back at full volume, the player stays below the raise until the
      // equalizer lets go of it.
      await deck.setVolume(0.5);
      expect(volumes().last, closeTo(0.5 / raise, 1e-9));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(configuration(lastEffect())['enabled'], isFalse);
      expect(volumes().last, closeTo(0.5, 1e-9));
      await deck.dispose();
    });

    test('a fade within one step leaves the equalizer alone', () async {
      final deck = AudioplayersPlaybackDeck(
        playerId: 'boost-fade',
        equalizerAvailable: true,
      );
      await deck.setFileSource('/song.flac');
      await deck.setVolume(gain);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final effects = calls.where((c) => c.method == 'setEqualizer').length;
      // Down to 4.13 dB, still within the 4.5 dB step.
      for (final level in [0.99, 0.98, 0.97]) {
        await deck.setVolume(gain * level);
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(
        calls.where((c) => c.method == 'setEqualizer'),
        hasLength(effects),
      );
      expect(volumes().last, closeTo(gain * 0.97 / raise, 1e-9));
      await deck.dispose();
    });

    test(
      'adds to the listener\'s equalizer as far as its input goes',
      () async {
        playbackEqualizer.value = const EqualizerSettings(
          enabled: true,
          preamp: 10,
        );
        final deck = AudioplayersPlaybackDeck(
          playerId: 'boost-eq',
          equalizerAvailable: true,
        );
        await deck.setFileSource('/song.flac');
        await deck.setVolume(gain);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(configuration(lastEffect())['inputGain'], closeTo(12, 1e-9));
        // Two of the 4.5 dB fit; the player stays at full volume for the rest.
        expect(volumes().last, 1);
        await deck.dispose();
      },
    );

    test('stays at full volume where the effect is refused', () async {
      final deck = AudioplayersPlaybackDeck(
        playerId: 'boost-refused',
        equalizerAvailable: true,
      );
      reject = true;
      await deck.setFileSource('/song.flac');
      await deck.setVolume(gain);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      // A raise the listener's equalizer never asked for reports nothing.
      expect(playbackEqualizerError.value, isNull);
      expect(volumes().last, 1);
      final effects = calls.where((c) => c.method == 'setEqualizer').length;
      await deck.setVolume(gain * 1.5);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(
        calls.where((c) => c.method == 'setEqualizer'),
        hasLength(effects),
      );
      await deck.dispose();
    });

    test('a deck without the equalizer stage plays at most full', () async {
      final deck = AudioplayersPlaybackDeck(
        playerId: 'boost-none',
        equalizerAvailable: false,
      );
      await deck.setFileSource('/song.flac');
      await deck.setVolume(gain);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(calls.where((c) => c.method == 'setEqualizer'), isEmpty);
      expect(volumes().last, 1);
      await deck.dispose();
    });
  });

  test('raise steps round up to half a decibel', () {
    expect(normalizationBoostDb(0.5), 0);
    expect(normalizationBoostDb(1), 0);
    expect(normalizationBoostDb(math.pow(10, 0.1 / 20).toDouble()), 0.5);
    expect(normalizationBoostDb(math.pow(10, 3 / 20).toDouble()), 3);
    expect(normalizationBoostDb(math.pow(10, 3.01 / 20).toDouble()), 3.5);
  });
}
