import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/audio_file_open_service.dart';
import 'package:path/path.dart' as p;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('mornye-open-audio-');
  });
  tearDown(() => directory.delete(recursive: true));

  test('decodes local file URLs without treating links or flags as files', () {
    final path = p.join(directory.path, 'Musik 日本語 #1.flac');
    expect(OpenAudioFile.parse(Uri.file(path).toString())?.source, path);
    for (final input in [
      'https://example.com/song.mp3',
      'mornye://callback',
      '--help',
      'relative.mp3',
      '/invalid\u0000.mp3',
      null,
      42,
    ]) {
      expect(OpenAudioFile.parse(input), isNull, reason: '$input');
    }
    expect(OpenAudioFile.parse('${Uri.file(path)}?query=yes'), isNull);
    expect(const OpenAudioFile('/no-extension').isAudio, isFalse);
    expect(const OpenAudioFile('/clip.mp4').isAudio, isFalse);
  });

  test(
    'uses SAF display names instead of opaque document identifiers',
    () async {
      final file = OpenAudioFile.parse({
        'source': 'content://documents/tree/root/document/231',
        'name': '01. Song.OPUS',
      })!;
      expect(file.isAudio, isTrue);
      expect(await collectOpenAudioFiles([file]), [file]);
    },
  );

  test(
    'recursively queues audio in order, deduplicating explicit selections',
    () async {
      final album = await Directory(p.join(directory.path, 'Album')).create();
      final first = await File(
        p.join(album.path, '01. First.FLAC'),
      ).writeAsString('audio');
      final second = await File(
        p.join(album.path, '02. Second.mp3'),
      ).writeAsString('audio');
      await File(p.join(album.path, 'cover.jpg')).writeAsString('image');
      final files = await collectOpenAudioFiles([
        OpenAudioFile(directory.path),
        OpenAudioFile(first.path),
      ]);
      expect(files.map((file) => file.source), [first.path, second.path]);
      expect(await first.exists(), isTrue);
      expect(await second.exists(), isTrue);
    },
  );

  test(
    'keeps explicitly selected file order and ignores missing files',
    () async {
      final first = await File(
        p.join(directory.path, 'a.wav'),
      ).writeAsString('a');
      final second = await File(
        p.join(directory.path, 'b.m4a'),
      ).writeAsString('b');
      final files = await collectOpenAudioFiles([
        OpenAudioFile(second.path),
        OpenAudioFile(first.path),
        OpenAudioFile(p.join(directory.path, 'missing.flac')),
      ]);
      expect(files.map((file) => file.source), [second.path, first.path]);
    },
  );

  test(
    'does not follow a directory symlink cycle and enforces queue limits',
    () async {
      await File(p.join(directory.path, 'a.wav')).writeAsString('a');
      await File(p.join(directory.path, 'b.wav')).writeAsString('b');
      if (!Platform.isWindows) {
        await Link(p.join(directory.path, 'loop')).create(directory.path);
      }
      expect(
        await collectOpenAudioFiles([OpenAudioFile(directory.path)]),
        hasLength(2),
      );
      await expectLater(
        collectOpenAudioFiles([OpenAudioFile(directory.path)], limit: 1),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'buffers launch requests and delivers subsequent explicit opens',
    () async {
      final service = AudioFileOpenService();
      final path = p.join(directory.path, 'song.mp3');
      service.receive([path, 'https://example.com/song.mp3']);
      expect(service.takePending().single.single.source, path);
      expect(service.takePending(), isEmpty);
      final seen = <List<OpenAudioFile>>[];
      final subscription = service.requests.listen(seen.add);
      service.receive([path]);
      service.receive([path]);
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(2));
      await subscription.cancel();
      await service.dispose();
    },
  );

  test('drains native launch events and accepts warm channel events', () async {
    const channel = MethodChannel('test/open-audio');
    final messenger = binding.defaultBinaryMessenger;
    final path = p.join(directory.path, 'song.flac');
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'takePending');
      return [
        [path],
      ];
    });
    final service = AudioFileOpenService(channel: channel);
    await service.initialize();
    expect(service.takePending().single.single.source, path);
    final incoming = service.requests.first;
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('open', [path])),
      (_) {},
    );
    expect((await incoming).single.source, path);
    await service.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'drains when Android attaches after the headless engine started',
    () async {
      const channel = MethodChannel('test/open-audio-late');
      final messenger = binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw MissingPluginException(),
      );
      final service = AudioFileOpenService(channel: channel);
      await service.initialize();
      final path = p.join(directory.path, 'late.mp3');
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => [
          [path],
        ],
      );
      final incoming = service.requests.first;
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(const MethodCall('ready')),
        (_) {},
      );
      expect((await incoming).single.source, path);
      await service.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    },
  );
}
