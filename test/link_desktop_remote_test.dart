import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/features/link_desktop_remote.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';

import 'support/link_fakes.dart';

Map<String, dynamic> _desktopState({
  bool playing = true,
  int positionMs = 10000,
  int updatedMs = 5,
}) => LinkPlayerState(
  track: const TrackRef(title: 'Desk', artist: 'Artist', durationMs: 180000),
  playing: playing,
  positionMs: positionMs,
  durationMs: 180000,
  updatedMs: updatedMs,
  queue: const [
    TrackRef(title: 'Desk', artist: 'Artist', durationMs: 180000),
    TrackRef(title: 'Next', artist: 'Artist', durationMs: 120000),
  ],
  index: 0,
).toJson();

void main() {
  late FakeLinkClient client;
  late ProviderContainer container;
  var now = 1000000;

  Future<LinkDesktopRemote> start() async {
    final remote = container.read(linkDesktopRemoteProvider.notifier);
    container.listen(linkDesktopRemoteProvider, (_, _) {});
    await pumpEventQueue();
    return remote;
  }

  LinkRemoteState read() => container.read(linkDesktopRemoteProvider);

  setUp(() {
    now = 1000000;
    client = FakeLinkClient(
      onGet: (op, query) => switch (op) {
        LinkOps.state => _desktopState(),
        LinkOps.downloads => {
          'items': [
            {
              'id': 'd1',
              'title': 'Queued',
              'artist': 'Artist',
              'status': 'Downloading',
              'progress': 40,
            },
          ],
        },
        _ => null,
      },
    );
    container = ProviderContainer(
      overrides: [
        linkPhoneClientProvider.overrideWithValue(client),
        linkDesktopRemoteProvider.overrideWith(
          () => LinkDesktopRemote(nowMs: () => now),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await client.close();
  });

  test('reads the desktop state and downloads on the phone clock', () async {
    await start();
    final state = read();
    expect(client.gets, [LinkOps.state, LinkOps.downloads]);
    expect(state.loading, isFalse);
    expect(state.connection, LinkConnectionState.connected);
    expect(state.player?.track?.title, 'Desk');
    // The desktop's clock is replaced by the time the state arrived.
    expect(state.player?.updatedMs, now);
    now += 3000;
    expect(read().player?.positionAt(now), 13000);
    final download = state.downloads.single;
    expect(download.status, 'downloading');
    expect(download.progress, closeTo(0.4, 1e-9));
  });

  test('follows player.state and downloads.changed pushes', () async {
    await start();
    client.push({
      'type': LinkMessageTypes.playerState,
      'state': _desktopState(playing: false, positionMs: 77000),
    });
    expect(read().player?.playing, isFalse);
    expect(read().player?.positionMs, 77000);
    client.push({
      'type': LinkMessageTypes.downloadsChanged,
      'items': [
        {'id': 'd1', 'title': 'Queued', 'status': 'completed'},
        {'id': 'd2', 'title': 'Broken', 'status': 'failed'},
      ],
    });
    expect(read().downloads.first.finished, isTrue);
    expect(read().downloads.last.failed, isTrue);

    client.setConnection(LinkConnectionState.disconnected);
    expect(read().connection, LinkConnectionState.disconnected);
  });

  test('maps each control to a POST command', () async {
    final remote = await start();
    await remote.play();
    await remote.pause();
    await remote.toggle();
    await remote.next();
    await remote.previous();
    await remote.seek(const Duration(seconds: 42));
    await remote.setVolume(1.4);
    await remote.setShuffle(true);
    await remote.setRepeat(LinkRepeatMode.one);
    await remote.setAutoplay(true);
    await remote.setAutoMix(true);
    await remote.jump(1);
    expect(client.posts.map((post) => post.op).toSet(), {LinkOps.command});
    expect(
      [for (final post in client.posts) post.body],
      [
        {'action': 'play', 'args': <String, dynamic>{}},
        {'action': 'pause', 'args': <String, dynamic>{}},
        {'action': 'toggle', 'args': <String, dynamic>{}},
        {'action': 'next', 'args': <String, dynamic>{}},
        {'action': 'previous', 'args': <String, dynamic>{}},
        {
          'action': 'seek',
          'args': {'positionMs': 42000},
        },
        {
          'action': 'volume',
          'args': {'value': 1.0},
        },
        {
          'action': 'shuffle',
          'args': {'enabled': true},
        },
        {
          'action': 'repeat',
          'args': {'mode': 'one'},
        },
        {
          'action': 'autoplay',
          'args': {'enabled': true},
        },
        {
          'action': 'auto_mix',
          'args': {'enabled': true},
        },
        {
          'action': 'jump',
          'args': {'index': 1},
        },
      ],
    );
    final player = read().player!;
    expect(player.index, 1);
    expect(player.track?.title, 'Next');
    expect(player.positionMs, 0);
    expect(player.shuffle, isTrue);
    expect(player.repeat, LinkRepeatMode.one);
    expect(player.volume, 1.0);
  });

  test('reorders and trims the queue at once', () async {
    client.onGet = (op, query) => op == LinkOps.state
        ? LinkPlayerState(
            track: const TrackRef(title: 'B', artist: 'Artist'),
            playing: true,
            positionMs: 0,
            updatedMs: 5,
            queue: const [
              TrackRef(title: 'A', artist: 'Artist'),
              TrackRef(title: 'B', artist: 'Artist'),
              TrackRef(title: 'C', artist: 'Artist'),
              TrackRef(title: 'D', artist: 'Artist'),
            ],
            index: 1,
          ).toJson()
        : null;
    final remote = await start();
    List<String> titles() => [
      for (final ref in read().player!.queue) ref.title,
    ];

    await remote.move(3, 0);
    expect(titles(), ['D', 'A', 'B', 'C']);
    expect(read().player!.index, 2);
    await remote.move(2, 3);
    expect(titles(), ['D', 'A', 'C', 'B']);
    expect(read().player!.index, 3);
    await remote.remove(0);
    expect(titles(), ['A', 'C', 'B']);
    expect(read().player!.index, 2);
    expect(read().player!.track?.title, 'B');
    expect(
      [for (final post in client.posts) post.body],
      [
        {
          'action': 'move',
          'args': {'from': 3, 'to': 0},
        },
        {
          'action': 'move',
          'args': {'from': 2, 'to': 3},
        },
        {
          'action': 'remove',
          'args': {'index': 0},
        },
      ],
    );
  });

  test('shows a command at once and takes it back when it fails', () async {
    final remote = await start();
    await remote.pause();
    expect(read().player?.playing, isFalse);

    client.onPost = (op, body) => const LinkException('unavailable');
    await expectLater(remote.play(), throwsA(isA<LinkException>()));
    expect(read().player?.playing, isFalse);
  });

  test('keeps the player when the download queue cannot be read', () async {
    client.onGet = (op, query) =>
        op == LinkOps.state ? _desktopState() : const LinkException('missing');
    await start();
    expect(read().player, isNotNull);
    expect(read().downloads, isEmpty);
    expect(read().error, isNull);
  });

  test('reports a failed state read', () async {
    client.onGet = (op, query) => const LinkException('offline');
    await start();
    expect(read().loading, isFalse);
    expect(read().error, isA<LinkException>());
  });
}
