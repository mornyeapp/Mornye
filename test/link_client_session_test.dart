import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/client/link_client_pairing.dart';
import 'package:mornye/services/link/client/link_client_session.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';

const _device = LinkDeviceIdentity(
  deviceId: 'phone-1',
  name: 'Test phone',
  platform: 'ios',
  appVersion: '5.3.0',
);

LinkServerRecord _record(String address) => LinkServerRecord(
  serverId: 'server-1',
  name: 'Studio PC',
  connectionId: 'connection-1',
  address: address,
  fingerprint: 'f' * 64,
);

const _welcome = {
  'type': 'welcome',
  'serverId': 'server-1',
  'name': 'Studio PC',
  'protocol': 1,
};

class _FakeTimer implements Timer {
  _FakeTimer(this._run);

  final void Function() _run;
  var _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _run();
  }
}

/// Records requested delays; tests fire retries by hand.
class _Timers {
  final delays = <Duration>[];
  final timers = <_FakeTimer>[];

  Timer call(Duration delay, void Function() run) {
    delays.add(delay);
    final timer = _FakeTimer(run);
    timers.add(timer);
    return timer;
  }

  _FakeTimer get last => timers.last;
}

class _FakeSocket implements LinkSocket {
  _FakeSocket({this.welcome = _welcome, this.closeBeforeWelcome});

  final Map<String, dynamic>? welcome;
  final int? closeBeforeWelcome;
  final incoming = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  int? _closeCode;
  bool closed = false;

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  void add(String data) {
    final message = jsonDecode(data) as Map<String, dynamic>;
    sent.add(message);
    if (message['type'] != 'hello') return;
    scheduleMicrotask(() {
      if (closeBeforeWelcome case final code?) {
        serverClose(code);
      } else if (welcome case final reply?) {
        incoming.add(jsonEncode(reply));
      }
    });
  }

  void push(Map<String, dynamic> message) => incoming.add(jsonEncode(message));

  void serverClose([int code = 1001]) {
    _closeCode = code;
    unawaited(incoming.close());
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    closed = true;
    _closeCode ??= code;
    unawaited(incoming.close());
  }
}

void main() {
  group('requests', () {
    late HttpServer server;
    late LinkClientSession session;
    final requests = <HttpRequest>[];
    final bodies = <String>[];

    setUp(() async {
      requests.clear();
      bodies.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests.add(request);
        bodies.add(await utf8.decoder.bind(request).join());
        final response = request.response;
        switch (request.uri.path) {
          case '/mornye/v1/state':
            response.headers.contentType = ContentType.json;
            response.write(jsonEncode({'playing': true}));
          case '/mornye/v1/handoff/play':
            response.headers.contentType = ContentType.json;
            response.write(jsonEncode({'resolved': 2, 'missing': <String>[]}));
          case '/mornye/v1/open':
            response.statusCode = 204;
          case final path when path.startsWith('/mornye/v1/files/'):
            response.headers.contentType = ContentType.json;
            response.write(jsonEncode({'name': request.uri.pathSegments.last}));
          case '/mornye/v1/secret':
            response.statusCode = 401;
          default:
            response.statusCode = 404;
            response.headers.contentType = ContentType.json;
            response.write(
              jsonEncode({'error': 'not_found', 'message': 'No handler'}),
            );
        }
        await response.close();
      });
      session = LinkClientSession(
        server: _record('http://127.0.0.1:${server.port}'),
        apiKey: 'key-1',
        device: _device,
        httpClient: (_) => HttpClient(),
        ensureAccess: (_) async {},
      );
    });

    tearDown(() async {
      await session.dispose();
      await server.close(force: true);
    });

    test('GET sends the bearer key and query, and decodes JSON', () async {
      final result = await session.get(LinkOps.state, {'since': '5'});
      expect(result, {'playing': true});
      final request = requests.single;
      expect(request.method, 'GET');
      expect(request.uri.path, '/mornye/v1/state');
      expect(request.uri.queryParameters, {'since': '5'});
      expect(request.headers.value('authorization'), 'Bearer key-1');
      expect(request.headers.value('accept'), 'application/json');
    });

    for (final upload in [false, true]) {
      test(
        '${upload ? 'upload' : 'GET'} cannot reopen a disposed session after permission resolves',
        () async {
          final permission = Completer<void>();
          final checkingPermission = Completer<void>();
          final clients = <HttpClient>[];
          final delayed = LinkClientSession(
            server: session.server,
            apiKey: 'key-1',
            device: _device,
            httpClient: (_) {
              final client = HttpClient();
              clients.add(client);
              return client;
            },
            ensureAccess: (_) {
              checkingPermission.complete();
              return permission.future;
            },
          );
          addTearDown(() async {
            await delayed.dispose();
            for (final client in clients) {
              client.close(force: true);
            }
          });
          final directory = await Directory.systemTemp.createTemp(
            'link-close-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final file = await File(
            '${directory.path}/song.flac',
          ).writeAsString('fLaC data');
          final pending = upload
              ? delayed.upload('${linkFileIdFor(file.path, 9)}.flac', file)
              : delayed.get(LinkOps.state);
          final rejected = expectLater(
            pending,
            throwsA(
              isA<LinkException>().having(
                (error) => error.code,
                'code',
                'unavailable',
              ),
            ),
          );
          await checkingPermission.future;
          await delayed.dispose();
          permission.complete();
          await rejected;
          expect(clients, isEmpty);
          expect(requests, isEmpty);
        },
      );
    }

    test('POST sends a JSON body to a nested op', () async {
      final result = await session.post(LinkOps.handoffPlay, {
        'index': 1,
        'queue': <Object?>[],
      });
      expect(result, {'resolved': 2, 'missing': <Object?>[]});
      expect(requests.single.method, 'POST');
      expect(requests.single.headers.contentType?.mimeType, 'application/json');
      expect(jsonDecode(bodies.single), {'index': 1, 'queue': <Object?>[]});
    });

    test('an empty success answers null', () async {
      expect(await session.post(LinkOps.open, {'url': 'x'}), isNull);
    });

    test('upload PUTs the file under files/<name>', () async {
      final dir = await Directory.systemTemp.createTemp('link_upload_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/song.flac');
      await file.writeAsString('fLaC data');
      final name = '${linkFileIdFor(file.path, 9)}.flac';
      final progress = <int>[];
      await session.upload(name, file, onProgress: progress.add);
      final request = requests.single;
      expect(request.method, 'PUT');
      expect(request.uri.path, '/mornye/v1/files/$name');
      expect(request.headers.value('authorization'), 'Bearer key-1');
      expect(request.headers.contentLength, 9);
      expect(bodies.single, 'fLaC data');
      expect(progress.last, 9);
    });

    test('an upload name that is not an id and format is refused', () async {
      final file = File('unused.flac');
      for (final name in ['../a.flac', '${'0' * 32}.exe', 'song.flac']) {
        await expectLater(
          session.upload(name, file),
          throwsA(
            isA<LinkException>().having((e) => e.code, 'code', 'invalid'),
          ),
        );
      }
      expect(requests, isEmpty);
    });

    test('error bodies become LinkException', () async {
      await expectLater(
        session.get('missing'),
        throwsA(
          isA<LinkException>()
              .having((e) => e.code, 'code', 'not_found')
              .having((e) => e.message, 'message', 'No handler'),
        ),
      );
    });

    test('a bare 401 is unauthorized and marks the session', () async {
      await expectLater(
        session.get('secret'),
        throwsA(
          isA<LinkException>().having((e) => e.code, 'code', 'unauthorized'),
        ),
      );
      expect(session.issue, LinkSessionIssue.unauthorized);
    });

    test('operations outside the API path are refused locally', () async {
      for (final op in [
        '../rest/ping',
        'library/../../rest',
        './state',
        '/state',
        'a//b',
        'state?x=1',
        '',
      ]) {
        await expectLater(
          session.get(op),
          throwsA(
            isA<LinkException>().having((e) => e.code, 'code', 'invalid'),
          ),
        );
      }
      expect(requests, isEmpty);
    });

    test('an unreachable desktop is unavailable', () async {
      final port = server.port;
      await server.close(force: true);
      final offline = LinkClientSession(
        server: _record('http://127.0.0.1:$port'),
        apiKey: 'key-1',
        device: _device,
        httpClient: (_) => HttpClient(),
        ensureAccess: (_) async {},
      );
      addTearDown(offline.dispose);
      await expectLater(
        offline.get(LinkOps.state),
        throwsA(
          isA<LinkException>().having((e) => e.code, 'code', 'unavailable'),
        ),
      );
    });
  });

  group('WebSocket', () {
    test('says hello, waits for welcome and relays messages', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final hello = Completer<Map<String, dynamic>>();
      final fromPhone = StreamController<Map<String, dynamic>>();
      addTearDown(fromPhone.close);
      WebSocket? desktop;
      String? authorization;
      server.listen((request) async {
        authorization = request.headers.value('authorization');
        desktop = await WebSocketTransformer.upgrade(request);
        desktop!.listen((data) {
          final message = jsonDecode(data as String) as Map<String, dynamic>;
          if (!hello.isCompleted) {
            hello.complete(message);
            desktop!.add(jsonEncode(_welcome));
          } else {
            fromPhone.add(message);
          }
        });
      });
      final timers = _Timers();
      final session = LinkClientSession(
        server: _record('http://127.0.0.1:${server.port}'),
        apiKey: 'key-1',
        device: _device,
        httpClient: (_) => HttpClient(),
        ensureAccess: (_) async {},
        timer: timers.call,
      );
      addTearDown(session.dispose);
      final states = <LinkConnectionState>[];
      session.connectionStates.listen(states.add);
      final messages = <Map<String, dynamic>>[];
      session.messages.listen(messages.add);

      session.start();
      await session.connectionStates
          .firstWhere((s) => s == LinkConnectionState.connected)
          .timeout(const Duration(seconds: 5));
      expect(authorization, 'Bearer key-1');
      expect(await hello.future, {
        'type': 'hello',
        'deviceId': 'phone-1',
        'name': 'Test phone',
        'platform': 'ios',
        'appVersion': '5.3.0',
        'protocol': 1,
      });
      expect(states, [
        LinkConnectionState.connecting,
        LinkConnectionState.connected,
      ]);

      desktop!.add(jsonEncode({'type': 'catalog.changed', 'version': 2}));
      desktop!.add('not json');
      desktop!.add(jsonEncode([1, 2]));
      session.send({'type': 'player.state', 'state': <String, Object?>{}});
      expect(await fromPhone.stream.first.timeout(const Duration(seconds: 5)), {
        'type': 'player.state',
        'state': <String, Object?>{},
      });
      await pumpEventQueue();
      expect(messages, [
        {'type': 'catalog.changed', 'version': 2},
      ]);

      // The desktop going away schedules a retry after the shortest delay.
      await desktop!.close();
      await session.connectionStates
          .firstWhere((s) => s == LinkConnectionState.disconnected)
          .timeout(const Duration(seconds: 5));
      await pumpEventQueue();
      expect(timers.delays, [LinkClientSession.minBackoff]);
    });

    test('backs off from 1 s doubling to 30 s, then resets', () async {
      final timers = _Timers();
      var failures = 6;
      final connects = <Uri>[];
      final session = LinkClientSession(
        server: _record('https://10.0.0.2:47710'),
        apiKey: 'key-1',
        device: _device,
        ensureAccess: (_) async {},
        timer: timers.call,
        connectSocket: (uri, headers, client) async {
          connects.add(uri);
          expect(
            headers['authorization'] ?? headers['Authorization'],
            'Bearer key-1',
          );
          if (failures-- > 0) throw const SocketException('offline');
          return _FakeSocket();
        },
      );
      addTearDown(session.dispose);
      session.start();
      await pumpEventQueue();
      for (var i = 0; i < 6; i++) {
        expect(session.connectionState, LinkConnectionState.disconnected);
        expect(session.issue, LinkSessionIssue.unreachable);
        timers.last.fire();
        await pumpEventQueue();
      }
      expect(timers.delays, const [
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
        Duration(seconds: 8),
        Duration(seconds: 16),
        Duration(seconds: 30),
      ]);
      expect(session.connectionState, LinkConnectionState.connected);
      expect(session.issue, isNull);
      expect(connects.first.toString(), 'wss://10.0.0.2:47710/mornye/v1/ws');
      expect(connects, hasLength(7));
    });

    test('a dropped link retries after 1 s again', () async {
      final timers = _Timers();
      final sockets = <_FakeSocket>[];
      final session = LinkClientSession(
        server: _record('https://10.0.0.2:47710'),
        apiKey: 'key-1',
        device: _device,
        ensureAccess: (_) async {},
        timer: timers.call,
        connectSocket: (_, _, _) async {
          final socket = _FakeSocket();
          sockets.add(socket);
          return socket;
        },
      );
      addTearDown(session.dispose);
      session.start();
      await pumpEventQueue();
      expect(session.connectionState, LinkConnectionState.connected);
      sockets.last.push({'type': 'open', 'url': 'x'});
      sockets.last.serverClose();
      await pumpEventQueue();
      expect(session.connectionState, LinkConnectionState.disconnected);
      expect(timers.delays, [LinkClientSession.minBackoff]);
      timers.last.fire();
      await pumpEventQueue();
      expect(session.connectionState, LinkConnectionState.connected);
      expect(sockets, hasLength(2));
    });

    test(
      'a socket opened after timeout is closed without disrupting retry',
      () async {
        final timers = _Timers();
        final connecting = Completer<LinkSocket>();
        final late = _FakeSocket();
        final retry = _FakeSocket();
        var attempts = 0;
        final session = LinkClientSession(
          server: _record('https://10.0.0.2:47710'),
          apiKey: 'key-1',
          device: _device,
          ensureAccess: (_) async {},
          timer: timers.call,
          handshakeTimeout: const Duration(milliseconds: 10),
          connectSocket: (_, _, _) =>
              attempts++ == 0 ? connecting.future : Future.value(retry),
        );
        addTearDown(session.dispose);
        final disconnected = session.connectionStates.firstWhere(
          (state) => state == LinkConnectionState.disconnected,
        );
        session.start();
        await disconnected.timeout(const Duration(seconds: 1));
        await pumpEventQueue();
        expect(timers.delays, [LinkClientSession.minBackoff]);

        timers.last.fire();
        await pumpEventQueue();
        expect(session.connectionState, LinkConnectionState.connected);
        connecting.complete(late);
        await pumpEventQueue();
        expect(late.closed, isTrue);
        expect(late.sent, isEmpty);
        expect(retry.closed, isFalse);
        expect(session.connectionState, LinkConnectionState.connected);
      },
    );

    test('pause closes the link and resume reconnects at once', () async {
      final timers = _Timers();
      final sockets = <_FakeSocket>[];
      final session = LinkClientSession(
        server: _record('https://10.0.0.2:47710'),
        apiKey: 'key-1',
        device: _device,
        ensureAccess: (_) async {},
        timer: timers.call,
        connectSocket: (_, _, _) async {
          final socket = _FakeSocket();
          sockets.add(socket);
          return socket;
        },
      );
      addTearDown(session.dispose);
      session.start();
      await pumpEventQueue();
      session.pause();
      await pumpEventQueue();
      expect(sockets.single.closed, isTrue);
      expect(session.connectionState, LinkConnectionState.disconnected);
      expect(timers.delays, isEmpty);
      session.send({'type': 'player.state'});
      session.reconnectNow();
      await pumpEventQueue();
      expect(sockets, hasLength(1));

      session.resume();
      await pumpEventQueue();
      expect(session.connectionState, LinkConnectionState.connected);
      expect(sockets, hasLength(2));
      expect(sockets.first.sent.map((m) => m['type']), ['hello']);
    });

    test('reconnectNow skips the remaining backoff', () async {
      final timers = _Timers();
      var online = false;
      final session = LinkClientSession(
        server: _record('https://10.0.0.2:47710'),
        apiKey: 'key-1',
        device: _device,
        ensureAccess: (_) async {},
        timer: timers.call,
        connectSocket: (_, _, _) async {
          if (!online) throw const SocketException('offline');
          return _FakeSocket();
        },
      );
      addTearDown(session.dispose);
      session.start();
      await pumpEventQueue();
      online = true;
      session.reconnectNow();
      await pumpEventQueue();
      expect(session.connectionState, LinkConnectionState.connected);
      expect(timers.last.isActive, isFalse);
    });

    test('a moved desktop reconnects at its new address', () async {
      final connects = <Uri>[];
      final session = LinkClientSession(
        server: _record('https://10.0.0.2:47710'),
        apiKey: 'key-1',
        device: _device,
        ensureAccess: (_) async {},
        timer: _Timers().call,
        connectSocket: (uri, _, _) async {
          connects.add(uri);
          return _FakeSocket();
        },
      );
      addTearDown(session.dispose);
      session.start();
      await pumpEventQueue();
      session.updateServer(_record('https://10.0.0.9:47711'));
      await pumpEventQueue();
      expect(session.server.address, 'https://10.0.0.9:47711');
      expect(connects.map((u) => u.toString()), [
        'wss://10.0.0.2:47710/mornye/v1/ws',
        'wss://10.0.0.9:47711/mornye/v1/ws',
      ]);
      expect(session.connectionState, LinkConnectionState.connected);
    });

    test('a refused key closes with 4401 and retries slowly', () async {
      final timers = _Timers();
      final session = LinkClientSession(
        server: _record('https://10.0.0.2:47710'),
        apiKey: 'key-1',
        device: _device,
        ensureAccess: (_) async {},
        timer: timers.call,
        connectSocket: (_, _, _) async =>
            _FakeSocket(closeBeforeWelcome: linkCloseUnauthorized),
      );
      addTearDown(session.dispose);
      session.start();
      await pumpEventQueue();
      expect(session.issue, LinkSessionIssue.unauthorized);
      expect(timers.delays, [LinkClientSession.maxBackoff]);
    });

    test('an upgrade refused with 401 is unauthorized', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = 401;
        await request.response.close();
      });
      final session = LinkClientSession(
        server: _record('http://127.0.0.1:${server.port}'),
        apiKey: 'revoked',
        device: _device,
        httpClient: (_) => HttpClient(),
        ensureAccess: (_) async {},
        timer: _Timers().call,
      );
      addTearDown(session.dispose);
      session.start();
      await session.connectionStates
          .firstWhere((s) => s == LinkConnectionState.disconnected)
          .timeout(const Duration(seconds: 5));
      expect(session.issue, LinkSessionIssue.unauthorized);
    });

    test('a welcome of another protocol is incompatible', () async {
      final session = LinkClientSession(
        server: _record('https://10.0.0.2:47710'),
        apiKey: 'key-1',
        device: _device,
        ensureAccess: (_) async {},
        timer: _Timers().call,
        connectSocket: (_, _, _) async =>
            _FakeSocket(welcome: {..._welcome, 'protocol': 2}),
      );
      addTearDown(session.dispose);
      session.start();
      await pumpEventQueue();
      expect(session.connectionState, LinkConnectionState.disconnected);
      expect(session.issue, LinkSessionIssue.incompatible);
    });

    test('a missing welcome times out', () async {
      final timers = _Timers();
      final session = LinkClientSession(
        server: _record('https://10.0.0.2:47710'),
        apiKey: 'key-1',
        device: _device,
        ensureAccess: (_) async {},
        timer: timers.call,
        handshakeTimeout: const Duration(milliseconds: 50),
        connectSocket: (_, _, _) async => _FakeSocket(welcome: null),
      );
      addTearDown(session.dispose);
      session.start();
      await session.connectionStates
          .firstWhere((s) => s == LinkConnectionState.disconnected)
          .timeout(const Duration(seconds: 5));
      expect(session.issue, LinkSessionIssue.unreachable);
      expect(timers.delays, [LinkClientSession.minBackoff]);
    });
  });
}
