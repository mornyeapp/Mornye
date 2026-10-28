import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/client/link_client_controller.dart';
import 'package:mornye/services/link/client/link_client_discovery.dart';
import 'package:mornye/services/link/client/link_client_pairing.dart';
import 'package:mornye/services/link/client/link_client_session.dart';
import 'package:mornye/services/link/client/link_client_store.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/link_client_fakes.dart';

Future<LinkClientHarness> _started({
  bool supported = true,
  bool localNetworkAllowed = true,
  bool onWifi = true,
  Stream<void> networkChanges = const Stream<void>.empty(),
}) async {
  final harness =
      LinkClientHarness(supported: supported, networkChanges: networkChanges)
        ..localNetworkAllowed = localNetworkAllowed
        ..onWifi = onWifi;
  addTearDown(harness.container.dispose);
  await harness.start();
  await pumpEventQueue();
  return harness;
}

Future<void> _lifecycle(List<AppLifecycleState> states) async {
  for (final state in states) {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(state);
  }
  await pumpEventQueue();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  test('pairing publishes the first desktop and follows the choice', () async {
    final harness = await _started();
    expect(harness.state.loaded, isTrue);
    expect(harness.state.activeServerId, isNull);
    expect(harness.active, isNull);

    final a = await harness.controller.pair(linkTestTarget('a'), '123456');
    await pumpEventQueue();
    expect(harness.pairing.pins, ['123456']);
    final device = harness.pairing.devices.single;
    expect(device.name, 'Test phone');
    expect(device.platform, 'android');
    expect(device.deviceId, await LinkClientStore().deviceId());

    final connection = harness.bridge.connections[a.connectionId]!;
    expect(connection.protocol, NetworkProtocol.subsonic);
    expect(connection.subsonicAuth, SubsonicAuth.apiKey);
    expect(connection.apiKey, 'key-1');
    expect(connection.address, 'https://10.0.0.2:47710');
    expect(connection.name, 'Desktop a');
    expect(connection.trustedCertificateSha256, linkTestFingerprint('a'));
    expect(harness.bridge.calls, [
      'save ${a.connectionId}',
      'source ${a.connectionId}',
    ]);
    expect(harness.state.activeServerId, 'a');
    expect(harness.sessions, hasLength(1));
    final first = harness.sessions.single;
    expect(harness.active, same(first));
    expect(first.apiKey, 'key-1');
    expect(first.calls, ['start']);
    final stored = await LinkClientStore().servers();
    expect(stored.single.toJson(), a.toJson());

    // A second desktop does not take over.
    await harness.controller.pair(
      linkTestTarget('b', host: '10.0.0.3'),
      '654321',
    );
    await pumpEventQueue();
    expect(harness.state.servers.map((s) => s.serverId), ['a', 'b']);
    expect(harness.sessions, hasLength(1));
    expect(harness.active, same(first));

    await harness.controller.setActive('b');
    await pumpEventQueue();
    expect(harness.sessions, hasLength(2));
    expect(first.disposed, isTrue);
    expect(harness.active, same(harness.sessions.last));
    expect(harness.active!.server.serverId, 'b');
    expect(await LinkClientStore().activeServerId(), 'b');

    final b = harness.state.activeServer!;
    await harness.controller.forget('b', removeLibrary: true);
    await pumpEventQueue();
    expect(harness.state.activeServerId, 'a');
    expect(harness.active!.server.serverId, 'a');
    expect(harness.sessions[1].disposed, isTrue);
    expect(harness.bridge.calls.last, 'remove ${b.connectionId}');

    await harness.controller.forget('a', removeLibrary: false);
    await pumpEventQueue();
    expect(harness.state.servers, isEmpty);
    expect(harness.active, isNull);
    expect(harness.bridge.connections, contains(a.connectionId));
    expect(await LinkClientStore().servers(), isEmpty);
  });

  test('re-pairing replaces the key and keeps the connection', () async {
    final harness = await _started();
    final first = await harness.controller.pair(linkTestTarget('a'), '111111');
    harness.pairing.key = 'key-2';
    final second = await harness.controller.pair(
      linkTestTarget('a', host: '10.0.0.9'),
      '222222',
    );
    await pumpEventQueue();
    expect(second.connectionId, first.connectionId);
    expect(harness.state.servers, hasLength(1));
    expect(harness.state.servers.single.address, 'https://10.0.0.9:47710');
    expect(harness.bridge.connections[first.connectionId]!.apiKey, 'key-2');
    expect(harness.sessions.last.apiKey, 'key-2');
    expect(harness.sessions.first.disposed, isTrue);
    expect(harness.active, same(harness.sessions.last));
  });

  test('a failed pairing saves nothing', () async {
    final harness = await _started();
    harness.pairing.error = LinkPairingError.badPin;
    await expectLater(
      harness.controller.pair(linkTestTarget('a'), '000000'),
      throwsA(
        isA<LinkPairingException>().having(
          (e) => e.error,
          'error',
          LinkPairingError.badPin,
        ),
      ),
    );
    expect(harness.state.servers, isEmpty);
    expect(harness.bridge.calls, isEmpty);
    expect(harness.active, isNull);
  });

  test('a bad address fails before any request', () async {
    final harness = await _started();
    await expectLater(
      harness.controller.probe('host/path', 47710),
      throwsA(
        isA<LinkPairingException>().having(
          (e) => e.error,
          'error',
          LinkPairingError.invalidAddress,
        ),
      ),
    );
    expect(harness.pairing.probes, isEmpty);
  });

  test('stored desktops load with the saved active choice', () async {
    final records = [
      for (final id in ['a', 'b'])
        LinkServerRecord(
          serverId: id,
          name: 'Desktop $id',
          connectionId: 'connection-$id',
          address: 'https://10.0.0.2:47710',
          fingerprint: linkTestFingerprint(id),
        ),
    ];
    SharedPreferences.setMockInitialValues({
      LinkClientStore.serversKey: jsonEncode([
        for (final record in records) record.toJson(),
      ]),
      LinkClientStore.activeServerKey: 'b',
    });
    final harness = LinkClientHarness();
    addTearDown(harness.container.dispose);
    harness.bridge.connections['connection-b'] = const NetworkConnection(
      id: 'connection-b',
      name: 'Desktop b',
      protocol: NetworkProtocol.subsonic,
      address: 'https://10.0.0.2:47710',
      subsonicAuth: SubsonicAuth.apiKey,
      apiKey: 'stored-key',
    );
    await harness.start();
    await pumpEventQueue();
    expect(harness.state.servers, hasLength(2));
    expect(harness.state.activeServerId, 'b');
    expect(harness.sessions.single.apiKey, 'stored-key');
    expect(harness.active, same(harness.sessions.single));

    // A desktop whose connection was removed elsewhere must pair again.
    await harness.controller.setActive('a');
    await pumpEventQueue();
    expect(harness.active, isNull);
    expect(harness.state.issue, LinkSessionIssue.unauthorized);
  });

  test('state follows the session and discovery follows the desktop', () async {
    final harness = await _started();
    final record = await harness.controller.pair(linkTestTarget('a'), '123456');
    await pumpEventQueue();
    final session = harness.sessions.single;

    // Disconnected: discovery looks for the desktop.
    expect(harness.browser.started, 1);
    expect(harness.state.discovery, LinkDiscoveryStatus.searching);

    session.emit(LinkConnectionState.connected);
    await pumpEventQueue();
    expect(harness.state.connection, LinkConnectionState.connected);
    expect(harness.browser.stopped, 1);
    expect(harness.bridge.reachable[record.connectionId], isTrue);

    session.emit(
      LinkConnectionState.disconnected,
      LinkSessionIssue.unreachable,
    );
    await pumpEventQueue();
    expect(harness.state.issue, LinkSessionIssue.unreachable);
    expect(harness.browser.started, 2);
    // The desktop's songs fail quickly while it cannot be reached.
    expect(harness.bridge.reachable[record.connectionId], isFalse);

    // Seen again at the same address: reconnect at once.
    harness.browser.resolve('a', '10.0.0.2');
    await pumpEventQueue();
    expect(session.calls.last, 'reconnect');

    // Seen at a new address: the record, connection and session move.
    harness.browser.resolve('a', '10.0.0.7');
    await pumpEventQueue();
    expect(harness.state.servers.single.address, 'https://10.0.0.7:47710');
    expect(
      (await LinkClientStore().servers()).single.address,
      'https://10.0.0.7:47710',
    );
    expect(
      harness.bridge.calls.last,
      'address ${record.connectionId} https://10.0.0.7:47710',
    );
    expect(session.calls.last, 'update https://10.0.0.7:47710');
  });

  test('another certificate under a known id is not followed', () async {
    final harness = await _started();
    await harness.controller.pair(linkTestTarget('a'), '123456');
    await pumpEventQueue();
    final session = harness.sessions.single;
    harness.browser.resolve('a', '10.0.0.66', fingerprint: 'cc' * 32);
    await pumpEventQueue();
    expect(harness.state.servers.single.address, 'https://10.0.0.2:47710');
    expect(session.calls, ['start']);
    expect(
      harness.state.certificateChanged(harness.state.activeServer!),
      isTrue,
    );
  });

  test('the session pauses in the background and resumes after', () async {
    final harness = await _started();
    await harness.controller.pair(linkTestTarget('a'), '123456');
    await pumpEventQueue();
    final session = harness.sessions.single;

    await _lifecycle([AppLifecycleState.inactive]);
    expect(session.calls, ['start']);

    await _lifecycle([AppLifecycleState.hidden, AppLifecycleState.paused]);
    expect(session.calls, ['start', 'pause']);
    expect(harness.browser.stopped, 1);

    await _lifecycle([
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    expect(session.calls, ['start', 'pause', 'resume', 'reconnect']);
    expect(harness.browser.started, 2);
  });

  test('the session stays connected in the background when asked', () async {
    final harness = await _started();
    await harness.controller.pair(linkTestTarget('a'), '123456');
    await pumpEventQueue();
    final session = harness.sessions.single;

    harness.keepConnected(true);
    await pumpEventQueue();
    await _lifecycle([AppLifecycleState.hidden, AppLifecycleState.paused]);
    expect(session.calls, ['start']);

    harness.keepConnected(false);
    await pumpEventQueue();
    expect(session.calls, ['start', 'pause']);

    harness.keepConnected(true);
    await pumpEventQueue();
    expect(session.calls, ['start', 'pause', 'resume']);

    await _lifecycle([
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    harness.keepConnected(false);
    await pumpEventQueue();
    expect(session.calls, ['start', 'pause', 'resume', 'reconnect']);
  });

  test('catalog.changed rescans the desktop once bursts settle', () async {
    final harness = await _started();
    final record = await harness.controller.pair(linkTestTarget('a'), '123456');
    await pumpEventQueue();
    final session = harness.sessions.single;
    session.push({'type': LinkMessageTypes.catalogChanged, 'version': 1});
    session.push({'type': 'player.state'});
    session.push({'type': LinkMessageTypes.catalogChanged, 'version': 2});
    await pumpEventQueue();
    expect(harness.bridge.calls.where((c) => c.startsWith('rescan')), isEmpty);
    await Future<void>.delayed(
      LinkClientController.rescanDelay + const Duration(milliseconds: 200),
    );
    expect(harness.bridge.calls.where((c) => c.startsWith('rescan')), [
      'rescan ${record.connectionId}',
    ]);
  });

  test('a refused permission stops discovery until asked again', () async {
    final harness = await _started(localNetworkAllowed: false);
    final release = harness.controller.acquireDiscovery();
    addTearDown(release);
    await pumpEventQueue();
    expect(harness.state.discovery, LinkDiscoveryStatus.permissionDenied);
    expect(harness.browser.started, 0);

    await expectLater(
      harness.controller.requestLocalNetworkAccess(),
      throwsA(isA<LocalNetworkPermissionException>()),
    );
    harness.localNetworkAllowed = true;
    await harness.controller.requestLocalNetworkAccess();
    await pumpEventQueue();
    expect(harness.state.discovery, LinkDiscoveryStatus.searching);
    expect(harness.browser.started, 1);

    harness.browser.resolve('b', '10.0.0.3');
    await pumpEventQueue();
    expect(harness.state.unpaired.single.serverId, 'b');

    release();
    await pumpEventQueue();
    expect(harness.state.discovery, LinkDiscoveryStatus.idle);
    expect(harness.state.discovered, isEmpty);
  });

  test('the page hears when Wi-Fi is off', () async {
    final harness = await _started(onWifi: false);
    harness.controller.acquireDiscovery()();
    await pumpEventQueue();
    expect(harness.state.localNetworkAvailable, isFalse);
  });

  test('joining Wi-Fi restarts discovery without restarting the app', () async {
    final changes = StreamController<void>.broadcast();
    addTearDown(changes.close);
    final harness = await _started(
      onWifi: false,
      networkChanges: changes.stream,
    );
    final release = harness.controller.acquireDiscovery();
    addTearDown(release);
    await pumpEventQueue();
    expect(harness.state.localNetworkAvailable, isFalse);

    harness.onWifi = true;
    changes.add(null);
    await pumpEventQueue();
    expect(harness.state.localNetworkAvailable, isTrue);
    expect(harness.state.discovery, LinkDiscoveryStatus.searching);
    harness.browser.resolve('b', '192.168.18.5');
    await pumpEventQueue();
    expect(harness.state.unpaired.single.host, '192.168.18.5');
  });

  test(
    'a new network refreshes a stale browser and disconnected session',
    () async {
      final changes = StreamController<void>.broadcast();
      addTearDown(changes.close);
      final harness = await _started(networkChanges: changes.stream);
      await harness.controller.pair(linkTestTarget('a'), '123456');
      await pumpEventQueue();
      final started = harness.browser.started;
      changes.add(null);
      await pumpEventQueue();
      expect(harness.browser.started, started + 1);
      expect(harness.sessions.single.calls.last, 'reconnect');
    },
  );

  test('returning from Control Centre refreshes discovery', () async {
    final harness = await _started();
    final release = harness.controller.acquireDiscovery();
    addTearDown(release);
    await pumpEventQueue();
    final started = harness.browser.started;
    await _lifecycle([AppLifecycleState.inactive, AppLifecycleState.resumed]);
    expect(harness.browser.started, started + 1);
  });

  test('network changes keep an already connected session open', () async {
    final changes = StreamController<void>.broadcast();
    addTearDown(changes.close);
    final harness = await _started(networkChanges: changes.stream);
    await harness.controller.pair(linkTestTarget('a'), '123456');
    await pumpEventQueue();
    final session = harness.sessions.single;
    session.emit(LinkConnectionState.connected);
    await pumpEventQueue();
    changes.add(null);
    await pumpEventQueue();
    expect(session.calls, ['start']);
    expect(harness.state.connection, LinkConnectionState.connected);
  });

  test(
    'a failed browser is recreated while the Link page stays open',
    () async {
      final harness = await _started();
      final release = harness.controller.acquireDiscovery();
      addTearDown(release);
      await pumpEventQueue();
      harness.browser.events!.addError(StateError('Bonjour failed'));
      await pumpEventQueue();
      expect(harness.state.discovery, LinkDiscoveryStatus.failed);
      await Future<void>.delayed(
        LinkClientController.discoveryRetryDelay +
            const Duration(milliseconds: 50),
      );
      expect(harness.browser.started, 2);
      harness.browser.resolve('b', '192.168.18.5');
      await pumpEventQueue();
      expect(harness.state.unpaired.single.host, '192.168.18.5');
    },
  );

  test('disposing closes the session and discovery', () async {
    final harness = LinkClientHarness();
    await harness.start();
    await harness.controller.pair(linkTestTarget('a'), '123456');
    await pumpEventQueue();
    harness.container.dispose();
    await pumpEventQueue();
    expect(harness.sessions.single.disposed, isTrue);
    expect(harness.browser.stopped, 1);
  });

  test('unsupported platforms stay inert', () async {
    final harness = await _started(supported: false);
    expect(harness.state.loaded, isTrue);
    harness.controller.acquireDiscovery();
    await harness.controller.requestLocalNetworkAccess();
    await pumpEventQueue();
    expect(harness.browser.started, 0);
    expect(harness.active, isNull);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getKeys(), isEmpty);
  });
}
