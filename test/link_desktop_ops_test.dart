import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/link/desktop/link_catalog_index.dart';
import 'package:mornye/services/link/desktop/link_desktop_ops.dart';
import 'package:mornye/services/link/desktop/link_player.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';

import 'support/link_desktop_fakes.dart';

void main() {
  late FakeLinkPlayer player;
  late FakeLinkDownloads downloads;
  late List<DownloadItem> items;
  late List<String> opened;
  late DesktopLinkCatalogIndex? index;
  late int now;
  late String received;
  late LinkHostRouter router;
  late LinkDesktopOps ops;

  final songs = [
    catalogSong('l:a'),
    catalogSong('l:b'),
    catalogSong('d:c'),
    catalogSong('l:d'),
  ];

  setUp(() {
    player = FakeLinkPlayer();
    downloads = FakeLinkDownloads();
    items = [];
    opened = [];
    index = DesktopLinkCatalogIndex(
      serverId: 'srv',
      songs: songs,
      covers: const {'l:a': '/covers/a.jpg'},
    );
    now = 1000;
    received = '';
    router = LinkHostRouter();
    ops = LinkDesktopOps(
      player: player,
      downloads: downloads,
      downloadItems: () => items,
      openUrl: (url) async => opened.add(url),
      index: () => index,
      desktopName: () => 'Studio',
      deviceName: (id) => 'Phone $id',
      receivedDir: () => received,
      nowMs: () => now,
    )..register(router);
  });

  Future<Object?> call(
    String op, [
    Map<String, dynamic> args = const {},
    String deviceId = 'p1',
  ]) => router.dispatch(
    LinkRequest(requestId: 'r', op: op, deviceId: deviceId, args: args),
  );

  Matcher linkError(String code) =>
      isA<LinkException>().having((error) => error.code, 'code', code);

  LinkPlayerSnapshot snapshot({
    List<LinkPlayerItem>? queue,
    int index = 1,
    bool playing = true,
    int positionMs = 42000,
  }) => LinkPlayerSnapshot(
    queue: queue ?? [playerItem('a'), playerItem('b'), playerItem('x')],
    index: index,
    playing: playing,
    positionMs: positionMs,
    shuffle: true,
    repeat: LinkRepeatMode.all,
    volume: 0.5,
    updatedMs: 900,
  );

  test('registers every L2 op', () {
    for (final op in [
      LinkOps.state,
      LinkOps.command,
      LinkOps.handoffPlay,
      LinkOps.handoffAppend,
      LinkOps.handoffCurrent,
      LinkOps.queueAdd,
      LinkOps.downloads,
      LinkOps.open,
      LinkOps.resolve,
      LinkOps.getPlayQueue,
      LinkOps.savePlayQueue,
    ]) {
      expect(router.handles(op), isTrue, reason: op);
    }
  });

  test('state maps the desktop player with catalog ids', () async {
    player.current = snapshot();
    final json = await call(LinkOps.state) as Map<String, dynamic>;
    expect(json['playing'], isTrue);
    expect(json['positionMs'], 42000);
    expect(json['updatedMs'], 900);
    expect(json['index'], 1);
    expect(json['shuffle'], isTrue);
    expect(json['repeat'], 'all');
    expect(json['volume'], 0.5);
    expect(json['durationMs'], 200000);
    final track = json['track'] as Map<String, dynamic>;
    expect(track['title'], 'Title b');
    expect(track['songId'], 'l:b');
    expect(track['serverId'], 'srv');
    expect(track['matchKey'], 'title b|artist b');
    final queue = json['queue'] as List;
    expect(queue, hasLength(3));
    expect((queue.last as Map).containsKey('songId'), isFalse);
  });

  test('state sends a window of 200 around the current entry', () {
    final queue = [for (var i = 0; i < 500; i++) playerItem('q$i')];
    player.current = snapshot(queue: queue, index: 450);
    final state = ops.state();
    expect(state.queue, hasLength(LinkPlayerState.maxQueue));
    expect(state.queue.first.title, 'Title q300');
    expect(state.index, 150);
    expect(state.track!.title, 'Title q450');
  });

  group('command', () {
    setUp(() => player.current = snapshot());

    test('runs transport commands', () async {
      for (final command in [
        {'action': 'play'},
        {'action': 'pause'},
        {'action': 'toggle'},
        {'action': 'next'},
        {'action': 'previous'},
        {
          'action': 'seek',
          'args': {'positionMs': 5000},
        },
        {
          'action': 'volume',
          'args': {'value': 1.5},
        },
        {
          'action': 'shuffle',
          'args': {'enabled': false},
        },
        {
          'action': 'repeat',
          'args': {'mode': 'one'},
        },
        {
          'action': 'jump',
          'args': {'index': 2},
        },
      ]) {
        expect(await call(LinkOps.command, command), {'ok': true});
      }
      expect(player.calls, [
        'play',
        'pause',
        'pause',
        'next',
        'previous',
        'seek:5000',
        'volume:1.0',
        'shuffle:false',
        'repeat:one',
        'jump:2',
      ]);
    });

    test('rejects bad commands as invalid', () async {
      await expectLater(call(LinkOps.command), throwsA(linkError('invalid')));
      await expectLater(
        call(LinkOps.command, {'action': 'dance'}),
        throwsA(linkError('invalid')),
      );
      await expectLater(
        call(LinkOps.command, {'action': 'seek'}),
        throwsA(linkError('invalid')),
      );
      await expectLater(
        call(LinkOps.command, {
          'action': 'jump',
          'args': {'index': 3},
        }),
        throwsA(linkError('invalid')),
      );
      expect(player.calls, isEmpty);
    });

    test('play_queue plays the handed-off queue', () async {
      await call(LinkOps.command, {
        'action': 'play_queue',
        'args': {
          'queue': [
            {'title': 'Title b', 'artist': 'Artist b', 'durationMs': 200000},
          ],
          'index': 0,
          'positionMs': 1000,
        },
      });
      expect(player.playedQueue!.single.id, 'b');
    });
  });

  group('handoff/play', () {
    test('plays the resolved songs from the requested entry', () async {
      final result = await call(LinkOps.handoffPlay, {
        'queue': [
          {'title': 'Title a', 'artist': 'Artist a', 'durationMs': 200000},
          {'title': 'Missing', 'artist': 'Nobody'},
          {'songId': 'd:c', 'serverId': 'srv', 'title': 'Title c'},
          {'title': 'Title d', 'artist': 'Artist d', 'durationMs': 200900},
        ],
        'index': 2,
        'positionMs': 61000,
        'playing': false,
      });
      expect(result, {
        'resolved': 3,
        'missing': [1],
        'handoffId': isA<String>(),
      });
      expect(player.playedQueue!.map((media) => media.id), ['a', 'c', 'd']);
      expect(player.playedQueue!.first.source, '/music/a.flac');
      expect(
        player.playedQueue!.first.artUri,
        Uri.file('/covers/a.jpg').toString(),
      );
      expect(player.playedIndex, 1);
      expect(player.playedPosition, const Duration(seconds: 61));
      expect(player.playedPlaying, isFalse);
    });

    test('starts at the next resolved entry from the start', () async {
      await call(LinkOps.handoffPlay, {
        'queue': [
          {'title': 'Title a', 'artist': 'Artist a'},
          {'title': 'Missing', 'artist': 'Nobody'},
          {'title': 'Title b', 'artist': 'Artist b'},
        ],
        'index': 1,
        'positionMs': 61000,
      });
      expect(player.playedIndex, 1);
      expect(player.playedPosition, Duration.zero);
      expect(player.playedPlaying, isTrue);
    });

    test('nothing resolved plays nothing', () async {
      final result = await call(LinkOps.handoffPlay, {
        'queue': [
          {'title': 'Missing', 'artist': 'Nobody'},
        ],
      });
      expect(result, {
        'resolved': 0,
        'missing': [0],
      });
      expect(player.calls, isEmpty);
    });

    test('needs a catalog and a queue', () async {
      await expectLater(
        call(LinkOps.handoffPlay),
        throwsA(linkError('invalid')),
      );
      index = null;
      await expectLater(
        call(LinkOps.handoffPlay, {'queue': <Object?>[]}),
        throwsA(linkError('unavailable')),
      );
    });

    test('check only reports what is missing', () async {
      final result = await call(LinkOps.handoffPlay, {
        'queue': [
          {'title': 'Title a', 'artist': 'Artist a'},
          {'title': 'Missing', 'artist': 'Nobody'},
        ],
        'check': true,
      });
      expect(result, {
        'resolved': 1,
        'missing': [1],
      });
      expect(player.calls, isEmpty);
    });
  });

  group('songs a phone uploaded', () {
    const fileId = '0123456789abcdef0123456789abcdef';
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('link_received_');
      received = dir.path;
      await File('${dir.path}/$fileId.flac').writeAsBytes([1]);
      // Partial uploads and foreign names are not songs.
      await File('${dir.path}/.$fileId.flac.1a2b.part').writeAsBytes([1]);
      await File('${dir.path}/notes.txt').writeAsBytes([1]);
    });

    tearDown(() => dir.delete(recursive: true));

    Map<String, dynamic> phoneSong(String title, {String? id = fileId}) => {
      'title': title,
      'artist': 'Phone',
      'album': 'Pocket',
      'durationMs': 180000,
      'fileId': ?id,
    };

    test('play from the uploaded file when the Library lacks them', () async {
      final result = await call(LinkOps.handoffPlay, {
        'queue': [
          phoneSong('Only on the phone'),
          phoneSong('Not sent', id: 'ffffffffffffffffffffffffffffffff'),
          {'title': 'Title b', 'artist': 'Artist b'},
        ],
        'index': 0,
        'positionMs': 5000,
      });
      expect(result, containsPair('missing', [1]));
      final first = player.playedQueue!.first;
      expect(first.source, '${dir.path}/$fileId.flac');
      expect(first.title, 'Only on the phone');
      expect(first.album, 'Pocket');
      expect(first.duration, const Duration(minutes: 3));
      expect(first.artUri, isNull);
      expect(player.playedQueue!.last.id, 'b');
      expect(player.playedPosition, const Duration(seconds: 5));
    });

    test('the Library copy wins over an uploaded file', () async {
      await call(LinkOps.handoffPlay, {
        'queue': [
          {...phoneSong('Title a'), 'artist': 'Artist a', 'durationMs': 200000},
        ],
      });
      expect(player.playedQueue!.single.source, '/music/a.flac');
    });

    test('append queues more songs while that handoff plays', () async {
      final started = await call(LinkOps.handoffPlay, {
        'queue': [
          {'title': 'Title a', 'artist': 'Artist a'},
        ],
      });
      final handoffId = (started! as Map)['handoffId'];
      final result = await call(LinkOps.handoffAppend, {
        'handoffId': handoffId,
        'queue': [
          phoneSong('Sent later'),
          {'title': 'Missing', 'artist': 'Nobody'},
          {'title': 'Title b', 'artist': 'Artist b'},
        ],
      });
      expect(result, {'resolved': 2});
      expect(player.appended.single.map((media) => media.title), [
        'Sent later',
        'Title b',
      ]);
    });

    test('append refuses a queue that no longer plays', () async {
      await call(LinkOps.handoffPlay, {
        'queue': [
          {'title': 'Title a', 'artist': 'Artist a'},
        ],
      });
      await expectLater(
        call(LinkOps.handoffAppend, {
          'handoffId': 'old',
          'queue': [phoneSong('Late')],
        }),
        throwsA(linkError('invalid')),
      );
      expect(player.appended, isEmpty);
    });

    test('queue/add queues the songs it has, next when asked', () async {
      final result = await call(LinkOps.queueAdd, {
        'queue': [
          phoneSong('Sent'),
          {'title': 'Missing', 'artist': 'Nobody'},
          {'title': 'Title b', 'artist': 'Artist b'},
        ],
        'next': true,
      });
      expect(result, {'resolved': 2});
      expect(player.calls, ['playNext']);
      expect(player.appended.single.map((media) => media.title), [
        'Sent',
        'Title b',
      ]);
      await expectLater(call(LinkOps.queueAdd), throwsA(linkError('invalid')));
    });
  });

  test('handoff/current returns the desktop queue and position', () async {
    player.current = snapshot();
    final result = await call(LinkOps.handoffCurrent) as Map<String, dynamic>;
    expect(result['index'], 1);
    expect(result['positionMs'], 42000);
    expect(result['playing'], isTrue);
    expect((result['queue'] as List).first, {
      'title': 'Title a',
      'artist': 'Artist a',
      'album': 'Album',
      'durationMs': 200000,
      'matchKey': 'title a|artist a',
      'songId': 'l:a',
      'serverId': 'srv',
    });
  });

  group('downloads', () {
    Track track(String id) => Track(
      id: id,
      name: 'Song $id',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 100,
    );

    test('GET summarizes the queue', () async {
      items = [
        DownloadItem(
          id: 'q1',
          track: track('1'),
          service: 'svc',
          status: DownloadStatus.downloading,
          progress: 0.4,
          createdAt: DateTime(2024),
        ),
        DownloadItem(
          id: 'q2',
          track: track('2'),
          service: 'svc',
          status: DownloadStatus.completed,
          createdAt: DateTime(2024),
        ),
      ];
      expect(await call(LinkOps.downloads, {'_method': 'GET'}), {
        'items': [
          {
            'id': 'q1',
            'title': 'Song 1',
            'artist': 'Artist',
            'status': 'downloading',
            'progress': 0.4,
          },
          {
            'id': 'q2',
            'title': 'Song 2',
            'artist': 'Artist',
            'status': 'completed',
            'progress': 1.0,
          },
        ],
      });
    });

    test('POST url resolves the link and queues its tracks', () async {
      downloads.resolved = (
        tracks: [track('1'), track('2')],
        playlistName: 'Mix',
      );
      expect(
        await call(LinkOps.downloads, {'url': 'https://example.com/a/1'}),
        {'queued': 2},
      );
      expect(downloads.urls, ['https://example.com/a/1']);
      expect(downloads.queued.single.playlistName, 'Mix');
    });

    test('POST url passes resolution errors through', () async {
      downloads.resolveError = const LinkException(
        'invalid',
        'url_not_recognized',
      );
      await expectLater(
        call(LinkOps.downloads, {'url': 'https://example.com/x'}),
        throwsA(linkError('invalid')),
      );
    });

    test('POST tracks queues them with the requested service', () async {
      expect(
        await call(LinkOps.downloads, {
          'tracks': [track('7').toJson()],
          'service': 'svc',
          'quality': 'LOSSLESS',
        }),
        {'queued': 1},
      );
      final queued = downloads.queued.single;
      expect(queued.tracks.single.id, '7');
      expect(queued.service, 'svc');
      expect(queued.quality, 'LOSSLESS');
    });

    test('POST without url or tracks is invalid', () async {
      await expectLater(call(LinkOps.downloads), throwsA(linkError('invalid')));
      await expectLater(
        call(LinkOps.downloads, {
          'tracks': ['nope'],
        }),
        throwsA(linkError('invalid')),
      );
    });
  });

  test('open accepts web, Spotify and app links only', () async {
    expect(await call(LinkOps.open, {'url': 'https://example.com/t/1'}), {
      'ok': true,
    });
    expect(await call(LinkOps.open, {'url': 'mornye://callback?x=1'}), {
      'ok': true,
    });
    for (final url in [
      'file:///etc/passwd',
      'javascript:alert(1)',
      'http://',
    ]) {
      await expectLater(
        call(LinkOps.open, {'url': url}),
        throwsA(linkError('invalid')),
        reason: url,
      );
    }
    expect(opened, ['https://example.com/t/1', 'mornye://callback?x=1']);
  });

  test('resolve maps refs to song ids in order', () async {
    expect(
      await call(LinkOps.resolve, {
        'tracks': [
          {'title': 'Title b', 'artist': 'Artist b', 'durationMs': 199000},
          {'title': 'Missing', 'artist': 'Nobody'},
          'garbage',
        ],
      }),
      {
        'songIds': ['l:b', null, null],
      },
    );
    index = null;
    await expectLater(
      call(LinkOps.resolve, {'tracks': <Object?>[]}),
      throwsA(linkError('unavailable')),
    );
  });

  group('Subsonic play queue', () {
    test('returns the desktop queue before any save', () async {
      player.current = snapshot(
        queue: [playerItem('a'), playerItem('x'), playerItem('b')],
        index: 2,
      );
      expect(await call(LinkOps.getPlayQueue), {
        'songIds': ['l:a', 'l:b'],
        'currentId': 'l:b',
        'positionMs': 42000,
        'changedMs': 1000,
        'changedBy': 'Studio',
      });
    });

    test('keeps a saved queue per device until the desktop changes', () async {
      // The player hands out the same list while its queue is unchanged.
      final queue = [playerItem('a'), playerItem('b'), playerItem('x')];
      player.current = snapshot(queue: queue);
      ops.observe(player.current);
      now = 2000;
      expect(
        await call(LinkOps.savePlayQueue, {
          'songs': [
            {'id': 'l:b'},
            {'id': 'd:c'},
            {'title': 'no id'},
          ],
          'currentId': 'd:c',
          'positionMs': 3000,
        }),
        <String, dynamic>{},
      );
      final saved = {
        'songIds': ['l:b', 'd:c'],
        'currentId': 'd:c',
        'positionMs': 3000,
        'changedMs': 2000,
        'changedBy': 'Phone p1',
      };
      expect(await call(LinkOps.getPlayQueue), saved);

      // Another device has its own queue.
      final other = await call(LinkOps.getPlayQueue, {}, 'p2') as Map;
      expect(other['changedBy'], 'Studio');

      // A position tick on the same queue keeps the saved one.
      now = 3000;
      ops.observe(snapshot(queue: queue, positionMs: 50000));
      expect(await call(LinkOps.getPlayQueue), saved);

      // A new desktop queue wins.
      final newer = snapshot(queue: [playerItem('d')], index: 0);
      player.current = newer;
      ops.observe(newer);
      expect(await call(LinkOps.getPlayQueue), {
        'songIds': ['l:d'],
        'currentId': 'l:d',
        'positionMs': 42000,
        'changedMs': 3000,
        'changedBy': 'Studio',
      });
    });
  });

  group('player state mapping', () {
    LinkPlayerState state0({int positionMs = 0, int updatedMs = 0}) =>
        LinkPlayerState(
          track: const TrackRef(title: 'A', artist: 'B'),
          playing: true,
          positionMs: positionMs,
          durationMs: 100000,
          updatedMs: updatedMs,
        );

    test('a position that playback explains is not a change', () {
      expect(
        linkPlayerStateChanged(
          state0(),
          state0(positionMs: 5000, updatedMs: 5000),
        ),
        isFalse,
      );
      expect(
        linkPlayerStateChanged(
          state0(),
          state0(positionMs: 30000, updatedMs: 5000),
        ),
        isTrue,
        reason: 'a seek',
      );
    });

    test('anything else is a change', () {
      final base = state0();
      expect(
        linkPlayerStateChanged(
          base,
          LinkPlayerState(
            track: base.track,
            playing: false,
            durationMs: base.durationMs,
            updatedMs: 0,
          ),
        ),
        isTrue,
      );
      expect(
        linkPlayerStateChanged(
          base,
          LinkPlayerState(
            track: const TrackRef(title: 'C', artist: 'B'),
            playing: true,
            durationMs: base.durationMs,
            updatedMs: 0,
          ),
        ),
        isTrue,
      );
    });

    test('handoff args carry the queue, index and position', () {
      expect(
        linkHandoffArgs(
          LinkPlayerState(
            track: const TrackRef(title: 'A', artist: 'B'),
            queue: const [TrackRef(title: 'A', artist: 'B')],
            index: 0,
            positionMs: 7,
            updatedMs: 0,
          ),
          playing: true,
        ),
        {
          'queue': [
            {'title': 'A', 'artist': 'B'},
          ],
          'index': 0,
          'positionMs': 7,
          'playing': true,
        },
      );
    });

    test('queue windows stay inside the queue', () {
      expect(linkQueueWindow(10, 3), (start: 0, end: 10));
      expect(linkQueueWindow(500, 0), (start: 0, end: 200));
      expect(linkQueueWindow(500, 499), (start: 300, end: 500));
      expect(linkQueueWindow(500, -1), (start: 0, end: 200));
    });
  });
}
