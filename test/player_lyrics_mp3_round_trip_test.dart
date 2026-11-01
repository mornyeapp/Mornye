import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/ffmpeg_desktop.dart';
import 'package:mornye/services/metadata_cover_resources.dart';
import 'package:mornye/services/metadata_persistence_service.dart';
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/utils/desktop_platform.dart';

class _Covers extends MetadataCoverResources {
  @override
  Future<MetadataCoverPreview?> extract(String filePath) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test(
    'MP3 lyrics fallback preserves audio, embedded cover and tags',
    () async {
      try {
        if ((await Process.run('ffmpeg', ['-version'])).exitCode != 0 ||
            (await Process.run('ffprobe', ['-version'])).exitCode != 0) {
          markTestSkipped('FFmpeg tools are unavailable');
          return;
        }
      } on ProcessException {
        markTestSkipped('FFmpeg tools are unavailable');
        return;
      }
      final directory = await Directory.systemTemp.createTemp('player-lyrics-');
      addTearDown(() => directory.delete(recursive: true));
      messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
      addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
      debugDesktopPlatformOverride = true;
      DesktopFFmpegRunner.debugShared = DesktopFFmpegRunner(
        tools: () async => const DesktopFFmpegTools(ffmpegPath: 'ffmpeg'),
      );
      addTearDown(() {
        debugDesktopPlatformOverride = null;
        DesktopFFmpegRunner.debugShared = null;
      });
      Future<String> run(String executable, List<String> args) async {
        final result = await Process.run(executable, args);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        return result.stdout.toString();
      }

      final cover = '${directory.path}/cover.png';
      final audio = '${directory.path}/song.mp3';
      await run('ffmpeg', [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'color=c=blue:s=16x16',
        '-frames:v',
        '1',
        cover,
      ]);
      await run('ffmpeg', [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=0.2',
        '-i',
        cover,
        '-map',
        '0:a',
        '-map',
        '1:v',
        '-c:a',
        'libmp3lame',
        '-c:v',
        'copy',
        '-id3v2_version',
        '3',
        '-disposition:v',
        'attached_pic',
        '-metadata',
        'title=Keep title',
        '-metadata',
        'artist=Artist One; Artist Two',
        '-metadata',
        'album=Keep album',
        '-metadata',
        'custom_tag=Keep custom',
        '-metadata',
        'REPLAYGAIN_TRACK_GAIN=-3.20 dB',
        audio,
      ]);
      Future<String> hash(String stream) => run('ffmpeg', [
        '-v',
        'error',
        '-i',
        audio,
        '-map',
        stream,
        '-c',
        'copy',
        '-f',
        'hash',
        '-hash',
        'sha256',
        '-',
      ]);
      final audioHash = await hash('0:a');
      final coverHash = await hash('0:v');
      final covers = _Covers();
      addTearDown(covers.dispose);
      final result =
          await MetadataPersistenceService(
            covers: covers,
            edit: (_, _) async => {'method': 'ffmpeg'},
            read: (_) async => const {},
          ).save(
            MetadataSaveRequest(
              filePath: audio,
              metadata: const {'lyrics': '[00:01.00]Saved for offline'},
              artistTagMode: artistTagModeJoined,
              preserveUnspecifiedTags: true,
            ),
          );
      expect(result.failure, isNull);
      expect(await hash('0:a'), audioHash);
      expect(await hash('0:v'), coverHash);
      final probe =
          jsonDecode(
                await run('ffprobe', [
                  '-v',
                  'error',
                  '-show_format',
                  '-of',
                  'json',
                  audio,
                ]),
              )
              as Map;
      final tags = (probe['format'] as Map)['tags'] as Map;
      expect(tags['title'], 'Keep title');
      expect(tags['artist'], 'Artist One; Artist Two');
      expect(tags['album'], 'Keep album');
      expect(tags['custom_tag'], 'Keep custom');
      expect(tags['REPLAYGAIN_TRACK_GAIN'], '-3.20 dB');
      expect(tags.values, contains('[00:01.00]Saved for offline'));
    },
  );
}
