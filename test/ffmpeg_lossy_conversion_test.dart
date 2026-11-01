import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/ffmpeg_desktop.dart';
import 'package:mornye/services/ffmpeg_conversion.dart';
import 'package:mornye/utils/desktop_platform.dart';

Map<String, Uint8List> _itunesAtoms(Uint8List file) {
  var start = 0;
  var end = file.length;
  final bytes = ByteData.sublistView(file);
  for (final container in ['moov', 'udta', 'meta', 'ilst']) {
    var found = false;
    for (var offset = start; offset + 8 <= end;) {
      final size = bytes.getUint32(offset);
      if (size < 8 || offset + size > end) break;
      final type = latin1.decode(file.sublist(offset + 4, offset + 8));
      if (type == container) {
        start = offset + (container == 'meta' ? 12 : 8);
        end = offset + size;
        found = true;
        break;
      }
      offset += size;
    }
    if (!found) throw StateError('Missing iTunes container: $container');
  }
  final atoms = <String, Uint8List>{};
  for (var offset = start; offset + 8 <= end;) {
    final size = bytes.getUint32(offset);
    if (size < 8 || offset + size > end) break;
    final type = latin1.decode(file.sublist(offset + 4, offset + 8));
    atoms[type] = file.sublist(offset + 8, offset + size);
    offset += size;
  }
  return atoms;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late DesktopFFmpegTools tools;
  late Directory directory;

  setUpAll(() async {
    tools = await DesktopFFmpegTools.locate(
      environment: {'PATH': Platform.environment['PATH'] ?? ''},
    );
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lossy-conversion-');
    debugDesktopPlatformOverride = true;
    DesktopFFmpegRunner.debugShared = DesktopFFmpegRunner(
      tools: () async => tools,
    );
    messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    debugDesktopPlatformOverride = null;
    DesktopFFmpegRunner.debugShared = null;
    await directory.delete(recursive: true);
  });

  bool haveTools() {
    if (tools.ffmpegPath != null && tools.ffprobePath != null) return true;
    markTestSkipped('Requires ffmpeg and ffprobe on PATH');
    return false;
  }

  Future<void> ffmpeg(List<String> arguments) async {
    final result = await Process.run(tools.ffmpegPath!, [
      '-v',
      'error',
      ...arguments,
    ]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
  }

  Future<String> source(
    String name, {
    Map<String, String> metadata = const {},
  }) async {
    final path = '${directory.path}/$name.flac';
    await ffmpeg([
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:sample_rate=44100:duration=0.1',
      '-c:a',
      'flac',
      for (final entry in metadata.entries) ...[
        '-metadata',
        '${entry.key}=${entry.value}',
      ],
      path,
    ]);
    return path;
  }

  for (final format in ['aac', 'mp3', 'opus']) {
    test('$format converts quoted paths without deleting a sibling', () async {
      if (!haveTools()) return;
      final path = await source('Song "live"');
      final extension = format == 'aac' ? 'm4a' : format;
      final sibling = File('${directory.path}/Song "live".$extension');
      await sibling.writeAsString('existing file');

      final converted = await FFmpegConversion.convertAudioFormat(
        inputPath: path,
        targetFormat: format,
        bitrate: format == 'opus' ? '160k' : '128k',
        metadata: const {},
      );

      expect(converted, '${directory.path}/Song "live" (2).$extension');
      expect(await sibling.readAsString(), 'existing file');
      expect(await File(path).exists(), isFalse);
      final probe = await Process.run(tools.ffprobePath!, [
        '-v',
        'error',
        '-show_entries',
        'stream=codec_name',
        '-of',
        'json',
        converted!,
      ]);
      expect(probe.exitCode, 0, reason: probe.stderr.toString());
      final json = jsonDecode(probe.stdout as String) as Map<String, dynamic>;
      expect((json['streams'] as List<dynamic>).single, {'codec_name': format});
    });
  }

  for (final explicitTags in [false, true]) {
    test(
      'AAC stores iTunes album credits with explicit=$explicitTags',
      () async {
        if (!haveTools()) return;
        final cover = '${directory.path}/cover.png';
        await ffmpeg([
          '-f',
          'lavfi',
          '-i',
          'color=c=blue:s=16x16',
          '-frames:v',
          '1',
          cover,
        ]);
        for (final artist in ['Main Artist', 'Main Artist, Guest']) {
          final metadata = {
            'TITLE': 'Song',
            'ARTIST': artist,
            'ALBUM': 'Shared Album',
            'ALBUMARTIST': 'Main Artist',
            'TRACKNUMBER': '2/10',
            'DISCNUMBER': '1/2',
          };
          final path = await source(
            artist,
            metadata: explicitTags ? const {} : metadata,
          );
          final converted = await FFmpegConversion.convertAudioFormat(
            inputPath: path,
            targetFormat: 'aac',
            bitrate: '256k',
            metadata: explicitTags ? metadata : const {},
            coverPath: explicitTags ? cover : null,
            deleteOriginal: false,
          );
          expect(converted, endsWith('.m4a'));
          final atoms = _itunesAtoms(await File(converted!).readAsBytes());
          String text(String kind) => utf8.decode(atoms[kind]!.sublist(16));
          expect(text('\u00a9nam'), 'Song');
          expect(text('\u00a9ART'), artist);
          expect(text('aART'), 'Main Artist');
          expect(text('\u00a9alb'), 'Shared Album');
          expect(atoms['trkn']!.sublist(16), [0, 0, 0, 2, 0, 10, 0, 0]);
          expect(atoms['disk']!.sublist(16, 22), [0, 0, 0, 1, 0, 2]);
          if (explicitTags) expect(atoms['covr'], isNotEmpty);
          expect(await File(path).exists(), isTrue);
        }
      },
    );
  }

  test('failed AAC conversion retains the source and cleans output', () async {
    if (!haveTools()) return;
    final path = '${directory.path}/Invalid.flac';
    await File(path).writeAsString('invalid audio');

    final converted = await FFmpegConversion.convertAudioFormat(
      inputPath: path,
      targetFormat: 'aac',
      bitrate: '256k',
      metadata: const {},
    );

    expect(converted, isNull);
    expect(await File(path).readAsString(), 'invalid audio');
    expect(await directory.list().length, 1);
  });
}
