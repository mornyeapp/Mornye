import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/network_storage_service.dart';

// Android 17 requires ACCESS_LOCAL_NETWORK to be granted before this transport
// test. It deliberately exercises HTTP independently of the permission prompt.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'WebDAV HTTP lists and reads through a non-loopback Android address',
    (tester) async {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      final address = interfaces
          .expand((value) => value.addresses)
          .firstWhere((value) => !value.isLoopback && !value.isLinkLocal);
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      addTearDown(() => server.close(force: true));
      final methods = <String>[];
      server.listen((request) async {
        methods.add(request.method);
        expect(
          request.headers.value('authorization'),
          'Basic ${base64Encode(utf8.encode('fixture:secret'))}',
        );
        await request.drain<void>();
        if (request.method == 'PROPFIND') {
          request.response.statusCode = 207;
          request.response.write(
            '<d:multistatus xmlns:d="DAV:">'
            '<d:response><d:href>/music/Song.flac</d:href><d:propstat><d:prop>'
            '<d:getcontentlength>4</d:getcontentlength></d:prop>'
            '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
            '</d:multistatus>',
          );
        } else {
          request.response.statusCode = 206;
          request.response.headers.set('Content-Range', 'bytes 0-3/4');
          request.response.contentLength = 4;
          request.response.add([1, 2, 3, 4]);
        }
        await request.response.close();
      });
      final storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
        // Isolate HTTP policy from the separate runtime LAN permission gate.
        ensureAccess: (_) async {},
      );
      addTearDown(storage.dispose);
      final connection = NetworkConnection(
        id: 'fixture',
        name: 'HTTP NAS',
        protocol: NetworkProtocol.webdav,
        address: 'http://${address.address}:${server.port}/music/',
        username: 'fixture',
        password: 'secret',
      );
      final entries = await storage.list(connection);
      expect(entries.single.name, 'Song.flac');
      await storage.save(connection);
      final url = await storage.resolve('network://fixture/Song.flac');
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('Range', 'bytes=0-3');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(await response.expand((value) => value).toList(), [1, 2, 3, 4]);
      expect(methods, ['PROPFIND', 'GET']);
    },
  );
}
