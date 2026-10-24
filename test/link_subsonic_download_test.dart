import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:path/path.dart' as p;

import 'support/subsonic_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late SubsonicFixture server;
  late NetworkStorageService storage;
  late Directory directory;

  setUp(() async {
    server = await SubsonicFixture.start();
    directory = await Directory.systemTemp.createTemp('subsonic-download-');
    String? saved;
    storage = NetworkStorageService(
      read: () async => saved,
      write: (value) async => saved = value,
      ensureAccess: (_) async {},
    );
    await storage.save(server.connection());
  });

  tearDown(() async {
    await storage.dispose();
    await server.close();
    await directory.delete(recursive: true);
  });

  Future<SubsonicClient> open() async {
    final client = storage.openSubsonic(await storage.connection('fixture'));
    addTearDown(client.close);
    return client;
  }

  test('download saves the original file and reports progress', () async {
    server.audio = List.generate(4096, (index) => index % 256);
    final client = await open();
    final output = File(p.join(directory.path, 'song.flac'));
    final progress = <(int, int?)>[];
    await client.download(
      'song / 1',
      output,
      progress: (received, total) => progress.add((received, total)),
    );
    expect(await output.readAsBytes(), server.audio);
    expect(server.requests.last.pathSegments.last, startsWith('download'));
    expect(server.requests.last.queryParameters['id'], 'song / 1');
    expect(progress.last, (4096, 4096));
  });

  test('download refuses a Subsonic error reply', () async {
    server.mediaError = true;
    final client = await open();
    final output = File(p.join(directory.path, 'song.flac'));
    await expectLater(
      client.download('song', output),
      throwsA(isA<HttpException>()),
    );
    expect(output.existsSync(), isFalse);
  });

  test('a throwing checkpoint stops the download', () async {
    server.audio = List.filled(1024, 7);
    final client = await open();
    final output = File(p.join(directory.path, 'song.flac'));
    await expectLater(
      client.download(
        'song',
        output,
        checkpoint: () => throw const FileSystemException('stopped'),
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
}
