import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/music_haptics.dart';

Uint8List _pcm(double seconds, double Function(double time) sample) {
  final count = (seconds * musicHapticsSampleRate).round();
  final data = ByteData(count * 2);
  for (var i = 0; i < count; i++) {
    final value = sample(i / musicHapticsSampleRate).clamp(-1.0, 1.0);
    data.setInt16(i * 2, (value * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Decaying bursts every [period] seconds, starting at [offset].
double Function(double) _hits(double frequency, double period, double offset) =>
    (time) {
      if (time < offset) return 0;
      final local = (time - offset) % period;
      return 0.8 * exp(-local * 30) * sin(2 * pi * frequency * local);
    };

class _Analyzer extends MusicHapticsAnalyzer {
  _Analyzer(this.result);
  final HapticTrack result;
  final paths = <String>[];

  @override
  Future<HapticTrack?> analyze(String path) async {
    paths.add(path);
    return result;
  }
}

class _PendingAnalyzer extends MusicHapticsAnalyzer {
  final pending = <String, Completer<HapticTrack?>>{};

  @override
  Future<HapticTrack?> analyze(String path) =>
      (pending[path] = Completer<HapticTrack?>()).future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('a kick on every beat becomes one deep pulse per beat', () {
    final track = analyzeHapticPcm(_pcm(6, _hits(60, 0.5, 0.25))).select(0.5);
    expect(track.length, inInclusiveRange(11, 12));
    for (var n = 0; n < track.length; n++) {
      final beat = ((track.times[n] - 250) / 500).round();
      expect(
        (track.times[n] - (250 + beat * 500)).abs(),
        lessThanOrEqualTo(30),
      );
      expect(track.sharpness[n], lessThan(128));
    }
  });

  test('bright hits are sharper than bass hits', () {
    final track = analyzeHapticPcm(_pcm(4, _hits(1200, 0.4, 0.2))).select(0.5);
    expect(track.length, greaterThan(6));
    expect(track.sharpness.reduce(min), greaterThan(128));
  });

  test('silence and steady tones produce no pulses', () {
    expect(analyzeHapticPcm(_pcm(3, (_) => 0)).length, 0);
    final tone = analyzeHapticPcm(
      _pcm(3, (time) => 0.5 * sin(2 * pi * 220 * time)),
    ).select(1);
    expect(tone.length, lessThanOrEqualTo(1));
  });

  test('higher sensitivity adds softer hits and keeps the spacing', () {
    // Loud kicks on the beat, quieter ones between them.
    final loud = _hits(60, 0.5, 0.25);
    final soft = _hits(60, 0.5, 0.5);
    HapticTrack candidates(double level) =>
        analyzeHapticPcm(_pcm(6, (time) => loud(time) + level * soft(time)));

    final faint = candidates(0.1);
    expect(faint.select(0.5).length, inInclusiveRange(11, 12));
    final loose = faint.select(1);
    expect(loose.length, greaterThan(20));
    for (var n = 1; n < loose.length; n++) {
      expect(loose.times[n] - loose.times[n - 1], greaterThanOrEqualTo(150));
    }

    final quiet = candidates(0.15);
    expect(quiet.select(0.5).length, greaterThan(20));
    expect(quiet.select(0).length, inInclusiveRange(11, 12));
  });

  test('sensitivity maps to the tuned threshold at its midpoint', () {
    expect(musicHapticsScoreFor(0), closeTo(1.6, 1e-9));
    expect(musicHapticsScoreFor(0.5), closeTo(1, 1e-9));
    expect(musicHapticsScoreFor(1), closeTo(0.5, 1e-9));
  });

  testWidgets('settings reselect pulses and scale strength without decoding', (
    tester,
  ) async {
    final state = PlaybackState(
      playing: true,
      processingState: AudioProcessingState.ready,
      updatePosition: Duration.zero,
    );
    final pulses = <double>[];
    final analyzer = _Analyzer(
      HapticTrack(
        Int32List.fromList([80, 300, 600]),
        Uint8List.fromList([255, 51, 255]),
        Uint8List(3),
        Float32List.fromList([2, 0.8, 2]),
      ),
    );
    final haptics = MusicHaptics(
      state: () => state,
      analyzer: analyzer,
      pulse: (intensity, _) async => pulses.add(intensity),
    );
    haptics.update('/music/song.flac');
    await tester.pump();
    expect(haptics.track?.times, [80, 600]);

    haptics.configure(sensitivity: 1, strength: 1);
    expect(haptics.track?.times, [80, 300, 600]);
    await tester.pump(const Duration(milliseconds: 400));
    expect(pulses, [1.0, closeTo(0.32, 1e-9)]);
    expect(analyzer.paths, ['/music/song.flac']);
    haptics.dispose();
  });

  // Pulse timing runs on the widget binding's fake clock: the scheduler uses
  // timers and PlaybackState extrapolates its position from clock.now().
  testWidgets('music pulses keep the media usage on the native channel', (
    tester,
  ) async {
    const channel = MethodChannel('com.zarz.mornye/haptics');
    final calls = <Map<Object?, Object?>>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.arguments as Map<Object?, Object?>);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final state = PlaybackState(
      playing: true,
      processingState: AudioProcessingState.ready,
      updatePosition: Duration.zero,
    );
    final haptics = MusicHaptics(
      state: () => state,
      analyzer: _Analyzer(
        HapticTrack(
          Int32List.fromList([80]),
          Uint8List.fromList([255]),
          Uint8List.fromList([0]),
        ),
      ),
    );
    addTearDown(haptics.dispose);
    haptics.update('/music/song.flac');
    await tester.pump(const Duration(milliseconds: 200));

    expect(calls, hasLength(1));
    // No usage means media vibration on Android, as before.
    expect(calls.single.containsKey('usage'), isFalse);
  });

  testWidgets('pulses follow the playing position and stop on pause', (
    tester,
  ) async {
    var state = PlaybackState(
      playing: true,
      processingState: AudioProcessingState.ready,
      updatePosition: Duration.zero,
    );
    final pulses = <(double, double)>[];
    final analyzer = _Analyzer(
      HapticTrack(
        Int32List.fromList([80, 280, 900]),
        Uint8List.fromList([255, 51, 255]),
        Uint8List.fromList([0, 255, 0]),
      ),
    );
    final haptics = MusicHaptics(
      state: () => state,
      analyzer: analyzer,
      pulse: (intensity, sharpness) async => pulses.add((intensity, sharpness)),
    );
    haptics.update('/music/song.flac');
    await tester.pump(const Duration(milliseconds: 400));
    expect(pulses, [(1.0, 0.0), (0.2, 1.0)]);

    state = state.copyWith(
      playing: false,
      updatePosition: const Duration(milliseconds: 400),
    );
    haptics.update('/music/song.flac');
    await tester.pump(const Duration(milliseconds: 600));
    expect(pulses, hasLength(2));

    haptics.update(null);
    expect(analyzer.paths, ['/music/song.flac']);
    haptics.dispose();
  });

  testWidgets(
    'analysis finished during loading starts on the first ready state',
    (tester) async {
      var state = PlaybackState(
        playing: true,
        processingState: AudioProcessingState.loading,
      );
      var pulses = 0;
      final analyzer = _Analyzer(
        HapticTrack(
          Int32List.fromList([80]),
          Uint8List.fromList([255]),
          Uint8List.fromList([0]),
        ),
      );
      final haptics = MusicHaptics(
        state: () => state,
        analyzer: analyzer,
        pulse: (_, _) async => pulses++,
      );
      addTearDown(haptics.dispose);
      haptics.update('/music/first.flac');
      await tester.pump();
      expect(haptics.track, isNotNull);
      expect(pulses, 0);
      state = PlaybackState(
        playing: true,
        processingState: AudioProcessingState.ready,
      );
      haptics.update('/music/first.flac');
      await tester.pump(const Duration(milliseconds: 150));
      expect(pulses, 1);
      expect(analyzer.paths, ['/music/first.flac']);
    },
  );

  test(
    'late analysis from a skipped song cannot replace the active pulses',
    () async {
      final state = PlaybackState(
        playing: true,
        processingState: AudioProcessingState.ready,
      );
      final analyzer = _PendingAnalyzer();
      final haptics = MusicHaptics(
        state: () => state,
        analyzer: analyzer,
        pulse: (_, _) async {},
      );
      addTearDown(haptics.dispose);
      haptics.update('content://music/one');
      haptics.update('content://music/two');
      final latest = HapticTrack(Int32List(0), Uint8List(0), Uint8List(0));
      analyzer.pending['content://music/two']!.complete(latest);
      await Future<void>.delayed(Duration.zero);
      analyzer.pending['content://music/one']!.complete(
        HapticTrack(
          Int32List.fromList([80]),
          Uint8List.fromList([255]),
          Uint8List(1),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(haptics.track, same(latest));
    },
  );

  group('document analysis', () {
    const channel = MethodChannel('com.zarz.mornye/backend');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late Directory temporary;
    late MusicHapticsAnalyzer analyzer;
    late List<String> inputs;
    var modified = 1;

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('haptics-test-');
      inputs = [];
      modified = 1;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getSafFileModTimes');
        final source =
            (jsonDecode((call.arguments as Map)['uris'] as String) as List)
                    .single
                as String;
        return {source: modified};
      });
      analyzer = MusicHapticsAnalyzer(
        temporaryDirectory: () async => temporary,
        jobs: AudioAnalysisJobs<bool>(
          start: (arguments) async {
            inputs.add(arguments[arguments.indexOf('-i') + 1]);
            await File(
              arguments.last,
            ).writeAsBytes(_pcm(2, _hits(60, 0.5, 0.25)));
            return (id: inputs.length, completed: Future.value(true));
          },
          cancel: (_) async {},
        ),
      );
    });
    tearDown(() async {
      analyzer.dispose();
      messenger.setMockMethodCallHandler(channel, null);
      await temporary.delete(recursive: true);
    });

    test('document URI is decoded without a playback cache copy', () async {
      const source = 'content://music/document/first.flac';
      final first = await analyzer.analyze(source);
      expect(first?.length, greaterThan(0));
      expect(await analyzer.analyze(source), same(first));
      expect(inputs, [source]);
      modified++;
      expect(await analyzer.analyze(source), isNot(same(first)));
      expect(inputs, [source, source]);
      expect(await temporary.list().toList(), isEmpty);
    });

    test(
      'unknown modification time permits analysis without caching stale pulses',
      () async {
        modified = 0;
        const source = 'content://music/document/unknown.flac';
        expect((await analyzer.analyze(source))?.length, greaterThan(0));
        expect((await analyzer.analyze(source))?.length, greaterThan(0));
        expect(inputs, [source, source]);
      },
    );
  });
}
