import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_storage_service.dart';

String _listing(String body) =>
    '<d:multistatus xmlns:d="DAV:">$body</d:multistatus>';

String _entry(
  String href, {
  bool directory = false,
  String status = '200 OK',
}) =>
    '<d:response><d:href>$href</d:href><d:propstat><d:prop>'
    '<d:resourcetype>${directory ? '<d:collection/>' : ''}</d:resourcetype>'
    '<d:getcontentlength>4</d:getcontentlength></d:prop>'
    '<d:status>HTTP/1.1 $status</d:status></d:propstat></d:response>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  for (final advertised in [
    'https://127.0.0.1:5006',
    'http://192.168.1.20:5005',
  ]) {
    test(
      'HTTP WebDAV retains its transport when the NAS advertises $advertised',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final requests = <String>[];
        server.listen((request) async {
          expect(
            request.headers.value('authorization'),
            'Basic ${base64Encode(utf8.encode('test:secret'))}',
          );
          await request.drain<void>();
          requests.add('${request.method} ${request.uri}');
          if (request.method == 'PROPFIND') {
            request.response.statusCode = HttpStatus.multiStatus;
            final root = '$advertised${request.uri.path}';
            request.response.write(
              _listing(
                (request.uri.path == '/music/'
                        ? _entry('${root}Album/', directory: true)
                        : _entry('${root}A%20B.flac')) +
                    _entry(root, directory: true),
              ),
            );
          } else {
            expect(request.uri.toString(), '/music/Album/A%20B.flac');
            expect(request.headers.value('range'), 'bytes=1-2');
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set('content-range', 'bytes 1-2/4');
            request.response.contentLength = 2;
            request.response.add([1, 2]);
          }
          await request.response.close();
        });
        final storage = NetworkStorageService(
          read: () async => null,
          write: (_) async {},
        );
        addTearDown(storage.dispose);
        final connection = NetworkConnection(
          id: 'nas',
          name: 'NAS',
          protocol: NetworkProtocol.webdav,
          address: 'http://127.0.0.1:${server.port}/music/',
          username: 'test',
          password: 'secret',
        );
        await storage.save(connection);
        final albums = await storage.list(connection);
        expect(albums.single.path, 'Album/');
        final tracks = await storage.list(connection, albums.single.path);
        expect(tracks.single.path, 'Album/A B.flac');
        final location = await storage.resolve(
          NetworkStorageService.source(connection.id, tracks.single.path),
        );
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final request = await client.getUrl(Uri.parse(location));
        request.headers.set('range', 'bytes=1-2');
        final response = await request.close();
        expect(response.statusCode, HttpStatus.partialContent);
        expect(await response.expand((chunk) => chunk).toList(), [1, 2]);
        expect(requests, [
          'PROPFIND /music/',
          'PROPFIND /music/Album/',
          'GET /music/Album/A%20B.flac',
        ]);
      },
    );
  }

  test(
    'successful WebDAV property statuses do not require a reason phrase',
    () {
      const connection = NetworkConnection(
        id: 'nas',
        name: 'NAS',
        protocol: NetworkProtocol.webdav,
        address: 'http://nas.test/music/',
      );
      for (final status in ['200', '200 ', '200 OK']) {
        final result = NetworkStorageService.parseListing(
          connection,
          '',
          _listing(_entry('/music/song.flac', status: status)),
        );
        expect(result.single.name, 'song.flac');
      }
    },
  );

  test(
    'non-WebDAV pages cannot masquerade as an empty WebDAV directory',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.html;
        request.response.write('<html><body>Please sign in</body></html>');
        await request.response.close();
      });
      final storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
      );
      addTearDown(storage.dispose);
      await expectLater(
        storage.list(
          NetworkConnection(
            id: 'nas',
            name: 'NAS',
            protocol: NetworkProtocol.webdav,
            address: 'http://127.0.0.1:${server.port}/music/',
          ),
        ),
        throwsA(isA<HttpException>()),
      );
    },
  );
}
