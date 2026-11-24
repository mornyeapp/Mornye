import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/desktop/link_desktop_backend.dart';
import 'package:mornye/services/link/desktop/link_phone_host_backend.dart';

const _channel = MethodChannel('test/link');
const _events = EventChannel('test/link/events');

class _FakeAdvertiser implements LinkHostAdvertiser {
  final calls = <String>[];
  Object? startError;

  @override
  Future<void> start(LinkHostServer server, {required String platform}) async {
    calls.add('start:${server.serverId}:$platform');
    final error = startError;
    if (error != null) throw error;
  }

  @override
  Future<void> stop() async => calls.add('stop');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<(String, Map<String, dynamic>)> calls;
  late Map<String, Object?> replies;
  late _FakeAdvertiser advertiser;
  late ChannelLinkHostBackend backend;
  MockStreamHandlerEventSink? sink;

  setUp(() {
    calls = [];
    replies = {};
    advertiser = _FakeAdvertiser();
    messenger.setMockMethodCallHandler(_channel, (call) async {
      final args = jsonDecode(call.arguments as String) as Map;
      calls.add((call.method, args.cast<String, dynamic>()));
      if (call.method == 'linkFail') {
        throw PlatformException(code: 'LINK_HOST', message: 'broken');
      }
      return jsonEncode(replies[call.method]);
    });
    messenger.setMockStreamHandler(
      _events,
      MockStreamHandler.inline(
        onListen: (_, events) => sink = events,
        onCancel: (_) => sink = null,
      ),
    );
    backend = ChannelLinkHostBackend(
      channel: _channel,
      events: _events,
      paths: () async => {
        'appSupportDir': '/data/app',
        'tempDir': '/data/tmp',
        'appVersion': '5.3.1',
      },
      advertiser: advertiser,
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    messenger.setMockStreamHandler(_events, null);
  });

  final server = {
    'port': 47710,
    'fingerprint': 'ab' * 32,
    'serverId': 'server-1',
    'name': 'Test phone',
    'addresses': ['https://192.168.1.9:47710'],
    'receivedDir': '/data/app/received',
  };

  test(
    'configures once, starts without Rust mDNS and announces itself',
    () async {
      replies['linkStart'] = server;
      final started = await backend.start(
        name: 'Test phone',
        platform: 'android',
        features: const [],
      );
      expect(started.serverId, 'server-1');
      expect(calls.map((call) => call.$1), ['linkConfigure', 'linkStart']);
      expect(calls.first.$2, {
        'appSupportDir': '/data/app',
        'tempDir': '/data/tmp',
        'appVersion': '5.3.1',
      });
      expect(calls[1].$2, {
        'name': 'Test phone',
        'platform': 'android',
        'features': <String>[],
        'advertise': false,
      });
      expect(advertiser.calls, ['start:server-1:android']);

      await backend.stop();
      expect(advertiser.calls.last, 'stop');
      expect(calls.last.$1, 'linkStop');
      expect(calls.where((call) => call.$1 == 'linkConfigure'), hasLength(1));
    },
  );

  test('a failed announcement leaves the server running', () async {
    replies['linkStart'] = server;
    advertiser.startError = StateError('no service discovery');
    final started = await backend.start(name: 'Test phone');
    expect(started.port, 47710);
    expect(calls.last.$2.containsKey('platform'), isFalse);
  });

  test('reads devices, pairing windows and catalog counts', () async {
    replies['linkDevices'] = [
      {'deviceId': 'p1', 'name': 'Pixel', 'platform': 'android'},
    ];
    replies['linkBeginPairing'] = {
      'pin': '123456',
      'expiresMs': 99,
      'fingerprint': 'ab' * 32,
    };
    replies['linkSetCatalog'] = {'songs': 12};
    replies['linkSend'] = {'delivered': 2};
    expect((await backend.devices()).single.deviceId, 'p1');
    expect((await backend.beginPairing()).pin, '123456');
    expect(await backend.setCatalog('/data/app/catalog.json'), 12);
    expect(await backend.send({'type': 'x'}, deviceId: 'p1'), 2);
    expect(calls.last.$2, {
      'deviceId': 'p1',
      'message': {'type': 'x'},
    });
  });

  test('turns event channel JSON into host events', () async {
    final requests = <LinkRequestEvent>[];
    final pairing = <LinkPairingEvent>[];
    final clients = <int>[];
    final subscriptions = [
      backend.requests.listen(requests.add),
      backend.pairing.listen(pairing.add),
      backend.clients.listen((list) => clients.add(list.length)),
    ];
    await pumpEventQueue();
    expect(sink, isNotNull);
    sink!
      ..success(
        jsonEncode({
          'method': 'linkRequest',
          'arguments': {
            'requestId': 'r1',
            'op': 'state',
            'deviceId': 'p1',
            'args': <String, Object?>{},
          },
        }),
      )
      ..success('not json')
      ..success(
        jsonEncode({
          'method': 'linkClients',
          'arguments': {
            'clients': [
              {'deviceId': 'p1', 'name': 'Pixel', 'platform': 'android'},
            ],
          },
        }),
      )
      ..success(
        jsonEncode({
          'method': 'linkPaired',
          'arguments': {'deviceId': 'p1', 'name': 'Pixel'},
        }),
      )
      ..success(
        jsonEncode({
          'method': 'linkPairingEnded',
          'arguments': {'reason': 'expired'},
        }),
      );
    await pumpEventQueue();
    expect(requests.single.op, 'state');
    expect(requests.single.deviceId, 'p1');
    expect(clients, [1]);
    expect(pairing, hasLength(2));
    expect((pairing.first as LinkPairedEvent).name, 'Pixel');
    expect(
      (pairing.last as LinkPairingEndedEvent).reason,
      LinkPairingEndReason.expired,
    );
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  });

  test('platform errors reach the caller and configuring is retried', () async {
    var failConfigure = true;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add((call.method, const {}));
      if (call.method == 'linkConfigure' && failConfigure) {
        throw PlatformException(code: 'LINK_HOST', message: 'no folder');
      }
      return jsonEncode(<String, Object?>{});
    });
    await expectLater(backend.status(), throwsA(isA<PlatformException>()));
    failConfigure = false;
    final status = await backend.status();
    expect(status.server, isNull);
    expect(calls.map((call) => call.$1), [
      'linkConfigure',
      'linkConfigure',
      'linkStatus',
    ]);
  });
}
