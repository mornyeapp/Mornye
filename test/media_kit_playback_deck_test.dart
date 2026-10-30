import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/services/alsa_output_devices.dart';
import 'package:mornye/services/media_kit_playback_deck.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/playback_equalizer.dart';

import 'support/fake_mpv_engine.dart';

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 150));

void main() {
  late FakeMpvEngine engine;
  late MediaKitPlaybackDeck deck;

  setUp(() {
    MediaKitPlaybackDeck.debugResetMissingFilters();
    playbackEqualizer.value = const EqualizerSettings();
    playbackEqualizerError.value = null;
    playbackOutputVolume.value = 1;
    engine = FakeMpvEngine();
    deck = MediaKitPlaybackDeck(playerId: 'mpv-test', engine: engine);
  });

  tearDown(() async {
    await deck.dispose();
    playbackEqualizer.value = const EqualizerSettings();
    playbackOutputVolume.value = 1;
  });

  test('loads a file paused and reports its duration', () async {
    final durations = <Duration>[];
    deck.onDurationChanged.listen(durations.add);
    await deck.setFileSource('/music/song.flac');
    expect(
      engine.calls,
      containsAllInOrder([
        ['stop'],
        ['open', '/music/song.flac'],
      ]),
    );
    expect(await deck.getDuration(), const Duration(seconds: 90));
    expect(durations, [const Duration(seconds: 90)]);
    expect(engine.calls, isNot(contains(['play'])));
  });

  test('transport changes the reported state', () async {
    final states = <PlaybackDeckState>[];
    deck.onPlayerStateChanged.listen(states.add);
    await deck.setFileSource('/song.flac');
    await deck.resume();
    expect(deck.state, PlaybackDeckState.playing);
    await deck.pause();
    expect(deck.state, PlaybackDeckState.paused);
    await deck.resume();
    engine.completedEvents.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(deck.state, PlaybackDeckState.completed);
    expect(states, [
      PlaybackDeckState.stopped,
      PlaybackDeckState.playing,
      PlaybackDeckState.paused,
      PlaybackDeckState.playing,
      PlaybackDeckState.completed,
    ]);
  });

  test('positions are published on a timer while playing', () async {
    final positions = <Duration>[];
    deck.onPositionChanged.listen(positions.add);
    deck.startPositionUpdates(const Duration(milliseconds: 10));
    await deck.setFileSource('/song.flac');
    engine.position = const Duration(seconds: 3);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(positions, isEmpty);
    await deck.resume();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(positions, isNotEmpty);
    expect(positions.last, const Duration(seconds: 3));
  });

  test('the position timer runs only while playing', () async {
    const interval = Duration(milliseconds: 10);
    final timers = <Timer>[];
    final positions = <Duration>[];
    bool ticking() => timers.any((timer) => timer.isActive);
    await runZoned(
      () async {
        deck.onPositionChanged.listen(positions.add);
        deck.startPositionUpdates(interval);
        expect(ticking(), isFalse);
        await deck.setFileSource('/song.flac');
        expect(ticking(), isFalse);
        await deck.resume();
        expect(ticking(), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(positions, isNotEmpty);
        await deck.pause();
        expect(ticking(), isFalse);
        // A tick from just before the pause may still be in delivery.
        await Future<void>.delayed(Duration.zero);
        positions.clear();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(positions, isEmpty);
        await deck.resume();
        expect(ticking(), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(positions, isNotEmpty);
        engine.completedEvents.add(true);
        await Future<void>.delayed(Duration.zero);
        expect(deck.state, PlaybackDeckState.completed);
        expect(ticking(), isFalse);
        await deck.resume();
        await deck.stop();
        expect(ticking(), isFalse);
      },
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, period, callback) {
          final timer = parent.createPeriodicTimer(zone, period, callback);
          if (period == interval) timers.add(timer);
          return timer;
        },
      ),
    );
    // One timer for each of the three times the deck played.
    expect(timers, hasLength(3));
  });

  test(
    'a source that fails to open throws, DSD as UsbDsdUnavailable',
    () async {
      engine.openError = (prefix: 'cplayer', text: 'Failed to recognize file');
      await expectLater(
        deck.setFileSource('/broken.flac'),
        throwsA(isA<MediaKitSourceException>()),
      );
      await expectLater(
        deck.setFileSource('/song.dsf', requiresDsd: true),
        throwsA(isA<UsbDsdUnavailable>()),
      );
      engine.openError = null;
      await deck.setFileSource('/song.dsf', requiresDsd: true);
      expect(await deck.getDuration(), const Duration(seconds: 90));
    },
  );

  test('a runtime source error fails the next resume', () async {
    final errors = <Object>[];
    deck.onPlayerStateChanged.listen((_) {}, onError: errors.add);
    await deck.setFileSource('/song.flac');
    await deck.resume();
    engine.errorEvents.add((prefix: 'ad', text: 'Error decoding frame'));
    await Future<void>.delayed(Duration.zero);
    expect(errors, isEmpty);
    engine.errorEvents.add((prefix: 'stream', text: 'Read error'));
    await Future<void>.delayed(Duration.zero);
    expect(errors.single, isA<MediaKitSourceException>());
    await expectLater(deck.resume(), throwsA(isA<MediaKitSourceException>()));
  });

  for (final diagnostic in [
    (prefix: 'ffmpeg', text: 'Incorrect BOM value'),
    (prefix: 'ffmpeg/demuxer', text: 'Error reading frame TIT2, skipped'),
    (prefix: 'ad', text: 'Error decoding frame'),
    (
      prefix: 'cplayer',
      text: r'Can not open external file \\?\D:\Music\100% Hits\Song.lrc.',
    ),
  ]) {
    test(
      'recoverable ${diagnostic.prefix} error does not abort opening',
      () async {
        engine.openError = diagnostic;
        final errors = <Object>[];
        final subscription = deck.onPlayerStateChanged.listen(
          (_) {},
          onError: errors.add,
        );
        addTearDown(subscription.cancel);
        final loaded = expectLater(
          deck.setFileSource('/tagged.mp3'),
          completes,
        );
        await Future<void>.delayed(Duration.zero);
        engine.durationEvents.add(const Duration(seconds: 90));
        await loaded;
        expect(await deck.getDuration(), const Duration(seconds: 90));
        await deck.resume();
        expect(deck.state, PlaybackDeckState.playing);
        expect(errors, isEmpty);
        expect(
          engine.calls.where((call) => call.first == 'stop'),
          hasLength(1),
        );
      },
    );
  }

  test(
    'a fatal opening error after a tag diagnostic still rejects the source',
    () async {
      engine.openError = (prefix: 'ffmpeg', text: 'Incorrect BOM value');
      final failed = expectLater(
        deck.setFileSource('/broken.mp3'),
        throwsA(
          isA<MediaKitSourceException>().having(
            (error) => error.message,
            'fatal error',
            contains('Failed to recognize file'),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      engine.errorEvents.add((
        prefix: 'cplayer',
        text: 'Failed to recognize file',
      ));
      await failed;
    },
  );

  test(
    'volume is scaled by the in-app output volume on a cubic curve',
    () async {
      await deck.setVolume(0.8);
      expect(engine.volume, closeTo(100 * 0.9283, 0.01));
      playbackOutputVolume.value = 0.5;
      await Future<void>.delayed(Duration.zero);
      // 0.8 * 0.5 = 0.4 linear gain; mpv's volume is cubic.
      expect(engine.volume, closeTo(100 * 0.7368, 0.01));
      await deck.setVolume(0);
      expect(engine.volume, 0);
    },
  );

  test('equalizer changes set the chain while playing', () async {
    await _settle();
    expect(engine.filterWrites.single, ['set', 'af', '']);

    playbackEqualizer.value = const EqualizerSettings(enabled: true);
    await _settle();
    expect(
      engine.properties['af'],
      contains('@mornye_dsp:lavfi=[volume@pre=precision=float:volume=0dB,'),
    );

    await deck.setFileSource('/song.flac');
    await deck.resume();
    playbackEqualizer.value = playbackEqualizer.value.copyWith(preamp: -2);
    await _settle();
    expect(engine.properties['af'], contains('volume=-2dB'));

    var writes = engine.filterWrites.length;
    for (final gain in [-1.0, -1.5, -2.0]) {
      playbackEqualizer.value = playbackEqualizer.value.copyWith(
        gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, gain],
      );
    }
    await _settle();
    expect(engine.filterWrites.length, writes + 1);
    expect(
      engine.properties['af'],
      contains('equalizer@band9=f=16000:t=q:w=1.4142:g=-2,'),
    );

    // An identical chain, here from a new rate below every band, is not set
    // again.
    writes = engine.filterWrites.length;
    engine.sampleRateEvents.add(48000);
    await _settle();
    expect(engine.filterWrites.length, writes);
    expect(playbackEqualizerError.value, isNull);

    playbackEqualizer.value = const EqualizerSettings();
    await _settle();
    expect(engine.properties['af'], '');
  });

  test('filters libmpv lacks are probed once and left out', () async {
    MediaKitPlaybackDeck.debugResetMissingFilters();
    addTearDown(MediaKitPlaybackDeck.debugResetMissingFilters);
    engine.missingFilters = {'volume', 'stereotools', 'alimiter'};
    await deck.setVolume(1);
    playbackEqualizer.value = const EqualizerSettings(
      enabled: true,
    ).copyWith(gains: [6, 0, 0, 0, 0, 0, 0, 0, 0, 0], balance: 0.5);
    await _settle();
    final af = engine.properties['af']!;
    expect(af, contains('equalizer@band0'));
    expect(af, isNot(contains('volume@pre')));
    expect(af, isNot(contains('stereotools')));
    // The -6 dB headroom moves to mpv's cubic volume.
    expect(engine.volume, closeTo(100 * 0.7943, 0.01));
    expect(playbackEqualizerError.value, contains('balance'));

    final probes = engine.filterWrites
        .where((call) => call[2].startsWith('@mornye_probe'))
        .length;
    expect(probes, 4);
    final other = FakeMpvEngine()..missingFilters = engine.missingFilters;
    final second = MediaKitPlaybackDeck(playerId: 'mpv-other', engine: other);
    await _settle();
    expect(
      other.filterWrites.where((call) => call[2].startsWith('@mornye_probe')),
      isEmpty,
    );
    await second.dispose();
  });

  test('a chain mpv disabled is set again on the next change', () async {
    playbackEqualizer.value = const EqualizerSettings(enabled: true);
    await _settle();
    engine.errorEvents.add((
      prefix: 'af',
      text: 'Disabling filter mornye_dsp because it has failed.',
    ));
    await Future<void>.delayed(Duration.zero);
    expect(playbackEqualizerError.value, contains('mornye_dsp'));
    final writes = engine.filterWrites.length;
    // Same chain as before: a rate change that leaves every band in place.
    engine.sampleRateEvents.add(48000);
    await _settle();
    expect(engine.filterWrites.length, writes + 1);
    expect(playbackEqualizerError.value, isNull);
  });

  test('a new sample rate rebuilds the bands', () async {
    playbackEqualizer.value = const EqualizerSettings(
      enabled: true,
    ).withBandCount(31);
    await _settle();
    expect(engine.properties['af'], contains('f=19845'));
    engine.sampleRateEvents.add(96000);
    await _settle();
    expect(engine.properties['af'], contains('f=20000'));
  });

  test('filter failures are reported for this player only', () async {
    engine.rejectFilters = true;
    playbackEqualizer.value = const EqualizerSettings(enabled: true);
    await _settle();
    expect(playbackEqualizerError.value, contains('mpv error -7'));
    engine.rejectFilters = false;
    playbackEqualizer.value = const EqualizerSettings();
    await _settle();
    expect(playbackEqualizerError.value, isNull);

    playbackEqualizer.value = const EqualizerSettings(enabled: true);
    await _settle();
    engine.errorEvents.add((
      prefix: 'ffmpeg/Parsed_equalizer_0',
      text: 'Invalid frequency',
    ));
    await Future<void>.delayed(Duration.zero);
    expect(playbackEqualizerError.value, contains('Invalid frequency'));
    await deck.dispose();
    expect(playbackEqualizerError.value, isNull);
    expect(engine.disposed, isTrue);
  });

  group('exclusive output', () {
    tearDown(() {
      playbackExclusiveOutput.value = false;
      playbackExclusiveStatus.value = ExclusiveOutputStatus.pending;
    });

    int reloads() => engine.calls
        .where((call) => call[0] == 'command' && call[1] == 'ao-reload')
        .length;

    test('each source opens in exclusive mode while it is on', () async {
      playbackExclusiveOutput.value = true;
      await deck.configureOutput();
      await deck.setFileSource('/song.flac');
      expect(engine.properties['audio-exclusive'], 'yes');
      expect(playbackExclusiveStatus.value, ExclusiveOutputStatus.active);
      // Nothing was open yet, so the output needed no reload.
      expect(reloads(), 0);
    });

    test('a change during playback reopens the output at once', () async {
      await deck.configureOutput();
      await deck.setFileSource('/song.flac');
      await deck.resume();
      playbackExclusiveOutput.value = true;
      await _settle();
      expect(engine.properties['audio-exclusive'], 'yes');
      expect(reloads(), 1);
      expect(playbackExclusiveStatus.value, ExclusiveOutputStatus.active);

      playbackExclusiveOutput.value = false;
      await _settle();
      expect(engine.properties['audio-exclusive'], 'no');
      expect(reloads(), 2);
      expect(playbackExclusiveStatus.value, ExclusiveOutputStatus.pending);
    });

    test('a refused device plays the source through the mixer', () async {
      engine.refuseExclusive = true;
      final errors = <Object>[];
      deck.onPlayerStateChanged.listen((_) {}, onError: errors.add);
      playbackExclusiveOutput.value = true;
      await deck.configureOutput();
      await deck.setFileSource('/song.flac');
      await _settle();
      expect(playbackExclusiveStatus.value, ExclusiveOutputStatus.unavailable);
      expect(engine.properties['audio-exclusive'], 'no');
      expect(engine.calls.where((call) => call[0] == 'open'), hasLength(2));
      // The driver lines are not source failures.
      await deck.resume();
      expect(errors, isEmpty);

      // The next source tries exclusive mode again.
      engine.refuseExclusive = false;
      await deck.configureOutput();
      await deck.setFileSource('/next.flac');
      expect(engine.properties['audio-exclusive'], 'yes');
      expect(playbackExclusiveStatus.value, ExclusiveOutputStatus.active);
    });

    test('a device lost while playing resumes where it was', () async {
      playbackExclusiveOutput.value = true;
      await deck.configureOutput();
      await deck.setFileSource('/song.flac');
      await deck.resume();
      engine.calls.clear();
      engine.position = const Duration(seconds: 30);
      engine.errorEvents.add((
        prefix: 'cplayer',
        text: 'Could not open/initialize audio device -> no sound.',
      ));
      await _settle();
      // The equalizer may also set its chain; the transport is these calls.
      expect(engine.calls.where((call) => !call.contains('af')), [
        ['set', 'audio-exclusive', 'no'],
        ['open', '/song.flac'],
        ['seek', '30000'],
        ['play'],
      ]);
      expect(deck.state, PlaybackDeckState.playing);

      // Without exclusive mode the same line is a source failure.
      final errors = <Object>[];
      deck.onPlayerStateChanged.listen((_) {}, onError: errors.add);
      engine.errorEvents.add((
        prefix: 'cplayer',
        text: 'Could not open/initialize audio device -> no sound.',
      ));
      await _settle();
      expect(errors, hasLength(1));
    });

    group('on Linux', () {
      const device = 'alsa/hw:CARD=PCH,DEV=0';
      setUp(() {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        playbackExclusiveDevice.value = device;
      });
      tearDown(() {
        debugDefaultTargetPlatformOverride = null;
        playbackExclusiveDevice.value = '';
      });

      test('opens the ALSA device and returns to the mixer', () async {
        playbackExclusiveOutput.value = true;
        await deck.configureOutput();
        await deck.setFileSource('/song.flac');
        await deck.resume();
        expect(engine.properties['audio-device'], device);
        expect(engine.properties.containsKey('audio-exclusive'), isFalse);
        expect(playbackExclusiveStatus.value, ExclusiveOutputStatus.active);

        playbackExclusiveOutput.value = false;
        await _settle();
        expect(engine.properties['audio-device'], 'auto');
        expect(reloads(), 1);
        expect(playbackExclusiveStatus.value, ExclusiveOutputStatus.pending);
      });

      test('a busy device plays through the sound server', () async {
        engine.refuseExclusive = true;
        playbackExclusiveOutput.value = true;
        await deck.configureOutput();
        await deck.setFileSource('/song.flac');
        await _settle();
        expect(engine.properties['audio-device'], 'auto');
        expect(
          playbackExclusiveStatus.value,
          ExclusiveOutputStatus.unavailable,
        );
      });

      test('no known device keeps the shared output', () async {
        playbackExclusiveDevice.value = '';
        playbackExclusiveOutput.value = true;
        await deck.configureOutput();
        await deck.setFileSource('/song.flac');
        expect(engine.properties['audio-device'], 'auto');
        expect(playbackExclusiveStatus.value, ExclusiveOutputStatus.pending);

        // The device list arrives: the output switches to it.
        playbackExclusiveDevice.value = device;
        await _settle();
        expect(engine.properties['audio-device'], device);
      });
    });
  });

  test('ALSA playback devices come from /proc/asound', () {
    const cards = '''
 0 [PCH            ]: HDA-Intel - HDA Intel PCH
                      HDA Intel PCH at 0xf7f10000 irq 32
 1 [DAC            ]: USB-Audio - USB Audio DAC
                      Generic USB Audio DAC at usb-0000:00:14.0-2, high speed
''';
    const pcm = '''
00-00: ALC892 Analog : ALC892 Analog : playback 1 : capture 1
00-02: ALC892 Alt Analog : ALC892 Alt Analog : capture 1
01-00: USB Audio : USB Audio : playback 1
''';
    final devices = parseAlsaOutputDevices(cards: cards, pcm: pcm);
    expect(devices.map((device) => device.id), [
      'alsa/hw:CARD=PCH,DEV=0',
      'alsa/hw:CARD=DAC,DEV=0',
    ]);
    expect(devices.map((device) => device.label), [
      'HDA Intel PCH: ALC892 Analog',
      'USB Audio DAC: USB Audio',
    ]);
  });
}
