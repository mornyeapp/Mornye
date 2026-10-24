import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/client/link_client_http.dart';
import 'package:mornye/services/link/client/link_client_pairing.dart';
import 'package:mornye/services/link/link_protocol.dart';

const _device = LinkDeviceIdentity(
  deviceId: 'phone-1',
  name: 'Test phone',
  platform: 'android',
  appVersion: '1.0.0',
);

/// SHA-256 of the fixture certificate's DER bytes.
String _fixtureFingerprint() {
  final pem = File('test/fixtures/network_tls/cert.pem').readAsStringSync();
  final base64Body = pem
      .split('\n')
      .where((line) => line.isNotEmpty && !line.startsWith('-----'))
      .join();
  return sha256.convert(base64.decode(base64Body)).toString();
}

/// A desktop over TLS with the fixture certificate. [claimedFingerprint]
/// is what `info` reports; [onPair] answers `POST pair`.
Future<HttpServer> _desktop({
  required String claimedFingerprint,
  bool pairing = true,
  int protocol = linkProtocolVersion,
  Future<void> Function(HttpRequest request, Map<String, dynamic> body)? onPair,
}) async {
  final context = SecurityContext()
    ..useCertificateChain('test/fixtures/network_tls/cert.pem')
    ..usePrivateKey('test/fixtures/network_tls/key.pem');
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    context,
  );
  server.listen((request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    if (request.uri.path == '/mornye/v1/info') {
      response.write(
        jsonEncode({
          'serverId': 'server-1',
          'name': 'Studio PC',
          'protocol': protocol,
          'appVersion': '5.3.0',
          'fingerprint': claimedFingerprint,
          'pairing': pairing,
        }),
      );
    } else if (request.uri.path == '/mornye/v1/pair' &&
        request.method == 'POST') {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      await onPair?.call(request, body);
    } else {
      response.statusCode = 404;
    }
    await response.close();
  }, onError: (Object _) {});
  return server;
}

void main() {
  // TLS needs real sockets.
  HttpOverrides.global = null;
  final fingerprint = _fixtureFingerprint();

  group('pinned client', () {
    late HttpServer server;

    setUp(() async {
      server = await _desktop(claimedFingerprint: fingerprint);
    });
    tearDown(() => server.close(force: true));

    Uri info() => Uri.parse('https://127.0.0.1:${server.port}/mornye/v1/info');

    test('accepts exactly the pinned certificate', () async {
      final client = linkPinnedHttpClient(fingerprint.toUpperCase());
      addTearDown(() => client.close(force: true));
      final response = await linkHttpSend(client, 'GET', info());
      expect(response.statusCode, 200);
      expect(response.certificateFingerprint, fingerprint);
    });

    test('refuses any other certificate during the handshake', () async {
      final client = linkPinnedHttpClient('0' * 64);
      addTearDown(() => client.close(force: true));
      await expectLater(
        linkHttpSend(client, 'GET', info()),
        throwsA(isA<HandshakeException>()),
      );
    });

    test('first contact accepts only the target and records it', () async {
      final target = Uri.parse('https://127.0.0.1:${server.port}');
      final client = linkFirstContactHttpClient(target);
      addTearDown(() => client.close(force: true));
      final response = await linkHttpSend(client, 'GET', info());
      expect(response.certificateFingerprint, fingerprint);

      final other = linkFirstContactHttpClient(
        Uri.parse('https://127.0.0.1:${server.port + 1}'),
      );
      addTearDown(() => other.close(force: true));
      await expectLater(
        linkHttpSend(other, 'GET', info()),
        throwsA(isA<HandshakeException>()),
      );
    });
  });

  group('pairing', () {
    test('pairs with a proof over the observed fingerprint', () async {
      Map<String, dynamic>? sent;
      final server = await _desktop(
        claimedFingerprint: fingerprint,
        onPair: (request, body) async {
          sent = body;
          request.response.write(
            jsonEncode({
              'apiKey': 'key-1',
              'serverId': 'server-1',
              'name': 'Studio PC',
              'fingerprint': fingerprint,
            }),
          );
        },
      );
      addTearDown(() => server.close(force: true));
      final client = LinkPairingClient();
      final target = await client.probe(
        Uri.parse('https://127.0.0.1:${server.port}'),
        expectedFingerprint: fingerprint,
      );
      expect(target.address, 'https://127.0.0.1:${server.port}');
      expect(target.info.serverId, 'server-1');
      expect(target.info.pairing, isTrue);
      expect(target.shortFingerprint, fingerprint.substring(0, 8));

      final result = await client.pair(target, pin: '123456', device: _device);
      expect(result.apiKey, 'key-1');
      expect(result.serverId, 'server-1');
      expect(result.name, 'Studio PC');
      expect(result.fingerprint, fingerprint);
      expect(sent, {
        'deviceId': 'phone-1',
        'name': 'Test phone',
        'platform': 'android',
        'proof': linkPairingProof(
          pin: '123456',
          fingerprint: fingerprint,
          deviceId: 'phone-1',
        ),
      });
    });

    test('aborts when info claims another certificate', () async {
      final server = await _desktop(claimedFingerprint: 'a' * 64);
      addTearDown(() => server.close(force: true));
      await expectLater(
        LinkPairingClient().probe(
          Uri.parse('https://127.0.0.1:${server.port}'),
        ),
        throwsA(
          isA<LinkPairingException>().having(
            (e) => e.error,
            'error',
            LinkPairingError.certificateMismatch,
          ),
        ),
      );
    });

    test('aborts when mDNS advertised another certificate', () async {
      final server = await _desktop(claimedFingerprint: fingerprint);
      addTearDown(() => server.close(force: true));
      await expectLater(
        LinkPairingClient().probe(
          Uri.parse('https://127.0.0.1:${server.port}'),
          expectedFingerprint: 'b' * 64,
        ),
        throwsA(
          isA<LinkPairingException>().having(
            (e) => e.error,
            'error',
            LinkPairingError.certificateMismatch,
          ),
        ),
      );
    });

    test('refuses another protocol version', () async {
      final server = await _desktop(
        claimedFingerprint: fingerprint,
        protocol: 2,
      );
      addTearDown(() => server.close(force: true));
      await expectLater(
        LinkPairingClient().probe(
          Uri.parse('https://127.0.0.1:${server.port}'),
        ),
        throwsA(
          isA<LinkPairingException>().having(
            (e) => e.error,
            'error',
            LinkPairingError.incompatible,
          ),
        ),
      );
    });

    for (final (status, body, expected) in [
      (403, {'error': 'bad_proof'}, LinkPairingError.badPin),
      (403, {'error': 'pairing_closed'}, LinkPairingError.pairingClosed),
      (429, {'error': 'rate_limited'}, LinkPairingError.tooManyAttempts),
      (500, {'error': 'internal'}, LinkPairingError.failed),
    ]) {
      test('maps $status ${body['error']} to ${expected.name}', () async {
        final server = await _desktop(
          claimedFingerprint: fingerprint,
          onPair: (request, _) async {
            request.response.statusCode = status;
            request.response.write(jsonEncode(body));
          },
        );
        addTearDown(() => server.close(force: true));
        final client = LinkPairingClient();
        final target = await client.probe(
          Uri.parse('https://127.0.0.1:${server.port}'),
        );
        await expectLater(
          client.pair(target, pin: '000000', device: _device),
          throwsA(
            isA<LinkPairingException>().having(
              (e) => e.error,
              'error',
              expected,
            ),
          ),
        );
      });
    }

    test('a certificate swapped after info stops the pairing', () async {
      final server = await _desktop(claimedFingerprint: fingerprint);
      addTearDown(() => server.close(force: true));
      final target = LinkPairingTarget(
        address: 'https://127.0.0.1:${server.port}',
        info: LinkServerInfo(
          serverId: 'server-1',
          name: 'Studio PC',
          protocol: linkProtocolVersion,
          appVersion: '5.3.0',
          fingerprint: 'c' * 64,
          pairing: true,
        ),
      );
      await expectLater(
        LinkPairingClient().pair(target, pin: '123456', device: _device),
        throwsA(
          isA<LinkPairingException>().having(
            (e) => e.error,
            'error',
            LinkPairingError.certificateMismatch,
          ),
        ),
      );
    });

    test('rejects a PIN that is not six digits without a request', () async {
      final target = LinkPairingTarget(
        address: 'https://127.0.0.1:1',
        info: LinkServerInfo(
          serverId: 'server-1',
          name: 'Studio PC',
          protocol: linkProtocolVersion,
          appVersion: '5.3.0',
          fingerprint: fingerprint,
          pairing: true,
        ),
      );
      await expectLater(
        LinkPairingClient().pair(target, pin: '12a456', device: _device),
        throwsA(
          isA<LinkPairingException>().having(
            (e) => e.error,
            'error',
            LinkPairingError.badPin,
          ),
        ),
      );
    });

    test('an unreachable computer is reported as such', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      await expectLater(
        LinkPairingClient().probe(Uri.parse('https://127.0.0.1:$port')),
        throwsA(
          isA<LinkPairingException>().having(
            (e) => e.error,
            'error',
            LinkPairingError.unreachable,
          ),
        ),
      );
    });
  });

  group('fingerprint checks', () {
    test('need an observed certificate equal to every claim', () {
      expect(
        linkFingerprintsMatch(observed: 'ab', claimed: 'AB', advertised: 'ab'),
        isTrue,
      );
      expect(linkFingerprintsMatch(observed: null, claimed: 'ab'), isFalse);
      expect(linkFingerprintsMatch(observed: 'ab', claimed: 'cd'), isFalse);
      expect(
        linkFingerprintsMatch(observed: 'ab', claimed: 'ab', advertised: 'cd'),
        isFalse,
      );
    });

    test('server addresses accept hosts and refuse URLs', () {
      expect(
        linkServerAddress('192.168.1.20', 47710).toString(),
        'https://192.168.1.20:47710',
      );
      expect(
        linkServerAddress('fe80::2', 47710).toString(),
        'https://[fe80::2]:47710',
      );
      expect(
        linkServerAddress('[2001:db8::1]', 1).toString(),
        'https://[2001:db8::1]:1',
      );
      expect(linkServerAddress('', 47710), isNull);
      expect(linkServerAddress('host/path', 47710), isNull);
      expect(linkServerAddress('host:1', 47710), isNull);
      expect(linkServerAddress('host', 0), isNull);
      expect(linkServerAddress('host', 70000), isNull);
    });
  });
}
