import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/motion_artwork_proxy.dart';

void main() {
  late HttpClient reader;
  setUp(() => reader = HttpClient());
  tearDown(() => reader.close(force: true));

  Future<({int status, HttpHeaders headers, List<int> bytes})> fetch(
    Uri uri, {
    String method = 'GET',
    String? range,
  }) async {
    final request = await reader.openUrl(method, uri);
    if (range != null) request.headers.set('range', range);
    final response = await request.close();
    return (
      status: response.statusCode,
      headers: response.headers,
      bytes: await response.expand((chunk) => chunk).toList(),
    );
  }

  Future<HttpServer> tlsServer() async {
    final context = SecurityContext()
      ..useCertificateChain('test/fixtures/network_tls/cert.pem')
      ..usePrivateKey('test/fixtures/network_tls/key.pem');
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    addTearDown(() => server.close(force: true));
    return server;
  }

  HttpClient trustedFixtureClient(HttpServer server) =>
      HttpClient()
        ..badCertificateCallback = (_, host, port) =>
            host == '127.0.0.1' && port == server.port;

  test('TLS MP4 relays GET, HEAD, ranges, status and content type', () async {
    final server = await tlsServer();
    final requests = <(String, String?)>[];
    server.listen((request) async {
      requests.add((request.method, request.headers.value('range')));
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.headers.set('accept-ranges', 'bytes');
      if (request.headers.value('range') == 'bytes=1-2') {
        request.response
          ..statusCode = 206
          ..headers.set('content-range', 'bytes 1-2/4')
          ..contentLength = 2
          ..add([20, 30]);
      } else {
        request.response.contentLength = 4;
        if (request.method != 'HEAD') request.response.add([10, 20, 30, 40]);
      }
      await request.response.close();
    }, onError: (Object _) {});
    final proxy = await MotionArtworkProxy.start(
      Uri.parse('https://127.0.0.1:${server.port}/cover.mp4'),
      client: trustedFixtureClient(server),
    );
    addTearDown(proxy.close);
    final full = await fetch(proxy.source);
    expect(full.bytes, [10, 20, 30, 40]);
    expect(full.headers.contentType?.mimeType, 'video/mp4');
    final range = await fetch(proxy.source, range: 'bytes=1-2');
    expect(range.status, 206);
    expect(range.bytes, [20, 30]);
    expect(range.headers.value('content-range'), 'bytes 1-2/4');
    final head = await fetch(proxy.source, method: 'HEAD');
    expect(head.status, 200);
    expect(head.bytes, isEmpty);
    expect(head.headers.contentLength, 4);
    final count = requests.length;
    expect(
      (await fetch(proxy.source.replace(query: 'url=http://other'))).status,
      404,
    );
    expect(
      (await fetch(proxy.source.replace(path: '/unknown/0.bin'))).status,
      404,
    );
    expect((await fetch(proxy.source, method: 'POST')).status, 405);
    expect(requests.length, count);
    expect(requests, [('GET', null), ('GET', 'bytes=1-2'), ('HEAD', null)]);
  });

  test(
    'TLS stays verified unless the test explicitly trusts its fixture',
    () async {
      final server = await tlsServer();
      var requests = 0;
      server.listen((request) async {
        requests++;
        await request.response.close();
      }, onError: (Object _) {});
      final proxy = await MotionArtworkProxy.start(
        Uri.parse('https://127.0.0.1:${server.port}/cover.mp4'),
      );
      addTearDown(proxy.close);
      expect((await fetch(proxy.source)).status, 502);
      expect(requests, 0);
    },
  );

  test(
    'HLS rewrites master, redirected media, key, map and byte ranges',
    () async {
      final server = await tlsServer();
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.toString());
        final response = request.response;
        switch (request.uri.path) {
          case '/start.m3u8':
            response.statusCode = 302;
            response.headers.set('location', '/cdn/master.m3u8');
          case '/cdn/master.m3u8':
            response.write(
              '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100,CODECS="avc1.4"\nsub/media.m3u8\n',
            );
          case '/cdn/sub/media.m3u8':
            response.statusCode = 302;
            response.headers.set('location', '/final/media/list.m3u8');
          case '/final/media/list.m3u8':
            response.write('''#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="../key.bin?token=secret"
#EXT-X-MAP:URI="../init.mp4",BYTERANGE="2@0"
#EXTINF:1,
one.ts
#EXT-X-BYTERANGE:2@1
../../shared.mp4
#EXTINF:1,
two.ts
#EXT-X-ENDLIST
''');
          case '/final/key.bin':
            response.add(List.filled(16, 42));
          case '/final/init.mp4':
            expect(request.headers.value('range'), 'bytes=0-1');
            response
              ..statusCode = 206
              ..headers.set('content-range', 'bytes 0-1/4')
              ..add([1, 2]);
          case '/shared.mp4':
            expect(request.headers.value('range'), 'bytes=1-2');
            response
              ..statusCode = 206
              ..headers.set('content-range', 'bytes 1-2/4')
              ..add([20, 30]);
          case '/final/media/one.ts':
            response.add([4, 5]);
          case '/final/media/two.ts':
            response.add([6, 7]);
          default:
            response.statusCode = 404;
        }
        await response.close();
      }, onError: (Object _) {});
      final proxy = await MotionArtworkProxy.start(
        Uri.parse('https://127.0.0.1:${server.port}/start.m3u8'),
        client: trustedFixtureClient(server),
      );
      addTearDown(proxy.close);
      final master = utf8.decode((await fetch(proxy.source)).bytes);
      final child = Uri.parse(master.split('\n').last);
      expect(child.scheme, 'http');
      expect(child.host, '127.0.0.1');
      final media = utf8.decode((await fetch(child)).bytes);
      expect(media, isNot(contains('https:')));
      expect(media, contains('#EXT-X-BYTERANGE:2@1'));
      expect(media, contains('BYTERANGE="2@0"'));
      final attributes = RegExp(
        r'URI="([^"]+)"',
      ).allMatches(media).map((match) => Uri.parse(match[1]!)).toList();
      final segments = const LineSplitter()
          .convert(media)
          .where((line) => line.isNotEmpty && !line.startsWith('#'))
          .map(Uri.parse)
          .toList();
      expect((await fetch(attributes[0])).bytes, List.filled(16, 42));
      expect((await fetch(attributes[1], range: 'bytes=0-1')).bytes, [1, 2]);
      expect((await fetch(segments[0])).bytes, [4, 5]);
      expect((await fetch(segments[1], range: 'bytes=1-2')).bytes, [20, 30]);
      expect((await fetch(segments[2])).bytes, [6, 7]);
      expect(paths, contains('/final/key.bin?token=secret'));
      expect(paths, contains('/cdn/sub/media.m3u8'));
      expect(paths, contains('/final/media/list.m3u8'));
    },
  );

  test(
    'binary responses start streaming before the upstream finishes',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final continueBody = Completer<void>();
      server.listen((request) async {
        request.response.add(List.filled(16384, 1));
        await request.response.flush();
        await continueBody.future;
        request.response.add(List.filled(1024 * 1024, 2));
        await request.response.close();
      });
      final proxy = await MotionArtworkProxy.start(
        Uri.parse('http://127.0.0.1:${server.port}/cover.mp4'),
      );
      addTearDown(proxy.close);
      final response = await (await reader.getUrl(proxy.source)).close();
      var bytes = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 2))) {
        bytes += chunk.length;
        if (!continueBody.isCompleted) continueBody.complete();
      }
      expect(bytes, 16384 + 1024 * 1024);
    },
  );

  test(
    'large declared MP4 supports partial reads and consumer cancellation',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final stop = Completer<void>();
      server.listen((request) async {
        expect(request.headers.value('range'), 'bytes=0-');
        request.response
          ..bufferOutput = false
          ..statusCode = 206
          ..headers.set('content-range', 'bytes 0-67108863/67108864')
          ..contentLength = 64 << 20
          ..add(List.filled(1024, 1));
        await request.response.flush();
        await stop.future;
        try {
          await request.response.close();
        } catch (_) {
          // FFmpeg stops after reading its clip instead of downloading 64 MiB.
        }
      });
      final proxy = await MotionArtworkProxy.start(
        Uri.parse('http://127.0.0.1:${server.port}/cover.mp4'),
        maxBytes: 4096,
      );
      addTearDown(proxy.close);
      final request = await reader.getUrl(proxy.source);
      request.headers.set('range', 'bytes=0-');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(response.contentLength, 64 << 20);
      final body = StreamIterator(response);
      expect(await body.moveNext(), isTrue);
      expect(body.current, everyElement(1));
      expect(proxy.isClosed, isFalse);
      await body.cancel();
      stop.complete();
    },
  );

  test(
    'gzip playlists rewrite URI attributes and preserve unrelated names',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.headers.set('content-encoding', 'gzip');
        request.response.add(
          gzip.encode(
            utf8.encode('''#EXTM3U
#EXT-X-UNKNOWN:SERVER-URI="urn:ignored",X-FOO-URI="file:///ignored"
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXTINF:1,
one.ts
#EXT-X-ENDLIST
'''),
          ),
        );
        await request.response.close();
      });
      final proxy = await MotionArtworkProxy.start(
        Uri.parse('http://127.0.0.1:${server.port}/opaque'),
      );
      addTearDown(proxy.close);
      expect(proxy.isHls, isFalse);
      final response = await fetch(proxy.source);
      expect(proxy.isHls, isTrue);
      expect(response.status, 200);
      expect(response.headers.value('content-encoding'), isNull);
      final text = utf8.decode(response.bytes);
      expect(
        text,
        contains('SERVER-URI="urn:ignored",X-FOO-URI="file:///ignored"'),
      );
      expect(text, contains('METHOD=AES-128,URI="http://127.0.0.1:'));
      expect(
        text.split('\n').where((line) => line.startsWith('http')).single,
        endsWith('.ts'),
      );
    },
  );

  test(
    'cumulative byte limit closes the proxy instead of retaining video',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response
          ..contentLength = 5
          ..add([1, 2, 3, 4, 5]);
        await request.response.close();
      });
      final proxy = await MotionArtworkProxy.start(
        Uri.parse('http://127.0.0.1:${server.port}/cover.mp4'),
        maxBytes: 8,
      );
      addTearDown(proxy.close);
      expect((await fetch(proxy.source)).bytes, [1, 2, 3, 4, 5]);
      await expectLater(fetch(proxy.source), throwsA(isA<HttpException>()));
      expect(proxy.isClosed, isTrue);
    },
  );

  test('deadline and close release their client and loopback server', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.write('video');
      await request.response.close();
    });
    final source = Uri.parse('http://127.0.0.1:${server.port}/cover.mp4');
    final client = HttpClient();
    final closed = await MotionArtworkProxy.start(source, client: client);
    await closed.close();
    await expectLater(fetch(closed.source), throwsA(isA<SocketException>()));
    expect(() => client.getUrl(source), throwsStateError);
    final proxy = await MotionArtworkProxy.start(
      source,
      lifetime: const Duration(milliseconds: 30),
    );
    addTearDown(proxy.close);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(proxy.isClosed, isTrue);
    await expectLater(fetch(proxy.source), throwsA(isA<SocketException>()));
  });

  test(
    'playlist references cannot enable local file or non-HTTP resources',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write(
          '#EXTM3U\n#EXT-X-KEY:URI="file:///private/key"\n',
        );
        await request.response.close();
      });
      final proxy = await MotionArtworkProxy.start(
        Uri.parse('http://127.0.0.1:${server.port}/cover.m3u8'),
      );
      addTearDown(proxy.close);
      expect((await fetch(proxy.source)).status, 502);
    },
  );
}
