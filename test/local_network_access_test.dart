import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/services/network_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/local_network');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  HttpOverrides.global = null;

  var granted = false;
  var allowRequest = true;
  var checks = 0;
  var requests = 0;
  Completer<bool>? pending;

  setUp(() {
    granted = false;
    allowRequest = true;
    checks = 0;
    requests = 0;
    pending = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isGranted') {
        checks++;
        return granted;
      }
      expect(call.method, 'request');
      requests++;
      return pending == null ? allowRequest : await pending!.future;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final host in [
    'nas',
    'nas.local',
    'NAS.LOCAL.',
    'nas.home.arpa',
    '10.0.0.1',
    '172.16.0.1',
    '172.31.255.254',
    '192.168.1.2',
    '169.254.1.1',
    '100.64.0.1',
    '[fd12::1]',
    '[fe80::1]',
    '[::ffff:192.168.1.2]',
  ]) {
    test('requests permission before local access to $host', () async {
      final access = LocalNetworkAccess(
        isAndroid: true,
        lookup: (_) async => fail('Local names must not be resolved first'),
      );
      await access.ensureAccess(Uri.parse('smb://$host/music/'));
      expect(checks, 1);
      expect(requests, 1);
    });
  }

  for (final host in [
    'localhost',
    'server.localhost',
    '127.0.0.1',
    '[::1]',
    '8.8.8.8',
    '172.32.0.1',
    '[2001:4860:4860::8888]',
  ]) {
    test('does not gate loopback or public address $host', () async {
      allowRequest = false;
      final access = LocalNetworkAccess(isAndroid: true);
      await access.ensureAccess(Uri.parse('https://$host/music/'));
      expect(requests, 0);
    });
  }

  test('older Android or a grant avoids DNS and permission requests', () async {
    granted = true;
    final access = LocalNetworkAccess(
      isAndroid: true,
      lookup: (_) async => fail('No DNS needed when access is allowed'),
    );
    await access.ensureAccess(Uri.parse('https://music.example.test/'));
    expect(requests, 0);
    expect(checks, 1);
  });

  test('other platforms do not call the Android permission channel', () async {
    final access = LocalNetworkAccess(isAndroid: false);
    await access.ensureAccess(Uri.parse('smb://nas.local/music/'));
    await access.ensureGranted();
    expect(checks, 0);
    expect(requests, 0);
  });

  test('ensureGranted requests without a target and reports denial', () async {
    final access = LocalNetworkAccess(
      isAndroid: true,
      lookup: (_) async => fail('No target to resolve'),
    );
    await access.ensureGranted();
    expect(requests, 1);
    granted = true;
    await access.ensureGranted();
    expect(requests, 1);
    granted = false;
    allowRequest = false;
    await expectLater(
      access.ensureGranted(),
      throwsA(isA<LocalNetworkPermissionException>()),
    );
    expect(requests, 2);
  });

  for (final local in [false, true]) {
    test(
      'DNS names resolving to ${local ? 'LAN' : 'public'} addresses',
      () async {
        final access = LocalNetworkAccess(
          isAndroid: true,
          lookup: (host) async {
            expect(host, 'music.example.test');
            return [InternetAddress(local ? '192.168.1.2' : '8.8.8.8')];
          },
        );
        await access.ensureAccess(Uri.parse('https://music.example.test/'));
        expect(requests, local ? 1 : 0);
      },
    );
  }

  test(
    'concurrent operations await one request and recheck revocation',
    () async {
      final access = LocalNetworkAccess(isAndroid: true);
      final target = Uri.parse('smb://nas.local/music/');
      pending = Completer<bool>();
      final ready = Future.wait(
        List.generate(6, (_) => access.ensureAccess(target)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(requests, 1);
      granted = true;
      pending!.complete(true);
      await ready;
      await access.ensureAccess(target);
      expect(requests, 1);
      granted = false;
      pending = null;
      allowRequest = false;
      await expectLater(
        access.ensureAccess(target),
        throwsA(isA<LocalNetworkPermissionException>()),
      );
      expect(requests, 2);
      allowRequest = true;
      await access.ensureAccess(target);
      expect(requests, 3);
    },
  );

  test(
    'denial stops SMB share enumeration, reads, writes and playback',
    () async {
      final seen = <Uri>[];
      final storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
        ensureAccess: (target) async {
          seen.add(target);
          throw const LocalNetworkPermissionException();
        },
      );
      addTearDown(storage.dispose);
      const root = NetworkConnection(
        id: 'nas',
        name: 'NAS',
        protocol: NetworkProtocol.smb,
        address: 'smb://nas.local/',
      );
      await storage.save(root);
      final denied = throwsA(isA<LocalNetworkPermissionException>());
      await expectLater(storage.list(root), denied);
      await expectLater(storage.list(root, 'Music/'), denied);
      final source = NetworkStorageService.source('nas', 'Music/song.flac');
      await expectLater(storage.resolve(source), denied);
      await expectLater(storage.deleteFile(source), denied);
      await expectLater(
        storage.prepareUpload(
          NetworkStorageService.source('nas', 'Music/'),
          '',
          'new.flac',
        ),
        denied,
      );
      expect(seen, hasLength(5));
    },
  );

  test('revoked permission blocks WebDAV before any server request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var serverRequests = 0;
    server.listen((request) async {
      serverRequests++;
      request.response.statusCode = 404;
      await request.response.close();
    });
    var allowed = true;
    final storage = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
      ensureAccess: (_) async {
        if (!allowed) throw const LocalNetworkPermissionException();
      },
    );
    addTearDown(() async {
      await storage.dispose();
      await server.close(force: true);
    });
    final connection = NetworkConnection(
      id: 'nas',
      name: 'NAS',
      protocol: NetworkProtocol.webdav,
      address: 'http://127.0.0.1:${server.port}/music/',
    );
    await storage.save(connection);
    await expectLater(storage.list(connection), throwsA(isA<HttpException>()));
    expect(serverRequests, 1);
    allowed = false;
    final denied = throwsA(isA<LocalNetworkPermissionException>());
    await expectLater(storage.list(connection), denied);
    await expectLater(
      storage.deleteFile(NetworkStorageService.source('nas', 'song.flac')),
      denied,
    );
    await expectLater(
      storage.prepareUpload(
        NetworkStorageService.source('nas', ''),
        '',
        'new.flac',
      ),
      denied,
    );
    expect(serverRequests, 1);
  });
}
