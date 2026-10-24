import 'package:audio_service/audio_service.dart';
import 'package:mornye/services/playable_media.dart';

/// Another device playing in this one's place, such as a computer paired
/// through Mornye Link. While one is active, the player screens show what it
/// plays and their controls drive it; the local player stays paused.
///
/// Each stream starts with the current value, like the local player's
/// events, and the playback states keep coming while it plays so positions
/// move.
abstract interface class RemotePlayback {
  /// The device's name, shown as where the music plays.
  String get name;

  Stream<MediaItem?> get mediaItems;
  Stream<PlaybackState> get playbackStates;
  Stream<List<MediaItem>> get queues;

  /// Its volume, 0 to 1, which the player's volume slider sets.
  Stream<double> get volumes;
  Future<void> setVolume(double value);

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> next();
  Future<void> previous();

  /// Plays entry [index] of the queue [queues] reports.
  Future<void> jumpTo(int index);
  Future<void> setShuffle(bool enabled);
  Future<void> setRepeatMode(AudioServiceRepeatMode mode);

  /// Starts [items] there, from [initialIndex], as the local player would.
  Future<void> playAll(List<PlayableMedia> items, {int initialIndex = 0});

  /// Adds [items] there, after the current song when [playNext].
  Future<void> enqueue(List<PlayableMedia> items, {bool playNext = false});
}
