import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_audio/media_information.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/audio_analysis_ffmpeg.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/audio_compare_dsp.dart';
import 'package:mornye/services/audio_compare_engine.dart';
import 'package:mornye/services/ffmpeg_desktop.dart';
import 'package:mornye/services/ffmpeg_models.dart';

MediaInformation _media({
  String codec = 'flac',
  int sampleRate = 44100,
  int channels = 2,
  double duration = 60,
}) => MediaInformation({
  'streams': [
    {
      'codec_type': 'audio',
      'codec_name': codec,
      'sample_rate': '$sampleRate',
      'channels': channels,
      'duration': '$duration',
      'bits_per_raw_sample': codec == 'flac' ? '24' : '0',
    },
  ],
  'format': {'format_name': codec, 'duration': '$duration'},
});

/// FFmpeg stand-in: writes the files a command names, then waits for the
/// test to finish or cancel it.
class _FakeFFmpeg {
  final started = <List<String>>[];
  final sessions = <int, Completer<FFmpegSessionResult>>{};
  final startedSignal = StreamController<int>.broadcast();
  int _next = 1;
  bool autoComplete = false;
  int returnCode = 0;

  Future<({int id, Future<FFmpegSessionResult> completed})> start(
    List<String> arguments,
  ) async {
    started.add(arguments);
    for (final argument in arguments) {
      if (argument.endsWith('.f32') || argument.endsWith('.rgba')) {
        await File(argument).writeAsBytes(Uint8List(64));
      }
    }
    final id = _next++;
    final completer = Completer<FFmpegSessionResult>();
    sessions[id] = completer;
    if (autoComplete) {
      completer.complete(
        FFmpegSessionResult(
          returnCode: returnCode,
          logs: () async => 'fake log',
        ),
      );
    }
    startedSignal.add(id);
    return (id: id, completed: completer.future);
  }

  Future<void> cancel(int id) async {
    final completer = sessions[id];
    if (completer != null && !completer.isCompleted) {
      completer.complete(
        FFmpegSessionResult(returnCode: 255, logs: () async => 'cancelled'),
      );
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('audio-compare-test-');
  });
  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<List<String>> leftovers() async => [
    await for (final entity in temp.list())
      if (entity.path.contains('audio-compare-')) entity.path,
  ];

  AudioCompareEngine engine(
    _FakeFFmpeg ffmpeg, {
    Map<String, MediaInformation?> probes = const {},
  }) => AudioCompareEngine(
    start: ffmpeg.start,
    cancel: ffmpeg.cancel,
    probe: (path) async => probes.containsKey(path) ? probes[path] : _media(),
    temporaryDirectory: () async => temp,
  );

  test('cancelling mid-run stops FFmpeg and removes temporary files', () async {
    final ffmpeg = _FakeFFmpeg();
    final compare = engine(ffmpeg);
    final stages = <AudioCompareStage>[];
    final firstStart = ffmpeg.startedSignal.stream.first;
    final result = compare.compare(
      referencePath: '/music/a.flac',
      otherPath: '/music/a.mp3',
      onStage: stages.add,
    );
    await firstStart;
    // The excerpt pass has written its outputs into the run directory.
    expect(await leftovers(), hasLength(1));
    compare.cancel();
    await expectLater(result, throwsA(isA<AudioAnalysisCancelled>()));
    expect(await leftovers(), isEmpty);
    expect(stages, [AudioCompareStage.preparing, AudioCompareStage.aligning]);
    expect(ffmpeg.started, hasLength(1));
  });

  test('disposing the engine also cancels and cleans up', () async {
    final ffmpeg = _FakeFFmpeg();
    final compare = engine(ffmpeg);
    final firstStart = ffmpeg.startedSignal.stream.first;
    final result = compare.compare(
      referencePath: '/music/a.flac',
      otherPath: '/music/a.mp3',
    );
    await firstStart;
    compare.dispose();
    await expectLater(result, throwsA(isA<AudioAnalysisCancelled>()));
    expect(await leftovers(), isEmpty);
  });

  test('a failed decode is an error and still cleans up', () async {
    final ffmpeg = _FakeFFmpeg()
      ..autoComplete = true
      ..returnCode = 1;
    await expectLater(
      engine(
        ffmpeg,
      ).compare(referencePath: '/music/a.flac', otherPath: '/music/b.mp3'),
      throwsA(
        isA<AudioCompareException>().having(
          (e) => e.failure,
          'failure',
          AudioCompareFailure.decodeFailed,
        ),
      ),
    );
    expect(await leftovers(), isEmpty);
  });

  test('AC-4 is refused before any decode', () async {
    final ffmpeg = _FakeFFmpeg();
    await expectLater(
      engine(
        ffmpeg,
        probes: {'/music/b.m4a': _media(codec: 'ac4')},
      ).compare(referencePath: '/music/a.flac', otherPath: '/music/b.m4a'),
      throwsA(
        isA<UnsupportedAudioAnalysisCodecException>().having(
          (e) => e.codecLabel,
          'codec',
          'AC-4',
        ),
      ),
    );
    expect(ffmpeg.started, isEmpty);
  });

  test('an unreadable file names the file', () async {
    final ffmpeg = _FakeFFmpeg();
    await expectLater(
      engine(
        ffmpeg,
        probes: {'/music/broken.mp3': null},
      ).compare(referencePath: '/music/a.flac', otherPath: '/music/broken.mp3'),
      throwsA(
        isA<AudioCompareException>()
            .having((e) => e.failure, 'failure', AudioCompareFailure.unreadable)
            .having((e) => e.fileName, 'file', 'broken.mp3'),
      ),
    );
  });

  test('files shorter than two seconds are refused', () async {
    final ffmpeg = _FakeFFmpeg();
    await expectLater(
      engine(
        ffmpeg,
        probes: {'/music/short.mp3': _media(duration: 1.5)},
      ).compare(referencePath: '/music/a.flac', otherPath: '/music/short.mp3'),
      throwsA(
        isA<AudioCompareException>().having(
          (e) => e.failure,
          'failure',
          AudioCompareFailure.tooShort,
        ),
      ),
    );
    expect(ffmpeg.started, isEmpty);
  });

  test('a content URI reference is copied and the copy deleted', () async {
    final ffmpeg = _FakeFFmpeg()
      ..autoComplete = true
      ..returnCode = 1;
    final copy = File('${temp.path}/saf-copy.flac');
    final compare = AudioCompareEngine(
      start: ffmpeg.start,
      cancel: ffmpeg.cancel,
      probe: (path) async => _media(),
      temporaryDirectory: () async => temp,
      copyContentUri: (uri) async {
        await copy.writeAsBytes([1, 2, 3]);
        return copy.path;
      },
    );
    await expectLater(
      compare.compare(
        referencePath: 'content://provider/tree/primary%3AMusic%2Fsong.flac',
        otherPath: '/music/b.mp3',
      ),
      throwsA(isA<AudioCompareException>()),
    );
    expect(ffmpeg.started.first, contains(copy.path));
    expect(await copy.exists(), isFalse);
  });

  test('display names of paths and URIs', () {
    expect(audioCompareDisplayName('/music/Artist/Song.flac'), 'Song.flac');
    expect(audioCompareDisplayName(r'C:\Music\Song.mp3'), 'Song.mp3');
    expect(
      audioCompareDisplayName(
        'content://provider/document/primary%3AMusic%2FSong.m4a',
      ),
      'Song.m4a',
    );
    expect(
      audioCompareDisplayName('network://nas/Music/Song.flac'),
      'Song.flac',
    );
  });

  group('end to end with FFmpeg on this machine', () {
    late DesktopFFmpegTools tools;
    late Directory fixtures;
    var available = false;

    setUpAll(() async {
      tools = await DesktopFFmpegTools.locate();
      available = tools.ffmpegPath != null && tools.ffprobePath != null;
      if (!available) return;
      fixtures = await Directory.systemTemp.createTemp('audio-compare-e2e-');
    });
    tearDownAll(() async {
      if (available) await fixtures.delete(recursive: true);
    });

    Future<bool> ffmpeg(List<String> arguments) async {
      final result = await Process.run(tools.ffmpegPath!, [
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        ...arguments,
      ]);
      return result.exitCode == 0;
    }

    // A 90 s tone, chord and pink-noise mix with quiet and dense passages,
    // long enough for the drift check's second excerpt.
    Future<String> reference() async {
      final path = '${fixtures.path}/reference.flac';
      if (await File(path).exists()) return path;
      final ok = await ffmpeg([
        '-f',
        'lavfi',
        '-i',
        "aevalsrc='0.3*sin(2*PI*220*t)*(1+0.5*sin(2*PI*0.5*t))"
            '+0.15*sin(2*PI*1760*t+sin(2*PI*3*t))|'
            '0.3*sin(2*PI*330*t)+0.1*sin(2*PI*5000*t)*gt(mod(t,4),2)'
            "':s=44100:d=90",
        '-f',
        'lavfi',
        '-i',
        'anoisesrc=d=90:c=pink:r=44100:a=0.08:seed=11',
        '-filter_complex',
        "[1]volume='if(gt(mod(t,8),5),1,0.15)':eval=frame,"
            'pan=stereo|c0=c0|c1=c0[n];[0][n]amix=inputs=2:normalize=0[o]',
        '-map',
        '[o]',
        '-c:a',
        'flac',
        '-sample_fmt',
        's32',
        '-bits_per_raw_sample',
        '24',
        path,
      ]);
      expect(ok, isTrue);
      return path;
    }

    final cases = <String, List<String>>{
      'identical copy': ['-c:a', 'flac', 'identical.flac'],
      'MP3 128 kbps': ['-c:a', 'libmp3lame', '-b:a', '128k', 'mp3.mp3'],
      'MP3 without LAME header': [
        '-c:a',
        'libmp3lame',
        '-b:a',
        '128k',
        '-write_xing',
        '0',
        'mp3_noxing.mp3',
      ],
      'AAC 128 kbps (M4A)': ['-c:a', 'aac', '-b:a', '128k', 'aac.m4a'],
      'AAC 128 kbps (ADTS)': [
        '-c:a',
        'aac',
        '-b:a',
        '128k',
        '-f',
        'adts',
        'aac_adts.aac',
      ],
      'starts 12345 samples later': [
        '-af',
        'adelay=12345S:all=1',
        '-c:a',
        'flac',
        'delayed.flac',
      ],
      'starts 7000 samples earlier': [
        '-af',
        'atrim=start_sample=7000',
        '-c:a',
        'flac',
        'trimmed.flac',
      ],
      '8 kHz low-pass': [
        '-af',
        'lowpass=f=8000,lowpass=f=8000',
        '-c:a',
        'flac',
        'lowpass.flac',
      ],
      'resampled to 48 kHz': ['-ar', '48000', '-c:a', 'flac', 'r48.flac'],
      '0.01% faster (drift)': [
        '-af',
        'asetrate=44104.41,aresample=44100',
        '-c:a',
        'flac',
        'drift.flac',
      ],
      '3 dB quieter': ['-af', 'volume=-3dB', '-c:a', 'flac', 'quiet.flac'],
    };

    final results = <String, AudioCompareResult>{};

    Future<AudioCompareResult?> run(String name) async {
      if (!available) {
        markTestSkipped('ffmpeg and ffprobe are not on PATH');
        return null;
      }
      final referencePath = await reference();
      final arguments = cases[name]!;
      final output = '${fixtures.path}/${arguments.last}';
      final encoded = await ffmpeg([
        '-i',
        referencePath,
        ...arguments.sublist(0, arguments.length - 1),
        output,
      ]);
      if (!encoded) {
        markTestSkipped('this FFmpeg cannot encode $name');
        return null;
      }
      final runner = DesktopFFmpegRunner(tools: () async => tools);
      final compare = AudioCompareEngine(
        start: runner.start,
        cancel: runner.cancel,
        probe: runner.probe,
        temporaryDirectory: () async => temp,
      );
      final watch = Stopwatch()..start();
      final result = await compare.compare(
        referencePath: referencePath,
        otherPath: output,
      );
      watch.stop();
      results[name] = result;
      // ignore: avoid_print
      print(
        '$name: offset ${result.offsetFrames} samples '
        '(${result.offsetMs.toStringAsFixed(2)} ms), '
        'gain ${result.gainDb.toStringAsFixed(3)} dB, '
        'correlation ${result.correlation.toStringAsFixed(4)}, '
        'overall ${result.overallDb.toStringAsFixed(1)} dB, '
        'median ${result.medianDb.toStringAsFixed(1)} dB, '
        'excerpt ${result.excerptResidualDb.toStringAsFixed(1)} dB, '
        'peak ${result.peak?.seconds.toStringAsFixed(1)} s '
        '${result.peak?.db.toStringAsFixed(1)} dB, '
        'band ${result.band.name}, level ${result.level.name}, '
        'drift ${result.driftMs?.toStringAsFixed(2)} ms, '
        'notices ${result.notices.map((n) => n.name).join(',')}, '
        'windows ${result.windows.length}, '
        'spectrogram ${result.spectrogram != null}, '
        '${watch.elapsedMilliseconds} ms',
      );
      expect(await leftovers(), isEmpty);
      return result;
    }

    tearDownAll(() {
      for (final result in results.values) {
        result.dispose();
      }
    });

    test('an identical copy cancels completely', () async {
      final result = await run('identical copy');
      if (result == null) return;
      expect(result.offsetFrames, 0);
      expect(result.gain, 1);
      expect(result.overallDb, audioCompareFloorDb);
      expect(result.level, AudioCompareLevel.identical);
      expect(result.notices, isEmpty);
      expect(result.spectrogram, isNotNull);
      expect(result.windows.length, inInclusiveRange(300, 2000));
    });

    test('lossy copies line up and show their losses', () async {
      for (final name in [
        'MP3 128 kbps',
        'MP3 without LAME header',
        'AAC 128 kbps (M4A)',
        'AAC 128 kbps (ADTS)',
      ]) {
        final result = await run(name);
        if (result == null) continue;
        expect(result.correlation, greaterThan(0.99), reason: name);
        expect(result.overallDb, inInclusiveRange(-60, -15), reason: name);
        expect(result.notices, isEmpty, reason: name);
        expect(result.gainDb.abs(), lessThan(1), reason: name);
      }
      final noXing = results['MP3 without LAME header'];
      final withXing = results['MP3 128 kbps'];
      if (noXing != null && withXing != null) {
        // Without the header FFmpeg cannot remove the encoder delay.
        expect(noXing.offsetFrames - withXing.offsetFrames, greaterThan(500));
      }
    });

    test('a shifted copy is found exactly in both directions', () async {
      final later = await run('starts 12345 samples later');
      if (later == null) return;
      expect(later.offsetFrames, 12345);
      expect(later.overallDb, audioCompareFloorDb);
      final earlier = (await run('starts 7000 samples earlier'))!;
      expect(earlier.offsetFrames, -7000);
      expect(earlier.notices, isEmpty);
      // Only the windows covering the 7000 samples the trimmed file lacks
      // differ.
      final series = audioCompareSeries(
        earlier.windows,
        AudioCompareChannel.combined,
      );
      final missing = (7000 / earlier.windows.first.frames).ceil();
      expect(series.take(missing), everyElement(greaterThan(-10)));
      expect(series.skip(missing), everyElement(audioCompareFloorDb));
    });

    test('a low-passed copy differs in the highs', () async {
      final result = await run('8 kHz low-pass');
      if (result == null) return;
      expect(result.band, AudioCompareBand.high);
      expect(result.notices, isEmpty);
    });

    test('a resampled copy is compared at the reference rate', () async {
      final result = await run('resampled to 48 kHz');
      if (result == null) return;
      expect(result.sampleRate, 44100);
      expect(result.resampled, isTrue);
      expect(result.offsetFrames.abs(), lessThanOrEqualTo(1));
      expect(result.overallDb, lessThan(-40));
    });

    test('drifting timing raises the notice', () async {
      final result = await run('0.01% faster (drift)');
      if (result == null) return;
      expect(result.meaningful, isFalse);
      expect(
        result.notices.intersection({
          AudioCompareNotice.drift,
          AudioCompareNotice.residualHigh,
        }),
        isNotEmpty,
      );
    });

    test('a quieter copy is level matched', () async {
      final result = await run('3 dB quieter');
      if (result == null) return;
      expect(result.gainDb, closeTo(3, 0.01));
      expect(result.overallDb, lessThan(-90));
    });

    test('unrelated audio is not the same source', () async {
      if (!available) {
        markTestSkipped('ffmpeg and ffprobe are not on PATH');
        return;
      }
      final referencePath = await reference();
      final noise = '${fixtures.path}/noise.flac';
      expect(
        await ffmpeg([
          '-f',
          'lavfi',
          '-i',
          'anoisesrc=d=90:c=white:r=44100:a=0.2:seed=5',
          '-ac',
          '2',
          '-c:a',
          'flac',
          noise,
        ]),
        isTrue,
      );
      final runner = DesktopFFmpegRunner(tools: () async => tools);
      final result =
          await AudioCompareEngine(
            start: runner.start,
            cancel: runner.cancel,
            probe: runner.probe,
            temporaryDirectory: () async => temp,
          ).compare(
            referencePath: referencePath,
            otherPath: noise,
            includeSpectrogram: false,
          );
      // ignore: avoid_print
      print(
        'unrelated: correlation ${result.correlation.toStringAsFixed(4)}, '
        'overall ${result.overallDb.toStringAsFixed(1)} dB, '
        'notices ${result.notices.map((n) => n.name).join(',')}',
      );
      expect(
        result.notices,
        containsAll([
          AudioCompareNotice.weakAlignment,
          AudioCompareNotice.residualHigh,
        ]),
      );
    });
  });
}
