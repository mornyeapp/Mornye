// Exercises the typed device API used by PlaybackAutomation.
// ignore_for_file: experimental_member_use

import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/playback_automation.dart';

AudioDevice device(String id, AudioDeviceType type, {bool output = true}) =>
    AudioDevice(
      id: id,
      name: id,
      isInput: !output,
      isOutput: output,
      type: type,
    );

class _Transport {
  bool playing = true;
  bool available = true;
  int pauses = 0;
  int plays = 0;
  int mutedWarnings = 0;
  Completer<void>? pauseGate;
  bool failPause = false;
  DateTime now = DateTime(2026, 11, 8, 12);
  final List<Object> errors = [];

  late final PlaybackAutomation automation = PlaybackAutomation(
    isPlaying: () => playing,
    canResume: () => available,
    pause: () async {
      pauses++;
      if (failPause) throw StateError('pause failed');
      await pauseGate?.future;
      playing = false;
    },
    play: () async {
      plays++;
      playing = true;
    },
    onError: errors.add,
    onMutedPause: () => mutedWarnings++,
    now: () => now,
  );

  Future<void> enable({
    bool mute = true,
    bool headphones = false,
    bool reconnect = false,
  }) => automation.configure(
    pauseOnMute: mute,
    playOnHeadphonesConnected: headphones,
    resumeAfterNoisyPause: reconnect,
  );

  /// The handler's becoming-noisy path: supersede, mark, then pause.
  Future<void> unplugWhilePlaying() async {
    automation.cancelPendingActions();
    automation.noisyPause();
    playing = false;
    await automation.devicesChanged({});
  }
}

final _bluetooth = {device('car', AudioDeviceType.bluetoothA2dp)};

void main() {
  test('mute automation defaults on and saved preferences survive restore', () {
    final defaults = AppSettings.fromJson({});
    expect(const AppSettings().pauseOnMute, isTrue);
    expect(defaults.pauseOnMute, isTrue);
    expect(defaults.headphoneResume, 'off');
    final settings = defaults.copyWith(
      pauseOnMute: false,
      headphoneResume: 'always',
    );
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.pauseOnMute, isFalse);
    expect(restored.headphoneResume, 'always');
    expect(restored.copyWith(autoMix: true).pauseOnMute, isFalse);
  });

  test('mute pauses once; unmute resumes only a pause owned by mute', () async {
    final transport = _Transport();
    await transport.enable();
    await transport.automation.volumeChanged(0.4);
    expect(transport.pauses, 0);
    await transport.automation.volumeChanged(0);
    await transport.automation.volumeChanged(0);
    expect(transport.pauses, 1);
    await transport.automation.volumeChanged(0.01);
    await transport.automation.volumeChanged(0.4);
    expect(transport.plays, 1);
    expect(transport.playing, isTrue);
    await transport.automation.dispose();
  });

  test('an already paused song cannot start on unmute', () async {
    final transport = _Transport()..playing = false;
    await transport.enable();
    await transport.automation.volumeChanged(0);
    await transport.automation.volumeChanged(0.5);
    expect(transport.pauses, 0);
    expect(transport.plays, 0);
    await transport.automation.dispose();
  });

  test('manual play accepts mute until volume is raised again', () async {
    final transport = _Transport();
    await transport.enable();
    await transport.automation.volumeChanged(0);
    expect(transport.playing, isFalse);
    expect(transport.mutedWarnings, 1);
    expect(transport.automation.blocksPlayback, isTrue);

    transport.automation.manualPlaybackRequested();
    transport.playing = true;
    await transport.automation.playbackStarted();
    await transport.automation.volumeChanged(0);
    await transport.automation.volumeChanged(0);
    expect(transport.playing, isTrue);
    expect(transport.pauses, 1);
    expect(transport.mutedWarnings, 1);
    expect(transport.automation.blocksPlayback, isFalse);

    // Source reloads/queue changes must preserve the explicit choice.
    transport.automation.cancelPendingActions();
    await transport.automation.playbackStarted();
    expect(transport.pauses, 1);

    await transport.automation.volumeChanged(0.5);
    await transport.automation.volumeChanged(0);
    expect(transport.playing, isFalse);
    expect(transport.pauses, 2);
    expect(transport.mutedWarnings, 2);
    await transport.automation.dispose();
  });

  test('first manual play of a paused muted song still warns', () async {
    final transport = _Transport()..playing = false;
    await transport.enable();
    await transport.automation.volumeChanged(0);
    transport.automation.manualPlaybackRequested();
    transport.playing = true;
    await transport.automation.playbackStarted();
    expect(transport.playing, isFalse);
    expect(transport.mutedWarnings, 1);
    await transport.automation.dispose();
  });

  test('a superseded automatic pause does not issue a stale warning', () async {
    final transport = _Transport()..pauseGate = Completer<void>();
    await transport.enable();
    final muted = transport.automation.volumeChanged(0);
    await Future<void>.delayed(Duration.zero);
    transport.automation.manualPlaybackRequested();
    transport.pauseGate!.complete();
    await muted;
    transport.playing = true;
    await transport.automation.playbackStarted();
    expect(transport.mutedWarnings, 0);
    expect(transport.playing, isTrue);
    await transport.automation.dispose();
  });

  for (final reason in ['manual pause', 'sleep timer', 'focus loss', 'stop']) {
    test('$reason cancels an unmute resume', () async {
      final transport = _Transport();
      await transport.enable();
      await transport.automation.volumeChanged(0);
      transport.automation.cancelPendingActions();
      await transport.automation.volumeChanged(0.5);
      expect(transport.plays, 0);
      await transport.automation.dispose();
    });
  }

  test('rapid mute and unmute do not leave a paused song behind', () async {
    final transport = _Transport()..pauseGate = Completer<void>();
    await transport.enable();
    final muted = transport.automation.volumeChanged(0);
    await Future<void>.delayed(Duration.zero);
    expect(transport.pauses, 1);
    final unmuted = transport.automation.volumeChanged(0.5);
    transport.pauseGate!.complete();
    await Future.wait([muted, unmuted]);
    expect(transport.plays, 1);
    expect(transport.playing, isTrue);
    await transport.automation.dispose();
  });

  test('explicit pause during an automatic pause cancels resume', () async {
    final transport = _Transport()..pauseGate = Completer<void>();
    await transport.enable();
    final muted = transport.automation.volumeChanged(0);
    await Future<void>.delayed(Duration.zero);
    transport.automation.cancelPendingActions();
    final unmuted = transport.automation.volumeChanged(0.5);
    transport.pauseGate!.complete();
    await Future.wait([muted, unmuted]);
    expect(transport.plays, 0);
    await transport.automation.dispose();
  });

  test('disabled preferences and unavailable sessions do nothing', () async {
    final transport = _Transport();
    await transport.automation.volumeChanged(0);
    expect(transport.pauses, 0);
    transport.available = false;
    await transport.enable();
    expect(transport.pauses, 0);
    await transport.automation.dispose();
  });

  test('turning mute automation off cancels its pending resume', () async {
    final transport = _Transport();
    await transport.enable();
    await transport.automation.volumeChanged(0);
    await transport.enable(mute: false);
    await transport.automation.volumeChanged(0.5);
    expect(transport.plays, 0);
    await transport.automation.dispose();
  });

  test('starting a new song at zero volume pauses it', () async {
    final transport = _Transport()..playing = false;
    await transport.enable();
    await transport.automation.volumeChanged(0);
    transport.playing = true;
    await transport.automation.playbackStarted();
    expect(transport.pauses, 1);
    await transport.automation.volumeChanged(0.5);
    expect(transport.plays, 1);
    await transport.automation.dispose();
  });

  test('failed pause is reported and cannot trigger unmute autoplay', () async {
    final transport = _Transport()..failPause = true;
    await transport.enable();
    await transport.automation.volumeChanged(0);
    await transport.automation.volumeChanged(0.5);
    expect(transport.errors, hasLength(1));
    expect(transport.mutedWarnings, 0);
    expect(transport.plays, 0);
    await transport.automation.dispose();
  });

  test(
    'initial headphone inventory does not start a restored session',
    () async {
      final transport = _Transport()..playing = false;
      await transport.enable(headphones: true);
      await transport.automation.devicesChanged({
        device('wired', AudioDeviceType.wiredHeadphones),
      });
      expect(transport.plays, 0);
      await transport.automation.dispose();
    },
  );

  for (final type in [
    AudioDeviceType.wiredHeadset,
    AudioDeviceType.wiredHeadphones,
    AudioDeviceType.usbAudio,
    AudioDeviceType.bluetoothA2dp,
    AudioDeviceType.bluetoothLe,
  ]) {
    test('$type connects once and disconnecting pauses', () async {
      final transport = _Transport()..playing = false;
      await transport.enable(headphones: true);
      await transport.automation.volumeChanged(0.5);
      await transport.automation.devicesChanged({});
      final headphones = {device('headphones', type)};
      await transport.automation.devicesChanged(headphones);
      await transport.automation.devicesChanged(headphones);
      expect(transport.plays, 1);
      await transport.automation.devicesChanged({});
      expect(transport.pauses, 1);
      expect(transport.playing, isFalse);
      await transport.automation.dispose();
    });
  }

  test(
    'speakers, microphones and Bluetooth call profiles do not autoplay',
    () async {
      final transport = _Transport()..playing = false;
      await transport.enable(headphones: true);
      await transport.automation.devicesChanged({});
      await transport.automation.devicesChanged({
        device('speaker', AudioDeviceType.builtInSpeaker),
        device('call', AudioDeviceType.bluetoothSco),
        device('mic', AudioDeviceType.wiredHeadset, output: false),
      });
      expect(transport.plays, 0);
      await transport.automation.dispose();
    },
  );

  test('headphone connections respect mute and audio interruptions', () async {
    final transport = _Transport()..playing = false;
    await transport.enable(headphones: true);
    await transport.automation.devicesChanged({});
    await transport.automation.volumeChanged(0);
    await transport.automation.devicesChanged({
      device('wired', AudioDeviceType.wiredHeadphones),
    });
    expect(transport.plays, 0);
    await transport.automation.volumeChanged(0.5);
    expect(transport.plays, 0);
    transport.available = false;
    await transport.automation.devicesChanged({
      device('bluetooth', AudioDeviceType.bluetoothA2dp),
    });
    expect(transport.plays, 0);
    await transport.automation.dispose();
  });

  test('unplugging cancels an unmute resume', () async {
    final transport = _Transport();
    await transport.enable(headphones: true);
    await transport.automation.devicesChanged({
      device('wired', AudioDeviceType.wiredHeadphones),
    });
    await transport.automation.volumeChanged(0);
    await transport.automation.devicesChanged({});
    await transport.automation.volumeChanged(0.5);
    expect(transport.plays, 0);
    await transport.automation.dispose();
  });

  test(
    'pending connection playback is cancelled by an explicit pause',
    () async {
      final transport = _Transport()..playing = false;
      await transport.enable(headphones: true);
      await transport.automation.devicesChanged({});
      final connected = transport.automation.devicesChanged({
        device('wired', AudioDeviceType.wiredHeadphones),
      });
      transport.automation.cancelPendingActions();
      await connected;
      expect(transport.plays, 0);
      await transport.automation.dispose();
    },
  );

  group('resume when headphones reconnect', () {
    test('the choice defaults to off and round-trips through JSON', () {
      expect(const AppSettings().headphoneResume, 'off');
      expect(AppSettings.fromJson(const {}).headphoneResume, 'off');
      for (final mode in headphoneResumeModes) {
        final saved = const AppSettings().copyWith(headphoneResume: mode);
        expect(AppSettings.fromJson(saved.toJson()).headphoneResume, mode);
      }
    });

    test('settings from before the choice migrate', () {
      AppSettings read(Map<String, dynamic> json) => AppSettings.fromJson(json);
      // The old switch on means Always, whatever the unreleased one held.
      expect(
        read({'playOnHeadphonesConnected': true}).headphoneResume,
        'always',
      );
      expect(
        read({
          'playOnHeadphonesConnected': true,
          'resumeOnOutputReconnect': true,
        }).headphoneResume,
        'always',
      );
      expect(
        read({
          'playOnHeadphonesConnected': false,
          'resumeOnOutputReconnect': true,
        }).headphoneResume,
        'after_disconnect',
      );
      expect(read({'playOnHeadphonesConnected': false}).headphoneResume, 'off');
      // A saved choice wins over the old keys it writes for older builds.
      expect(
        read({
          'headphoneResume': 'after_disconnect',
          'playOnHeadphonesConnected': false,
        }).headphoneResume,
        'after_disconnect',
      );
      expect(
        read({
          'headphoneResume': 'off',
          'playOnHeadphonesConnected': true,
        }).headphoneResume,
        'off',
      );
      // Unknown values fall back to the old keys, then off.
      expect(read({'headphoneResume': 'sometimes'}).headphoneResume, 'off');
      expect(
        read({
          'headphoneResume': 42,
          'playOnHeadphonesConnected': true,
        }).headphoneResume,
        'always',
      );
    });

    test('older builds and backups still read the old switch', () {
      for (final (mode, old) in [
        ('off', false),
        ('after_disconnect', false),
        ('always', true),
      ]) {
        final json = const AppSettings()
            .copyWith(headphoneResume: mode)
            .toJson();
        expect(json['headphoneResume'], mode);
        expect(json['playOnHeadphonesConnected'], old);
        expect(json.containsKey('resumeOnOutputReconnect'), isFalse);
      }
    });

    test('the window keeps recent pauses and drops old or future ones', () {
      final at = DateTime(2026, 11, 8, 12);
      expect(resumesNoisyPause(null, at), isFalse);
      expect(resumesNoisyPause(at, at), isTrue);
      expect(resumesNoisyPause(at, at.add(noisyPauseResumeWindow)), isTrue);
      expect(
        resumesNoisyPause(
          at,
          at.add(noisyPauseResumeWindow + const Duration(seconds: 1)),
        ),
        isFalse,
      );
      expect(
        resumesNoisyPause(at, at.subtract(const Duration(minutes: 1))),
        isFalse,
      );
    });

    test('a route-loss pause resumes once on reconnect', () async {
      final transport = _Transport();
      await transport.enable(mute: false, reconnect: true);
      await transport.automation.devicesChanged(_bluetooth);
      await transport.unplugWhilePlaying();
      // Disconnecting is not this setting's business: no extra pause.
      expect(transport.pauses, 0);
      transport.now = transport.now.add(const Duration(minutes: 29));
      await transport.automation.devicesChanged(_bluetooth);
      expect(transport.plays, 1);
      expect(transport.playing, isTrue);

      transport.playing = false;
      await transport.automation.devicesChanged({});
      await transport.automation.devicesChanged(_bluetooth);
      expect(transport.plays, 1);
      await transport.automation.dispose();
    });

    test('an old route-loss pause stays paused', () async {
      final transport = _Transport();
      await transport.enable(mute: false, reconnect: true);
      await transport.automation.devicesChanged(_bluetooth);
      await transport.unplugWhilePlaying();
      transport.now = transport.now.add(const Duration(minutes: 31));
      await transport.automation.devicesChanged(_bluetooth);
      expect(transport.plays, 0);
      await transport.automation.dispose();
    });

    test('a pause the user made never resumes', () async {
      final transport = _Transport()..playing = false;
      await transport.enable(mute: false, reconnect: true);
      await transport.automation.devicesChanged(_bluetooth);
      await transport.automation.devicesChanged({});
      await transport.automation.devicesChanged(_bluetooth);
      expect(transport.plays, 0);
      await transport.automation.dispose();
    });

    test('pausing, playing or a new song after the unplug wins', () async {
      final transport = _Transport();
      await transport.enable(mute: false, reconnect: true);
      await transport.automation.devicesChanged(_bluetooth);
      await transport.unplugWhilePlaying();
      // Pause, Play, a skip and Stop all supersede pending actions.
      transport.automation.cancelPendingActions();
      await transport.automation.devicesChanged(_bluetooth);
      expect(transport.plays, 0);
      await transport.automation.dispose();
    });

    test('a fresh automation (the app was killed) resumes nothing', () async {
      final before = _Transport();
      await before.enable(mute: false, reconnect: true);
      await before.automation.devicesChanged(_bluetooth);
      await before.unplugWhilePlaying();
      await before.automation.dispose();

      final after = _Transport()..playing = false;
      await after.enable(mute: false, reconnect: true);
      await after.automation.devicesChanged({});
      await after.automation.devicesChanged(_bluetooth);
      expect(after.plays, 0);
      await after.automation.dispose();
    });

    test('an unavailable session still blocks the resume', () async {
      final transport = _Transport();
      await transport.enable(reconnect: true);
      await transport.automation.volumeChanged(0.5);
      await transport.automation.devicesChanged(_bluetooth);
      await transport.unplugWhilePlaying();
      transport.available = false;
      await transport.automation.devicesChanged(_bluetooth);
      expect(transport.plays, 0);
      await transport.automation.dispose();
    });

    test('off: a route-loss pause stays paused', () async {
      final transport = _Transport();
      await transport.enable(mute: false);
      await transport.automation.devicesChanged(_bluetooth);
      await transport.unplugWhilePlaying();
      await transport.automation.devicesChanged(_bluetooth);
      expect(transport.plays, 0);
      await transport.automation.dispose();
    });

    test('with Play when headphones or a car connect, a disconnect keeps the '
        'route-loss pause resumable', () async {
      final transport = _Transport();
      await transport.enable(mute: false, headphones: true, reconnect: true);
      await transport.automation.devicesChanged(_bluetooth);
      transport.automation.cancelPendingActions();
      transport.automation.noisyPause();
      await transport.automation.devicesChanged({});
      expect(transport.pauses, 1);
      await transport.automation.devicesChanged(_bluetooth);
      expect(transport.plays, 1);
      await transport.automation.dispose();
    });
  });

  test('disposal cancels queued work and stale notifications', () async {
    final transport = _Transport();
    await transport.enable(headphones: true);
    final muted = transport.automation.volumeChanged(0);
    await transport.automation.dispose();
    await muted;
    await transport.automation.volumeChanged(0.5);
    expect(transport.pauses, 0);
    expect(transport.plays, 0);
  });
}
