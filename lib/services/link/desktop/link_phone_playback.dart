import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/link_mirrored_playback.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/remote_playback.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// A connected phone's player as the desktop's player screens show and
/// drive it, while the desktop follows that phone. Songs picked on the
/// desktop play here instead, which takes the player back.
class LinkPhonePlayback extends LinkMirroredPlayback {
  LinkPhonePlayback({
    required super.name,
    required Future<bool> Function(LinkCommand command) send,
    required Future<PlayableMedia?> Function(TrackRef ref) resolve,
    required Future<void> Function(List<PlayableMedia> items, int index)
    playHere,
    required Future<void> Function(List<PlayableMedia> items, bool playNext)
    enqueueHere,
    required super.resolveArtwork,
    super.tick,
    super.nowMs,
  }) : _send = send,
       _resolve = resolve,
       _playHere = playHere,
       _enqueueHere = enqueueHere;

  final Future<bool> Function(LinkCommand command) _send;
  final Future<PlayableMedia?> Function(TrackRef ref) _resolve;
  final Future<void> Function(List<PlayableMedia> items, int index) _playHere;
  final Future<void> Function(List<PlayableMedia> items, bool playNext)
  _enqueueHere;

  @override
  Future<void> send(LinkCommand command) async {
    if (!await _send(command)) {
      throw const LinkException('unavailable', 'The phone is not connected');
    }
  }

  @override
  Future<PlayableMedia?> resolvePlayable(TrackRef ref) => _resolve(ref);

  @override
  Future<void> playAll(List<PlayableMedia> items, {int initialIndex = 0}) =>
      _playHere(items, initialIndex);

  @override
  Future<void> enqueue(List<PlayableMedia> items, {bool playNext = false}) =>
      _enqueueHere(items, playNext);
}

/// The phone the desktop follows, as [activeRemotePlaybackProvider] shows
/// it, else null. Always null on phones.
final linkFollowedPhonePlaybackProvider = Provider<RemotePlayback?>((ref) {
  if (!isDesktopPlatform) return null;
  final deviceId = ref.watch(
    linkDesktopHostProvider.select((state) => state.followedPhone),
  );
  if (deviceId == null) return null;
  final host = ref.read(linkDesktopHostProvider.notifier);
  final runtime = ref.watch(musicPlayerRuntimeProvider);
  // The desktop's own player, which songs picked here start.
  final local = MusicPlayerController(runtime: runtime);
  final playback = LinkPhonePlayback(
    name: host.deviceName(deviceId),
    send: (command) => host.sendCommand(deviceId, command),
    resolve: (track) => host.phoneTrackMedia(deviceId, track),
    playHere: (items, index) async {
      host.stopFollowingPhone();
      await local.playAll(items, initialIndex: index);
    },
    enqueueHere: (items, playNext) async {
      host.stopFollowingPhone();
      await (await local.ensureInitialized())?.enqueueAll(
        items,
        playNext: playNext,
      );
    },
    resolveArtwork: runtime.dependencies.resolveNetworkSource,
  );
  playback.show(ref.read(linkDesktopHostProvider).phoneStates[deviceId]);
  ref.listen(
    linkDesktopHostProvider.select((state) => state.phoneStates[deviceId]),
    (_, next) => playback.show(next),
  );
  ref.listen(
    linkDesktopHostProvider.select(
      (state) => state.phoneCatalogRevisions[deviceId],
    ),
    (_, _) => playback.refreshTracks(),
  );
  ref.onDispose(playback.dispose);
  return playback;
});
