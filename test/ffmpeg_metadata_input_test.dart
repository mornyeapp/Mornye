import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/services/ffmpeg_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  var toolsAvailable = false;

  setUpAll(() async {
    try {
      toolsAvailable =
          (await Process.run('ffmpeg', ['-version'])).exitCode == 0 &&
          (await Process.run('ffprobe', ['-version'])).exitCode == 0;
    } on ProcessException {
      // Media round trips run when FFmpeg tools are on PATH.
    }
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'metadata round trip 音楽 ',
    );
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(paths, null);
    await directory.delete(recursive: true);
  });

  Future<ProcessResult> run(String tool, List<String> arguments) async {
    final result = await Process.run(tool, arguments);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    return result;
  }

  Future<FFmpegResult> execute(List<String> arguments) async {
    expect(arguments.join(' ').length, lessThan(32767));
    final result = await Process.run('ffmpeg', arguments);
    return FFmpegResult(
      success: result.exitCode == 0,
      returnCode: result.exitCode,
      output: '${result.stdout}${result.stderr}',
    );
  }

  Future<Map<String, String>> tags(String path) async {
    final result = await run('ffprobe', [
      '-v',
      'error',
      '-show_entries',
      'format_tags:stream_tags',
      '-of',
      'json',
      path,
    ]);
    final decoded = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final values = <String, String>{};
    for (final section in [
      decoded['format'],
      ...?decoded['streams'] as List<dynamic>?,
    ]) {
      if (section is! Map || section['tags'] is! Map) continue;
      for (final entry in (section['tags'] as Map).entries) {
        values[entry.key.toString().toLowerCase()] = entry.value.toString();
      }
    }
    return values;
  }

  Future<String> audioHash(String path) async {
    final result = await run('ffmpeg', [
      '-v',
      'error',
      '-i',
      path,
      '-map',
      '0:a:0',
      '-c:a',
      'copy',
      '-f',
      'hash',
      '-hash',
      'sha256',
      '-',
    ]);
    return result.stdout.toString().trim();
  }

  for (final format in [
    (name: 'FLAC', extension: 'flac', codec: 'flac'),
    (name: 'MP3', extension: 'mp3', codec: 'libmp3lame'),
    (name: 'AAC', extension: 'm4a', codec: 'aac'),
    (name: 'ALAC', extension: 'm4a', codec: 'alac'),
    (name: 'Opus', extension: 'opus', codec: 'libopus'),
    (name: 'WAV', extension: 'wav', codec: 'pcm_s16le'),
    (name: 'AIFF', extension: 'aiff', codec: 'pcm_s16be'),
  ]) {
    test('${format.name} preserves large tags and encoded audio', () async {
      if (!toolsAvailable) {
        markTestSkipped('Requires ffmpeg and ffprobe on PATH');
        return;
      }
      final input = File.fromUri(
        directory.uri.resolve('source.${format.extension}'),
      ).path;
      final output = File.fromUri(
        directory.uri.resolve('output.${format.extension}'),
      ).path;
      await run('ffmpeg', [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'sine=duration=0.1',
        '-c:a',
        format.codec,
        '-metadata',
        'title=Before',
        '-metadata',
        'artist=Before Artist',
        '-metadata',
        'album=Preserved album',
        '-metadata',
        'comment=Before comment',
        input,
      ]);
      final before = await tags(input);
      final beforeHash = await audioHash(input);
      final title = '音楽 ${List.filled(2500, 'Title').join()}';
      final lyrics = List.filled(4000, 'Line = #; \\ \r\n音楽 😀\n').join();
      const comment = 'Comment = #; \\ \r\n音楽 😀\n';
      final result = await FFmpegExecution.arguments([
        '-v',
        'error',
        '-i',
        input,
        '-map',
        '0:a:0',
        '-c:a',
        'copy',
        if (format.name == 'Opus') ...[
          '-map_metadata',
          '0:s:a:0',
          '-map_metadata:s:a',
          '-1',
        ] else if (format.name != 'FLAC') ...[
          '-map_metadata',
          '0',
        ],
        '-metadata',
        'title=$title',
        '-metadata',
        'artist=After Artist',
        '-metadata',
        'comment=$comment',
        '-metadata',
        'lyrics=$lyrics',
        if (format.name == 'MP3') ...['-id3v2_version', '3'],
        output,
      ], execute: execute);
      expect(result.success, isTrue, reason: result.output);
      final after = await tags(output);
      expect(after['title'], title);
      if (before.containsKey('artist')) {
        expect(after['artist'], 'After Artist');
      }
      if (before.containsKey('album')) {
        expect(after['album'], 'Preserved album');
      }
      if (before.containsKey('comment')) expect(after['comment'], comment);
      if (!const {'WAV', 'AIFF'}.contains(format.name)) {
        expect(after['lyrics'], lyrics);
      }
      expect(await audioHash(output), beforeHash);
      expect(
        await directory.list().where((entry) => entry is Directory).length,
        0,
      );
    });
  }

  test('large tags retain last assignments and explicit deletions', () async {
    if (!toolsAvailable) {
      markTestSkipped('Requires ffmpeg and ffprobe on PATH');
      return;
    }
    final input = File.fromUri(directory.uri.resolve('source.opus')).path;
    final output = File.fromUri(directory.uri.resolve('output.opus')).path;
    await run('ffmpeg', [
      '-v',
      'error',
      '-f',
      'lavfi',
      '-i',
      'sine=duration=0.1',
      '-c:a',
      'libopus',
      '-metadata',
      'album=Remove album',
      '-metadata',
      'composer=Remove composer',
      input,
    ]);
    final result = await FFmpegExecution.arguments([
      '-v',
      'error',
      '-i',
      input,
      '-map',
      '0:a',
      '-c:a',
      'copy',
      '-map_metadata',
      '0:s:a:0',
      '-map_metadata:s:a',
      '-1',
      '-metadata',
      'lyrics=${List.filled(4000, 'Lyrics\n').join()}',
      '-metadata',
      'artist=First',
      '-metadata',
      'ARTIST=Second',
      '-metadata',
      'album=',
      '-metadata',
      'composer=New composer',
      '-metadata',
      'COMPOSER=',
      '-metadata',
      'genre=',
      '-metadata',
      'GENRE=Rock',
      output,
    ], execute: execute);
    expect(result.success, isTrue, reason: result.output);
    final after = await tags(output);
    expect(after['artist'], 'Second');
    expect(after['genre'], 'Rock');
    expect(after, isNot(contains('album')));
    expect(after, isNot(contains('composer')));
  });
}
