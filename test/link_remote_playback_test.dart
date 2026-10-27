import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/link/features/link_desktop_remote.dart';
import 'package:mornye/services/link/features/link_handoff.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/services/link/features/link_phone_files.dart';
import 'package:mornye/services/link/features/link_phone_options.dart';
import 'package:mornye/services/link/features/link_remote_playback.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/features/link_track_resolver.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/remote_playback.dart';

import 'support/link_fakes.dart';

/// The phone's player with its playback states pushed by the test.
class _Runtime extends MusicPlayerRuntime {
  _Runtime(this.states);

  final StreamController<PlaybackState> states;

  @override
  Stream<PlaybackState> playbackStateEvents() => states.stream;
}

class _PlaybackSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();

  @override
  void setAutoplay(bool enabled) => state = state.copyWith(autoplay: enabled);

  @override
  void setAutoMix(bool enabled) => state = state.copyWith(autoMix: enabled);
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
  final extracted = <String>[];
  String? embeddedCover;
  var artworkUnavailable = false;
  Future<String> Function(String)? resolveCover;

  setUp(() async {
    client = FakeLinkClient(
      onGet: (op, query) => null,
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
    extracted.clear();
    embeddedCover = null;
    artworkUnavailable = false;
    resolveCover = null;
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
        if (artworkUnavailable) throw StateError('offline');
        if (resolveCover case final resolve?) return resolve(source);
        return 'http://127.0.0.1:1/${artwork.length}';
      },
      extractArtwork: (source) async {
        extracted.add(source);
        return embeddedCover;
      },
      tick: const Duration(milliseconds: 10),
    );
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() {
    playback.dispose();
    container.dispose();
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 5));

  test(
    'active remote preferences stay synchronized through reconnection',
    () async {
      var desktopAutoplay = true;
      var desktopAutoMix = true;
      client.onGet = (op, _) => op == LinkOps.state
          ? {
              ...(_state()['state'] as Map),
              'autoplay': desktopAutoplay,
              'autoMix': desktopAutoMix,
            }
          : null;
      client.onPost = (op, body) {
        final args = body['args'] as Map;
        if (body['action'] == LinkActions.autoplay) {
          desktopAutoplay = args['enabled'] as bool;
        }
        if (body['action'] == LinkActions.autoMix) {
          desktopAutoMix = args['enabled'] as bool;
        }
        return {'ok': true};
      };
      final localStates = StreamController<PlaybackState>.broadcast();
      addTearDown(localStates.close);
      final phone = ProviderContainer(
        overrides: [
          linkPhoneClientProvider.overrideWithValue(client),
          musicPlayerRuntimeProvider.overrideWithValue(_Runtime(localStates)),
          settingsProvider.overrideWith(_PlaybackSettings.new),
          linkHandoffProvider.overrideWithValue(
            LinkHandoff(
              client: client,
              player: FakePhonePlayer(),
              refs: LinkTrackRefCache(lookup: lookup),
              resolver: LinkTrackResolver(lookup: lookup),
            ),
          ),
        ],
      );
      addTearDown(phone.dispose);
      phone.listen(linkRemotePlaybackProvider, (_, _) {});
      phone.read(linkPlaysOnDesktopProvider.notifier).set(true);
      await settle();
      expect(phone.read(settingsProvider).autoplay, isTrue);
      expect(phone.read(settingsProvider).autoMix, isTrue);
      expect(client.posts, isEmpty);

      phone.read(settingsProvider.notifier).setAutoplay(false);
      phone.read(settingsProvider.notifier).setAutoMix(false);
      await settle();
      expect(desktopAutoplay, isFalse);
      expect(desktopAutoMix, isFalse);
      expect(client.posts, hasLength(2));

      client.setConnection(LinkConnectionState.disconnected);
      desktopAutoplay = true;
      client.setConnection(LinkConnectionState.connecting);
      client.setConnection(LinkConnectionState.connected);
      await settle();
      expect(phone.read(settingsProvider).autoplay, isTrue);
      expect(phone.read(linkPlaysOnDesktopProvider), isTrue);
      expect(
        client.posts,
        hasLength(2),
        reason: 'Refresh must not echo preferences',
      );
    },
  );

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

  for (final staleThumbnail in [false, true]) {
    test(
      'recovers matched phone artwork in both views ($staleThumbnail)',
      () async {
        final directory = await Directory.systemTemp.createTemp('link-cover-');
        addTearDown(() => directory.delete(recursive: true));
        final cover = await File(
          '${directory.path}/embedded.jpg',
        ).writeAsBytes([1]);
        embeddedCover = cover.path;
        lookup.tracks.add(
          LinkLocalTrack(
            PlayableMedia(
              id: 'mine',
              source: '/music/mine.flac',
              title: 'Song s0',
              artist: 'Artist',
              artUri: staleThumbnail
                  ? Uri.file('${directory.path}/missing.jpg').toString()
                  : null,
            ),
          ),
        );
        client.push(_state());
        await settle();

        final item = (await playback.mediaItems.first)!;
        final row = (await playback.queues.first).first;
        expect(item.id, 'mine');
        expect(item.extras!['source'], '/music/mine.flac');
        expect(item.artUri, cover.uri);
        expect(row.artUri, item.artUri);
        expect(extracted, ['/music/mine.flac']);
      },
    );
  }

  test('keeps a valid phone thumbnail without extracting again', () async {
    final directory = await Directory.systemTemp.createTemp('link-cover-');
    addTearDown(() => directory.delete(recursive: true));
    final cover = await File('${directory.path}/scanned.jpg').writeAsBytes([1]);
    lookup.tracks.add(
      LinkLocalTrack(
        PlayableMedia(
          id: 'mine',
          source: '/music/mine.flac',
          title: 'Song s0',
          artist: 'Artist',
          artUri: cover.uri.toString(),
        ),
      ),
    );
    client.push(_state());
    await settle();

    expect((await playback.mediaItems.first)!.artUri, cover.uri);
    expect(extracted, isEmpty);
  });

  test('a phone file without artwork borrows the desktop cover', () async {
    lookup.tracks.add(
      LinkLocalTrack(
        linkLocalMedia('mine', title: 'Song s0', artist: 'Artist'),
      ),
    );
    client.push(_state());
    await settle();

    final item = (await playback.mediaItems.first)!;
    expect(item.id, 'mine');
    expect(item.extras!['source'], '/music/mine.flac');
    expect(item.artUri.toString(), startsWith('http://127.0.0.1:1/'));
    expect((await playback.queues.first).first.artUri, item.artUri);
    expect(extracted, ['/music/mine.flac']);
  });

  test(
    'resolves covers before the current song and beyond the next twenty',
    () async {
      await settle();
      final songs = [for (var i = 0; i < 55; i++) _desktopSong('long$i')];
      client.push({
        'type': LinkMessageTypes.playerState,
        'state': LinkPlayerState(
          track: songs[5],
          queue: songs,
          index: 5,
          playing: false,
          positionMs: 0,
          updatedMs: 1,
          volume: 1,
        ).toJson(),
      });
      final queue = await playback.queues
          .firstWhere(
            (rows) =>
                rows.length == songs.length &&
                rows.every((row) => row.artUri != null),
          )
          .timeout(const Duration(seconds: 2));
      expect(queue.first.artUri, isNotNull);
      expect(queue.last.artUri, isNotNull);
      expect((await playback.mediaItems.first)!.artUri, queue[5].artUri);
      final resolved = artwork.length;
      client.push({
        'type': LinkMessageTypes.playerState,
        'state': LinkPlayerState(
          track: songs[5],
          queue: songs,
          index: 5,
          playing: false,
          positionMs: 0,
          updatedMs: 2,
          volume: 1,
        ).toJson(),
      });
      await settle();
      expect(artwork, hasLength(resolved));
    },
  );

  test('retries failed artwork after reconnecting without looping', () async {
    artworkUnavailable = true;
    client.push(_state());
    await settle();
    expect((await playback.mediaItems.first)!.artUri, isNull);
    final failed = artwork.length;
    client.push(_state());
    await settle();
    expect(artwork, hasLength(failed));

    artworkUnavailable = false;
    client.onGet = (op, _) => op == LinkOps.state ? _state()['state'] : null;
    client.setConnection(LinkConnectionState.disconnected);
    client.setConnection(LinkConnectionState.connected);
    await settle();
    final item = (await playback.mediaItems.first)!;
    expect(item.artUri, isNotNull);
    expect((await playback.queues.first).first.artUri, item.artUri);
    expect(artwork, hasLength(failed * 2));
  });

  test(
    'queue lookups stay bounded and stop scheduling after disposal',
    () async {
      final pending = <Completer<String>>[];
      resolveCover = (_) {
        final reply = Completer<String>();
        pending.add(reply);
        return reply.future;
      };
      final songs = [for (var i = 0; i < 55; i++) _desktopSong('long$i')];
      client.push({
        'type': LinkMessageTypes.playerState,
        'state': LinkPlayerState(
          track: songs[5],
          queue: songs,
          index: 5,
          playing: false,
          positionMs: 0,
          updatedMs: 1,
          volume: 1,
        ).toJson(),
      });
      await settle();
      expect(pending, hasLength(4));
      pending.first.complete('https://example.test/cover.jpg');
      await settle();
      expect(pending, hasLength(5));
      expect(
        (await playback.mediaItems.first)!.artUri.toString(),
        'https://example.test/cover.jpg',
      );
      playback.dispose();
      final queue = await playback.queues.first;
      for (final reply in pending.skip(1)) {
        reply.complete('https://example.test/cover.jpg');
      }
      await settle();
      expect(pending, hasLength(5));
      expect(await playback.queues.first, same(queue));
    },
  );

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

  test('queue rows reorder and remove on the desktop', () async {
    // The first state read lands before this push.
    await settle();
    client.push({
      'type': LinkMessageTypes.playerState,
      'state': LinkPlayerState(
        track: _desktopSong('s0'),
        playing: true,
        positionMs: 0,
        updatedMs: 1,
        queue: [_desktopSong('s0'), _desktopSong('s1'), _desktopSong('s0')],
        index: 0,
      ).toJson(),
    });
    await settle();
    final rows = await playback.queues.first;
    // A song queued twice keeps two rows the queue sheet tells apart.
    expect(identical(rows[0], rows[2]), isFalse);
    client.posts.clear();

    await playback.moveQueueItem(1, 2);
    final moved = await playback.queues.first;
    expect(moved.map((item) => item.title), ['Song s0', 'Song s0', 'Song s1']);
    // Moved rows are the same objects in their new places.
    expect(identical(moved[1], rows[2]), isTrue);
    expect(identical(moved[2], rows[1]), isTrue);

    await playback.removeQueueItem(rows[2]);
    expect((await playback.queues.first).map((item) => item.title), [
      'Song s0',
      'Song s1',
    ]);
    expect(
      [for (final post in client.posts) post.body],
      [
        {
          'action': 'move',
          'args': {'from': 1, 'to': 2},
        },
        {
          'action': 'remove',
          'args': {'index': 1},
        },
      ],
    );
  });

  test('reports a song file on its way to the desktop', () async {
    final dir = await Directory.systemTemp.createTemp('link_remote_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/mine.flac';
    await File(path).writeAsBytes([1, 2, 3]);
    client.onPost = (op, body) => switch (op) {
      LinkOps.handoffPlay when body['check'] == true => {
        'resolved': 0,
        'missing': [0],
      },
      _ => {'resolved': 1, 'missing': <int>[]},
    };
    final sending = LinkRemotePlayback(
      name: 'Studio PC',
      remote: container.read(linkDesktopRemoteProvider.notifier),
      handoff: LinkHandoff(
        client: client,
        player: FakePhonePlayer(),
        refs: LinkTrackRefCache(lookup: lookup, server: client.server),
        resolver: LinkTrackResolver(lookup: lookup, server: client.server),
        files: LinkPhoneFiles(copyContentUri: (_) async => null),
      ),
      resolveArtwork: (source) async => source,
    );
    addTearDown(sending.dispose);
    final transfers = <RemoteTransfer?>[];
    final subscription = sending.transfers.listen(transfers.add);
    addTearDown(subscription.cancel);

    await sending.playAll([
      PlayableMedia(
        id: 'mine',
        source: path,
        title: 'Mine',
        artist: 'Artist',
        album: 'Album',
      ),
    ]);
    await settle();
    expect(client.uploads, hasLength(1));
    expect(transfers.first, isNull);
    expect(transfers.whereType<RemoteTransfer>().last.fraction, 1);
    expect(transfers.last, isNull);
  });

  test('keeps the song just sent until the desktop state arrives', () async {
    final sent = linkMediaItem(linkLocalMedia('sent', title: 'Sent'));
    final seeded = LinkRemotePlayback(
      name: 'Studio PC',
      remote: container.read(linkDesktopRemoteProvider.notifier),
      handoff: LinkHandoff(
        client: client,
        player: FakePhonePlayer(),
        refs: LinkTrackRefCache(lookup: lookup),
        resolver: LinkTrackResolver(lookup: lookup),
      ),
      resolveArtwork: (source) async => source,
      initialItem: sent,
    );
    addTearDown(seeded.dispose);
    seeded.update(const LinkRemoteState(loading: true));
    expect((await seeded.mediaItems.first)?.title, 'Sent');
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

    test('the phone takes over when the desktop cannot be reached', () {
      phone.listen(linkPlaysOnDesktopProvider, (_, _) {});
      phone.read(linkPlaysOnDesktopProvider.notifier).set(true);
      // The session pauses in the background and reconnects on return.
      client.setConnection(LinkConnectionState.disconnected);
      client.setConnection(LinkConnectionState.connecting);
      client.setConnection(LinkConnectionState.connected);
      expect(phone.read(linkPlaysOnDesktopProvider), isTrue);

      client.setConnection(LinkConnectionState.disconnected);
      client.setConnection(LinkConnectionState.connecting);
      client.setConnection(LinkConnectionState.disconnected);
      expect(phone.read(linkPlaysOnDesktopProvider), isFalse);
    });

    ProviderContainer phoneOf(FakeLinkClient desktop, {bool follow = true}) {
      final container = ProviderContainer(
        overrides: [
          linkPhoneClientProvider.overrideWithValue(desktop),
          musicPlayerRuntimeProvider.overrideWithValue(runtime),
          linkPhoneOptionsProvider.overrideWith(
            () => LinkPhoneOptionsNotifier(
              initial: LinkPhoneOptions(loaded: true, followDesktop: follow),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(linkPlaysOnDesktopProvider, (_, _) {});
      return container;
    }

    test('the phone follows the desktop when it starts playing', () async {
      final desktop = FakeLinkClient(
        onGet: (op, query) => _state(playing: false)['state'],
      );
      final follower = phoneOf(desktop);
      await settle();
      expect(follower.read(linkPlaysOnDesktopProvider), isFalse);

      desktop.push(_state());
      expect(follower.read(linkPlaysOnDesktopProvider), isTrue);
    });

    test('the phone follows a desktop that plays when it connects', () async {
      final desktop = FakeLinkClient(
        connectionState: LinkConnectionState.disconnected,
        onGet: (op, query) => _state()['state'],
      );
      final follower = phoneOf(desktop);
      await settle();
      expect(follower.read(linkPlaysOnDesktopProvider), isFalse);

      desktop.setConnection(LinkConnectionState.connecting);
      desktop.setConnection(LinkConnectionState.connected);
      await settle();
      expect(follower.read(linkPlaysOnDesktopProvider), isTrue);
    });

    test('the phone keeps its player when following is off', () async {
      final desktop = FakeLinkClient(
        onGet: (op, query) => _state(playing: false)['state'],
      );
      final follower = phoneOf(desktop, follow: false);
      await settle();

      desktop.push(_state());
      expect(follower.read(linkPlaysOnDesktopProvider), isFalse);
    });

    test('a phone that plays keeps its own player', () async {
      final desktop = FakeLinkClient(
        onGet: (op, query) => _state(playing: false)['state'],
      );
      final follower = phoneOf(desktop);
      runtime.states.add(PlaybackState(playing: true));
      await settle();

      desktop.push(_state());
      expect(follower.read(linkPlaysOnDesktopProvider), isFalse);
    });

    test('a desktop that plays on does not take over again', () async {
      final desktop = FakeLinkClient(onGet: (op, query) => _state()['state']);
      final follower = phoneOf(desktop);
      await settle();
      expect(follower.read(linkPlaysOnDesktopProvider), isTrue);

      // Picking this phone stays while the desktop moves to its next song.
      follower.read(linkPlaysOnDesktopProvider.notifier).set(false);
      desktop.push(_state(index: 1));
      expect(follower.read(linkPlaysOnDesktopProvider), isFalse);

      // Pausing, then playing again is a new start.
      desktop.push(_state(playing: false, index: 1));
      desktop.push(_state(index: 1));
      expect(follower.read(linkPlaysOnDesktopProvider), isTrue);
    });

    test('the player screens follow the desktop only while it plays', () {
      phone.listen(linkRemotePlaybackProvider, (_, _) {});
      expect(phone.read(linkRemotePlaybackProvider), isNull);
      phone.read(linkPlaysOnDesktopProvider.notifier).set(true);
      expect(phone.read(linkRemotePlaybackProvider)?.name, 'Studio PC');
    });
  });
}
