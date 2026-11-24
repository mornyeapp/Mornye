import 'package:mornye/services/link/link_protocol.dart';

/// Mornye Link Play together: the phone and the paired computer play the
/// same queue at the same time. The wire constants and models both sides
/// share; the ops are forwarded to Dart like every unknown Mornye op.
abstract final class LinkTogetherOps {
  /// GET: the computer's player as a [LinkTogetherReport].
  static const time = 'together/time';

  /// POST `{"session","role"}`: the computer takes part in a session.
  static const start = 'together/start';

  /// POST `{"session","rejoin":LinkTogetherCue}` or
  /// `{"session","nudge":{"factor","durationMs"}}`.
  static const align = 'together/align';

  /// POST `{"session","pause"?}`: the session ends.
  static const stop = 'together/stop';
}

abstract final class LinkTogetherMessages {
  /// Computer to phone, at once on a song, play or seek change:
  /// `{"session","report":LinkTogetherReport}`.
  static const state = 'together.state';

  /// Computer to phone: what its own controls did while it follows,
  /// `{"session","action"}`, one of [LinkTogetherActions].
  static const action = 'together.action';
}

/// [LinkTogetherMessages.action] values.
abstract final class LinkTogetherActions {
  static const pause = 'pause';
  static const play = 'play';
  static const next = 'next';
  static const previous = 'previous';

  /// Another song or This computer was picked there: the computer plays on
  /// alone.
  static const left = 'left';

  /// The phone was picked in the computer's Devices: the phone plays on
  /// alone and ends the session, which pauses the computer.
  static const leftForPhone = 'left_for_phone';
}

/// Which device owns the queue in a session.
enum LinkTogetherRole { leader, follower }

int? _int(Object? value) => value is num ? value.toInt() : null;

/// One device's player as Play together reads it: everything at [nowMs] on
/// that device's own clock.
class LinkTogetherReport {
  const LinkTogetherReport({
    required this.nowMs,
    this.session,
    this.track,
    this.index = -1,
    this.playing = false,
    this.ready = false,
    this.positionMs = 0,
    this.durationMs,
    this.repeat = LinkRepeatMode.none,
    this.silent = false,
    this.busy = false,
    this.canNudge = false,
    this.rate,
  });

  /// When it was read, on the device's clock.
  final int nowMs;

  /// The session the device takes part in, if any.
  final String? session;

  /// The current song, as other devices match it.
  final TrackRef? track;

  /// The current entry of the device's own queue, or -1.
  final int index;
  final bool playing;

  /// False while a song loads, or after it failed.
  final bool ready;

  /// The position at [nowMs].
  final int positionMs;
  final int? durationMs;
  final LinkRepeatMode repeat;

  /// The follower holds still because it cannot play the leader's song.
  final bool silent;

  /// A cue is being carried out.
  final bool busy;

  /// The device can change its playback rate a little to close a gap.
  final bool canNudge;

  /// The rate its player moves at now (a nudge included), or null from a
  /// device that does not say.
  final double? rate;

  /// The position at [atMs] of the same clock, advanced at [rate] while
  /// playing.
  int positionAt(int atMs) {
    if (!playing) return positionMs;
    final advanced = positionMs + ((atMs - nowMs) * (rate ?? 1)).round();
    final duration = durationMs;
    if (advanced < 0) return 0;
    return duration != null && duration > 0 && advanced > duration
        ? duration
        : advanced;
  }

  /// How long until the song ends at [atMs], or null without a length.
  int? remainingAt(int atMs) {
    final duration = durationMs;
    if (duration == null || duration <= 0) return null;
    return duration - positionAt(atMs);
  }

  /// This report on a clock that runs [offsetMs] behind the device's.
  LinkTogetherReport shifted(int offsetMs) => copyWith(nowMs: nowMs - offsetMs);

  LinkTogetherReport copyWith({
    int? nowMs,
    bool? silent,
    bool? busy,
    bool? canNudge,
    String? session,
  }) => LinkTogetherReport(
    nowMs: nowMs ?? this.nowMs,
    session: session ?? this.session,
    track: track,
    index: index,
    playing: playing,
    ready: ready,
    positionMs: positionMs,
    durationMs: durationMs,
    repeat: repeat,
    silent: silent ?? this.silent,
    busy: busy ?? this.busy,
    canNudge: canNudge ?? this.canNudge,
    rate: rate,
  );

  Map<String, dynamic> toJson() => {
    'nowMs': nowMs,
    'session': ?session,
    if (track != null) 'track': track!.toJson(),
    'index': index,
    'playing': playing,
    'ready': ready,
    'positionMs': positionMs,
    'durationMs': ?durationMs,
    'repeat': repeat.name,
    'silent': silent,
    'busy': busy,
    'canNudge': canNudge,
    'rate': ?rate,
  };

  static LinkTogetherReport? fromJson(Object? json) {
    if (json is! Map) return null;
    final nowMs = _int(json['nowMs']);
    if (nowMs == null || nowMs <= 0) return null;
    final session = json['session'];
    final rate = json['rate'];
    return LinkTogetherReport(
      nowMs: nowMs,
      session: session is String && session.isNotEmpty ? session : null,
      track: TrackRef.fromJson(json['track']),
      index: _int(json['index']) ?? -1,
      playing: json['playing'] == true,
      ready: json['ready'] == true,
      positionMs: _int(json['positionMs']) ?? 0,
      durationMs: _int(json['durationMs']),
      repeat:
          LinkRepeatMode.values.asNameMap()[json['repeat']] ??
          LinkRepeatMode.none,
      silent: json['silent'] == true,
      busy: json['busy'] == true,
      canNudge: json['canNudge'] == true,
      // A session plays at 1x with nudges of a few percent; a value far from
      // that is not a rate to extrapolate with.
      rate: rate is num && rate > 0.5 && rate < 2 ? rate.toDouble() : null,
    );
  }
}

/// Where the follower must be: on [track] at [positionMs] at [atMs] of its
/// own clock, playing or paused. Play is called [leadMs] early, as much
/// longer as that device takes to sound than the leader (negative: late).
class LinkTogetherCue {
  const LinkTogetherCue({
    required this.track,
    required this.positionMs,
    required this.atMs,
    required this.playing,
    this.leadMs = 0,
  });

  final TrackRef track;
  final int positionMs;
  final int atMs;
  final bool playing;
  final int leadMs;

  /// The leader's position at [whenMs], on the follower's clock.
  int positionAt(int whenMs) {
    if (!playing) return positionMs;
    final position = positionMs + (whenMs - atMs);
    return position < 0 ? 0 : position;
  }

  /// This cue on a clock that runs [offsetMs] ahead.
  LinkTogetherCue shifted(int offsetMs) => LinkTogetherCue(
    track: track,
    positionMs: positionMs,
    atMs: atMs + offsetMs,
    playing: playing,
    leadMs: leadMs,
  );

  Map<String, dynamic> toJson() => {
    'track': track.toJson(),
    'positionMs': positionMs,
    'atMs': atMs,
    'playing': playing,
    'leadMs': leadMs,
  };

  static LinkTogetherCue? fromJson(Object? json) {
    if (json is! Map) return null;
    final track = TrackRef.fromJson(json['track']);
    final positionMs = _int(json['positionMs']);
    final atMs = _int(json['atMs']);
    if (track == null || positionMs == null || atMs == null) return null;
    return LinkTogetherCue(
      track: track,
      positionMs: positionMs < 0 ? 0 : positionMs,
      atMs: atMs,
      playing: json['playing'] != false,
      leadMs: (_int(json['leadMs']) ?? 0).clamp(-1000, 1000),
    );
  }
}

/// Whether two devices play the same song: by catalog id, ISRC, match key,
/// then title and artist, as the handoff matches songs.
bool linkTogetherSameTrack(TrackRef? a, TrackRef? b) {
  if (a == null || b == null) return a == null && b == null;
  return (a.songId != null &&
          a.songId == b.songId &&
          (a.serverId == null ||
              b.serverId == null ||
              a.serverId == b.serverId)) ||
      (a.fileId != null && a.fileId == b.fileId) ||
      (a.isrc != null && a.isrc == b.isrc) ||
      (a.matchKey != null && a.matchKey == b.matchKey) ||
      (a.title == b.title && a.artist == b.artist);
}
