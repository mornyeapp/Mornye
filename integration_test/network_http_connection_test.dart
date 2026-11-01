import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/secure_storage_options.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  var completed = 0;
  tearDownAll(() {
    binding.reportData = {
      'http_connection_cases': completed,
      'platform': Platform.operatingSystem,
    };
  });

  for (final redirect in [false, true]) {
    testWidgets(
      'HTTP verifies and saves through native parsing and secure storage (redirect=$redirect)',
      (tester) async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          expect(request.method, 'GET');
          expect(
            request.headers.value('authorization'),
            'Basic ${base64Encode(utf8.encode('fixture:secret'))}',
          );
          await request.drain<void>();
          if (redirect && request.uri.path == '/music') {
            request.response.statusCode = HttpStatus.seeOther;
            request.response.headers.set('location', '/music/');
          } else {
            request.response.headers.contentType = ContentType.html;
            request.response.write(
              '<html><a href="Album/">Album/</a><a href="A%20B.flac">A B.flac</a></html>',
            );
          }
          await request.response.close();
        });
        const secrets = FlutterSecureStorage(
          aOptions: secureStorageAndroidOptions,
          mOptions: secureStorageMacOsOptions,
        );
        final key = 'network_http_regression_$redirect';
        addTearDown(() => secrets.delete(key: key));
        final storage = NetworkStorageService(
          read: () => secrets.read(key: key),
          write: (value) => secrets.write(key: key, value: value),
        );
        addTearDown(storage.dispose);
        final connection = NetworkConnection(
          id: 'fixture-http',
          name: 'Fixture HTTP',
          protocol: NetworkProtocol.http,
          address:
              'http://127.0.0.1:${server.port}/${redirect ? 'music' : 'music/'}',
          username: 'fixture',
          password: 'secret',
        );
        final native = await PlatformBridge.runNativeDataJob(
          {
            'operation': 'parse_network_listing',
            'protocol': 'http',
            'base_url': connection.address,
            'path': '',
          },
          bytes: Uint8List.fromList(
            utf8.encode('<a href="native.flac">native.flac</a>'),
          ),
        );
        final nativeEntries = (native['entries'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        expect(nativeEntries.single['name'], 'native.flac');
        final entries = await storage.verify(connection);
        expect(entries.map((entry) => entry.path), ['Album/', 'A B.flac']);
        await storage.save(connection);
        final restored = NetworkStorageService(
          read: () => secrets.read(key: key),
          write: (_) async {},
        );
        addTearDown(restored.dispose);
        expect(
          (await restored.connection(connection.id)).toJson(),
          connection.toJson(),
        );
        completed++;
      },
    );
  }

  testWidgets('HTTP WebDAV accepts an advertised NAS origin through a tunnel', (
    tester,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.method, 'PROPFIND');
      await request.drain<void>();
      request.response.statusCode = HttpStatus.multiStatus;
      request.response.write(
        '<d:multistatus xmlns:d="DAV:">'
        '<d:response><d:href>http://192.168.1.20:8080/music/</d:href>'
        '<d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200</d:status></d:propstat></d:response>'
        '<d:response><d:href>http://192.168.1.20:8080/music/A%20B.flac</d:href>'
        '<d:propstat><d:prop><d:resourcetype/><d:getcontentlength>4</d:getcontentlength></d:prop><d:status>HTTP/1.1 200</d:status></d:propstat></d:response>'
        '</d:multistatus>',
      );
      await request.response.close();
    });
    final storage = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
    );
    addTearDown(storage.dispose);
    final connection = NetworkConnection(
      id: 'fixture-dav',
      name: 'Fixture DAV',
      protocol: NetworkProtocol.webdav,
      address: 'http://127.0.0.1:${server.port}/music/',
    );
    expect((await storage.verify(connection)).single.path, 'A B.flac');
    completed++;
  });
}
