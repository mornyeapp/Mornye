import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/services/apk_downloader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final knownLength in [true, false]) {
    test(
      'APK progress is bounded for chunk bursts and finishes with the latest byte count ($knownLength)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'mornye-progress-test-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final chunks = [
          [0x50, 0x4b, 0x03, 0x04],
          for (var i = 1; i < 1000; i++) List<int>.filled(64, i % 256),
        ];
        final total = chunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
        final client = MockClient.streaming(
          (request, body) async => http.StreamedResponse(
            Stream<List<int>>.fromIterable(chunks),
            200,
            contentLength: knownLength ? total : null,
          ),
        );
        addTearDown(client.close);
        final progress = <(int, int)>[];
        final clock = Stopwatch()..start();
        final path = await ApkDownloader.downloadApk(
          url: 'https://updates.example.test/update.apk',
          version: 'burst',
          client: client,
          downloadDirectory: directory,
          onProgress: (received, length) => progress.add((received, length)),
        );
        expect(path, isNotNull);
        expect(progress.first, (0, knownLength ? total : 0));
        expect(progress.last, (total, knownLength ? total : 0));
        expect(
          progress.length,
          lessThanOrEqualTo(2 + clock.elapsedMilliseconds ~/ 500),
        );
        expect(await File(path!).length(), total);
        final count = progress.length;
        await Future<void>.delayed(Duration.zero);
        expect(progress.length, count);
      },
    );
  }

  test(
    'APK progress still updates while a slower stream is downloading',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'mornye-progress-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      Stream<List<int>> chunks() async* {
        yield [0x50, 0x4b, 0x03, 0x04];
        await Future<void>.delayed(const Duration(milliseconds: 550));
        yield [1, 2, 3];
        yield [4, 5, 6];
      }

      final client = MockClient.streaming(
        (request, body) async =>
            http.StreamedResponse(chunks(), 200, contentLength: 10),
      );
      addTearDown(client.close);
      final progress = <int>[];
      final path = await ApkDownloader.downloadApk(
        url: 'https://updates.example.test/update.apk',
        version: 'slow',
        client: client,
        downloadDirectory: directory,
        onProgress: (received, _) => progress.add(received),
      );
      expect(path, isNotNull);
      expect(progress, [0, 7, 10]);
    },
  );

  test('APK updater resumes a matching partial and verifies SHA-256', () async {
    final directory = await Directory.systemTemp.createTemp(
      'mornye-updater-test-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final payload = <int>[
      0x50,
      0x4b,
      0x03,
      0x04,
      ...List.generate(64, (i) => i),
    ];
    const version = '5.0.0';
    const url = 'https://updates.example.test/Mornye.apk';
    final finalPath = p.join(directory.path, 'Mornye-$version.apk');
    final part = File('$finalPath.part');
    await part.writeAsBytes(payload.sublist(0, 12));
    await File(
      '$finalPath.part.json',
    ).writeAsString(jsonEncode({'url': url, 'etag': '"release-1"'}));

    final client = MockClient((request) async {
      expect(request.headers['range'], 'bytes=12-');
      expect(request.headers['if-range'], '"release-1"');
      return http.Response.bytes(
        payload.sublist(12),
        206,
        headers: {
          'content-range': 'bytes 12-${payload.length - 1}/${payload.length}',
          'content-length': '${payload.length - 12}',
          'etag': '"release-1"',
        },
        request: request,
      );
    });
    var lastReceived = 0;
    var lastTotal = 0;

    final downloaded = await ApkDownloader.downloadApk(
      url: url,
      version: version,
      expectedSha256: sha256.convert(payload).toString(),
      client: client,
      downloadDirectory: directory,
      onProgress: (received, total) {
        lastReceived = received;
        lastTotal = total;
      },
    );

    expect(downloaded, finalPath);
    expect(await File(finalPath).readAsBytes(), payload);
    expect(lastReceived, payload.length);
    expect(lastTotal, payload.length);
    expect(await part.exists(), isFalse);
    expect(await File('$finalPath.part.json').exists(), isFalse);
  });

  test(
    'native hashing verifies the completed partial before publishing',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'mornye-native-updater-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final payload = <int>[0x50, 0x4b, 0x03, 0x04, 1, 2, 3];
      final expected = sha256.convert(payload).toString();
      var hashes = 0;
      var nativeDigest = expected;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'runNativeDataJob');
            final args = Map<String, dynamic>.from(call.arguments as Map);
            final request = jsonDecode(args['request_json'] as String) as Map;
            expect(request['operation'], 'hash_file');
            final file = File(request['path'] as String);
            expect(file.path, endsWith('.apk.part'));
            expect(await file.readAsBytes(), payload);
            hashes++;
            return {'sha256': nativeDigest};
          });
      final client = MockClient(
        (request) async => http.Response.bytes(payload, 200, request: request),
      );
      final downloaded = await ApkDownloader.downloadApk(
        url: 'https://updates.example.test/update.apk',
        version: 'native',
        expectedSha256: expected,
        client: client,
        downloadDirectory: directory,
      );
      expect(downloaded, isNotNull);
      expect(await File(downloaded!).readAsBytes(), payload);
      nativeDigest = '0' * 64;
      final rejected = await ApkDownloader.downloadApk(
        url: 'https://updates.example.test/update.apk',
        version: 'mismatch',
        expectedSha256: expected,
        client: client,
        downloadDirectory: directory,
      );
      expect(rejected, isNull);
      expect(hashes, 2);
      expect(
        await File('${directory.path}/Mornye-mismatch.apk').exists(),
        false,
      );
      expect(
        await File('${directory.path}/Mornye-mismatch.apk.part').exists(),
        false,
      );
    },
  );
}
