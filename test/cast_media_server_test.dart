import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/cast_media_server.dart';

void main() {
  late Directory directory;
  late CastMediaServer server;
  late HttpClient client;
  late Uri media;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('mornye-cast-');
    final file = File('${directory.path}/private song.flac');
    await file.writeAsBytes(List.generate(100, (i) => i));
    server = CastMediaServer();
    await server.bind(InternetAddress.loopbackIPv4);
    media = server.register(file.path, 'audio/flac');
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await server.close();
    await directory.delete(recursive: true);
  });

  Future<HttpClientResponse> request({
    String method = 'GET',
    String? range,
    Uri? uri,
  }) async {
    final request = await client.openUrl(method, uri ?? media);
    if (range != null) request.headers.set('Range', range);
    return request.close();
  }

  test(
    'serves the registered file with HEAD and CORS, without exposing its path',
    () async {
      expect(media.toString(), isNot(contains('private')));
      final head = await request(method: 'HEAD');
      expect(head.statusCode, 200);
      expect(head.contentLength, 100);
      expect(head.headers.contentType?.mimeType, 'audio/flac');
      expect(head.headers.value('access-control-allow-origin'), '*');
      expect(await head.expand((bytes) => bytes).toList(), isEmpty);
      final get = await request();
      expect(
        await get.expand((bytes) => bytes).toList(),
        List.generate(100, (i) => i),
      );
    },
  );

  test(
    'supports bounded, open-ended and suffix byte ranges used when seeking',
    () async {
      for (final example in [
        ('bytes=10-19', 10, 19),
        ('bytes=95-', 95, 99),
        ('bytes=-3', 97, 99),
      ]) {
        final reply = await request(range: example.$1);
        expect(reply.statusCode, 206);
        expect(
          reply.headers.value('content-range'),
          'bytes ${example.$2}-${example.$3}/100',
        );
        expect(await reply.expand((bytes) => bytes).toList(), [
          for (var i = example.$2; i <= example.$3; i++) i,
        ]);
      }
    },
  );

  test(
    'rejects invalid ranges and unregistered paths and revokes previous URLs',
    () async {
      for (final range in [
        'bytes=100-',
        'bytes=50-20',
        'bytes=-0',
        'bytes=-',
        'bytes=1-2,4-5',
      ]) {
        final reply = await request(range: range);
        expect(reply.statusCode, 416);
        await reply.drain<void>();
      }
      final unknown = await request(
        uri: media.replace(path: '/media/not-registered'),
      );
      expect(unknown.statusCode, 404);
      await unknown.drain<void>();
      final traversal = await request(
        uri: media.replace(path: '/media/../../secret'),
      );
      expect(traversal.statusCode, 404);
      await traversal.drain<void>();
      server.clear();
      final revoked = await request();
      expect(revoked.statusCode, 404);
      await revoked.drain<void>();
    },
  );

  test(
    'relays private HTTP sources and seeking without revealing upstream URLs',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => upstream.close(force: true));
      upstream.listen((request) async {
        expect(request.uri.query, 'credential=private-token');
        expect(request.headers.value('range'), 'bytes=2-4');
        request.response
          ..statusCode = 206
          ..headers.set('content-range', 'bytes 2-4/100')
          ..contentLength = 3;
        if (request.method != 'HEAD') request.response.add([2, 3, 4]);
        await request.response.close();
      });
      final relayed = server.register(
        'http://127.0.0.1:${upstream.port}/song?credential=private-token',
        'audio/mpeg',
      );
      expect(relayed.toString(), isNot(contains('credential')));
      final reply = await request(uri: relayed, range: 'bytes=2-4');
      expect(reply.statusCode, 206);
      expect(reply.headers.value('content-range'), 'bytes 2-4/100');
      expect(await reply.expand((bytes) => bytes).toList(), [2, 3, 4]);
      final head = await request(
        uri: relayed,
        range: 'bytes=2-4',
        method: 'HEAD',
      );
      expect(head.contentLength, 3);
      expect(await head.expand((bytes) => bytes).toList(), isEmpty);
    },
  );
}
