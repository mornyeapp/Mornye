import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/automix_analysis.dart';
import 'package:mornye/services/automix_analyzer.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/music_haptics.dart';
import 'package:mornye/services/playback_notification.dart';
import 'package:mornye/models/automix_options.dart';
import 'package:mornye/services/automix_effect_renderer.dart';
import 'package:mornye/services/automix_status.dart';

import 'virtual_time.dart';

class FakeEffectRenderer extends AutoMixEffectRenderer {
  final tails = <RenderedMixTail>[];
  final bassHandoffs = <bool>[];
  bool fail = false;

  @override
  Future<RenderedMixTail?> render(
    String path, {
    required Duration start,
    required Duration duration,
    required AutoMixOptions options,
    bool bassHandoff = false,
  }) async {
    bassHandoffs.add(bassHandoff);
    if (fail) return null;
    final work = await Directory.systemTemp.createTemp('fake-mix-tail-');
    final tail = RenderedMixTail(work, '${work.path}/tail.wav');
    tails.add(tail);
    return tail;
  }
}

class FakeAutoMixAnalyzer extends AutoMixAnalyzer {
  final calls = <String>[];
  Completer<AutoMixBeatGrid?>? pending;
  bool matchBeats = false;
  double confidence = 0.9;

  @override
  Future<AutoMixBeatGrid?> analyze(String path, {double offset = 0}) async {
    calls.add(path);
    if (matchBeats) {
      return AutoMixBeatGrid(
        bpm: offset > 0 ? 120 : 124,
        phase: 0.17,
        confidence: confidence,
        firstSound: 0.1,
      );
    }
    return pending?.future;
  }
}

class FakeHapticsAnalyzer extends MusicHapticsAnalyzer {
  final paths = <String>[];

  @override
  Future<HapticTrack?> analyze(String path) async {
    paths.add(path);
    return HapticTrack(
      Int32List.fromList(List.generate(20, (index) => (index + 1) * 150)),
      Uint8List.fromList(List.filled(20, 255)),
      Uint8List(20),
    );
  }
}

/// Exercises the real AudioPlayer transport/streams against a native-channel
/// fake, including preparation, seek completion and outgoing completion events.
class AudioNative {
  AudioNative([this.newClock = Stopwatch.new]);

  /// Times mix and effect decks.
  final Stopwatch Function() newClock;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <(String, String, Map<Object?, Object?>)>[];
  final positions = <String, int>{};
  final live = <String>{};
  final playing = <String>{};
  final sources = <String, String>{};
  final sourceContents = <String, String>{};
  final preparedContents = <String, String>{};
  final sourceGates = <String, Completer<void>>{};
  final releases = <String, int>{};
  final sourceFailures = <String>{};
  final resumeFailures = <String>{};
  bool failResumeMethod = false;
  final resumedSources = <String>[];
  Completer<void>? resumeGate;
  final resumeGates = <String, Completer<void>>{};
  final stalled = <String>{};
  final clocks = <String, Stopwatch>{};
  final rates = <String, double>{};
  final ignoredSeeks = <String>{};
  final missingPositions = <String>{};
  bool emitsDuration = true;

  int currentPosition(String id) =>
      (positions[id] ?? 0) +
      (stalled.contains(id)
          ? 0
          : ((clocks[id]?.elapsedMilliseconds ?? 0) * (rates[id] ?? 1))
                .round());

  void install() {
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
        final args = call.arguments as Map<Object?, Object?>;
        final id = args['playerId']! as String;
        calls.add((id, call.method, args));
        switch (call.method) {
          case 'create':
            live.add(id);
            positions[id] = 0;
            messenger.setMockMethodCallHandler(
              MethodChannel('xyz.luan/audioplayers/events/$id'),
              (_) async => null,
            );
          case 'setSourceUrl':
            final source = args['url']! as String;
            final released = releases[id];
            await sourceGates[source]?.future;
            // A release meanwhile reset the player and its old prepare.
            if (releases[id] != released) return null;
            if (sourceFailures.contains(source)) {
              unawaited(error(id));
              return null;
            }
            // Android caches equal URLs, including recycled SAF descriptors.
            if (sources[id] != source) {
              sources[id] = source;
              preparedContents[id] = sourceContents[source] ?? source;
            }
            unawaited(event(id, 'audio.onPrepared', true));
            if (emitsDuration) unawaited(event(id, 'audio.onDuration', 60000));
          case 'seek':
            if (!ignoredSeeks.contains(id)) {
              positions[id] = args['position']! as int;
              clocks[id]?.reset();
            }
            unawaited(event(id, 'audio.onSeekComplete'));
          case 'setPlaybackRate':
            positions[id] = currentPosition(id);
            clocks[id]?.reset();
            rates[id] = (args['playbackRate']! as num).toDouble();
          case 'resume':
            await resumeGate?.future;
            await resumeGates[id]?.future;
            if (failResumeMethod) {
              throw PlatformException(code: 'AndroidAudioError');
            }
            if (resumeFailures.contains(id)) {
              await error(id);
              return null;
            }
            playing.add(id);
            resumedSources.add(sources[id]!);
            if (id.startsWith('music-mix-') || id.startsWith('music-effect-')) {
              clocks[id] = newClock()..start();
            }
          case 'pause' || 'stop':
            playing.remove(id);
            clocks[id]?.stop();
          case 'release':
            releases[id] = (releases[id] ?? 0) + 1;
            playing.remove(id);
            sources.remove(id);
            preparedContents.remove(id);
          case 'dispose':
            playing.remove(id);
            live.remove(id);
          case 'getDuration':
            return 60000;
          case 'getCurrentPosition':
            if (missingPositions.contains(id)) return null;
            return currentPosition(id);
        }
        return null;
      },
    );
  }

  Future<void> event(String id, String name, [Object? value]) async {
    await messenger.handlePlatformMessage(
      'xyz.luan/audioplayers/events/$id',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': name,
        'value': ?value,
      }),
      (_) {},
    );
  }

  Future<void> error(String id, {String details = 'MEDIA_ERROR_SYSTEM'}) async {
    await messenger.handlePlatformMessage(
      'xyz.luan/audioplayers/events/$id',
      const StandardMethodCodec().encodeErrorEnvelope(
        code: 'AndroidAudioError',
        message: 'Audio output failed',
        details: details,
      ),
      (_) {},
    );
  }

  String get prepared => live.singleWhere((id) => id != 'music-player');

  double? lastVolume(String id) =>
      calls
              .where((call) => call.$1 == id && call.$2 == 'setVolume')
              .lastOrNull
              ?.$3['volume']
          as double?;
}

const testTracks = [
  PlayableMedia(id: 'one', source: '/one.flac', title: 'One', artist: 'Artist'),
  PlayableMedia(id: 'two', source: '/two.flac', title: 'Two', artist: 'Artist'),
  PlayableMedia(
    id: 'three',
    source: '/three.flac',
    title: 'Three',
    artist: 'Artist',
  ),
];

Future<void> waitUntil(bool Function() ready) async {
  for (var i = 0; i < 100; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Playback did not reach the expected state');
}

void configurePlaybackNotification({
  required PlaybackNotification presentation,
  required Future<bool> Function(MediaItem) toggleFavorite,
}) => musicPlayerRuntime.configureNotification(
  presentation: presentation,
  toggleFavorite: toggleFavorite,
);

void setPlaybackAutomationOptions({
  required bool enabled,
  required bool pauseOnMute,
  required bool playOnHeadphonesConnected,
}) => musicPlayerRuntime.configure(
  musicPlayerRuntime.settings.copyWith(
    playerMode: enabled ? 'internal' : 'external',
    pauseOnMute: pauseOnMute,
    playOnHeadphonesConnected: playOnHeadphonesConnected,
  ),
);

void setAutoMixEnabled(bool enabled) => musicPlayerRuntime.configure(
  musicPlayerRuntime.settings.copyWith(autoMix: enabled),
);

void setAutoMixOptions(AutoMixOptions options) => musicPlayerRuntime.configure(
  musicPlayerRuntime.settings.copyWith(
    autoMixDuration: options.durationSeconds,
    autoMixEffect: options.effect,
    autoMixSpeed: options.speed,
    autoMixPitch: options.pitchSemitones,
    autoMixEcho: options.echo,
    autoMixLowPass: options.lowPass,
  ),
);

void setUsbBitPerfectEnabled(bool enabled) => musicPlayerRuntime.configure(
  musicPlayerRuntime.settings.copyWith(usbBitPerfect: enabled),
);

void setAutoplayEnabled(bool enabled, {bool includeLocal = true}) =>
    musicPlayerRuntime.configure(
      musicPlayerRuntime.settings.copyWith(
        autoplay: enabled,
        localLibraryEnabled: includeLocal,
      ),
    );

// The player under test and its fakes, rebuilt for every test by the setUp
// that [setUpMusicPlayerHarness] registers.
late AudioNative native;
late FakeAutoMixAnalyzer analyzer;
late FakeEffectRenderer effectRenderer;
late MusicPlayerHandler handler;
late AutoplayLibraryLoader autoplayLoader;
late FakeHapticsAnalyzer hapticsAnalyzer;
late List<String?> hapticSongs;
late VirtualTime time;

void _setUpPlayer() {
  musicPlayerRuntime.configure(
    musicPlayerRuntime.settings.copyWith(musicHaptics: false),
  );
  setPlaybackAutomationOptions(
    enabled: true,
    pauseOnMute: false,
    playOnHeadphonesConnected: false,
  );
  setAutoMixEnabled(false);
  setAutoMixOptions(const AutoMixOptions());
  setUsbBitPerfectEnabled(false);
  setAutoplayEnabled(false);
  native = AudioNative(time.stopwatch)..install();
  analyzer = FakeAutoMixAnalyzer();
  effectRenderer = FakeEffectRenderer();
  autoplayLoader = (_) async => testTracks;
  hapticsAnalyzer = FakeHapticsAnalyzer();
  hapticSongs = [];
  handler = MusicPlayerHandler(
    autoMixAnalyzer: analyzer,
    autoMixEffectRenderer: effectRenderer,
    autoplayLibraryLoader: (seed) => autoplayLoader(seed),
    hapticsAnalyzer: hapticsAnalyzer,
    hapticPulse: (_, _) async => hapticSongs.add(handler.mediaItem.value?.id),
  );
}

/// Registers the shared player setUp and tearDown in the calling `main`.
void setUpMusicPlayerHarness() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUp(() {
    time = VirtualTime();
    autoMixStopwatch = time.stopwatch;
    addTearDown(() => autoMixStopwatch = Stopwatch.new);
    // Timers follow the zone of the listener that creates them, so the player
    // is built in the zone that fakeTimeTest can switch to virtual time.
    time.zone.run(_setUpPlayer);
  });

  tearDown(() async {
    await handler.dispose();
    configurePlaybackNotification(
      presentation: const PlaybackNotification(),
      toggleFavorite: (_) async => false,
    );
    analyzer.pending?.complete(null);
    setAutoMixEnabled(false);
    setUsbBitPerfectEnabled(false);
    setAutoplayEnabled(false);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(native.live, isEmpty);
    expect(native.playing, isEmpty);
    expect(autoMixStatus.value, AutoMixStatus.idle);
    for (final tail in effectRenderer.tails) {
      expect(await tail.directory.exists(), isFalse);
    }
  });
}

/// A test whose waits (fades, readiness checks, waits for nothing to
/// happen) run on virtual time instead of the wall clock.
void fakeTimeTest(String description, Future<void> Function() body) =>
    test(description, () => time.run(body));
