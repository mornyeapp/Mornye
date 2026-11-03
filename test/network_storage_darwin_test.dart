import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final nativeTest = Platform.environment['MORNYE_DARWIN_SOURCE_TEST'];

  test(
    'native AVPlayer prepares audio through the real NAS playback proxy',
    () async {
      // One second of mono PCM, served as generic bytes by a NAS with Range.
      final wave = Uint8List(44 + 44100 * 2);
      final header = ByteData.sublistView(wave);
      wave.setRange(0, 4, ascii.encode('RIFF'));
      header.setUint32(4, wave.length - 8, Endian.little);
      wave.setRange(8, 16, ascii.encode('WAVEfmt '));
      header.setUint32(16, 16, Endian.little);
      header.setUint16(20, 1, Endian.little);
      header.setUint16(22, 1, Endian.little);
      header.setUint32(24, 44100, Endian.little);
      header.setUint32(28, 44100 * 2, Endian.little);
      header.setUint16(32, 2, Endian.little);
      header.setUint16(34, 16, Endian.little);
      wave.setRange(36, 40, ascii.encode('data'));
      header.setUint32(40, wave.length - 44, Endian.little);

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final ranges = <String>[];
      server.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null) ranges.add(range);
        final part = networkByteRange(range, wave.length);
        final response = request.response;
        response.statusCode = range == null ? 200 : 206;
        response.headers.contentType = ContentType.binary;
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        response.contentLength = part.end - part.start + 1;
        if (range != null) {
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes ${part.start}-${part.end}/${wave.length}',
          );
        }
        if (request.method != 'HEAD') {
          response.add(Uint8List.sublistView(wave, part.start, part.end + 1));
        }
        await response.close();
      });
      final storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
        ensureAccess: (_) async {},
      );
      addTearDown(storage.dispose);
      await storage.save(
        NetworkConnection(
          id: 'nas',
          name: 'NAS',
          protocol: NetworkProtocol.webdav,
          address: 'http://127.0.0.1:${server.port}/music/',
        ),
      );
      final url = await storage.resolve(
        NetworkStorageService.source('nas', '日本語 #1.WAV'),
      );
      final result = await Process.run(nativeTest!, [url]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(
        result.stdout,
        contains('PASS: native AVPlayer prepares the HTTP proxy source'),
      );
      expect(ranges, isNotEmpty);
    },
    skip: !Platform.isMacOS || nativeTest == null
        ? 'Set MORNYE_DARWIN_SOURCE_TEST to the compiled SourceLifecycleTests binary'
        : false,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
