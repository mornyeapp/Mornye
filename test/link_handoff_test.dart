import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/features/link_handoff.dart';
import 'package:mornye/services/link/features/link_phone_files.dart';
import 'package:mornye/services/link/features/link_phone_player.dart';
import 'package:mornye/services/link/features/link_track_resolver.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/playable_media.dart';

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
          shuffle: true,
          repeat: LinkRepeatMode.one,
          autoplay: true,
          autoMix: true,
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
      expect(post.body['shuffle'], isTrue);
      expect(post.body['repeat'], 'one');
      expect(post.body['autoplay'], isTrue);
      expect(post.body['autoMix'], isTrue);
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

  group('Play on desktop with songs only the phone has', () {
    late Directory dir;
    late LinkPhoneFiles files;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('link_handoff_');
      files = LinkPhoneFiles(copyContentUri: (_) async => null);
    });

    tearDown(() => dir.delete(recursive: true));

    /// A queued song whose file is on the phone when [bytes] is given.
    Future<MediaItem> song(
      String name, {
      List<int>? bytes,
      Duration? duration,
    }) async {
      final path = '${dir.path}/$name.flac';
      if (bytes != null) await File(path).writeAsBytes(bytes);
      return linkMediaItem(
        PlayableMedia(
          id: name,
          source: path,
          title: name,
          artist: 'Artist',
          album: 'Album',
          duration: duration,
        ),
      );
    }

    LinkHandoff withFiles(
      FakeLinkClient client,
      FakePhonePlayer player, {
      int aheadSongs = linkHandoffAheadSongs,
      int aheadBytes = linkHandoffAheadBytes,
    }) {
      final records = FakeLibraryLookup();
      return LinkHandoff(
        client: client,
        player: player,
        refs: LinkTrackRefCache(lookup: records, server: client.server),
        resolver: LinkTrackResolver(lookup: records, server: client.server),
        files: files,
        aheadSongs: aheadSongs,
        aheadBytes: aheadBytes,
      );
    }

    /// The desktop pushes that it plays [title].
    void plays(FakeLinkClient client, String title) => client.push({
      'type': LinkMessageTypes.playerState,
      'state': LinkPlayerState(
        track: TrackRef(title: title, artist: 'Artist'),
        playing: true,
        updatedMs: 0,
      ).toJson(),
    });

    /// The desktop: `check` reports [missing], playing answers `h1`.
    FakeLinkClient desktop(List<int> missing) => FakeLinkClient(
      onPost: (op, body) => switch (op) {
        LinkOps.handoffPlay when body['check'] == true => {
          'resolved': (body['queue'] as List).length - missing.length,
          'missing': missing,
        },
        LinkOps.handoffPlay => {
          'resolved': (body['queue'] as List).length,
          'missing': <int>[],
          'handoffId': 'h1',
        },
        _ => {'resolved': 1},
      },
    );

    List<String> titles(Map<String, dynamic> body) => [
      for (final item in body['queue'] as List)
        (item as Map)['title'] as String,
    ];

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test('uploads the current song before the desktop plays it', () async {
      final a = await song('a', bytes: [1, 2, 3]);
      final b = await song('b');
      final player = FakePhonePlayer(
        LinkPhoneSnapshot(queue: [a, b], index: 0, playing: true),
      );
      final client = desktop([0]);
      final progress = <(int, int)>[];
      final result = await withFiles(
        client,
        player,
      ).playOnDesktop(onSending: (sent, total) => progress.add((sent, total)));

      final fileId = linkFileIdFor(a.extras!['source'] as String, 3);
      expect(client.uploads.single.name, '$fileId.flac');
      expect(client.uploads.single.bytes, [1, 2, 3]);
      expect(progress.last, (3, 3));
      final check = client.posts.first;
      expect(check.body['check'], isTrue);
      final play = client.posts[1].body;
      expect(play['check'], isNull);
      expect(titles(play), ['a', 'b']);
      expect(((play['queue'] as List).first as Map)['fileId'], fileId);
      expect(((play['queue'] as List).last as Map)['fileId'], isNull);
      expect(result!.started, isTrue);
      expect(player.calls, ['pause']);
    });

    test('the desktop starts a large song before all of it is sent', () async {
      const size = 2 << 20;
      final a = await song('a', bytes: List.filled(size, 1));
      final b = await song('b', bytes: [2]);
      final player = FakePhonePlayer(
        LinkPhoneSnapshot(queue: [a, b], index: 0, playing: true),
      );
      final client = desktop([0, 1]);
      final rest = Completer<void>();
      client.whileUploading = (name, length, sent) async {
        if (length != size) return;
        sent(600 * 1024);
        await rest.future;
        sent(length);
      };
      final progress = <(int, int)>[];
      await withFiles(
        client,
        player,
      ).playOnDesktop(onSending: (sent, total) => progress.add((sent, total)));

      final play = client.posts[1].body;
      final fileId = linkFileIdFor(a.extras!['source'] as String, size);
      expect(play['arriving'], [
        {'name': '$fileId.flac', 'size': size},
      ]);
      expect(titles(play), ['a']);
      // The start needs the header and a first buffer.
      expect(progress.single, (600 * 1024, linkStartBytes(size, 0)));
      expect(player.calls, ['pause']);
      // The next song waits until this one is whole.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.uploads, isEmpty);

      rest.complete();
      await until(() => client.posts.length == 3);
      expect(
        [for (final upload in client.uploads) upload.bytes.length],
        [size, 1],
      );
      expect(client.posts.last.op, LinkOps.handoffAppend);
    });

    test('a song resumed deep in waits for the bytes up to there', () async {
      const size = 4 << 20;
      final a = await song(
        'a',
        bytes: List.filled(size, 1),
        duration: const Duration(minutes: 4),
      );
      final player = FakePhonePlayer(
        LinkPhoneSnapshot(
          queue: [a],
          index: 0,
          playing: true,
          positionMs: 120000,
        ),
      );
      final client = desktop([0]);
      final halfway = Completer<void>();
      final rest = Completer<void>();
      client.whileUploading = (name, length, sent) async {
        sent(1 << 20);
        await halfway.future;
        sent(3 << 20);
        await rest.future;
        sent(length);
      };
      final started = withFiles(client, player).playOnDesktop();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Only the check went out: the desktop would wait on a quarter.
      expect(client.posts, hasLength(1));

      halfway.complete();
      await started;
      expect(client.posts, hasLength(2));
      expect(client.posts.last.body['positionMs'], 120000);
      rest.complete();
    });

    test(
      'sends later songs in the background and queues them in order',
      () async {
        final player = FakePhonePlayer(
          LinkPhoneSnapshot(
            queue: [
              await song('a'),
              await song('b', bytes: [1]),
              await song('c'),
              await song('d', bytes: [2]),
            ],
            index: 0,
            playing: true,
          ),
        );
        final client = desktop([1, 3]);
        await withFiles(client, player).playOnDesktop();

        expect(titles(client.posts[1].body), ['a']);
        await until(() => client.posts.length == 4);
        expect(
          [for (final upload in client.uploads) upload.bytes],
          [
            [1],
            [2],
          ],
        );
        final appends = client.posts.skip(2).toList();
        expect(
          [for (final post in appends) post.op],
          [LinkOps.handoffAppend, LinkOps.handoffAppend],
        );
        expect(appends.first.body['handoffId'], 'h1');
        expect(titles(appends.first.body), ['b', 'c']);
        expect(titles(appends.last.body), ['d']);
      },
    );

    test(
      'a song that fails to send is skipped, the rest still queue',
      () async {
        final player = FakePhonePlayer(
          LinkPhoneSnapshot(
            queue: [
              await song('a'),
              await song('b', bytes: [1]),
              await song('c'),
            ],
            index: 0,
            playing: true,
          ),
        );
        final client = desktop([1])
          ..onUpload = (_) => const LinkException('unavailable', 'gone');
        await withFiles(client, player).playOnDesktop();

        await until(() => client.posts.length == 3);
        expect(client.posts.last.op, LinkOps.handoffAppend);
        expect(titles(client.posts.last.body), ['c']);
      },
    );

    test(
      'sends songs only so far ahead of the one the desktop plays',
      () async {
        final player = FakePhonePlayer(
          LinkPhoneSnapshot(
            queue: [
              await song('a'),
              await song('b', bytes: [1]),
              await song('c'),
              await song('d', bytes: [2]),
              await song('e', bytes: [3]),
            ],
            index: 0,
            playing: true,
          ),
        );
        final client = desktop([1, 3, 4]);
        await withFiles(client, player, aheadSongs: 1).playOnDesktop();

        await until(() => client.posts.length == 3);
        expect(titles(client.posts.last.body), ['b', 'c']);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // 'b' waits on the desktop, so 'd' does not go yet.
        expect(client.uploads, hasLength(1));

        plays(client, 'b');
        await until(() => client.posts.length == 4);
        expect(client.uploads.last.bytes, [2]);
        expect(titles(client.posts.last.body), ['d']);

        // The desktop's own 'c' leaves 'd' ahead of it.
        plays(client, 'c');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(client.uploads, hasLength(2));

        plays(client, 'd');
        await until(() => client.posts.length == 5);
        expect(client.uploads.last.bytes, [3]);
        expect(titles(client.posts.last.body), ['e']);
        expect([
          for (final post in client.posts.skip(2)) post.op,
        ], everyElement(LinkOps.handoffAppend));
      },
    );

    test('keeps the songs sent ahead within the byte budget', () async {
      final player = FakePhonePlayer(
        LinkPhoneSnapshot(
          queue: [
            await song('a'),
            await song('b', bytes: [1, 1]),
            await song('c', bytes: [2, 2]),
            await song('d', bytes: [3, 3]),
          ],
          index: 0,
          playing: true,
        ),
      );
      final client = desktop([1, 2, 3]);
      await withFiles(client, player, aheadBytes: 3).playOnDesktop();

      // 'c' passes the budget once 'b' is ahead; nothing more goes.
      await until(() => client.uploads.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.uploads.last.bytes, [2, 2]);
      expect(client.uploads, hasLength(2));

      plays(client, 'b');
      await until(() => client.uploads.length == 3);
      expect(client.uploads.last.bytes, [3, 3]);
    });

    test('stops sending once another queue plays on the desktop', () async {
      final player = FakePhonePlayer(
        LinkPhoneSnapshot(
          queue: [
            await song('a'),
            await song('b', bytes: [1]),
            await song('c', bytes: [2]),
          ],
          index: 0,
          playing: true,
        ),
      );
      final client = desktop([1, 2]);
      final answer = client.onPost!;
      client.onPost = (op, body) =>
          op == LinkOps.handoffAppend && (body['queue'] as List).isEmpty
          ? const LinkException('invalid', 'Another queue plays')
          : answer(op, body);
      await withFiles(client, player, aheadSongs: 1).playOnDesktop();
      await until(() => client.posts.length == 3);

      // The desktop plays a song outside the queue: the phone asks whether
      // the queue still plays there.
      plays(client, 'Elsewhere');
      await until(() => client.posts.length == 4);
      expect(client.posts.last.op, LinkOps.handoffAppend);
      expect(client.posts.last.body['handoffId'], 'h1');
      expect(client.posts.last.body['queue'], isEmpty);

      plays(client, 'b');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.uploads, hasLength(1));
      expect(client.posts, hasLength(4));
    });

    test('sending another queue stops songs waiting for the desktop', () async {
      final player = FakePhonePlayer(
        LinkPhoneSnapshot(
          queue: [
            await song('a'),
            await song('b', bytes: [1]),
            await song('c', bytes: [2]),
          ],
          index: 0,
          playing: true,
        ),
      );
      final client = desktop([1, 2]);
      await withFiles(client, player, aheadSongs: 1).playOnDesktop();
      await until(() => client.posts.length == 3);

      files.begin();
      plays(client, 'b');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.uploads, hasLength(1));
      expect(client.posts, hasLength(3));
    });

    test('sending another queue stops the uploads of the one before', () async {
      final player = FakePhonePlayer(
        LinkPhoneSnapshot(
          queue: [
            await song('a'),
            await song('b', bytes: [1]),
          ],
          index: 0,
          playing: true,
        ),
      );
      final client = desktop([1]);
      client.onUpload = (_) {
        files.begin();
        return null;
      };
      await withFiles(client, player).playOnDesktop();

      await until(() => client.uploads.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        client.posts.map((post) => post.op),
        isNot(contains(LinkOps.handoffAppend)),
      );
    });

    test('asks nothing more when no queued song is a phone file', () async {
      final player = FakePhonePlayer(
        LinkPhoneSnapshot(queue: [await song('a')], index: 0, playing: true),
      );
      final client = desktop(const []);
      await withFiles(client, player).playOnDesktop();
      expect(client.posts.single.body['check'], isNull);
      expect(client.uploads, isEmpty);
    });

    test('songs picked while the desktop plays start there', () async {
      final player = FakePhonePlayer();
      final client = desktop(const [0]);
      final items = [
        await song('a', bytes: [1, 2]),
        await song('b'),
      ];
      final result = await withFiles(
        client,
        player,
      ).playItemsOnDesktop(items, index: 1);

      expect(client.uploads, isEmpty);
      final play = client.posts.last.body;
      expect(titles(play), ['b']);
      expect(play['index'], 0);
      expect(play['positionMs'], 0);
      expect(result!.started, isTrue);
      // 'a' plays before 'b', so it is not sent.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.uploads, isEmpty);
    });

    test('songs added while the desktop plays are sent first', () async {
      final client = desktop(const [0]);
      final queued = await withFiles(client, FakePhonePlayer())
          .addToDesktopQueue([
            await song('a', bytes: [1, 2]),
            await song('b'),
          ], playNext: true);

      expect(client.uploads, hasLength(1));
      final add = client.posts.last;
      expect(add.op, LinkOps.queueAdd);
      expect(titles(add.body), ['a', 'b']);
      expect(add.body['next'], isTrue);
      expect(queued, 1);
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
          'shuffle': true,
          'repeat': 'all',
          'autoplay': true,
          'autoMix': true,
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
      expect(player.snapshot.shuffle, isTrue);
      expect(player.snapshot.repeat, LinkRepeatMode.all);
      expect(player.snapshot.autoplay, isTrue);
      expect(player.snapshot.autoMix, isTrue);
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
