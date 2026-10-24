import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/features/link_handoff.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/services/link/features/link_phone_player.dart';
import 'package:mornye/services/link/features/link_phone_session.dart';
import 'package:mornye/services/link/features/link_track_resolver.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/share_intent_service.dart';

import 'support/link_fakes.dart';

void main() {
  late FakeLinkClient client;
  late FakePhonePlayer player;
  late List<String> opened;
  var now = 1000;

  LinkPhoneSession session([FakeLibraryLookup? lookup]) {
    final records = lookup ?? FakeLibraryLookup();
    final refs = LinkTrackRefCache(lookup: records, server: client.server);
    return LinkPhoneSession(
      client: client,
      player: player,
      refs: refs,
      handoff: LinkHandoff(
        client: client,
        player: player,
        refs: refs,
        resolver: LinkTrackResolver(lookup: records, server: client.server),
      ),
      openUrl: opened.add,
      nowMs: () => now,
    );
  }

  // The player keeps its queue list until the queue changes.
  final queue = [
    for (final id in ['a', 'b', 'c'])
      linkMediaItem(linkLocalMedia(id, title: 'Song $id')),
  ];

  LinkPhoneSnapshot playing({int positionMs = 0, int index = 0}) =>
      LinkPhoneSnapshot(
        queue: queue,
        index: index,
        playing: true,
        positionMs: positionMs,
        durationMs: 200000,
      );

  setUp(() {
    client = FakeLinkClient();
    player = FakePhonePlayer(playing());
    opened = [];
    now = 1000;
  });

  group('state push', () {
    testWidgets('sends once 250 ms after a burst of changes', (tester) async {
      final linked = session()..start();
      await tester.pump(const Duration(milliseconds: 250));
      expect(client.sentStates, hasLength(1));
      expect(client.sentStates.single.track?.title, 'Song a');
      expect(client.sentStates.single.updatedMs, 1000);

      player.update(playing(index: 1));
      await tester.pump(const Duration(milliseconds: 100));
      player.update(playing(index: 2));
      await tester.pump(const Duration(milliseconds: 249));
      expect(client.sentStates, hasLength(1));
      await tester.pump(const Duration(milliseconds: 1));
      expect(client.sentStates, hasLength(2));
      expect(client.sentStates.last.index, 2);
      expect(client.sentStates.last.queue, hasLength(3));
      linked.dispose();
    });

    testWidgets('position ticks wait for the heartbeat, a seek does not', (
      tester,
    ) async {
      final linked = session()..start();
      await tester.pump(const Duration(milliseconds: 250));
      expect(client.sentStates, hasLength(1));

      // Playback moving on as expected is no news.
      now += 5000;
      player.update(playing(positionMs: 5000));
      await tester.pump(const Duration(seconds: 1));
      expect(client.sentStates, hasLength(1));

      player.update(playing(positionMs: 90000));
      await tester.pump(const Duration(milliseconds: 250));
      expect(client.sentStates, hasLength(2));
      expect(client.sentStates.last.positionMs, 90000);

      await tester.pump(const Duration(seconds: 15));
      expect(client.sentStates, hasLength(3));
      linked.dispose();
    });

    testWidgets('sends again after a reconnect', (tester) async {
      final linked = session()..start();
      await tester.pump(const Duration(milliseconds: 250));
      client.setConnection(LinkConnectionState.disconnected);
      client.setConnection(LinkConnectionState.connected);
      await tester.pump(const Duration(milliseconds: 250));
      expect(client.sentStates, hasLength(2));
      linked.dispose();
      await tester.pump(const Duration(seconds: 30));
      expect(client.sentStates, hasLength(2));
    });
  });

  group('incoming messages', () {
    Future<void> command(
      LinkPhoneSession linked,
      String action, [
      Map<String, dynamic> args = const {},
    ]) => linked.handle({
      'type': LinkMessageTypes.command,
      'action': action,
      'args': args,
    });

    testWidgets('every command drives the phone player', (tester) async {
      final linked = session()..start();
      await command(linked, LinkActions.pause);
      await command(linked, LinkActions.play);
      await command(linked, LinkActions.toggle);
      await command(linked, LinkActions.next);
      await command(linked, LinkActions.previous);
      await command(linked, LinkActions.seek, {'positionMs': 1234});
      await command(linked, LinkActions.volume, {'value': 1.7});
      await command(linked, LinkActions.shuffle, {'enabled': true});
      await command(linked, LinkActions.repeat, {'mode': 'one'});
      await command(linked, LinkActions.repeat, {'mode': 'sideways'});
      await command(linked, LinkActions.jump, {'index': 2});
      await command(linked, LinkActions.jump, {'index': 9});
      await command(linked, 'dance');
      expect(player.calls, [
        'pause',
        'play',
        'pause',
        'next',
        'previous',
        'seek 1234',
        'volume 1.0',
        'shuffle true',
        'repeat one',
        'jump 2',
      ]);
      await tester.pump(const Duration(milliseconds: 250));
      linked.dispose();
    });

    testWidgets('jump indexes count from the window the desktop saw', (
      tester,
    ) async {
      player.update(
        LinkPhoneSnapshot(
          queue: [
            for (var i = 0; i < 300; i++) linkMediaItem(linkLocalMedia('t$i')),
          ],
          index: 150,
          playing: true,
        ),
      );
      final linked = session()..start();
      await tester.pump(const Duration(milliseconds: 250));
      expect(client.sentStates.single.index, 50);
      await command(linked, LinkActions.jump, {'index': 51});
      expect(player.calls, ['jump 151']);
      linked.dispose();
    });

    testWidgets('play_queue continues the given queue on the phone', (
      tester,
    ) async {
      final linked = session(
        FakeLibraryLookup([LinkLocalTrack(linkLocalMedia('x', title: 'X'))]),
      )..start();
      await command(linked, LinkActions.playQueue, {
        'queue': [
          {'title': 'Missing', 'artist': 'Artist'},
          {'title': 'X', 'artist': 'Artist'},
        ],
        'index': 1,
        'positionMs': 4000,
        'playing': false,
      });
      final played = player.played!;
      expect(played.items.single.id, 'x');
      expect(played.index, 0);
      expect(played.position, const Duration(seconds: 4));
      expect(played.playing, isFalse);
      await tester.pump(const Duration(milliseconds: 250));
      linked.dispose();
    });

    testWidgets('open messages go to the shared link handler', (tester) async {
      final linked = session()..start();
      client.push({
        'type': LinkMessageTypes.open,
        'url': '  https://music.example.com/album/1 ',
      });
      client.push({'type': LinkMessageTypes.open, 'url': ' '});
      client.push({'type': LinkMessageTypes.open});
      await tester.pump();
      expect(opened, ['https://music.example.com/album/1']);
      await tester.pump(const Duration(milliseconds: 250));
      linked.dispose();
    });

    test('the default open hook is the shared link path', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final received = ShareIntentService().sharedUrlStream.first;
      container.read(linkOpenUrlProvider)('https://music.example.com/t/9');
      expect(await received, 'https://music.example.com/t/9');
      // A shell that mounts later still picks the link up.
      expect(
        ShareIntentService().consumePendingUrl(),
        'https://music.example.com/t/9',
      );
    });
  });
}
