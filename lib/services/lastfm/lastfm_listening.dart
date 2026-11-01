import 'package:audio_service/audio_service.dart';

class LastfmTrack {
  const LastfmTrack({
    required this.title,
    required this.artist,
    this.album = '',
    this.duration,
  });

  factory LastfmTrack.fromJson(Map<String, dynamic> json) {
    final seconds = int.tryParse('${json['duration']}');
    return LastfmTrack(
      title: json['track'] as String,
      artist: json['artist'] as String,
      album: json['album'] as String? ?? '',
      duration: seconds == null ? null : Duration(seconds: seconds),
    );
  }

  final String title;
  final String artist;
  final String album;
  final Duration? duration;

  Map<String, String> toJson() => {
    'track': title,
    'artist': artist,
    if (album.isNotEmpty) 'album': album,
    if (duration != null) 'duration': '${duration!.inSeconds}',
  };
}

/// Measures time spent playing, independently of the seek slider. The player
/// publishes a stable playback instance so repeat-one starts a new listen
/// while metadata updates, pause and seek retain the existing one.
class LastfmListening {
  LastfmListening({
    required this.elapsed,
    required this.now,
    required this.onNowPlaying,
    required this.onScrobble,
  });

  final Duration Function() elapsed;
  final DateTime Function() now;
  final void Function(LastfmTrack track) onNowPlaying;
  final void Function(LastfmTrack track, DateTime started) onScrobble;
  Object? _instance;
  LastfmTrack? _track;
  Duration? _mark;
  Duration _listened = Duration.zero;
  DateTime? _started;
  bool _playing = false;
  bool _submitted = false;
  bool _announced = false;

  void update(
    MediaItem? item,
    PlaybackState state, {
    required bool enabled,
    String unknownTitle = 'Unknown title',
    String unknownArtist = 'Unknown artist',
  }) {
    tick();
    final instance = item == null
        ? null
        : item.extras?['playbackInstance'] ?? item.id;
    if (instance != _instance) {
      reset();
      _instance = instance;
    }
    final title = item?.title.trim() ?? '';
    final artist = item?.artist?.trim() ?? '';
    _track =
        title.isEmpty ||
            artist.isEmpty ||
            title == unknownTitle ||
            artist == unknownArtist
        ? null
        : LastfmTrack(
            title: title,
            artist: artist,
            album: item?.album?.trim() ?? '',
            duration: item?.duration,
          );
    _playing =
        enabled &&
        _track != null &&
        state.playing &&
        state.speed > 0 &&
        state.processingState == AudioProcessingState.ready;
    _mark = elapsed();
    if (!state.playing) _announced = false;
    if (_playing) {
      _started ??= now().toUtc();
      if (!_announced) {
        _announced = true;
        onNowPlaying(_track!);
      }
    }
    if (state.processingState == AudioProcessingState.completed ||
        state.processingState == AudioProcessingState.idle) {
      reset();
    } else {
      _submitIfEligible();
    }
  }

  void tick() {
    final mark = elapsed();
    if (_playing && _mark != null && mark > _mark!) {
      _listened += mark - _mark!;
    }
    _mark = mark;
    _submitIfEligible();
  }

  void _submitIfEligible() {
    final track = _track;
    final duration = track?.duration;
    if (_submitted ||
        track == null ||
        _started == null ||
        duration == null ||
        duration <= const Duration(seconds: 30)) {
      return;
    }
    final threshold = Duration(
      microseconds: (duration.inMicroseconds ~/ 2).clamp(
        0,
        const Duration(minutes: 4).inMicroseconds,
      ),
    );
    if (_listened >= threshold) {
      _submitted = true;
      onScrobble(track, _started!);
    }
  }

  void reset() {
    _instance = null;
    _track = null;
    _mark = null;
    _listened = Duration.zero;
    _started = null;
    _playing = false;
    _submitted = false;
    _announced = false;
  }

  void resetAnnouncement() => _announced = false;
}
