import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/desktop/link_phone_playback.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/playable_media.dart';

void main() {
  const song = TrackRef(
    title: 'On the phone',
    artist: 'Band',
    durationMs: 200000,
    fileId: 'f1',
  );

  LinkPlayerState phonePosition(
    int milliseconds, {
    TrackRef track = song,
    int index = 0,
  }) => LinkPlayerState(
    track: track,
    positionMs: milliseconds,
    durationMs: 200000,
    updatedMs: 100000,
    queue: [song, if (track != song) track],
    index: index,
  );

  LinkPhonePlayback linkedPhone(
    Future<bool> Function(LinkCommand) send, {
    Duration seekTimeout = const Duration(seconds: 3),
  }) => LinkPhonePlayback(
    name: 'Phone',
    send: send,
    resolve: (_) async => null,
    playHere: (_, _) async {},
    enqueueHere: (_, _) async {},
    resolveArtwork: (source) async => source,
    nowMs: () => 100000,
    seekTimeout: seekTimeout,
  );

  for (final target in [38000, 30000]) {
    test(
      'seek from 34 seconds holds $target until the phone confirms',
      () async {
        final playback = linkedPhone((_) async => true);
        addTearDown(playback.dispose);
        playback.show(phonePosition(34000));
        var completed = false;
        final seek = playback
            .seek(Duration(milliseconds: target))
            .then((_) => completed = true);
        await pumpEventQueue();
        expect(
          completed,
          isFalse,
          reason: 'Sending a command is not a seek confirmation',
        );
        expect(
          (await playback.playbackStates.first).updatePosition.inMilliseconds,
          target,
        );
        playback.show(phonePosition(34000));
        await pumpEventQueue();
        expect(completed, isFalse);
        expect(
          (await playback.playbackStates.first).updatePosition.inMilliseconds,
          target,
        );
        playback.show(phonePosition(target));
        await seek;
        expect(
          (await playback.playbackStates.first).updatePosition.inMilliseconds,
          target,
        );
        playback.show(phonePosition(target + 1000));
        expect(
          (await playback.playbackStates.first).updatePosition.inMilliseconds,
          target + 1000,
        );
      },
    );
  }

  test('an old failed seek cannot cancel a newer target', () async {
    final oldSend = Completer<bool>();
    var sent = 0;
    final playback = linkedPhone(
      (_) => ++sent == 1 ? oldSend.future : Future.value(true),
    );
    addTearDown(playback.dispose);
    playback.show(phonePosition(34000));
    final first = playback.seek(const Duration(seconds: 38));
    final second = playback.seek(const Duration(seconds: 42));
    await first;
    oldSend.complete(false);
    await pumpEventQueue();
    expect(
      (await playback.playbackStates.first).updatePosition,
      const Duration(seconds: 42),
    );
    playback.show(phonePosition(38000));
    expect(
      (await playback.playbackStates.first).updatePosition,
      const Duration(seconds: 42),
    );
    playback.show(phonePosition(42000));
    await second;
  });

  test('resolving phone metadata does not release a pending seek', () async {
    final unresolved = TrackRef(
      title: song.title,
      artist: song.artist,
      durationMs: song.durationMs,
    );
    final playback = linkedPhone((_) async => true);
    addTearDown(playback.dispose);
    playback.show(phonePosition(34000, track: unresolved));
    var completed = false;
    final seek = playback
        .seek(const Duration(seconds: 38))
        .then((_) => completed = true);
    playback.show(phonePosition(34000));
    await pumpEventQueue();
    expect(completed, isFalse);
    expect(
      (await playback.playbackStates.first).updatePosition,
      const Duration(seconds: 38),
    );
    playback.show(phonePosition(38000));
    await seek;
  });

  test('a failed seek returns to the latest reported position', () async {
    final send = Completer<bool>();
    final playback = linkedPhone((_) => send.future);
    addTearDown(playback.dispose);
    playback.show(phonePosition(34000));
    final seek = playback.seek(const Duration(seconds: 38));
    playback.show(phonePosition(34500));
    send.complete(false);
    await seek;
    expect(
      (await playback.playbackStates.first).updatePosition,
      const Duration(milliseconds: 34500),
    );
  });

  test(
    'unconfirmed and stalled sends release the preview after a timeout',
    () async {
      final send = Completer<bool>();
      final playback = linkedPhone(
        (_) => send.future,
        seekTimeout: const Duration(milliseconds: 10),
      );
      addTearDown(playback.dispose);
      playback.show(phonePosition(34000));
      await playback.seek(const Duration(seconds: 38));
      expect(
        (await playback.playbackStates.first).updatePosition,
        const Duration(seconds: 34),
      );
      send.complete(true);
    },
  );

  test(
    'a track change cancels the pending seek without moving the next song',
    () async {
      final playback = linkedPhone((_) async => true);
      addTearDown(playback.dispose);
      playback.show(phonePosition(34000));
      final seek = playback.seek(const Duration(seconds: 38));
      playback.show(
        phonePosition(
          0,
          track: const TrackRef(title: 'Next', artist: 'Band', fileId: 'next'),
          index: 1,
        ),
      );
      await seek;
      expect(
        (await playback.playbackStates.first).updatePosition,
        Duration.zero,
      );
      expect((await playback.mediaItems.first)?.title, 'Next');
    },
  );

  test('closing the remote releases a pending seek', () async {
    final playback = linkedPhone((_) async => true);
    playback.show(phonePosition(34000));
    final seek = playback.seek(const Duration(seconds: 38));
    playback.dispose();
    await seek;
  });

  test('seek clamps to the song bounds before sending', () async {
    final sent = <int>[];
    final playback = linkedPhone((command) async {
      sent.add(command.args['positionMs'] as int);
      return true;
    });
    addTearDown(playback.dispose);
    playback.show(phonePosition(34000));
    final beforeStart = playback.seek(const Duration(seconds: -1));
    playback.show(phonePosition(0));
    await beforeStart;
    final afterEnd = playback.seek(const Duration(seconds: 300));
    playback.show(phonePosition(200000));
    await afterEnd;
    expect(sent, [0, 200000]);
  });

  test('shows the phone, sends it commands and plays picks here', () async {
    final sent = <LinkCommand>[];
    final played = <(List<PlayableMedia>, int)>[];
    final queued = <(List<PlayableMedia>, bool)>[];
    var delivered = true;
    final playback = LinkPhonePlayback(
      name: 'Pixel',
      send: (command) async {
        sent.add(command);
        return delivered;
      },
      resolve: (ref) async => PlayableMedia(
        id: 'link:${ref.fileId}',
        source: '',
        title: ref.title,
        artist: ref.artist,
      ),
      playHere: (items, index) async => played.add((items, index)),
      enqueueHere: (items, playNext) async => queued.add((items, playNext)),
      resolveArtwork: (source) async => source,
      nowMs: () => 61000,
    );
    addTearDown(playback.dispose);
    playback.show(
      LinkPlayerState(
        track: song,
        playing: true,
        positionMs: 30000,
        durationMs: 200000,
        updatedMs: 60000,
        queue: const [song],
        index: 0,
      ),
    );

    expect((await playback.mediaItems.first)?.title, 'On the phone');
    final state = await playback.playbackStates.first;
    expect(state.playing, isTrue);
    expect(state.updatePosition, const Duration(seconds: 31));
    expect(await playback.queues.first, hasLength(1));

    await playback.pause();
    final seeking = playback.seek(const Duration(seconds: 5));
    playback.show(
      LinkPlayerState(
        track: song,
        positionMs: 5000,
        updatedMs: 61000,
        queue: const [song],
        index: 0,
      ),
    );
    await seeking;
    await playback.next();
    expect(
      [for (final command in sent) command.action],
      [LinkActions.pause, LinkActions.seek, LinkActions.next],
    );
    expect(sent[1].args['positionMs'], 5000);

    // A phone that left takes no command, and that is not thrown.
    delivered = false;
    await playback.play();
    expect(sent.last.action, LinkActions.play);

    const pick = PlayableMedia(
      id: 'a',
      source: '/a.flac',
      title: 'A',
      artist: 'Band',
    );
    await playback.playAll(const [pick], initialIndex: 0);
    await playback.enqueue(const [pick], playNext: true);
    expect(played.single.$1.single.id, 'a');
    expect(queued.single.$2, isTrue);
  });

  for (final initiallyMissing in [true, false]) {
    test(
      'refreshes a cover after the phone catalog arrives ($initiallyMissing)',
      () async {
        String? artwork;
        var calls = 0;
        final playback = LinkPhonePlayback(
          name: 'Phone',
          send: (_) async => true,
          resolve: (ref) async {
            calls++;
            if (initiallyMissing && artwork == null) return null;
            return PlayableMedia(
              id: 'link:${ref.fileId}',
              source: '',
              title: ref.title,
              artist: ref.artist,
              artUri: artwork,
            );
          },
          playHere: (_, _) async {},
          enqueueHere: (_, _) async {},
          resolveArtwork: (source) async => source,
        );
        addTearDown(playback.dispose);
        final state = LinkPlayerState(
          track: song,
          playing: false,
          positionMs: 0,
          updatedMs: 0,
          queue: const [song],
          index: 0,
        );
        playback.show(state);
        await pumpEventQueue();
        expect((await playback.mediaItems.first)!.artUri, isNull);
        playback.show(state);
        await pumpEventQueue();
        expect(calls, 1);

        artwork = 'https://example.test/phone-cover.jpg';
        playback.refreshTracks();
        final shown = await playback.mediaItems.firstWhere(
          (item) => item?.artUri != null,
        );
        expect(shown!.artUri.toString(), artwork);
        expect((await playback.queues.first).single.artUri, shown.artUri);
        expect(calls, 2);
      },
    );
  }

  test('catalog refresh discards an older lookup still in flight', () async {
    final old = Completer<PlayableMedia?>();
    var calls = 0;
    final playback = LinkPhonePlayback(
      name: 'Phone',
      send: (_) async => true,
      resolve: (ref) {
        if (++calls == 1) return old.future;
        return Future.value(
          PlayableMedia(
            id: 'link:${ref.fileId}',
            source: '',
            title: ref.title,
            artist: ref.artist,
            artUri: 'https://example.test/new.jpg',
          ),
        );
      },
      playHere: (_, _) async {},
      enqueueHere: (_, _) async {},
      resolveArtwork: (source) async => source,
    );
    addTearDown(playback.dispose);
    final shown = <String?>[];
    final subscription = playback.mediaItems.listen(
      (item) => shown.add(item?.artUri?.toString()),
    );
    addTearDown(subscription.cancel);
    playback.show(
      LinkPlayerState(
        track: song,
        playing: false,
        positionMs: 0,
        updatedMs: 0,
        queue: const [song],
        index: 0,
      ),
    );
    await pumpEventQueue();
    playback.refreshTracks();
    old.complete(
      const PlayableMedia(
        id: 'old',
        source: '',
        title: 'Old metadata',
        artist: 'Band',
        artUri: 'https://example.test/old.jpg',
      ),
    );
    await pumpEventQueue();
    expect(shown, isNot(contains('https://example.test/old.jpg')));
    expect(shown.last, 'https://example.test/new.jpg');
    expect(calls, 2);
  });
}
