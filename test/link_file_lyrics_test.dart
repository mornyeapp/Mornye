import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/features/link_phone_files.dart';
import 'package:mornye/services/link/features/link_phone_library_sync.dart';
import 'package:mornye/services/link/link_protocol.dart';

import 'support/link_fakes.dart';

void main() {
  late Directory directory;
  late FakeLinkClient client;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('link-lyrics-');
    client = FakeLinkClient();
  });
  tearDown(() async {
    await client.close();
    await directory.delete(recursive: true);
  });

  for (final saf in [false, true]) {
    test(
      'reads original embedded lyrics without uploading audio (SAF=$saf)',
      () async {
        final path = saf
            ? 'content://example.documents/document/old-song'
            : '${directory.path}/old-song.flac';
        if (!saf) File(path).writeAsStringSync('original audio');
        final rows = FakeLibraryRows([
          linkLocalRow(path, {'format': 'flac'}),
        ]);
        final library = rows.library();
        final song = (await library.catalog()).songs.single;
        final handler = LinkPhoneFileRequests(
          client: client,
          library: library,
          files: LinkPhoneFiles(),
          readLyrics: (source) async {
            expect(source, path);
            return '[00:01.00]Old embedded lyrics';
          },
        )..start();
        addTearDown(handler.dispose);
        client.push({
          'type': LinkMessageTypes.filesLyricsRequest,
          'requestId': 'lyrics-1',
          'name': song.name,
        });
        await pumpEventQueue();
        expect(client.sent.single, {
          'type': LinkMessageTypes.filesLyrics,
          'requestId': 'lyrics-1',
          'name': song.name,
          'lyrics': '[00:01.00]Old embedded lyrics',
        });
        expect(client.uploads, isEmpty);
        if (!saf) expect(File(path).readAsStringSync(), 'original audio');
      },
    );
  }

  test('unknown files and paths never reach the phone tag reader', () async {
    var reads = 0;
    final handler = LinkPhoneFileRequests(
      client: client,
      library: FakeLibraryRows([]).library(),
      files: LinkPhoneFiles(),
      readLyrics: (_) async {
        reads++;
        return 'private';
      },
    )..start();
    addTearDown(handler.dispose);
    for (final name in [
      '/private/song.flac',
      '../song.flac',
      '${'a' * 32}.exe',
      '${'a' * 32}.flac',
    ]) {
      client.push({
        'type': LinkMessageTypes.filesLyricsRequest,
        'requestId': 'missing',
        'name': name,
      });
    }
    await pumpEventQueue();
    expect(reads, 0);
    expect(client.sent.single['error'], 'not_found');
    expect(client.uploads, isEmpty);
  });

  test('oversized lyrics and read failures send bounded errors', () async {
    final path = '${directory.path}/song.flac';
    File(path).writeAsStringSync('audio');
    final library = FakeLibraryRows([linkLocalRow(path)]).library();
    final song = (await library.catalog()).songs.single;
    var read = 0;
    final handler = LinkPhoneFileRequests(
      client: client,
      library: library,
      files: LinkPhoneFiles(),
      readLyrics: (_) async {
        if (read++ == 0) return 'あ' * linkFileLyricsMaxBytes;
        throw const FileSystemException('private path must stay on the phone');
      },
    )..start();
    addTearDown(handler.dispose);
    for (var index = 0; index < 2; index++) {
      client.push({
        'type': LinkMessageTypes.filesLyricsRequest,
        'requestId': 'lyrics-$index',
        'name': song.name,
      });
      await pumpEventQueue();
    }
    expect(client.sent.map((reply) => reply['error']), [
      'too_large',
      'unavailable',
    ]);
    expect(client.sent.toString(), isNot(contains('private path')));
  });

  test(
    'concurrent lyric reads are bounded and disposal drops late replies',
    () async {
      final path = '${directory.path}/song.flac';
      File(path).writeAsStringSync('audio');
      final library = FakeLibraryRows([linkLocalRow(path)]).library();
      final song = (await library.catalog()).songs.single;
      final pending = <Completer<String>>[];
      final handler = LinkPhoneFileRequests(
        client: client,
        library: library,
        files: LinkPhoneFiles(),
        readLyrics: (_) {
          final read = Completer<String>();
          pending.add(read);
          return read.future;
        },
      )..start();
      for (var index = 0; index < 3; index++) {
        client.push({
          'type': LinkMessageTypes.filesLyricsRequest,
          'requestId': 'lyrics-$index',
          'name': song.name,
        });
      }
      await pumpEventQueue();
      expect(pending, hasLength(2));
      expect(client.sent.single['error'], 'busy');
      handler.dispose();
      for (final read in pending) {
        read.complete('late');
      }
      await pumpEventQueue();
      expect(client.sent, hasLength(1));
    },
  );
}
