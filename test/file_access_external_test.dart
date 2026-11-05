import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/utils/file_access.dart';

class _LinkSources implements NetworkVirtualSources {
  _LinkSources(this.location);

  final String location;

  @override
  bool owns(String id) => id == 'paired-phone';
  @override
  bool reachable(String id) => true;
  @override
  Stream<NetworkVirtualSong> songs(String id) => const Stream.empty();
  @override
  Future<Map<String, dynamic>> metadata(String id, String path) async => {};
  @override
  Future<String> resolve(String id, String path) async => location;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => calls.add(call),
    );
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('authenticated cloud audio opens through its private proxy', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final authorization = <String?>[];
    server.listen((request) async {
      authorization.add(request.headers.value(HttpHeaders.authorizationHeader));
      request.response.headers.contentType = ContentType('audio', 'flac');
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    final storage = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
      ensureAccess: (_) async {},
    );
    addTearDown(storage.dispose);
    await storage.save(
      NetworkConnection(
        id: 'cloud',
        name: 'Cloud',
        protocol: NetworkProtocol.webdav,
        address: 'http://127.0.0.1:${server.port}/music/',
        username: 'listener',
        password: 'test-secret',
      ),
    );
    await openFile('network://cloud/song.flac', storage: storage);
    expect(calls.single.method, 'openContentUri');
    final args = (calls.single.arguments as Map).cast<String, dynamic>();
    expect(args['mime_type'], 'audio/flac');
    final uri = Uri.parse(args['uri'] as String);
    expect(uri.host, '127.0.0.1');
    expect(uri.port, isNot(server.port));
    expect(uri.userInfo, isEmpty);
    expect(uri.query, isEmpty);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(uri)).close();
    expect(await response.expand((chunk) => chunk).toList(), [1, 2, 3, 4]);
    expect(
      authorization,
      everyElement(
        'Basic ${base64Encode(utf8.encode('listener:test-secret'))}',
      ),
    );
    expect(authorization, isNotEmpty);
  });

  for (final location in [
    'http://127.0.0.1:12345/song.m4a?token=one-time',
    'content://provider/music/song.m4a',
  ]) {
    test(
      'Link sources hand their resolved location to the external app: $location',
      () async {
        final storage = NetworkStorageService(
          read: () async => null,
          write: (_) async {},
        )..virtualSources = _LinkSources(location);
        addTearDown(storage.dispose);
        await openFile('network://paired-phone/song.m4a', storage: storage);
        expect(calls.single.method, 'openContentUri');
        expect(calls.single.arguments, {
          'uri': location,
          'mime_type': location.startsWith('http') ? 'audio/mp4' : '',
        });
      },
    );
  }
}
