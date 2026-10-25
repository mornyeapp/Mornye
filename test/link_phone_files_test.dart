import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/features/link_phone_files.dart';
import 'package:mornye/services/link/link_protocol.dart';

import 'support/link_fakes.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('link_phone_files_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  MediaItem item(String source) =>
      MediaItem(id: source, title: 'Song', extras: {'source': source});

  group('file ids', () {
    test('stay the same for a file and change with its size', () {
      final id = linkFileIdFor('/music/a.flac', 10);
      expect(isLinkFileId(id), isTrue);
      expect(linkFileIdFor('/music/a.flac', 10), id);
      expect(linkFileIdFor('/music/a.flac', 11), isNot(id));
    });

    test('travel in a TrackRef and invalid ones are dropped', () {
      final id = linkFileIdFor('/music/a.flac', 10);
      const ref = TrackRef(title: 'Song', artist: 'Artist');
      final sent = TrackRef.fromJson(ref.withFileId(id).toJson())!;
      expect(sent.fileId, id);
      expect(sent, ref.withFileId(id));
      expect(
        TrackRef.fromJson({...ref.toJson(), 'fileId': '../../etc/passwd'}),
        ref,
      );
    });
  });

  group('fileFor', () {
    test('names a local file the desktop can play', () async {
      final path = '${dir.path}/Song.FLAC';
      await File(path).writeAsBytes([1, 2, 3, 4]);
      final file = await LinkPhoneFiles().fileFor(item(path));
      expect(file!.fileId, linkFileIdFor(path, 4));
      expect(file.extension, 'flac');
    });

    test('skips streams, missing files and other formats', () async {
      final files = LinkPhoneFiles();
      final text = '${dir.path}/notes.txt';
      await File(text).writeAsString('hi');
      expect(await files.fileFor(item('https://host/a.flac')), isNull);
      expect(await files.fileFor(item('${dir.path}/gone.flac')), isNull);
      expect(await files.fileFor(item(text)), isNull);
    });

    test('takes a content URI, whose copy names the format', () async {
      const uri = 'content://media/external/audio/media/7';
      final file = await LinkPhoneFiles().fileFor(item(uri));
      expect(file!.fileId, linkFileIdFor(uri, 0));
      expect(file.extension, isNull);
    });
  });

  group('upload', () {
    test('keeps a background lease until the complete file arrives', () async {
      final path = '${dir.path}/background.flac';
      await File(path).writeAsBytes([1, 2]);
      final started = Completer<void>();
      final finish = Completer<void>();
      final calls = <String>[];
      final client = FakeLinkClient()
        ..whileUploading = (name, size, sent) {
          started.complete();
          return finish.future;
        };
      final files = LinkPhoneFiles(
        acquireTransfer: (name) async {
          calls.add('acquire');
          return () async => calls.add('release');
        },
      );
      final uploading = files.upload(
        client,
        (await files.fileFor(item(path)))!,
      );
      await started.future;
      expect(calls, ['acquire']);
      finish.complete();
      await uploading;
      expect(calls, ['acquire', 'release']);
    });

    test('failed transfers release their background lease', () async {
      final path = '${dir.path}/failed.flac';
      await File(path).writeAsBytes([1]);
      var released = 0;
      final client = FakeLinkClient()
        ..onUpload = (_) => const LinkException('unavailable', 'Offline');
      final files = LinkPhoneFiles(
        acquireTransfer: (_) async {
          return () async => released++;
        },
      );
      await expectLater(
        files.upload(client, (await files.fileFor(item(path)))!),
        throwsA(isA<LinkException>()),
      );
      expect(released, 1);
    });

    test('sends a local file under its id and extension', () async {
      final path = '${dir.path}/a.mp3';
      await File(path).writeAsBytes([5, 6]);
      final client = FakeLinkClient();
      final files = LinkPhoneFiles();
      final file = (await files.fileFor(item(path)))!;
      final progress = <(int, int)>[];
      await files.upload(
        client,
        file,
        onProgress: (sent, total) => progress.add((sent, total)),
      );
      expect(client.uploads.single.name, '${file.fileId}.mp3');
      expect(client.uploads.single.bytes, [5, 6]);
      expect(progress.last, (2, 2));
    });

    test('copies a content URI first and removes the copy', () async {
      final copy = '${dir.path}/saf_123.m4a';
      final client = FakeLinkClient();
      final files = LinkPhoneFiles(
        copyContentUri: (uri) async {
          await File(copy).writeAsBytes([9]);
          return copy;
        },
      );
      final file = (await files.fileFor(item('content://media/9')))!;
      await files.upload(client, file);
      expect(client.uploads.single.name, '${file.fileId}.m4a');
      expect(client.uploads.single.bytes, [9]);
      expect(await File(copy).exists(), isFalse);
    });

    test('says whether the desktop can start the file early', () async {
      /// An MP4 box of [type] with [length] payload bytes.
      List<int> box(String type, int length) => [
        ...[0, 0, (length + 8) >> 8, (length + 8) & 0xff],
        ...type.codeUnits,
        ...List.filled(length, 0),
      ];
      final files = LinkPhoneFiles();
      Future<LinkUploadStart?> start(String name, List<int> bytes) async {
        final path = '${dir.path}/$name';
        await File(path).writeAsBytes(bytes);
        LinkUploadStart? started;
        await files.upload(
          FakeLinkClient(),
          (await files.fileFor(item(path)))!,
          onStart: (value) => started = value,
        );
        return started;
      }

      final fastStart = await start('fast.m4a', [
        ...box('ftyp', 8),
        ...box('moov', 16),
        ...box('mdat', 64),
      ]);
      expect(fastStart!.streamable, isTrue);
      expect(fastStart.size, 112);
      expect(fastStart.name, endsWith('.m4a'));
      // The index comes after the audio, so the file must arrive whole.
      final indexLast = await start('late.m4a', [
        ...box('ftyp', 8),
        ...box('mdat', 64),
        ...box('moov', 16),
      ]);
      expect(indexLast!.streamable, isFalse);
      expect((await start('song.flac', [1, 2, 3]))!.streamable, isTrue);
    });

    test('fails when the content URI cannot be read', () async {
      final files = LinkPhoneFiles(copyContentUri: (_) async => null);
      final file = (await files.fileFor(item('content://media/9')))!;
      await expectLater(
        files.upload(FakeLinkClient(), file),
        throwsA(isA<LinkException>()),
      );
    });
  });
}
