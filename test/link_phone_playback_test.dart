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
    await playback.seek(const Duration(seconds: 5));
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
}
