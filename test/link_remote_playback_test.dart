import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/link/features/link_desktop_remote.dart';
import 'package:mornye/services/link/features/link_handoff.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/services/link/features/link_remote_playback.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/features/link_track_resolver.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/music_player_service.dart';

import 'support/link_fakes.dart';

/// The phone's player with its playback states pushed by the test.
class _Runtime extends MusicPlayerRuntime {
  _Runtime(this.states);

  final StreamController<PlaybackState> states;

  @override
  Stream<PlaybackState> playbackStateEvents() => states.stream;
}

TrackRef _desktopSong(String id, {String? isrc}) => TrackRef(
  title: 'Song $id',
  artist: 'Artist',
  durationMs: 200000,
  isrc: isrc,
  songId: id,
  serverId: linkTestServer.serverId,
);

Map<String, dynamic> _state({bool playing = true, int index = 0}) => {
  'type': LinkMessageTypes.playerState,
  'state': LinkPlayerState(
    track: _desktopSong('s$index'),
    playing: playing,
    positionMs: 30000,
    durationMs: 200000,
    updatedMs: 1,
    queue: [_desktopSong('s0'), _desktopSong('s1')],
    index: index,
    shuffle: true,
    repeat: LinkRepeatMode.one,
    volume: 0.4,
  ).toJson(),
};

void main() {
  late FakeLinkClient client;
  late ProviderContainer container;
  late FakeLibraryLookup lookup;
  late LinkRemotePlayback playback;
  final artwork = <String>[];

  setUp(() {
    client = FakeLinkClient(
      onGet: (op, query) => op == LinkOps.state ? _state()['state'] : null,
      onPost: (op, body) => {'resolved': 1, 'missing': <int>[]},
    );
    container = ProviderContainer(
      overrides: [linkPhoneClientProvider.overrideWithValue(client)],
    );
    container.listen(linkDesktopRemoteProvider, (_, next) {
      playback.update(next);
    });
    lookup = FakeLibraryLookup();
    artwork.clear();
    playback = LinkRemotePlayback(
      name: 'Studio PC',
      remote: container.read(linkDesktopRemoteProvider.notifier),
      handoff: LinkHandoff(
        client: client,
        player: FakePhonePlayer(),
        refs: LinkTrackRefCache(lookup: lookup, server: client.server),
        resolver: LinkTrackResolver(lookup: lookup, server: client.server),
      ),
      resolveArtwork: (source) async {
        artwork.add(source);
        return 'http://127.0.0.1:1/${artwork.length}';
      },
      tick: const Duration(milliseconds: 10),
    );
  });

  tearDown(() {
    playback.dispose();
    container.dispose();
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 5));

  test('shows the desktop song, queue and position as the player', () async {
    client.push(_state());
    await settle();

    final item = await playback.mediaItems.first;
    expect(item!.title, 'Song s0');
    expect(item.extras!['source'], linkDesktopSongSource(linkTestServer, 's0'));
    // Its cover comes from the desktop by the song's id.
    expect(item.artUri.toString(), startsWith('http://127.0.0.1:1/'));
    expect(artwork.first, contains('subsonic/cover/'));

    final queue = await playback.queues.first;
    expect(queue.map((item) => item.title), ['Song s0', 'Song s1']);

    final state = await playback.playbackStates.first;
    expect(state.playing, isTrue);
    expect(state.processingState, AudioProcessingState.ready);
    expect(state.queueIndex, 0);
    expect(state.position.inMilliseconds, greaterThanOrEqualTo(30000));
    expect(state.shuffleMode, AudioServiceShuffleMode.all);
    expect(state.repeatMode, AudioServiceRepeatMode.one);
    expect(await playback.volumes.first, 0.4);
  });

  test('a desktop song the phone has shows as its own file', () async {
    lookup.tracks.add(
      LinkLocalTrack(
        linkLocalMedia('mine', title: 'Song s0', artist: 'Artist'),
        isrc: 'USAAA0000001',
      ),
    );
    client.push({
      'type': LinkMessageTypes.playerState,
      'state': LinkPlayerState(
        track: _desktopSong('s0', isrc: 'USAAA0000001'),
        playing: false,
        positionMs: 0,
        updatedMs: 1,
        queue: [_desktopSong('s0', isrc: 'USAAA0000001')],
        index: 0,
        volume: 1,
      ).toJson(),
    });
    await settle();

    final item = await playback.mediaItems.first;
    expect(item!.id, 'mine');
    expect(item.extras!['source'], '/music/mine.flac');
  });

  test('positions move while the desktop plays', () async {
    client.push(_state());
    await settle();
    final states = <PlaybackState>[];
    final subscription = playback.playbackStates.listen(states.add);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await subscription.cancel();
    expect(states.length, greaterThan(2));

    client.push(_state(playing: false));
    await settle();
    final paused = <PlaybackState>[];
    final quiet = playback.playbackStates.listen(paused.add);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await quiet.cancel();
    expect(paused, hasLength(1));
  });

  test('controls drive the desktop', () async {
    client.push(_state());
    await settle();
    client.posts.clear();

    await playback.pause();
    await playback.seek(const Duration(seconds: 12));
    await playback.jumpTo(1);
    await playback.setRepeatMode(AudioServiceRepeatMode.all);
    await playback.setVolume(0.7);

    expect(
      [for (final post in client.posts) post.body['action']],
      ['pause', 'seek', 'jump', 'repeat', 'volume'],
    );
    expect(client.posts[1].body['args'], {'positionMs': 12000});
    expect(client.posts[3].body['args'], {'mode': 'all'});
  });

  test('songs picked on the phone play and queue on the desktop', () async {
    await playback.playAll([
      linkDesktopMedia('a', title: 'A'),
      linkDesktopMedia('b', title: 'B'),
    ], initialIndex: 1);
    final play = client.posts.single;
    expect(play.op, LinkOps.handoffPlay);
    expect(play.body['index'], 1);
    expect(
      [for (final ref in play.body['queue'] as List) (ref as Map)['songId']],
      ['a', 'b'],
    );

    await playback.enqueue([linkDesktopMedia('c')], playNext: true);
    expect(client.posts.last.op, LinkOps.queueAdd);
    expect(client.posts.last.body['next'], isTrue);
  });

  test('a failed command is logged, not thrown', () async {
    client.onPost = (op, body) => throw StateError('offline');
    client.push(_state());
    await settle();
    await expectLater(playback.next(), completes);
  });

  group('where the music plays', () {
    late _Runtime runtime;
    late ProviderContainer phone;

    setUp(() {
      final states = StreamController<PlaybackState>.broadcast(sync: true);
      addTearDown(() => states.close());
      runtime = _Runtime(states);
      phone = ProviderContainer(
        overrides: [
          linkPhoneClientProvider.overrideWithValue(client),
          musicPlayerRuntimeProvider.overrideWithValue(runtime),
        ],
      );
    });

    tearDown(() => phone.dispose());

    test('the phone takes over when its own player starts', () {
      phone.listen(linkPlaysOnDesktopProvider, (_, _) {});
      runtime.states.add(PlaybackState(playing: true));
      phone.read(linkPlaysOnDesktopProvider.notifier).set(true);
      // Pausing the phone after the handoff keeps the desktop.
      runtime.states.add(PlaybackState());
      expect(phone.read(linkPlaysOnDesktopProvider), isTrue);

      runtime.states.add(PlaybackState(playing: true));
      expect(phone.read(linkPlaysOnDesktopProvider), isFalse);
    });

    test('the player screens follow the desktop only while it plays', () {
      phone.listen(linkRemotePlaybackProvider, (_, _) {});
      expect(phone.read(linkRemotePlaybackProvider), isNull);
      phone.read(linkPlaysOnDesktopProvider.notifier).set(true);
      expect(phone.read(linkRemotePlaybackProvider)?.name, 'Studio PC');
    });
  });
}
