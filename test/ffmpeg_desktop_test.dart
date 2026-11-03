import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/ffmpeg_desktop.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/ffmpeg_support.dart';
import 'package:mornye/utils/desktop_platform.dart';

class _DiscardingConsumer implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() async {}
}

class _FakeProcess implements Process {
  _FakeProcess({String stdoutText = '', String stderrText = ''}) {
    _stdout
      ..add(utf8.encode(stdoutText))
      ..close();
    _stderr
      ..add(utf8.encode(stderrText))
      ..close();
  }

  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exit = Completer<int>();
  final kills = <ProcessSignal>[];

  void finish(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  IOSink get stdin => IOSink(_DiscardingConsumer());

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 42;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills.add(signal);
    finish(255);
    return true;
  }
}

class _Starts {
  final calls = <(String, List<String>)>[];
  final processes = <_FakeProcess>[];
  _FakeProcess Function() next = _FakeProcess.new;

  Future<Process> call(String executable, List<String> arguments) async {
    calls.add((executable, arguments));
    final process = next();
    processes.add(process);
    return process;
  }
}

const _tools = DesktopFFmpegTools(
  ffmpegPath: '/bundle/ffmpeg',
  ffprobePath: '/bundle/ffprobe',
);

const _probeJson = '''
{
  "streams": [
    {"index": 0, "codec_name": "mjpeg", "codec_type": "video",
     "width": 600, "height": 500},
    {"index": 1, "codec_name": "flac", "codec_type": "audio",
     "sample_fmt": "s32", "sample_rate": "96000", "channels": 2,
     "bits_per_raw_sample": "24", "duration": "12.500000"}
  ],
  "chapters": [],
  "format": {"filename": "a.flac", "format_name": "flac",
             "duration": "12.500000", "bit_rate": "2400000"}
}
''';

Future<void> _writeWav(File file) async {
  const sampleRate = 8000;
  const samples = sampleRate ~/ 4;
  final data = ByteData(44 + samples * 2);
  void ascii(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      data.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + samples * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    data.setInt16(44 + i * 2, (i % 40 - 20) * 800, Endian.little);
  }
  await file.writeAsBytes(data.buffer.asUint8List());
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  group('DesktopFFmpegTools', () {
    test('searches the override, the bundle, then PATH', () {
      expect(
        DesktopFFmpegTools.searchDirectories(
          operatingSystem: 'macos',
          executablePath: '/Applications/Mornye.app/Contents/MacOS/Mornye',
          environment: {'MORNYE_FFMPEG_DIR': '/opt/ff', 'PATH': '/a:/b'},
        ),
        [
          '/opt/ff',
          '/Applications/Mornye.app/Contents/Resources/ffmpeg',
          '/Applications/Mornye.app/Contents/MacOS',
          '/a',
          '/b',
        ],
      );
      expect(
        DesktopFFmpegTools.searchDirectories(
          operatingSystem: 'linux',
          executablePath: '/opt/mornye/mornye',
          environment: {'PATH': '/usr/bin'},
        ),
        ['/opt/mornye/lib/ffmpeg', '/usr/bin'],
      );
      expect(
        DesktopFFmpegTools.searchDirectories(
          operatingSystem: 'windows',
          executablePath: r'C:\Program Files\Mornye\mornye.exe',
          environment: {'PATH': r'C:\tools;;C:\bin'},
        ),
        [r'C:\Program Files\Mornye\ffmpeg', r'C:\tools', r'C:\bin'],
      );
    });

    test('takes each tool from the first folder that has it', () async {
      final existing = {
        '/usr/local/bin/ffmpeg',
        '/opt/mornye/lib/ffmpeg/ffmpeg',
        '/opt/mornye/lib/ffmpeg/ffprobe',
      };
      final tools = await DesktopFFmpegTools.locate(
        operatingSystem: 'linux',
        executablePath: '/opt/mornye/mornye',
        environment: {
          'MORNYE_FFMPEG_DIR': '/usr/local/bin',
          'PATH': '/usr/bin',
        },
        isFile: (path) async => existing.contains(path),
      );
      expect(tools.ffmpegPath, '/usr/local/bin/ffmpeg');
      expect(tools.ffprobePath, '/opt/mornye/lib/ffmpeg/ffprobe');
    });

    test('appends .exe on Windows and leaves missing tools null', () async {
      final tools = await DesktopFFmpegTools.locate(
        operatingSystem: 'windows',
        executablePath: r'C:\Mornye\mornye.exe',
        environment: const {},
        isFile: (path) async => path == r'C:\Mornye\ffmpeg\ffmpeg.exe',
      );
      expect(tools.ffmpegPath, r'C:\Mornye\ffmpeg\ffmpeg.exe');
      expect(tools.ffprobePath, isNull);
    });
  });

  group('DesktopFFmpegRunner', () {
    test('runs ffmpeg with an argument list and returns its log', () async {
      final starts = _Starts();
      final runner = DesktopFFmpegRunner(
        tools: () async => _tools,
        startProcess: starts.call,
      );
      final pending = runner.run(['-i', 'in put.flac', 'out.mp3']);
      await pumpEventQueue();
      starts.processes.single.finish(0);
      starts.next = () =>
          _FakeProcess(stderrText: 'Conversion failed!')..finish(1);

      final ok = await pending;
      expect(starts.calls.single.$1, '/bundle/ffmpeg');
      expect(starts.calls.single.$2, [
        '-nostdin',
        '-i',
        'in put.flac',
        'out.mp3',
      ]);
      expect(ok.success, isTrue);
      expect(ok.returnCode, 0);

      final failed = await runner.run(['-nostdin', '-i', 'x']);
      expect(starts.calls.last.$2, ['-nostdin', '-i', 'x']);
      expect(failed.success, isFalse);
      expect(failed.returnCode, 1);
      expect(failed.output, 'Conversion failed!');
    });

    test('cancels only the owned session', () async {
      final starts = _Starts();
      final runner = DesktopFFmpegRunner(
        tools: () async => _tools,
        startProcess: starts.call,
      );
      final first = await runner.start(['-i', 'a']);
      final second = await runner.start(['-i', 'b']);
      expect(first.id, isNot(second.id));

      await runner.cancel(first.id);
      final result = await first.completed;
      expect(result.success, isFalse);
      expect(starts.processes.first.kills, [ProcessSignal.sigterm]);
      expect(starts.processes.last.kills, isEmpty);

      await runner.cancel(first.id);
      await runner.cancel(999);
      expect(starts.processes.first.kills, hasLength(1));
      starts.processes.last.finish(0);
      expect((await second.completed).success, isTrue);
    });

    test('reports a missing executable clearly', () async {
      final runner = DesktopFFmpegRunner(
        tools: () async => const DesktopFFmpegTools(),
        startProcess: (_, _) => throw StateError('must not start'),
      );
      await expectLater(
        runner.start(['-i', 'a']),
        throwsA(
          isA<FFmpegUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('MORNYE_FFMPEG_DIR'),
          ),
        ),
      );
      await expectLater(
        runner.probe('a.flac'),
        throwsA(isA<FFmpegUnavailableException>()),
      );
      final result = await runner.run(['-i', 'a']);
      expect(result.success, isFalse);
      expect(result.output, contains('ffmpeg is not available'));
    });

    test('probes with ffprobe JSON into MediaInformation', () async {
      final starts = _Starts()
        ..next = () => _FakeProcess(stdoutText: _probeJson)..finish(0);
      final runner = DesktopFFmpegRunner(
        tools: () async => _tools,
        startProcess: starts.call,
      );
      final info = await runner.probe('/music/a.flac');
      expect(starts.calls.single.$1, '/bundle/ffprobe');
      expect(starts.calls.single.$2, [
        '-v',
        'quiet',
        '-print_format',
        'json',
        '-show_format',
        '-show_streams',
        '-show_chapters',
        '-i',
        '/music/a.flac',
      ]);
      expect(info!.getDuration(), '12.500000');
      expect(info.getBitrate(), '2400000');
      expect(info.getFormat(), 'flac');
      final streams = info.getStreams();
      expect(streams.map((s) => s.getType()), ['video', 'audio']);
      expect(
        FFmpegProbe.imageDimensionsFromProperties(
          streams.first.getAllProperties()!,
        ),
        (width: 600, height: 500),
      );
      expect(streams.last.getAllProperties()!['bits_per_raw_sample'], '24');

      starts.next = () => _FakeProcess(stdoutText: '{}')..finish(1);
      expect(await runner.probe('/music/missing.flac'), isNull);
    });

    test('parseFFprobeJson rejects empty or invalid output', () {
      expect(parseFFprobeJson(''), isNull);
      expect(parseFFprobeJson('{}'), isNull);
      expect(parseFFprobeJson('[1]'), isNull);
      expect(parseFFprobeJson(_probeJson)!.getStreams(), hasLength(2));
    });
  });

  group('FFmpegExecution on desktop', () {
    late _Starts starts;
    final nativeCalls = <String>[];
    const nativeChannel = MethodChannel('flutter.arthenica.com/ffmpeg_kit');

    setUp(() {
      nativeCalls.clear();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(nativeChannel, (
        call,
      ) async {
        nativeCalls.add(call.method);
        throw MissingPluginException('No FFmpegKit native plugin on Windows');
      });
      debugDesktopPlatformOverride = true;
      starts = _Starts()..next = () => _FakeProcess()..finish(0);
      DesktopFFmpegRunner.debugShared = DesktopFFmpegRunner(
        tools: () async => _tools,
        startProcess: starts.call,
      );
    });

    tearDown(() {
      debugDesktopPlatformOverride = null;
      DesktopFFmpegRunner.debugShared = null;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        nativeChannel,
        null,
      );
      expect(nativeCalls, isEmpty);
    });

    test('splits command strings with FFmpegKit quoting', () async {
      final result = await FFmpegExecution.command(
        '-v error -i "/music/My Song.flac" -metadata title=\'A B\' out.mp3',
      );
      expect(result.success, isTrue);
      expect(starts.calls.single.$2, [
        '-nostdin',
        '-v',
        'error',
        '-i',
        '/music/My Song.flac',
        '-metadata',
        'title=A B',
        'out.mp3',
      ]);
    });

    test('routes sessions and cancellation to the process runner', () async {
      starts.next = _FakeProcess.new;
      final session = await FFmpegExecution.start(['-i', 'a']);
      await FFmpegExecution.cancel(session.id);
      expect((await session.completed).success, isFalse);
      expect(starts.processes.single.kills, isNotEmpty);
    });

    test(
      'routes argument execution and metadata to standalone tools',
      () async {
        final result = await FFmpegExecution.arguments([
          '-i',
          'input.wav',
          '-c:a',
          'flac',
          'output.flac',
        ]);
        expect(result.success, isTrue);
        expect(starts.calls.single.$1, _tools.ffmpegPath);

        starts.next = () => _FakeProcess(stdoutText: _probeJson)..finish(0);
        final info = await FFmpegExecution.mediaInformation('output.flac');
        expect(info?.getFormat(), 'flac');
        expect(starts.calls.last.$1, _tools.ffprobePath);
      },
    );
  });

  final hostTools = DesktopFFmpegTools.locate(
    environment: {'PATH': Platform.environment['PATH'] ?? ''},
  );

  test(
    'converts a generated WAV to FLAC and probes it with host binaries',
    () async {
      final tools = await hostTools;
      if (tools.ffmpegPath == null || tools.ffprobePath == null) {
        markTestSkipped('ffmpeg and ffprobe are not on PATH');
        return;
      }
      debugDesktopPlatformOverride = true;
      DesktopFFmpegRunner.debugShared = DesktopFFmpegRunner(
        tools: () async => tools,
      );
      final directory = await Directory.systemTemp.createTemp('mornye-ff-');
      addTearDown(() async {
        debugDesktopPlatformOverride = null;
        DesktopFFmpegRunner.debugShared = null;
        await directory.delete(recursive: true);
      });
      final wav = File('${directory.path}/tone in.wav');
      final flac = '${directory.path}/tone out.flac';
      await _writeWav(wav);

      final result = await FFmpegExecution.arguments([
        '-v',
        'error',
        '-i',
        wav.path,
        '-c:a',
        'flac',
        flac,
      ]);
      expect(result.success, isTrue, reason: result.output);

      final properties = await FFmpegProbe.audioProperties(flac);
      expect(properties.codec, 'flac');
      expect(properties.sampleRate, 8000);
      expect(properties.bitDepth, 16);
      expect(await FFmpegProbe.isNativeFlacFile(flac), isTrue);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
