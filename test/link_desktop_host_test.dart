import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/link/desktop/link_desktop_backend.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/desktop/link_player.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/link_desktop_fakes.dart';

const _phone = LinkClientInfo(
  deviceId: 'p1',
  name: 'Pixel',
  platform: 'android',
);
const _tablet = LinkClientInfo(
  deviceId: 'p2',
  name: 'Tablet',
  platform: 'android',
);

void main() {
  late FakeLinkBackend backend;
  late FakeLinkPlayer player;
  late FakeLinkCatalogExporter exporter;
  late FakeLinkWebCovers webCovers;
  late List<String> opened;
  late ProviderContainer container;

  setUp(() {
    debugDesktopPlatformOverride = true;
    backend = FakeLinkBackend()..catalogSongs = 2;
    player = FakeLinkPlayer();
    exporter = FakeLinkCatalogExporter(
      songs: [catalogSong('l:a'), catalogSong('d:b')],
    );
    webCovers = FakeLinkWebCovers(backend: backend);
    opened = [];
  });

  tearDown(() => debugDesktopPlatformOverride = null);

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
  }

  LinkDesktopHost host() => container.read(linkDesktopHostProvider.notifier);
  LinkDesktopHostState hostState() => container.read(linkDesktopHostProvider);

  /// Builds the host with saved settings and lets it start.
  Future<void> boot(
    WidgetTester tester, {
    bool enabled = true,
    String? name = 'Studio',
  }) async {
    SharedPreferences.setMockInitialValues({
      linkDesktopEnabledKey: enabled,
      linkDesktopNameKey: ?name,
    });
    container = ProviderContainer(
      overrides: linkHostOverrides(
        backend: backend,
        player: player,
        exporter: exporter,
        openedUrls: opened,
        webCovers: webCovers,
      ),
    );
    container.read(linkDesktopHostProvider);
    await flush(tester);
  }

  /// Disposes the host, which cancels its timers.
  Future<void> shutdown(WidgetTester tester) async {
    container.dispose();
    await tester.pump();
  }

  LinkPlayerSnapshot snapshot({
    bool playing = true,
    int positionMs = 0,
    int updatedMs = 0,
    List<LinkPlayerItem>? queue,
  }) => LinkPlayerSnapshot(
    queue: queue ?? [playerItem('a'), playerItem('b')],
    index: 0,
    playing: playing,
    positionMs: positionMs,
    updatedMs: updatedMs,
  );

  testWidgets('starts when enabled, exports and publishes the index', (
    tester,
  ) async {
    await boot(tester);
    final state = hostState();
    expect(state.loaded, isTrue);
    expect(state.running, isTrue);
    expect(state.server!.name, 'Studio');
    expect(state.catalogSongs, 2);
    expect(backend.calls, containsAll(['status', 'start:Studio']));
    expect(backend.calls, contains('setCatalog'));
    expect(exporter.exports.single.serverId, 'server-1');
    expect(exporter.exports.single.includeLocal, isTrue);
    final index = container.read(linkCatalogIndexProvider)!;
    expect(index.length, 2);
    expect(index.songById('d:b'), isNotNull);
    // L2 ops are registered on the shared router.
    final router = container.read(linkHostRouterProvider);
    for (final op in [LinkOps.state, LinkOps.handoffPlay, LinkOps.resolve]) {
      expect(router.handles(op), isTrue, reason: op);
    }
    await shutdown(tester);
    expect(backend.calls.last, 'stop');
  });

  testWidgets('stays off by default and saves the switch', (tester) async {
    await boot(tester, enabled: false, name: null);
    expect(hostState().loaded, isTrue);
    expect(hostState().enabled, isFalse);
    expect(hostState().name, isNotEmpty);
    expect(backend.calls, ['devices']);

    await host().setEnabled(true);
    await flush(tester);
    expect(hostState().running, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(linkDesktopEnabledKey), isTrue);

    await host().setEnabled(false);
    await flush(tester);
    expect(hostState().phase, LinkHostPhase.stopped);
    expect(hostState().server, isNull);
    expect(container.read(linkCatalogIndexProvider), isNull);
    expect(backend.calls, contains('stop'));
    expect(prefs.getBool(linkDesktopEnabledKey), isFalse);
    await shutdown(tester);
  });

  testWidgets('renaming restarts the server under the new name', (
    tester,
  ) async {
    await boot(tester);
    backend.calls.clear();
    await host().setName('  Den ');
    await flush(tester);
    expect(backend.calls, containsAllInOrder(['stop', 'start:Den']));
    expect(hostState().server!.name, 'Den');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(linkDesktopNameKey), 'Den');
    await shutdown(tester);
  });

  testWidgets('a failed start reports why and can be retried', (tester) async {
    backend.startError = PlatformException(
      code: 'bind',
      message: 'Port in use',
    );
    await boot(tester);
    expect(hostState().phase, LinkHostPhase.failed);
    expect(hostState().error, 'Port in use');

    backend.startError = null;
    await host().retry();
    await flush(tester);
    expect(hostState().running, isTrue);
    expect(hostState().error, isNull);
    await shutdown(tester);
  });

  testWidgets('adopts a server that is still running', (tester) async {
    backend
      ..running = true
      ..runningName = 'Studio';
    await boot(tester);
    expect(hostState().running, isTrue);
    expect(backend.calls.where((call) => call.startsWith('start')), isEmpty);
    await shutdown(tester);
  });

  testWidgets('answers forwarded requests with linkReply', (tester) async {
    await boot(tester);
    player.current = snapshot();
    backend
      ..request(LinkOps.state, requestId: 'r1')
      ..request(
        LinkOps.command,
        requestId: 'r2',
        args: {'action': LinkActions.next},
      )
      ..request(LinkOps.command, requestId: 'r3', args: {'action': 'dance'})
      ..request('nope', requestId: 'r4')
      ..request(
        LinkOps.open,
        requestId: 'r5',
        args: {'url': 'https://example.com/album/1'},
      );
    await flush(tester);

    final replies = {
      for (final reply in backend.replies) reply.requestId: reply,
    };
    expect(replies.keys, unorderedEquals(['r1', 'r2', 'r3', 'r4', 'r5']));
    final state = replies['r1']!.result! as Map<String, dynamic>;
    expect(state['playing'], isTrue);
    expect((state['track'] as Map)['songId'], 'l:a');
    expect(replies['r1']!.error, isNull);
    expect(replies['r2']!.result, {'ok': true});
    expect(player.calls, ['next']);
    expect(replies['r3']!.error!.code, 'invalid');
    expect(replies['r4']!.error!.code, 'not_found');
    expect(replies['r5']!.result, {'ok': true});
    expect(opened, ['https://example.com/album/1']);
    await shutdown(tester);
  });

  testWidgets(
    'file operations are registered for paired phones and reject app keys',
    (tester) async {
      backend.deviceList = const [
        LinkPairedDevice(deviceId: 'phone', name: 'Phone', platform: 'android'),
        LinkPairedDevice(deviceId: 'app', name: 'Player', platform: 'subsonic'),
      ];
      await boot(tester);
      backend.request(
        LinkOps.libraryJobs,
        requestId: 'phone-work',
        deviceId: 'phone',
        args: const {'_method': 'GET'},
      );
      backend.request(
        LinkOps.libraryJobs,
        requestId: 'app-work',
        deviceId: 'app',
        args: const {'_method': 'GET'},
      );
      await flush(tester);
      final own = backend.replies.singleWhere(
        (reply) => reply.requestId == 'phone-work',
      );
      expect(
        (own.result as Map)['actions'],
        containsAll(['delete', 'convert', 'reEnrich', 'replayGain']),
      );
      expect(
        backend.replies
            .singleWhere((reply) => reply.requestId == 'app-work')
            .error
            ?.code,
        'forbidden',
      );
      await shutdown(tester);
    },
  );

  testWidgets('pushes player.state debounced and on a heartbeat', (
    tester,
  ) async {
    await boot(tester);
    player.current = snapshot();
    List<Map<String, dynamic>> pushed() =>
        backend.sentOfType(LinkMessageTypes.playerState);

    // Nobody is listening yet.
    player.emit(snapshot(positionMs: 90000));
    await tester.pump(const Duration(seconds: 1));
    expect(pushed(), isEmpty);

    // A phone connects: it gets the state after the debounce.
    player.current = snapshot();
    backend.connect([_phone]);
    await tester.pump(const Duration(milliseconds: 200));
    expect(pushed(), isEmpty);
    await tester.pump(const Duration(milliseconds: 100));
    expect(pushed(), hasLength(1));
    expect(backend.sent.single.deviceId, isNull);
    final state = pushed().single['state'] as Map<String, dynamic>;
    expect(state['playing'], isTrue);
    expect((state['track'] as Map)['title'], 'Title a');

    // A burst of changes sends once.
    for (var i = 0; i < 3; i++) {
      player.emit(snapshot(playing: false, positionMs: 1000 * i));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(pushed(), hasLength(2));
    expect((pushed().last['state'] as Map)['positionMs'], 2000);

    // Nothing that playback explains is sent.
    player.emit(snapshot(playing: false, positionMs: 2000, updatedMs: 9000));
    await tester.pump(const Duration(seconds: 1));
    expect(pushed(), hasLength(2));

    // The heartbeat repeats the state every 15 s.
    await tester.pump(const Duration(seconds: 15));
    expect(pushed(), hasLength(3));

    // Without phones the heartbeat and pushes stop.
    backend.connect(const []);
    await tester.pump();
    player.emit(snapshot(playing: true, positionMs: 5));
    await tester.pump(const Duration(seconds: 16));
    expect(pushed(), hasLength(3));
    await shutdown(tester);
  });

  testWidgets('downloads.changed is sent at most once a second', (
    tester,
  ) async {
    await boot(tester);
    backend.connect([_phone]);
    await tester.pump(const Duration(seconds: 1));
    backend.sent.clear();

    DownloadItem item(double progress) => DownloadItem(
      id: 'q1',
      track: const Track(
        id: 't',
        name: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 100,
      ),
      service: 'svc',
      status: DownloadStatus.downloading,
      progress: progress,
      createdAt: DateTime(2024),
    );
    final items = container.read(fakeDownloadItemsProvider.notifier);
    for (final progress in [0.1, 0.2, 0.3]) {
      items.replace([item(progress)]);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(backend.sentOfType(LinkMessageTypes.downloadsChanged), isEmpty);
    await tester.pump(const Duration(seconds: 1));
    final sent = backend.sentOfType(LinkMessageTypes.downloadsChanged);
    expect(sent, hasLength(1));
    expect(sent.single['items'], [
      {
        'id': 'q1',
        'title': 'Song',
        'artist': 'Artist',
        'status': 'downloading',
        'progress': 0.3,
      },
    ]);
    await shutdown(tester);
  });

  testWidgets('keeps each phone state until the phone disconnects', (
    tester,
  ) async {
    await boot(tester);
    expect(container.read(linkDevicesAvailableProvider), isFalse);
    backend.connect([_phone, _tablet]);
    await flush(tester);
    expect(container.read(linkDevicesAvailableProvider), isTrue);

    final phoneState = LinkPlayerState(
      track: const TrackRef(title: 'On the phone', artist: 'Band'),
      playing: true,
      updatedMs: 1,
    );
    backend
      ..message('p1', {
        'type': LinkMessageTypes.playerState,
        'state': phoneState.toJson(),
      })
      ..message('p2', {'type': 'something.else', 'state': phoneState.toJson()});
    await flush(tester);
    expect(hostState().phoneStates.keys, ['p1']);
    expect(hostState().phoneStates['p1']!.track!.title, 'On the phone');

    backend.connect([_tablet]);
    await flush(tester);
    expect(hostState().phoneStates, isEmpty);
    expect(hostState().clients.single.deviceId, 'p2');

    backend.connect(const []);
    await flush(tester);
    expect(container.read(linkDevicesAvailableProvider), isFalse);
    await shutdown(tester);
  });

  testWidgets('one player at a time: follows a phone, pauses it to play', (
    tester,
  ) async {
    await boot(tester);
    player.emit(snapshot(playing: false));
    backend.connect([_phone, _tablet]);
    await flush(tester);
    void phonePlays(String deviceId, {required bool playing}) =>
        backend.message(deviceId, {
          'type': LinkMessageTypes.playerState,
          'state': LinkPlayerState(
            track: const TrackRef(title: 'On the phone', artist: 'Band'),
            playing: playing,
            updatedMs: 1,
          ).toJson(),
        });
    List<String?> pausedPhones() => [
      for (final sent in backend.sent)
        if (sent.message['type'] == LinkMessageTypes.command &&
            sent.message['action'] == LinkActions.pause)
          sent.deviceId,
    ];

    // A paused phone is not followed; one that starts playing is.
    phonePlays('p1', playing: false);
    await flush(tester);
    expect(hostState().followedPhone, isNull);
    phonePlays('p1', playing: true);
    await flush(tester);
    expect(hostState().followedPhone, 'p1');
    expect(host().deviceName('p1'), 'Pixel');

    // The desktop starting shows its own player and pauses the phone.
    backend.sent.clear();
    player.emit(snapshot());
    await flush(tester);
    expect(hostState().followedPhone, isNull);
    expect(pausedPhones(), ['p1']);

    // A phone starting while the desktop plays is left to pause it.
    phonePlays('p2', playing: true);
    await flush(tester);
    expect(hostState().followedPhone, isNull);

    // Once paused, the desktop follows the phone that plays.
    phonePlays('p1', playing: false);
    player.emit(snapshot(playing: false));
    await flush(tester);
    expect(hostState().followedPhone, 'p2');

    // Picking a song here, or the phone leaving, ends following.
    host().stopFollowingPhone();
    expect(hostState().followedPhone, isNull);
    phonePlays('p2', playing: false);
    phonePlays('p2', playing: true);
    await flush(tester);
    expect(hostState().followedPhone, 'p2');
    backend.connect([_phone]);
    await flush(tester);
    expect(hostState().followedPhone, isNull);
    await shutdown(tester);
  });

  testWidgets('re-exports 10 s after a Library change, only while running', (
    tester,
  ) async {
    await boot(tester);
    expect(exporter.exports, hasLength(1));
    final revision = container.read(fakeLibraryRevisionProvider.notifier);
    revision.bump();
    await tester.pump(const Duration(seconds: 5));
    revision.bump();
    await tester.pump(const Duration(seconds: 9));
    expect(exporter.exports, hasLength(1));
    await tester.pump(const Duration(seconds: 2));
    await flush(tester);
    expect(exporter.exports, hasLength(2));
    expect(backend.catalogs, hasLength(2));

    await host().setEnabled(false);
    await flush(tester);
    revision.bump();
    await tester.pump(const Duration(seconds: 11));
    expect(exporter.exports, hasLength(2));
    await shutdown(tester);
  });

  testWidgets('keeps the web covers the served catalog wants and exports '
      'again once they arrive', (tester) async {
    const url = 'https://example.com/a.jpg';
    exporter.webCoverSongs = const [(path: '/a.flac', stamp: 'a', url: url)];
    await boot(tester);
    // Both after the server took the first catalog.
    expect(webCovers.calls, ['prune:1:$url', 'fetch:1:$url']);

    webCovers.arrive();
    await tester.pump(const Duration(seconds: 9));
    expect(exporter.exports, hasLength(1));
    await tester.pump(const Duration(seconds: 2));
    await flush(tester);
    expect(exporter.exports, hasLength(2));
    expect(webCovers.calls.sublist(2), ['prune:2:$url', 'fetch:2:$url']);

    await host().setEnabled(false);
    await flush(tester);
    expect(webCovers.calls.last, 'stop');
    webCovers.arrive();
    await tester.pump(const Duration(seconds: 11));
    expect(exporter.exports, hasLength(2));
    await shutdown(tester);
  });

  testWidgets('fetches no web covers once Link is turned off during an '
      'export', (tester) async {
    const url = 'https://example.com/a.jpg';
    exporter.webCoverSongs = const [(path: '/a.flac', stamp: 'a', url: url)];
    await boot(tester);
    backend.catalogGate = Completer();
    backend.stopGate = Completer();
    unawaited(host().exportCatalog());
    await flush(tester);
    expect(backend.calls.last, 'setCatalog');

    unawaited(host().setEnabled(false));
    await flush(tester);
    expect(backend.calls.last, 'stop');
    // The server takes the catalog while it stops.
    backend.catalogGate!.complete();
    await flush(tester);
    backend.stopGate!.complete();
    await flush(tester);

    expect(hostState().running, isFalse);
    expect(webCovers.calls.last, 'stop');
    await shutdown(tester);
  });

  testWidgets('sends commands, links and the queue to a phone', (tester) async {
    await boot(tester);
    backend.connect([_phone]);
    await tester.pump(const Duration(seconds: 1));
    backend.sent.clear();

    expect(
      await host().sendCommand('p1', const LinkCommand(LinkActions.next)),
      isTrue,
    );
    expect(backend.sent.last.deviceId, 'p1');
    expect(backend.sent.last.message, {
      'type': 'command',
      'action': 'next',
      'args': <String, dynamic>{},
    });

    expect(await host().openOnPhone('p1', ' https://example.com/x '), isTrue);
    expect(backend.sent.last.message, {
      'type': 'open',
      'url': 'https://example.com/x',
    });

    player.current = snapshot(positionMs: 30000, playing: false);
    expect(host().hasCurrentTrack, isTrue);
    expect(await host().continueOnPhone('p1'), isTrue);
    final handoff = backend.sent.last;
    expect(handoff.deviceId, 'p1');
    expect(handoff.message['action'], LinkActions.playQueue);
    final args = handoff.message['args'] as Map<String, dynamic>;
    expect(args['index'], 0);
    expect(args['positionMs'], 30000);
    expect(args['playing'], isTrue);
    expect((args['queue'] as List).map((ref) => (ref as Map)['songId']), [
      'l:a',
      'd:b',
    ]);
    expect(player.calls, ['pause']);

    // A phone that does not receive it leaves the desktop playing.
    backend.delivered = 0;
    expect(await host().continueOnPhone('p1'), isFalse);
    expect(player.calls, ['pause']);
    await shutdown(tester);
  });

  testWidgets('pairing events reach the dialog stream and refresh devices', (
    tester,
  ) async {
    await boot(tester);
    final events = <LinkPairingEvent>[];
    final subscription = host().pairingEvents.listen(events.add);
    backend.deviceList = [
      const LinkPairedDevice(deviceId: 'p9', name: 'New', platform: 'ios'),
    ];
    backend.pairingEvent(
      const LinkPairedEvent(deviceId: 'p9', name: 'New', platform: 'ios'),
    );
    await flush(tester);
    expect(events.single, isA<LinkPairedEvent>());
    expect(hostState().devices.single.deviceId, 'p9');

    await host().revoke('p9');
    await flush(tester);
    expect(backend.calls, contains('revoke:p9'));
    expect(hostState().devices, isEmpty);
    // Awaiting the cancel would resume the test outside the fake clock.
    unawaited(subscription.cancel());
    await shutdown(tester);
  });
}
