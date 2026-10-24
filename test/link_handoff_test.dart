import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/features/link_handoff.dart';
import 'package:mornye/services/link/features/link_phone_player.dart';
import 'package:mornye/services/link/features/link_track_resolver.dart';
import 'package:mornye/services/link/link_protocol.dart';

import 'support/link_fakes.dart';

void main() {
  LinkHandoff handoff(
    FakeLinkClient client,
    FakePhonePlayer player, [
    FakeLibraryLookup? lookup,
  ]) {
    final records = lookup ?? FakeLibraryLookup();
    return LinkHandoff(
      client: client,
      player: player,
      refs: LinkTrackRefCache(lookup: records, server: client.server),
      resolver: LinkTrackResolver(lookup: records, server: client.server),
    );
  }

  group('Play on desktop', () {
    test('sends the queue around the current item and pauses', () async {
      final queue = [
        for (var i = 0; i < 300; i++)
          linkMediaItem(linkLocalMedia('t$i', title: 'Track $i')),
      ];
      final player = FakePhonePlayer(
        LinkPhoneSnapshot(
          queue: queue,
          index: 120,
          playing: true,
          positionMs: 42000,
        ),
      );
      final client = FakeLinkClient(
        onPost: (op, body) => {
          'resolved': 199,
          'missing': [3],
        },
      );
      final result = await handoff(client, player).playOnDesktop();

      final post = client.posts.single;
      expect(post.op, LinkOps.handoffPlay);
      final sent = post.body['queue'] as List;
      expect(sent, hasLength(200));
      expect((sent.first as Map)['title'], 'Track 70');
      expect(post.body['index'], 50);
      expect(post.body['positionMs'], 42000);
      expect(post.body['playing'], isTrue);
      expect(result!.started, isTrue);
      expect(result.missingTracks.single.title, 'Track 73');
      expect(player.calls, ['pause']);
    });

    test('starts the desktop even when the phone is paused', () async {
      final player = FakePhonePlayer(
        LinkPhoneSnapshot(
          queue: [linkMediaItem(linkLocalMedia('a'))],
          index: 0,
          playing: false,
          positionMs: 7000,
        ),
      );
      final client = FakeLinkClient(
        onPost: (op, body) => {'resolved': 1, 'missing': <int>[]},
      );
      await handoff(client, player).playOnDesktop();
      final post = client.posts.single;
      expect(post.body['playing'], isTrue);
      expect(post.body['positionMs'], 7000);
    });

    test('keeps playing when the desktop has none of the tracks', () async {
      final player = FakePhonePlayer(
        LinkPhoneSnapshot(
          queue: [linkMediaItem(linkLocalMedia('a'))],
          index: 0,
          playing: true,
        ),
      );
      final client = FakeLinkClient(
        onPost: (op, body) => {
          'resolved': 0,
          'missing': [0],
        },
      );
      final result = await handoff(client, player).playOnDesktop();
      expect(result!.started, isFalse);
      expect(result.missingTracks, hasLength(1));
      expect(player.calls, isEmpty);
    });

    test('does nothing while the phone plays nothing', () async {
      final client = FakeLinkClient();
      final result = await handoff(client, FakePhonePlayer()).playOnDesktop();
      expect(result, isNull);
      expect(client.posts, isEmpty);
    });
  });

  group('Continue on this phone', () {
    LinkLocalTrack local(String id, String title) =>
        LinkLocalTrack(linkLocalMedia(id, title: title));

    test('plays the resolved queue, skips missing tracks and pauses the '
        'desktop', () async {
      final client = FakeLinkClient(
        onGet: (op, query) => {
          'queue': [
            {'title': 'One', 'artist': 'Artist'},
            {'title': 'Gone', 'artist': 'Artist'},
            {'title': 'Two', 'artist': 'Artist'},
            {'title': 'Three', 'artist': 'Artist'},
          ],
          'index': 2,
          'positionMs': 30500,
          'playing': false,
        },
      );
      final player = FakePhonePlayer();
      final lookup = FakeLibraryLookup([
        local('one', 'One'),
        local('two', 'Two'),
        local('three', 'Three'),
      ]);
      final result = await handoff(client, player, lookup).continueOnPhone();

      expect(client.gets, [LinkOps.handoffCurrent]);
      expect(result.played, 3);
      expect(result.skipped.single.title, 'Gone');
      final played = player.played!;
      expect(
        [for (final item in played.items) item.id],
        ['one', 'two', 'three'],
      );
      expect(played.index, 1);
      expect(played.position, const Duration(milliseconds: 30500));
      expect(played.playing, isTrue);
      final pause = client.posts.single;
      expect(pause.op, LinkOps.command);
      expect(pause.body, {'action': 'pause', 'args': <String, dynamic>{}});
    });

    test('an unresolved current track starts the next one from its '
        'beginning', () async {
      final client = FakeLinkClient(
        onGet: (op, query) => {
          'queue': [
            {'title': 'One', 'artist': 'Artist'},
            {'title': 'Gone', 'artist': 'Artist'},
            {'title': 'Two', 'artist': 'Artist'},
          ],
          'index': 1,
          'positionMs': 9000,
          'playing': true,
        },
      );
      final player = FakePhonePlayer();
      final lookup = FakeLibraryLookup([
        local('one', 'One'),
        local('two', 'Two'),
      ]);
      final result = await handoff(client, player, lookup).continueOnPhone();
      expect(result.played, 2);
      expect(player.played!.index, 1);
      expect(player.played!.position, Duration.zero);
    });

    test('leaves the desktop playing when nothing resolves', () async {
      final client = FakeLinkClient(
        onGet: (op, query) => {
          'queue': [
            {'title': 'Gone', 'artist': 'Artist'},
          ],
          'index': 0,
          'positionMs': 0,
          'playing': true,
        },
      );
      final player = FakePhonePlayer();
      final result = await handoff(client, player).continueOnPhone();
      expect(result.started, isFalse);
      expect(result.skipped, hasLength(1));
      expect(player.calls, isEmpty);
      expect(client.posts, isEmpty);
    });

    test('streams desktop songs the phone has no file for', () async {
      final client = FakeLinkClient(
        onGet: (op, query) => {
          'queue': [
            {
              'title': 'Remote',
              'artist': 'Artist',
              'songId': 's1',
              'serverId': linkTestServer.serverId,
            },
          ],
          'index': 0,
          'positionMs': 0,
          'playing': true,
        },
      );
      final player = FakePhonePlayer();
      final result = await handoff(client, player).continueOnPhone();
      expect(result.played, 1);
      expect(player.played!.items.single.isNetwork, isTrue);
    });
  });
}
