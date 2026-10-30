import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/playback_deck.dart';

import 'support/music_player_automix_harness.dart';

const _until = waitUntil;

void main() {
  setUpMusicPlayerHarness();

  group('USB playback transport', () {
    const methods = MethodChannel('com.zarz.mornye/usb_pcm');
    const events = MethodChannel('com.zarz.mornye/usb_pcm/events');
    late AudioplayersPlaybackDeck deck;
    late List<String> usbCalls;
    late int token;
    late String? fallbackReason;
    late bool failResume;
    late bool fatal;
    late bool volumeBlocked;
    Map<String, dynamic>? hardwareVolume;
    late String transport;
    late Map<dynamic, dynamic> prepareArguments;
    Completer<void>? pauseReply;
    Completer<Map<String, dynamic>>? prepareReply;
    var position = 0;

    Future<void> event(String name, {int? withToken}) =>
        native.messenger.handlePlatformMessage(
          events.name,
          const StandardMethodCodec().encodeSuccessEnvelope({
            'event': name,
            'token': withToken ?? token,
          }),
          (_) {},
        );

    setUp(() {
      usbCalls = [];
      token = 0;
      fallbackReason = null;
      failResume = false;
      fatal = false;
      volumeBlocked = false;
      hardwareVolume = null;
      transport = 'pcm';
      prepareArguments = {};
      pauseReply = null;
      prepareReply = null;
      position = 0;
      native.messenger.setMockMethodCallHandler(events, (_) async => null);
      native.messenger.setMockMethodCallHandler(methods, (call) async {
        usbCalls.add(call.method);
        switch (call.method) {
          case 'prepare':
            prepareArguments = call.arguments as Map;
            token = (call.arguments as Map)['token'] as int;
            if (prepareReply != null) return prepareReply!.future;
            if (fallbackReason != null) {
              return {'reason': fallbackReason, 'fatal': fatal};
            }
            return {
              'ready': true,
              'duration': 60000,
              'device': 'Test DAC',
              'sampleRate': 96000,
              'bitDepth': 24,
              'transport': transport,
              'driver': prepareArguments['direct'] == true
                  ? 'usb_direct'
                  : 'android',
              'volumeBlocked': volumeBlocked,
              if (hardwareVolume != null)
                'volume': {...hardwareVolume!, 'token': token},
            };
          case 'volume':
            expect((call.arguments as Map)['token'], token);
            return {
              ...hardwareVolume!,
              'token': token,
              'currentDb': (call.arguments as Map)['db'],
            };
          case 'position':
            return position;
          case 'seek':
            position = (call.arguments as Map)['position'] as int;
          case 'resume':
            if (failResume) throw PlatformException(code: 'route_changed');
          case 'pause':
            await pauseReply?.future;
          case 'stop':
            if (prepareReply != null && !prepareReply!.isCompleted) {
              prepareReply!.complete({'reason': 'cancelled'});
            }
        }
        return null;
      });
      deck = AudioplayersPlaybackDeck(
        playerId: 'usb-test',
        nativeAvailable: true,
      );
    });

    test('direct driver and DoP are explicit and passed to native', () async {
      await deck.setFileSource(
        '/one.dsf',
        preferBitPerfect: true,
        directUsb: true,
        allowDop: true,
      );
      expect(prepareArguments['direct'], isTrue);
      expect(prepareArguments['allowDop'], isTrue);
    });

    test('hardware volume changes the DAC, never PCM gain', () async {
      hardwareVolume = {
        'available': true,
        'minDb': -90.0,
        'maxDb': 0.0,
        'currentDb': -40.0,
      };
      await deck.setFileSource(
        '/one.flac',
        preferBitPerfect: true,
        directUsb: true,
      );
      expect(usbHardwareVolume.value?.currentDb, -40);
      await setUsbHardwareVolume(0.5);
      expect(usbHardwareVolume.value?.currentDb, -45);
      expect(usbCalls, ['prepare', 'volume']);
      expect(native.calls.where((call) => call.$2 == 'setVolume'), isEmpty);
      await deck.stop();
      expect(usbHardwareVolume.value, isNull);
    });

    test(
      'uncontrolled DAC is blocked without ordinary full-volume fallback',
      () async {
        volumeBlocked = true;
        hardwareVolume = {'available': false};
        await deck.setFileSource(
          '/one.flac',
          preferBitPerfect: true,
          directUsb: true,
        );
        await expectLater(deck.resume(), throwsA(isA<UsbOutputUnavailable>()));
        expect(usbCalls, ['prepare']);
        expect(usbAudioStatus.value.reason, 'volume_unavailable');
        expect(native.sources['usb-test'], isNull);
        await setUsbHardwareVolume(1);
        expect(usbCalls, ['prepare']);
      },
    );

    test(
      'AAudio exclusive and fixed volume require explicit options',
      () async {
        await deck.setFileSource(
          '/one.wav',
          preferBitPerfect: true,
          dapExclusive: true,
        );
        expect(prepareArguments['dapExclusive'], isTrue);
        expect(prepareArguments['allowFixedVolume'], isFalse);
        expect(prepareArguments['direct'], isFalse);
        fallbackReason = 'exclusive_unavailable';
        await deck.setFileSource(
          '/one.wav',
          preferBitPerfect: true,
          dapExclusive: true,
        );
        expect(usbAudioStatus.value.reason, 'exclusive_unavailable');
        expect(deck.isDirect, isFalse);
        expect(native.sources['usb-test'], '/one.wav');
      },
    );

    test(
      'changing tracks cancels a pending USB permission without fallback',
      () async {
        prepareReply = Completer<Map<String, dynamic>>();
        final preparing = deck.setFileSource(
          '/one.flac',
          preferBitPerfect: true,
          directUsb: true,
        );
        await _until(() => usbCalls.contains('prepare'));
        await deck.cancelPreparation();
        await preparing;
        expect(usbCalls, ['prepare', 'stop']);
        expect(native.sources['usb-test'], isNull);
        expect(deck.isDirect, isFalse);
      },
    );

    test(
      'unsupported DSD never falls back through ordinary PCM output',
      () async {
        fallbackReason = 'dsd_unsupported';
        fatal = true;
        await expectLater(
          deck.setFileSource(
            '/one.dsf',
            preferBitPerfect: true,
            directUsb: true,
          ),
          throwsStateError,
        );
        expect(native.sources['usb-test'], isNull);
        expect(usbAudioStatus.value.reason, 'dsd_unsupported');
      },
    );

    test('failed first DSD start does not switch to normal playback', () async {
      transport = 'dop';
      await deck.setFileSource(
        '/one.dsf',
        preferBitPerfect: true,
        directUsb: true,
      );
      failResume = true;
      await expectLater(deck.resume(), throwsA(isA<UsbOutputUnavailable>()));
      expect(native.sources['usb-test'], isNull);
      expect(deck.needsSourceReload, isTrue);
    });

    test('failed first DoP start pauses without normal playback', () async {
      transport = 'dop';
      failResume = true;
      await deck.setFileSource(
        '/one.dsf',
        preferBitPerfect: true,
        allowDop: true,
      );
      await expectLater(deck.resume(), throwsA(isA<UsbDsdUnavailable>()));
      expect(deck.state, PlaybackDeckState.paused);
      expect(deck.needsSourceReload, isTrue);
      expect(usbAudioStatus.value.reason, 'dsd_unsupported');
      expect(native.sources['usb-test'], isNull);
      expect(native.playing, isEmpty);
      expect(usbCalls, ['prepare', 'resume']);
    });

    test('DSD without a DAC never loads a normal audio source', () async {
      fallbackReason = 'no_usb';
      await expectLater(
        deck.setFileSource(
          '/one.dsf',
          preferBitPerfect: true,
          directUsb: true,
          requiresDsd: true,
        ),
        throwsA(isA<UsbDsdUnavailable>()),
      );
      expect(native.sources['usb-test'], isNull);
    });

    tearDown(() async {
      await deck.dispose();
      native.messenger.setMockMethodCallHandler(methods, null);
      native.messenger.setMockMethodCallHandler(events, null);
    });

    test(
      'verified route plays, pauses and seeks without software gain or rate changes',
      () async {
        await deck.setFileSource('/one.flac', preferBitPerfect: true);
        expect(usbAudioStatus.value.reason, 'ready');
        await deck.resume();
        await deck.setVolume(0.4);
        await deck.setPlaybackRate(1.1);
        expect(native.playing, isEmpty);
        expect(usbAudioStatus.value.reason, 'active');
        expect(usbAudioStatus.value.sampleRate, 96000);
        await deck.seek(const Duration(seconds: 21));
        expect(await deck.getCurrentPosition(), const Duration(seconds: 21));
        await deck.pause();
        expect(deck.state, PlaybackDeckState.paused);
        expect(usbCalls, ['prepare', 'resume', 'seek', 'position', 'pause']);
        expect(
          native.calls.where(
            (c) =>
                c.$1 == 'usb-test' &&
                ['setVolume', 'setPlaybackRate'].contains(c.$2),
          ),
          isEmpty,
        );
      },
    );

    test('direct playback asks for a position only on wanted ticks', () async {
      var wanted = false;
      deck.startPositionUpdates(
        const Duration(milliseconds: 10),
        wanted: () => wanted,
      );
      await deck.setFileSource('/one.flac', preferBitPerfect: true);
      await deck.resume();
      int reads() => usbCalls.where((call) => call == 'position').length;
      // Longer than the 200 ms the direct path once polled on regardless.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(reads(), 0);
      wanted = true;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      // Only the 10 ms interval reads this often.
      expect(reads(), greaterThanOrEqualTo(3));
      await deck.pause();
    });

    test('late pause reply does not pause a newly prepared source', () async {
      await deck.setFileSource('/one.flac', preferBitPerfect: true);
      await deck.resume();
      pauseReply = Completer<void>();
      final pausing = deck.pause();
      await _until(() => usbCalls.contains('pause'));
      await deck.setFileSource('/two.flac', preferBitPerfect: true);
      await deck.resume();
      pauseReply!.complete();
      await pausing;
      expect(deck.state, PlaybackDeckState.playing);
      expect(usbAudioStatus.value.reason, 'active');
    });

    test('missing support falls back without reporting bit-perfect', () async {
      fallbackReason = 'no_usb';
      await deck.setFileSource('/one.flac', preferBitPerfect: true);
      await deck.resume();
      expect(deck.isDirect, isFalse);
      expect(native.playing, {'usb-test'});
      expect(usbAudioStatus.value.reason, 'no_usb');
    });

    test('unverified route falls back before starting USB audio', () async {
      failResume = true;
      await deck.setFileSource('/one.flac', preferBitPerfect: true);
      await deck.resume();
      expect(deck.isDirect, isFalse);
      expect(native.sources['usb-test'], '/one.flac');
      expect(native.playing, {'usb-test'});
      expect(usbAudioStatus.value.reason, 'unsupported');
    });

    test(
      'direct USB failure before first sound never redirects to speaker',
      () async {
        failResume = true;
        await deck.setFileSource(
          '/one.flac',
          preferBitPerfect: true,
          directUsb: true,
        );
        await expectLater(deck.resume(), throwsA(isA<UsbOutputUnavailable>()));
        expect(native.sources['usb-test'], isNull);
        expect(native.playing, isEmpty);
        expect(deck.state, PlaybackDeckState.paused);
        expect(deck.needsSourceReload, isTrue);
        expect(usbAudioStatus.value.reason, 'route_changed');
      },
    );

    test(
      'route loss pauses and never starts the speaker automatically',
      () async {
        await deck.setFileSource('/one.flac', preferBitPerfect: true);
        await deck.resume();
        var statusChanges = 0;
        void onStatusChanged() => statusChanges++;
        usbAudioStatus.addListener(onStatusChanged);
        addTearDown(() => usbAudioStatus.removeListener(onStatusChanged));
        await event('paused');
        await _until(() => deck.state == PlaybackDeckState.paused);
        expect(native.playing, isEmpty);
        expect(usbAudioStatus.value.reason, 'route_changed');
        expect(statusChanges, 1);
        position = 19000;
        expect(deck.needsSourceReload, isTrue);
        await expectLater(deck.resume(), throwsA(isA<PlatformException>()));
        expect(native.playing, isEmpty);
        expect(deck.state, PlaybackDeckState.paused);
        expect(statusChanges, 1);
        expect(await deck.getCurrentPosition(), const Duration(seconds: 19));
      },
    );

    test(
      'events from an old song cannot pause or complete the new song',
      () async {
        await deck.setFileSource('/one.flac', preferBitPerfect: true);
        final oldToken = token;
        await deck.setFileSource('/two.flac', preferBitPerfect: true);
        await deck.resume();
        var completed = 0;
        final subscription = deck.onPlayerComplete.listen((_) => completed++);
        await event('complete', withToken: oldToken);
        await event('paused', withToken: oldToken);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(deck.state, PlaybackDeckState.playing);
        expect(completed, 0);
        await event('complete');
        await _until(() => completed == 1);
        expect(deck.state, PlaybackDeckState.completed);
        await subscription.cancel();
      },
    );
  });

  test('the ordinary output reads a position on wanted ticks and after '
      'a seek', () async {
    final deck = AudioplayersPlaybackDeck(playerId: 'ticks');
    try {
      var wanted = false;
      deck.startPositionUpdates(
        const Duration(milliseconds: 10),
        wanted: () => wanted,
      );
      int reads() => native.calls
          .where(
            (call) => call.$1 == 'ticks' && call.$2 == 'getCurrentPosition',
          )
          .length;
      await deck.setFileSource('/ticks.flac');
      await deck.resume();
      final loaded = reads();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(reads(), loaded);
      await deck.seek(const Duration(seconds: 5));
      expect(reads(), loaded + 1);
      wanted = true;
      await _until(() => reads() > loaded + 2);
      await deck.pause();
    } finally {
      await deck.dispose();
    }
  });
}
