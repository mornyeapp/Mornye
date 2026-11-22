import 'dart:math';

import 'package:audio_service/audio_service.dart';

/// What every scrobbling service is told about a song. The saved form keeps
/// the Last.fm parameter names so queues written before other services
/// existed still load.
class ScrobbleTrack {
  const ScrobbleTrack({
    required this.title,
    required this.artist,
    this.album = '',
    this.duration,
    this.isrc,
    this.trackNumber,
  });

  factory ScrobbleTrack.fromJson(Map<String, dynamic> json) {
    final seconds = int.tryParse('${json['duration']}');
    final isrc = json['isrc'];
    return ScrobbleTrack(
      title: json['track'] as String,
      artist: json['artist'] as String,
      album: json['album'] as String? ?? '',
      duration: seconds == null ? null : Duration(seconds: seconds),
      isrc: isrc is String && isrc.isNotEmpty ? isrc : null,
      trackNumber: int.tryParse('${json['trackNumber']}'),
    );
  }

  final String title;
  final String artist;
  final String album;
  final Duration? duration;
  final String? isrc;
  final int? trackNumber;

  /// The fields Last.fm-compatible services receive.
  Map<String, String> get lastfmParameters => {
    'track': title,
    'artist': artist,
    if (album.isNotEmpty) 'album': album,
    if (duration != null) 'duration': '${duration!.inSeconds}',
  };

  Map<String, String> toJson() => {
    ...lastfmParameters,
    'isrc': ?isrc,
    if (trackNumber != null) 'trackNumber': '$trackNumber',
  };
}

final _scrobbleIsrcPattern = RegExp(r'^[A-Za-z]{2}[A-Za-z0-9]{3}\d{7}$');

/// An ISRC or track number from the song's tags, when the player has them.
({String? isrc, int? trackNumber}) _identifiers(MediaItem? item) {
  final tags = item?.extras?['displayMetadata'];
  if (tags is! Map) return (isrc: null, trackNumber: null);
  final isrc = '${tags['isrc'] ?? ''}'.replaceAll('-', '').trim();
  final number = int.tryParse(
    '${tags['track_number'] ?? tags['track'] ?? ''}'.split('/').first.trim(),
  );
  return (
    isrc: _scrobbleIsrcPattern.hasMatch(isrc) ? isrc.toUpperCase() : null,
    trackNumber: number != null && number > 0 ? number : null,
  );
}

/// Measures time spent playing, independently of the seek slider. The player
/// publishes a stable playback instance so repeat-one starts a new listen
/// while metadata updates, pause and seek retain the existing one.
class ScrobbleListening {
  ScrobbleListening({
    required this.elapsed,
    required this.now,
    required this.onNowPlaying,
    required this.onScrobble,
  });

  final Duration Function() elapsed;
  final DateTime Function() now;
  final void Function(ScrobbleTrack track) onNowPlaying;
  final void Function(ScrobbleTrack track, DateTime started) onScrobble;
  Object? _instance;
  ScrobbleTrack? _track;
  Duration? _mark;

  /// Song time heard, which passes faster than [elapsed] above normal
  /// speed: the threshold is half the song, not half its length in time.
  Duration _listened = Duration.zero;
  double _speed = 1;
  DateTime? _started;
  bool _playing = false;
  bool _submitted = false;
  bool _announced = false;

  /// Whether listening time is being counted right now.
  bool get playing => _playing;

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
    final identifiers = _identifiers(item);
    _track =
        title.isEmpty ||
            artist.isEmpty ||
            title == unknownTitle ||
            artist == unknownArtist
        ? null
        : ScrobbleTrack(
            title: title,
            artist: artist,
            album: item?.album?.trim() ?? '',
            duration: item?.duration,
            isrc: identifiers.isrc,
            trackNumber: identifiers.trackNumber,
          );
    _playing =
        enabled &&
        _track != null &&
        state.playing &&
        state.speed > 0 &&
        state.processingState == AudioProcessingState.ready;
    _speed = state.speed;
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
      _listened += (mark - _mark!) * _speed;
    }
    _mark = mark;
    _submitIfEligible();
  }

  /// How far [elapsed] must advance after the last update or tick before
  /// this listen counts, or null while nothing would count it.
  Duration? get untilScrobble {
    final threshold = _threshold;
    if (!_playing || _submitted || _started == null || threshold == null) {
      return null;
    }
    final remaining = (threshold - _listened).inMicroseconds / _speed;
    return Duration(microseconds: max(0, remaining.ceil()));
  }

  Duration? get _threshold {
    final duration = _track?.duration;
    if (duration == null || duration <= const Duration(seconds: 30)) {
      return null;
    }
    return Duration(
      microseconds: (duration.inMicroseconds ~/ 2).clamp(
        0,
        const Duration(minutes: 4).inMicroseconds,
      ),
    );
  }

  void _submitIfEligible() {
    final track = _track;
    final threshold = _threshold;
    if (_submitted || track == null || _started == null || threshold == null) {
      return;
    }
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
