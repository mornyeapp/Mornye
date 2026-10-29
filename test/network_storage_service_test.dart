import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/network_storage_error.dart';

NetworkConnection connection(
  String url, {
  NetworkProtocol protocol = NetworkProtocol.http,
  String id = 'server',
  String user = '',
  String password = '',
}) => NetworkConnection(
  id: id,
  name: 'Music server',
  protocol: protocol,
  address: url,
  username: user,
  password: password,
);

class _VirtualSources implements NetworkVirtualSources {
  bool connected = true;
  String? location;

  @override
  bool owns(String id) => id == 'phone';

  @override
  bool reachable(String id) => connected;

  @override
  Stream<NetworkVirtualSong> songs(String id) => const Stream.empty();

  @override
  Future<String> resolve(String id, String path) async =>
      location ?? '/received/$id/$path';

  @override
  Future<Map<String, dynamic>> metadata(String id, String path) async => {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Listing now crosses a method channel before the isolated host fallback.
  // Keep the in-process transport fixtures on real HTTP clients.
  HttpOverrides.global = null;

  test('paths retain literal percent, spaces, Unicode, plus and hash', () {
    final c = connection('https://example.test/Music%20Library/');
    const path = '日本語/100% + #1.flac';
    final uri = networkTarget(c, path);
    expect(uri.pathSegments, ['Music Library', '日本語', '100% + #1.flac']);
    expect(
      Uri.parse(NetworkStorageService.source('server', path)).pathSegments,
      ['日本語', '100% + #1.flac'],
    );
    for (final invalid in [
      '../secret',
      '/secret',
      'a/../b',
      'a\\b',
      'a\u0000b',
    ]) {
      expect(() => networkTarget(c, invalid), throwsFormatException);
    }
  });

  test(
    'single HTTP byte ranges include suffix and reject malformed ranges',
    () {
      expect(networkByteRange(null, 10), (start: 0, end: 9));
      expect(networkByteRange('bytes=3-', 10), (start: 3, end: 9));
      expect(networkByteRange('bytes=-4', 10), (start: 6, end: 9));
      expect(networkByteRange('bytes=5-20', 10), (start: 5, end: 9));
      for (final range in [
        'bytes=10-',
        'bytes=-0',
        'bytes=5-2',
        'bytes=0-1,3-4',
        'bytes=-',
      ]) {
        expect(() => networkByteRange(range, 10), throwsFormatException);
      }
    },
  );

  test(
    'HTML indexes are confined to immediate children of the configured root',
    () {
      final result = NetworkStorageService.parseListing(
        connection('https://example.test/music/'),
        '',
        '''
      <a href="../">Parent</a><a href="album/">Album</a>
      <a href="song%20%23%25.flac">Song</a><a href="song%20%23%25.flac">Duplicate</a>
      <a href="https://other.test/music/a.mp3">Other server</a>
      <a href="/outside/a.mp3">Outside root</a><a href="%2e%2e/secret.mp3">Traversal</a>
      <a href="a/b.mp3">Nested</a><a href="?sort=name">Sort</a>
    ''',
      );
      expect(result.map((e) => e.path), ['album/', 'song #%.flac']);
      expect(result.first.directory, true);
    },
  );

  test('WebDAV reads successful properties and encoded child paths only', () {
    final result = NetworkStorageService.parseListing(
      connection('https://example.test/dav/', protocol: NetworkProtocol.webdav),
      'Album/',
      '''
      <d:multistatus xmlns:d="DAV:">
        <d:response><d:href>/dav/Album/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/dav/Album/A%20B.flac</d:href><d:propstat><d:prop><d:getcontentlength>123</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/dav/Album/Missing.flac</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
      </d:multistatus>''',
    );
    expect(result.single.path, 'Album/A B.flac');
    expect(result.single.size, 123);
  });

  test('WebDAV retains only successful modification dates and ETags', () {
    for (final date in ['Mon, 19 Oct 2026 12:00:00 GMT', 'invalid', '']) {
      final result = NetworkStorageService.parseListing(
        connection(
          'https://example.test/dav/',
          protocol: NetworkProtocol.webdav,
        ),
        '',
        '<d:multistatus xmlns:d="DAV:"><d:response>'
            '<d:href>/dav/song.flac</d:href><d:propstat><d:prop>'
            '<d:getcontentlength>123</d:getcontentlength>'
            '<d:getlastmodified>$date</d:getlastmodified>'
            '<d:getetag>&quot;revision-1&quot;</d:getetag>'
            '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
            '<d:propstat><d:prop><d:getetag>invalid-etag</d:getetag>'
            '</d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>'
            '</d:response></d:multistatus>',
      );
      expect(result.single.etag, '"revision-1"');
      expect(
        result.single.modifiedTime,
        date.startsWith('Mon')
            ? DateTime.utc(2026, 10, 19, 12).millisecondsSinceEpoch
            : null,
      );
    }
  });

  test('WebDAV accepts equivalent encoding of parent folder names', () {
    final server = connection(
      'https://example.test/dav/',
      protocol: NetworkProtocol.webdav,
    );
    for (final folder in [
      'Rock & Roll',
      'Artist + Band',
      'Album [Deluxe]',
      "Artist's Album",
      'हिन्दी 音楽',
    ]) {
      final href = '/dav/${Uri.encodeComponent(folder)}/A%20%26%20B.flac';
      final entries = NetworkStorageService.parseListing(
        server,
        '$folder/',
        '<d:multistatus xmlns:d="DAV:"><d:response><d:href>$href</d:href>'
            '<d:propstat><d:prop><d:getcontentlength>123</d:getcontentlength>'
            '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
            '</d:response></d:multistatus>',
      );
      expect(
        entries.map((entry) => entry.path),
        ['$folder/A & B.flac'],
        reason:
            'Requested ${networkTarget(server, '$folder/')} but href was $href',
      );
    }
  });

  test(
    'concurrent saves persist both connections and retain credentials privately',
    () async {
      String? stored;
      final service = NetworkStorageService(
        read: () async => stored,
        write: (s) async {
          stored = s;
        },
      );
      final empty = await service.connections();
      await Future.wait([
        service.save(
          connection(
            'https://example.test/',
            id: 'one',
            user: 'user',
            password: 'secret',
          ),
        ),
        service.save(
          connection(
            'smb://server/music/',
            id: 'two',
            protocol: NetworkProtocol.smb,
          ),
        ),
      ]);
      final saved = await service.connections();
      expect(empty, isEmpty);
      expect(saved.length, 2);
      expect(await service.connections(), same(saved));
      expect(() => saved.clear(), throwsUnsupportedError);
      final restored = NetworkStorageService(
        read: () async => stored,
        write: (_) async {},
      );
      final loaded = await restored.connections();
      expect(await restored.connections(), same(loaded));
      expect(() => loaded.clear(), throwsUnsupportedError);
      expect((await restored.connection('one')).password, 'secret');
      final source = NetworkStorageService.source('one', 'test.flac');
      expect(source, 'network://one/test.flac');
      await service.remove('one');
      final removed = await service.connections();
      expect(removed.single.id, 'two');
      expect(await service.connections(), same(removed));
      expect(saved.length, 2);
      expect(() => removed.clear(), throwsUnsupportedError);
    },
  );

  test('virtual hosts resolve through their owner, not a connection', () async {
    String? stored;
    final service = NetworkStorageService(
      read: () async => stored,
      write: (value) async => stored = value,
    );
    expect(service.virtualFor('phone'), isNull);
    final sources = _VirtualSources();
    service.virtualSources = sources;
    expect(service.virtualFor('phone'), same(sources));
    expect(service.virtualFor('nas'), isNull);
    expect(
      await service.resolve('network://phone/song.flac'),
      '/received/phone/song.flac',
    );
    await expectLater(
      service.resolve('network://phone/song.flac?x=1'),
      throwsFormatException,
    );
    await expectLater(
      service.resolve('network://nas/song.flac'),
      throwsStateError,
    );
    // Saved connections never list them.
    expect(await service.connections(), isEmpty);
    expect(stored, isNull);
  });

  test('virtual hosts answer covers with their local files only', () async {
    final service = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
    );
    final sources = _VirtualSources();
    service.virtualSources = sources;
    final temp = await Directory.systemTemp.createTemp('virtual-cover-');
    addTearDown(() => temp.delete(recursive: true));
    const png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    final cover = File('${temp.path}/cover.png')..writeAsBytesSync(png);
    for (final location in [cover.path, cover.uri.toString()]) {
      sources.location = location;
      final output = File('${temp.path}/copy.image');
      await service.downloadCover('network://phone/cover.png', output);
      expect(await output.readAsBytes(), png);
    }
    // A URL from a virtual source streams a song on its way.
    sources.location = 'http://127.0.0.1:9/stream';
    final output = File('${temp.path}/url.image');
    await expectLater(
      service.downloadCover('network://phone/cover.png', output),
      throwsA(isA<HttpException>()),
    );
    expect(await output.exists(), isFalse);
    await expectLater(
      service.downloadCover('network://phone/cover.png?size=1', output),
      throwsFormatException,
    );
  });

  test('a network song can play while its host is reachable', () async {
    final service = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
    );
    // A phone's songs after Link stopped belong to no host.
    expect(await service.reachable('network://phone/song.flac'), isFalse);
    final sources = _VirtualSources();
    service.virtualSources = sources;
    expect(await service.reachable('network://phone/song.flac'), isTrue);
    sources.connected = false;
    expect(await service.reachable('network://phone/song.flac'), isFalse);

    await service.save(
      connection(
        'smb://server/music/',
        id: 'nas',
        protocol: NetworkProtocol.smb,
      ),
    );
    expect(await service.reachable('network://nas/song.flac'), isTrue);
    service.setReachable('nas', reachable: false);
    expect(await service.reachable('network://nas/song.flac'), isFalse);
    expect(await service.reachable('network://gone/song.flac'), isFalse);
  });

  group('real HTTP transport', () {
    late HttpServer server;
    late NetworkStorageService service;
    late String origin;
    final requests = <String>[];
    List<List<int>>? listingChunks;
    const cover = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4];
    setUp(() async {
      requests.clear();
      listingChunks = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin = 'http://127.0.0.1:${server.port}';
      service = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
      );
      server.listen((r) async {
        requests.add('${r.method} ${r.uri.path}');
        if (r.headers.value(HttpHeaders.authorizationHeader) !=
            'Basic ${base64Encode(utf8.encode('test:secret'))}') {
          r.response.statusCode = 401;
        } else if (r.uri.path == '/music') {
          r.response.statusCode = 301;
          r.response.headers.set('location', '/music/');
        } else if (r.uri.path == '/external') {
          r.response.statusCode = 302;
          r.response.headers.set('location', 'https://elsewhere.invalid/');
        } else if (r.uri.path == '/chunks/') {
          try {
            for (final chunk in listingChunks!) {
              r.response.add(chunk);
              await r.response.flush();
            }
            await r.response.close();
          } on SocketException {
            // The client closes the response when it exceeds the size limit.
          } on HttpException {
            // A rejected response can also fail an in-flight flush.
          }
          return;
        } else if (r.uri.path.startsWith('/art/')) {
          try {
            final name = r.uri.pathSegments.last;
            r.response.headers.contentType = ContentType('image', 'jpeg');
            if (name == 'cover.jpg') {
              r.response.add(cover);
            } else if (name == 'page.jpg') {
              r.response.headers.contentType = ContentType.html;
              r.response.write('<html>Sign in</html>');
            } else if (name == 'large.jpg' || name == 'unsized.jpg') {
              if (name == 'large.jpg') {
                r.response.contentLength =
                    NetworkStorageService.maxCoverBytes + 1;
              }
              for (var mebibyte = 0; mebibyte < 16; mebibyte++) {
                r.response.add(Uint8List(1024 * 1024));
                await r.response.flush();
              }
              r.response.add([0]);
            } else {
              r.response.statusCode = 404;
            }
            await r.response.close();
          } on IOException {
            // The client stops reading a cover it rejects.
          }
          return;
        } else if (r.method == 'PROPFIND') {
          expect(r.headers.value('Depth'), '1');
          await r.drain<void>();
          r.response.statusCode = 207;
          r.response.write(
            '<d:multistatus xmlns:d="DAV:"><d:response><d:href>/music/A%20B.flac</d:href><d:propstat><d:prop><d:getcontentlength>10</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>',
          );
        } else if (r.uri.path.endsWith('/')) {
          r.response.write('<a href="A%20B.flac">Audio</a>');
        } else {
          final part = networkByteRange(r.headers.value('range'), 10);
          r.response.statusCode = r.headers.value('range') == null ? 200 : 206;
          r.response.headers.set('content-type', 'audio/flac');
          r.response.headers.set('accept-ranges', 'bytes');
          r.response.headers.set(
            'content-range',
            'bytes ${part.start}-${part.end}/10',
          );
          r.response.contentLength = part.end - part.start + 1;
          if (r.method != 'HEAD') {
            r.response.add(
              List.generate(10, (i) => i).sublist(part.start, part.end + 1),
            );
          }
        }
        await r.response.close();
      });
    });
    tearDown(() async {
      await service.dispose();
      await server.close(force: true);
    });

    test('chunked listings preserve Unicode and malformed UTF-8', () async {
      final body = [
        ...utf8.encode('<a href="日本語.flac">'),
        0xff,
        ...utf8.encode('</a><a href="Album/">Album</a>'),
      ];
      // One-byte writes split both three-byte code points and HTML tokens.
      listingChunks = [
        for (final byte in body) [byte],
      ];
      final c = connection('$origin/chunks/', user: 'test', password: 'secret');
      final entries = await service.list(c);
      expect(entries.map((entry) => entry.path), ['Album/', '日本語.flac']);
      expect(entries.last.name, '日本語.flac');
      expect(entries.first.directory, true);
    });

    test(
      'listing size limit accepts 4 MiB and rejects the next byte',
      () async {
        const limit = 4 * 1024 * 1024;
        final body = Uint8List(limit + 1)..fillRange(0, limit + 1, 32);
        final prefix = utf8.encode('<a href="Song.flac">Song</a>');
        body.setRange(0, prefix.length, prefix);
        listingChunks = [
          for (var offset = 0; offset < limit; offset += 64 * 1024)
            Uint8List.sublistView(body, offset, offset + 64 * 1024),
        ];
        final c = connection(
          '$origin/chunks/',
          user: 'test',
          password: 'secret',
        );
        expect((await service.list(c)).single.name, 'Song.flac');
        listingChunks = [...listingChunks!, Uint8List.sublistView(body, limit)];
        await expectLater(
          service.list(c),
          throwsA(
            isA<HttpException>().having(
              (error) => error.message,
              'message',
              'Directory listing is too large',
            ),
          ),
        );
      },
    );

    test('a server marked out of reach fails fast until it answers', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      await service.save(connection('http://127.0.0.1:$port/', id: 'gone'));
      await service.save(connection('$origin/music/'));
      final gone = NetworkStorageService.source('gone', 'A B.flac');
      final back = NetworkStorageService.source('server', 'A B.flac');

      service.setReachable('gone', reachable: false);
      await expectLater(service.resolve(gone), throwsA(isA<SocketException>()));
      service.setReachable('gone', reachable: true);
      expect(await service.resolve(gone), startsWith('http://127.0.0.1:'));

      // A server that answers again plays as usual.
      service.setReachable('server', reachable: false);
      expect(await service.resolve(back), startsWith('http://127.0.0.1:'));
    });

    test('covers are read over the connection, up to 16 MiB', () async {
      final c = connection('$origin/art/', user: 'test', password: 'secret');
      await service.save(c);
      final temp = await Directory.systemTemp.createTemp('network-cover-');
      addTearDown(() => temp.delete(recursive: true));
      final output = File('${temp.path}/cover.image');
      await service.downloadCover(
        NetworkStorageService.source(c.id, 'cover.jpg'),
        output,
      );
      expect(await output.readAsBytes(), cover);
      expect(requests, ['GET /art/cover.jpg']);
      for (final (name, message) in [
        ('page.jpg', 'Network cover unavailable'),
        ('large.jpg', 'Network cover is too large'),
        ('unsized.jpg', 'Network cover is too large'),
        ('missing.jpg', 'Server returned 404'),
      ]) {
        await expectLater(
          service.downloadCover(
            NetworkStorageService.source(c.id, name),
            File('${temp.path}/$name'),
          ),
          throwsA(
            isA<HttpException>().having(
              (error) => error.message,
              'message',
              message,
            ),
          ),
          reason: name,
        );
      }
    });

    test('a cover of a server marked out of reach fails fast', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      await service.save(connection('http://127.0.0.1:$port/', id: 'gone'));
      service.setReachable('gone', reachable: false);
      final temp = await Directory.systemTemp.createTemp('network-cover-');
      addTearDown(() => temp.delete(recursive: true));
      final output = File('${temp.path}/cover.image');
      await expectLater(
        service.downloadCover(
          NetworkStorageService.source('gone', 'cover.jpg'),
          output,
        ),
        throwsA(
          isA<SocketException>().having(
            (error) => error.message,
            'message',
            'The server cannot be reached',
          ),
        ),
      );
      expect(await output.exists(), isFalse);
    });

    test(
      'authenticated listing, proxy range seek, HEAD, and revocation',
      () async {
        final c = connection(
          '$origin/music/',
          user: 'test',
          password: 'secret',
        );
        await service.save(c);
        expect((await service.list(c)).single.name, 'A B.flac');
        final url = await service.resolve(
          NetworkStorageService.source(c.id, 'A B.flac'),
        );
        expect(url, isNot(contains('secret')));
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set('range', 'bytes=4-7');
        final response = await request.close();
        expect(response.statusCode, 206);
        expect(response.headers.value('content-range'), 'bytes 4-7/10');
        expect(await response.expand((e) => e).toList(), [4, 5, 6, 7]);
        final head = await (await client.openUrl(
          'HEAD',
          Uri.parse(url),
        )).close();
        expect(head.contentLength, 10);
        await head.drain<void>();
        await service.remove(c.id);
        final removed = await (await client.getUrl(Uri.parse(url))).close();
        expect(removed.statusCode, 404);
        await removed.drain<void>();
      },
    );

    test('WebDAV and direct HTTP file validation use real requests', () async {
      final dav = connection(
        '$origin/music/',
        protocol: NetworkProtocol.webdav,
        user: 'test',
        password: 'secret',
      );
      expect((await service.list(dav)).single.size, 10);
      final direct = connection(
        '$origin/song.mp3',
        user: 'test',
        password: 'secret',
      );
      expect((await service.list(direct)).single.path, '');
      expect(requests, contains('GET /song.mp3'));
      await expectLater(
        service.list(connection('$origin/music/')),
        throwsA(isA<HttpException>()),
      );
    });

    test(
      'same origin redirects work; cross origin redirects cannot leak credentials',
      () async {
        expect(
          (await service.list(
            connection('$origin/music', user: 'test', password: 'secret'),
          )).single.audio,
          true,
        );
        await expectLater(
          service.list(
            connection('$origin/external', user: 'test', password: 'secret'),
          ),
          throwsA(isA<HttpException>()),
        );
      },
    );
  });

  test('SMB server browsing and byte-range streaming', () async {
    final port = Platform.environment['TEST_SMB_PORT'] ?? '1445';
    final service = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
    );
    addTearDown(service.dispose);
    final c = connection(
      'smb://127.0.0.1:$port/MUSIC/',
      protocol: NetworkProtocol.smb,
      user: 'test',
      password: 'secret',
    );
    await service.save(c);
    final shares = await service.list(
      connection(
        'smb://127.0.0.1:$port/',
        protocol: NetworkProtocol.smb,
        user: 'test',
        password: 'secret',
      ),
    );
    expect(
      shares.any((entry) => entry.name == 'MUSIC' && entry.directory),
      true,
    );
    final entries = await service.list(c);
    expect(entries.any((e) => e.name == 'A B.wav'), true);
    final domainConnection = NetworkConnection(
      id: c.id,
      name: c.name,
      protocol: c.protocol,
      address: c.address,
      username: c.username,
      password: c.password,
      domain: 'WORKGROUP',
    );
    expect(
      (await service.list(domainConnection)).any((e) => e.name == 'A B.wav'),
      true,
    );
    final withoutSlash = connection(
      'smb://127.0.0.1:$port/MUSIC',
      protocol: NetworkProtocol.smb,
      user: 'test',
      password: 'secret',
    );
    expect(
      (await service.list(withoutSlash)).any((e) => e.name == 'A B.wav'),
      true,
    );
    await expectLater(
      service.list(
        connection(
          'smb://127.0.0.1:$port/DOES_NOT_EXIST',
          protocol: NetworkProtocol.smb,
          user: 'test',
          password: 'secret',
        ),
      ),
      throwsA(
        predicate<Object>(
          (error) =>
              classifyNetworkStorageError(error) ==
              NetworkStorageError.missingShare,
        ),
      ),
    );
    final url = await service.resolve(
      NetworkStorageService.source(c.id, 'A B.wav'),
    );
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('range', 'bytes=4-7');
    final response = await request.close();
    expect(response.statusCode, 206);
    expect(await response.expand((e) => e).toList(), [4, 5, 6, 7]);
    final head = await client.headUrl(Uri.parse(url));
    final headResponse = await head.close();
    expect(headResponse.contentLength, 256);
    expect(await headResponse.expand((e) => e).toList(), isEmpty);
    final suffix = await client.getUrl(Uri.parse(url));
    suffix.headers.set('range', 'bytes=-3');
    final suffixResponse = await suffix.close();
    expect(await suffixResponse.expand((e) => e).toList(), [253, 254, 255]);
    await expectLater(
      service.list(
        connection(
          'smb://127.0.0.1:$port/MUSIC/',
          protocol: NetworkProtocol.smb,
          user: 'test',
          password: 'incorrect',
        ),
      ),
      throwsA(
        predicate<Object>(
          (error) =>
              classifyNetworkStorageError(error) ==
              NetworkStorageError.authentication,
        ),
      ),
    );
    expect((await service.list(c)).any((e) => e.name == 'A B.wav'), true);
  }, skip: Platform.environment['TEST_SMB'] != '1');
  test('SMB guest works when credentials are explicitly blank', () async {
    final port = Platform.environment['TEST_SMB_GUEST_PORT']!;
    final service = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
    );
    try {
      final guest = connection(
        'smb://127.0.0.1:$port/MUSIC/',
        protocol: NetworkProtocol.smb,
      );
      expect((await service.list(guest)).any((e) => e.name == 'A B.wav'), true);
    } finally {
      await service.dispose();
    }
  }, skip: Platform.environment['TEST_SMB_GUEST_PORT'] == null);
}
