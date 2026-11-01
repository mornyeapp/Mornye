import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_certificate.dart';
import 'package:mornye/services/network_storage_error.dart';
import 'package:mornye/services/network_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The native listing fallback needs a binding while TLS must use real I/O.
  HttpOverrides.global = null;

  test(
    'self-signed WebDAV requires explicit trust for listing and streaming',
    () async {
      final context = SecurityContext()
        ..useCertificateChain('test/fixtures/network_tls/cert.pem')
        ..usePrivateKey('test/fixtures/network_tls/key.pem');
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      addTearDown(() => server.close(force: true));
      final requests = <String>[];
      server.listen((request) async {
        requests.add(request.method);
        expect(
          request.headers.value('authorization'),
          'Basic ${base64Encode(utf8.encode('test:secret'))}',
        );
        if (request.uri.path == '/music') {
          request.response.statusCode = 301;
          request.response.headers.set('location', '/music/');
        } else if (request.method == 'PROPFIND') {
          expect(request.headers.value('depth'), '1');
          expect(await utf8.decoder.bind(request).join(), contains('propfind'));
          request.response.statusCode = 207;
          request.response.write('''<d:multistatus xmlns:d="DAV:">
          <d:response><d:href>http://192.168.1.20:5005/music/A%20B.flac</d:href><d:propstat>
          <d:prop><d:getcontentlength>4</d:getcontentlength></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>http://192.168.1.20:5005/music/</d:href><d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          </d:multistatus>''');
        } else {
          expect(request.headers.value('range'), 'bytes=1-2');
          request.response.statusCode = 206;
          request.response.headers.set('content-range', 'bytes 1-2/4');
          request.response.contentLength = 2;
          request.response.add([1, 2]);
        }
        await request.response.close();
      }, onError: (Object _) {}); // Expected TLS rejection before approval.
      String? stored;
      final service = NetworkStorageService(
        read: () async => stored,
        write: (value) async => stored = value,
      );
      addTearDown(service.dispose);
      NetworkConnection connection([String? fingerprint]) => NetworkConnection(
        id: 'fixture',
        name: 'NAS',
        protocol: NetworkProtocol.webdav,
        address: 'https://127.0.0.1:${server.port}/music',
        username: 'test',
        password: 'secret',
        trustedCertificateSha256: fingerprint,
      );
      NetworkCertificateException? rejected;
      try {
        await service.list(connection());
        fail('An untrusted certificate must be rejected');
      } on NetworkCertificateException catch (error) {
        rejected = error;
        expect(
          classifyNetworkStorageError(error),
          NetworkStorageError.certificate,
        );
        expect(error.origin, 'https://127.0.0.1:${server.port}');
        expect(error.fingerprint.length, 64);
      }
      expect(
        requests,
        isEmpty,
      ); // Credentials have not reached the untrusted server.
      final trusted = connection(rejected.fingerprint);
      expect((await service.list(trusted)).single.path, 'A B.flac');
      await service.save(trusted);
      final restored = NetworkStorageService(
        read: () async => stored,
        write: (_) async {},
      );
      addTearDown(restored.dispose);
      expect(
        (await restored.connection('fixture')).trustedCertificateSha256,
        rejected.fingerprint,
      );
      final url = await restored.resolve(
        NetworkStorageService.source('fixture', 'A B.flac'),
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('range', 'bytes=1-2');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(await response.expand((chunk) => chunk).toList(), [1, 2]);
      await expectLater(
        service.list(connection()),
        throwsA(isA<NetworkCertificateException>()),
      );
      await expectLater(
        service.list(connection('0' * 64)),
        throwsA(isA<NetworkCertificateException>()),
      );
    },
  );
}
