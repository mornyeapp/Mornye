import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:mornye/services/remote_playback.dart';

/// What the system media session (notification, lock screen, headset and
/// car buttons) shows while [remote] plays in this device's place: its
/// song, queue and state, with the session's buttons driving it. Browsing,
/// searching and playing a Library item go to [local], so a song picked in
/// the car plays on this device; [onLocal] runs first to hand the session
/// back.
class RemoteMediaSession extends BaseAudioHandler {
  RemoteMediaSession(
    this.remote, {
    required AudioHandler local,
    required void Function() onLocal,
  }) : _local = local,
       _onLocal = onLocal {
    _subscriptions = [
      remote.mediaItems.listen(mediaItem.add),
      remote.queues.listen(queue.add),
      remote.playbackStates.listen(_showState),
    ];
  }

  final RemotePlayback remote;
  final AudioHandler _local;
  final void Function() _onLocal;
  late final List<StreamSubscription<Object?>> _subscriptions;
  PlaybackState? _shown;

  /// The session moves the position on its own, so the remote's position
  /// ticks only pass when something else changed or the position jumped.
  void _showState(PlaybackState state) {
    final shown = _shown;
    if (shown != null &&
        shown.playing == state.playing &&
        shown.processingState == state.processingState &&
        shown.queueIndex == state.queueIndex &&
        shown.shuffleMode == state.shuffleMode &&
        shown.repeatMode == state.repeatMode &&
        (shown.position - state.position).abs() < const Duration(seconds: 2)) {
      return;
    }
    final next = state.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        state.playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.skipToPrevious,
        MediaAction.skipToNext,
      },
      androidCompactActionIndices: const [0, 1, 2],
      // copyWith stamps a new update time; keep the position it reaches.
      updatePosition: state.position,
    );
    _shown = next;
    playbackState.add(next);
  }

  @override
  Future<void> play() => remote.play();

  @override
  Future<void> pause() => remote.pause();

  @override
  Future<void> stop() => remote.pause();

  @override
  Future<void> seek(Duration position) => remote.seek(position);

  @override
  Future<void> skipToNext() => remote.next();

  @override
  Future<void> skipToPrevious() => remote.previous();

  @override
  Future<void> skipToQueueItem(int index) => remote.jumpTo(index);

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      remote.setShuffle(shuffleMode != AudioServiceShuffleMode.none);

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) =>
      remote.setRepeatMode(repeatMode);

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) => _local.getChildren(parentMediaId, options);

  @override
  Future<List<MediaItem>> search(
    String query, [
    Map<String, dynamic>? extras,
  ]) => _local.search(query, extras);

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    for (final item in queue.value) {
      if (item.id == mediaId) return item;
    }
    return _local.getMediaItem(mediaId);
  }

  /// An entry of the remote queue plays there; a Library item plays here.
  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) {
    final index = queue.value.indexWhere((item) => item.id == mediaId);
    if (index >= 0) return remote.jumpTo(index);
    _onLocal();
    return _local.playFromMediaId(mediaId, extras);
  }

  /// A spoken request without words resumes there; one with words plays
  /// here.
  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) {
    if (query.trim().isEmpty) return remote.play();
    _onLocal();
    return _local.playFromSearch(query, extras);
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) =>
      playFromMediaId(mediaItem.id);

  @override
  Future<void> onTaskRemoved() => _local.onTaskRemoved();

  @override
  Future<void> onNotificationDeleted() => _local.onNotificationDeleted();

  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
  }
}
