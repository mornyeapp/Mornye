import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/song_lyrics_offset_provider.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/lyrics_timeline.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('LockScreenLyrics');

/// Synced lyrics as the lock screen shows them: the lead line being sung,
/// and no line before the first one, in a break of [minimumBreak] or more,
/// or after the last line's known end. Backing vocals never replace it,
/// nor does a line starting with it, such as a translation timed with the
/// line it translates. A line longer than [partLength] shows in parts, each from when it is
/// sung, since the system cuts a long title short.
class LockScreenLyricTimeline {
  LockScreenLyricTimeline(
    List<LyricLine> lines, {
    Duration offset = Duration.zero,
  }) : _rows = _rowsOf(lyricsShiftedBy(lines, offset));

  /// The shortest silence that shows the song's own title again. Shorter
  /// pauses keep the line, so the title does not flicker between lines.
  static const minimumBreak = Duration(seconds: 3);

  /// About as many characters as a phone's lock screen and notification
  /// show of a title before cutting it short with an ellipsis. A wide
  /// character (Chinese, Japanese, Korean) counts as two.
  static const partLength = 24;

  /// The shortest time a part stays, so it can be read before the next.
  /// A line sung too fast for that shows in fewer, longer parts.
  static const minimumPart = Duration(milliseconds: 1500);

  /// The pace of a line with no known end, for timing its parts, and the
  /// slowest pace a line keeps when the next one starts long after it (an
  /// instrumental break).
  static const _paceWithoutEnd = Duration(milliseconds: 70);
  static const _slowestPace = Duration(milliseconds: 150);

  static final _whitespace = RegExp(r'\s+');

  /// Sung lines, and empty rows where a break starts, in time order.
  final List<LyricLine> _rows;

  /// The line sung at [position], or null for none, and when the next row
  /// starts, or null after the last one.
  ({String? line, Duration? next}) at(Duration position) {
    final index = LyricsParser.activeIndex(_rows, position);
    final next = index + 1 < _rows.length ? _rows[index + 1].time : null;
    final text = index < 0 ? '' : _rows[index].text;
    return (line: text.isEmpty ? null : text, next: next);
  }

  static List<LyricLine> _rowsOf(List<LyricLine> lines) {
    final rows = <LyricLine>[];
    // When the singing stopped: an empty line, or the latest known end of
    // the lines sung so far. A line without an end lasts until the next.
    Duration? silentFrom;
    Duration? sungUntil;
    Duration? shownFrom;
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (line.isBackground) continue;
      final text = line.text.replaceAll(_whitespace, ' ').trim();
      if (text.isEmpty) {
        silentFrom ??= line.time;
        continue;
      }
      if (line.time == shownFrom) continue;
      shownFrom = line.time;
      if (silentFrom != null && line.time - silentFrom >= minimumBreak) {
        rows.add(LyricLine(time: silentFrom, text: ''));
      }
      rows.addAll(_partsOf(line, text, _nextStart(lines, index)));
      final end = _endOf(line);
      if (end == null) {
        sungUntil = null;
      } else if (sungUntil == null || end > sungUntil) {
        sungUntil = end;
      }
      silentFrom = sungUntil;
    }
    if (silentFrom != null) rows.add(LyricLine(time: silentFrom, text: ''));
    return List.unmodifiable(rows);
  }

  static Duration? _endOf(LyricLine line) {
    var end = line.end;
    final lastWord = line.words.lastOrNull?.end;
    if (lastWord != null && (end == null || lastWord > end)) end = lastWord;
    return end != null && end > line.time ? end : null;
  }

  /// When the lead line after [index] starts, or null after the last one.
  static Duration? _nextStart(List<LyricLine> lines, int index) {
    final time = lines[index].time;
    for (var next = index + 1; next < lines.length; next++) {
      final line = lines[next];
      if (!line.isBackground && line.time > time) return line.time;
    }
    return null;
  }

  /// [text] of [line] in parts that fit the lock screen, each starting
  /// when its first word is sung: by the word timing when the line has it,
  /// else at a steady pace across the line. Every part starts before
  /// [nextStart], so a line never shows over the one after it.
  static List<LyricLine> _partsOf(
    LyricLine line,
    String text,
    Duration? nextStart,
  ) {
    final own = _endOf(line);
    var end = own;
    if (nextStart != null && (end == null || nextStart < end)) end = nextStart;
    end ??= line.time + _paceWithoutEnd * text.length;
    final slowest = line.time + _slowestPace * text.length;
    if (own == null && end > slowest) end = slowest;
    for (var count = lyricPartCount(text, partLength); count > 1; count--) {
      final starts = lyricPartStarts(text, count);
      final parts = starts.length;
      final times = [
        line.time,
        for (final start in starts.skip(1)) _timeAt(line, text, start, end),
      ];
      var readable = parts > 1;
      for (var part = 0; part < parts && readable; part++) {
        final until = part + 1 < parts ? times[part + 1] : end;
        readable = until - times[part] >= minimumPart;
      }
      if (!readable) continue;
      return [
        for (var part = 0; part < parts; part++)
          LyricLine(
            time: times[part],
            text: text
                .substring(
                  starts[part],
                  part + 1 < parts ? starts[part + 1] : text.length,
                )
                .trim(),
          ),
      ];
    }
    return [LyricLine(time: line.time, text: text)];
  }

  /// When the character at [offset] of [text] is sung.
  static Duration _timeAt(
    LyricLine line,
    String text,
    int offset,
    Duration end,
  ) {
    if (line.hasWordTiming) {
      // Spacing differs between the words and the tidied text, so count
      // the letters before [offset] and find the word that holds the next.
      var before = text.substring(0, offset).replaceAll(_whitespace, '').length;
      for (final word in line.words) {
        final letters = word.text.replaceAll(_whitespace, '').length;
        if (before < letters) {
          return word.time < line.time ? line.time : word.time;
        }
        before -= letters;
      }
    }
    return line.time + (end - line.time) * (offset / text.length);
  }
}

/// How many parts [text] needs so that none is wider than [maxWidth]
/// characters, counting a wide character as two (see [lyricTextWidth]).
@visibleForTesting
int lyricPartCount(String text, int maxWidth) {
  final width = lyricTextWidth(text);
  if (width <= maxWidth) return 1;
  for (var count = (width / maxWidth).ceil(); ; count++) {
    final starts = lyricPartStarts(text, count);
    var fits = true;
    for (var part = 0; part < starts.length && fits; part++) {
      final until = part + 1 < starts.length ? starts[part + 1] : text.length;
      fits =
          lyricTextWidth(text.substring(starts[part], until).trim()) <=
          maxWidth;
    }
    // A single word wider than the lock screen cannot fit however the
    // line is cut; stop once more parts only cut words.
    if (fits || count >= text.length || count * maxWidth >= width * 2) {
      return count;
    }
  }
}

/// Where each of [count] parts of about equal width starts in [text], the
/// first at 0. A part ends after a space, preferably one after punctuation
/// near the even split, or after Chinese and Japanese punctuation; text
/// without either is cut at the even split.
@visibleForTesting
List<int> lyricPartStarts(String text, int count) {
  final widths = [for (final rune in text.runes) _runeWidth(rune)];
  final chars = text.runes.toList();
  // Code unit offsets of each rune, so substrings keep surrogate pairs.
  final offsets = <int>[];
  var unit = 0;
  for (final rune in chars) {
    offsets.add(unit);
    unit += rune > 0xFFFF ? 2 : 1;
  }
  final total = widths.fold(0, (sum, width) => sum + width);
  final window = total / count * 0.35;
  final starts = [0];
  for (var part = 1; part < count; part++) {
    final ideal = total * part / count;
    int? best;
    var bestScore = double.infinity;
    var position = 0;
    for (var index = 0; index < chars.length; index++) {
      if (index > 0 &&
          offsets[index] > starts.last &&
          _breaksBefore(chars, index)) {
        final distance = (position - ideal).abs();
        final score = _afterPunctuation(chars, index)
            ? distance - window
            : distance;
        if (score < bestScore) {
          bestScore = score;
          best = index;
        }
      }
      position += widths[index];
    }
    if (best == null || bestScore > window * 2) {
      // No space or punctuation near the even split: cut there.
      var at = 0;
      var width = 0;
      while (at < chars.length && width < ideal) {
        width += widths[at];
        at++;
      }
      best = at;
    }
    final start = best < offsets.length ? offsets[best] : text.length;
    if (start <= starts.last || start >= text.length) break;
    starts.add(start);
  }
  return starts;
}

/// The width [text] takes on screen in characters, a wide character
/// (Chinese, Japanese, Korean, full width forms) counting as two.
@visibleForTesting
int lyricTextWidth(String text) =>
    text.runes.fold(0, (sum, rune) => sum + _runeWidth(rune));

int _runeWidth(int rune) =>
    (rune >= 0x1100 && rune <= 0x115F) ||
        (rune >= 0x2E80 && rune <= 0xA4CF) ||
        (rune >= 0xAC00 && rune <= 0xD7A3) ||
        (rune >= 0xF900 && rune <= 0xFAFF) ||
        (rune >= 0xFE30 && rune <= 0xFE4F) ||
        (rune >= 0xFF00 && rune <= 0xFF60) ||
        (rune >= 0xFFE0 && rune <= 0xFFE6)
    ? 2
    : 1;

const _wideStops = {0x3001, 0x3002, 0xFF0C, 0xFF01, 0xFF1F, 0xFF1B, 0xFF1A};
const _stops = {0x2C, 0x3B, 0x3A, 0x2E, 0x21, 0x3F, 0x29};

/// Whether a part may start at rune [index]: after a space, or after
/// Chinese and Japanese punctuation, which has no space after it.
bool _breaksBefore(List<int> runes, int index) {
  final previous = runes[index - 1];
  return (previous == 0x20 && runes[index] != 0x20) ||
      _wideStops.contains(previous);
}

/// Whether the break at rune [index] follows punctuation, a natural pause.
bool _afterPunctuation(List<int> runes, int index) {
  final previous = runes[index - 1];
  if (_wideStops.contains(previous)) return true;
  return previous == 0x20 && index > 1 && _stops.contains(runes[index - 2]);
}

/// Whether the lock screen is showing. Android reports the screen on with
/// the keyguard up. iOS tells an app nothing about the lock screen, so
/// there it is whether Mornye is in the background, which includes it.
Stream<bool> lockScreenShowing() {
  if (defaultTargetPlatform == TargetPlatform.android) {
    return const EventChannel(
      'com.zarz.mornye/lock_screen',
    ).receiveBroadcastStream().map((showing) => showing == true);
  }
  return _inBackground();
}

Stream<bool> _inBackground() {
  bool hidden(AppLifecycleState? state) =>
      state == AppLifecycleState.hidden || state == AppLifecycleState.paused;
  AppLifecycleListener? listener;
  late final StreamController<bool> states;
  states = StreamController<bool>(
    onListen: () {
      states.add(hidden(WidgetsBinding.instance.lifecycleState));
      listener = AppLifecycleListener(
        onStateChange: (state) => states.add(hidden(state)),
      );
    },
    onCancel: () {
      listener?.dispose();
      listener = null;
      return states.close();
    },
  );
  return states.stream.distinct();
}

/// The stored app-wide offset plus [item]'s own, as the player times it.
Future<Duration> _storedLyricsOffset(MediaItemMessage item) async {
  final prefs = await SharedPreferences.getInstance();
  return Duration(
    milliseconds:
        normalizeLyricsOffsetMs(prefs.getInt(kLyricsOffsetKey)) +
        storedSongLyricsOffsetMs(
          prefs,
          songLyricsOffsetKey(item.title, item.artist),
        ),
  );
}

/// Shows the line being sung in place of the song's title on the lock
/// screen, or of its artist with [keepTitle], while the listener has it on.
///
/// It sits right before the system media session, under
/// `MediaSessionFilter`, so only the system sees the line. The app's own
/// listeners (Last.fm, Discord, widgets, Link) keep the real title. Other
/// readers of the system session, such as cars and watches, see what the
/// lock screen shows. The lyrics are the song's own and its `.mlrc` file;
/// nothing is searched online.
class LockScreenLyrics extends AudioServicePlatform {
  LockScreenLyrics(
    this.platform, {
    Stream<bool> Function()? lockScreen,
    PlayerMetadataController Function()? metadata,
    Future<Duration> Function(MediaItemMessage item)? lyricsOffset,
    this.restatePosition = false,
    DateTime Function()? now,
  }) : _lockScreen = lockScreen ?? lockScreenShowing,
       _createMetadata = metadata ?? PlayerMetadataController.new,
       _lyricsOffset = lyricsOffset ?? _storedLyricsOffset,
       _now = now ?? DateTime.now;

  /// The system's end of the session.
  final AudioServicePlatform platform;

  /// Whether each change goes out after a state at the current position.
  /// iOS's Now Playing takes a changed item's elapsed time from the last
  /// state as it was, so the scrubber would jump back to it.
  final bool restatePosition;

  /// The shortest time between two changes, below the rate at which
  /// Android drops notification updates.
  static const minimumInterval = Duration(milliseconds: 500);

  final Stream<bool> Function() _lockScreen;
  final PlayerMetadataController Function() _createMetadata;

  /// The lyrics timing of an item: app-wide plus the song's own.
  final Future<Duration> Function(MediaItemMessage item) _lyricsOffset;
  final DateTime Function() _now;

  bool _enabled = false;
  bool _keepTitle = false;
  bool _showing = false;
  StreamSubscription<bool>? _lockScreenStates;
  PlayerMetadataController? _metadata;

  /// The media item [_metadata] reads, by id.
  String? _loadedId;
  Duration _offset = Duration.zero;

  /// The real media item and state, as the filter above sends them.
  SetMediaItemRequest? _item;
  PlaybackStateMessage? _state;

  LockScreenLyricTimeline? _timeline;
  ParsedLyrics? _timelineLyrics;
  String? _timelineId;

  /// The line the system shows, or null for the song's own title and artist.
  String? _line;
  Timer? _nextLine;
  Timer? _publishing;
  DateTime? _publishedAt;

  bool get enabled => _enabled;

  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    if (value) {
      _lockScreenStates = _lockScreen().listen(
        _setShowing,
        onError: (Object error) => _log.w('No lock screen state: $error'),
      );
      return;
    }
    unawaited(_lockScreenStates?.cancel());
    _lockScreenStates = null;
    _setShowing(false);
    _metadata
      ?..removeListener(_lyricsChanged)
      ..dispose();
    _metadata = null;
    _loadedId = null;
    _clearTimeline();
  }

  /// Whether the line takes the artist's place and the title stays.
  bool get keepTitle => _keepTitle;

  set keepTitle(bool value) {
    if (value == _keepTitle) return;
    _keepTitle = value;
    // A line on show moves to its new place.
    if (_line != null && _publishing == null) _publish();
  }

  bool get _active => _enabled && _showing;

  void _setShowing(bool showing) {
    if (showing == _showing) return;
    _showing = showing;
    if (showing) _load();
    _update();
  }

  /// Reads the timing of [item]'s lyrics, each time the lock screen shows
  /// and for each song, since every song may have its own.
  void _loadOffset(MediaItemMessage item) {
    unawaited(
      _lyricsOffset(item).then((offset) {
        if (!_active || _item?.mediaItem.id != item.id) return;
        if (offset == _offset) return;
        _offset = offset;
        _timelineLyrics = null;
        _lyricsChanged();
      }, onError: (Object error) => _log.w('No lyrics offset: $error')),
    );
  }

  /// Reads the current item's lyrics. A controller already reading the
  /// same item keeps what it has.
  void _load() {
    final item = _item?.mediaItem;
    if (!_active || item == null) return;
    _loadOffset(item);
    final metadata = _metadata ??= _createMetadata()
      ..addListener(_lyricsChanged);
    _loadedId = item.id;
    unawaited(
      metadata.load(
        MediaItem(
          id: item.id,
          title: item.title,
          album: item.album,
          artist: item.artist,
          duration: item.duration,
          extras: item.extras,
        ),
        // Playback streams an SAF song straight from its document and
        // publishes no resolved copy, so the lyrics are read from it.
        inspectUnresolvedContentUri: true,
      ),
    );
    _lyricsChanged();
  }

  void _lyricsChanged() {
    final metadata = _metadata;
    final id = _item?.mediaItem.id;
    if (metadata == null || id == null || _loadedId != id) return;
    final lyrics = metadata.lyrics;
    // A new source of the same song clears its lyrics until they are read
    // again; keep the line meanwhile.
    if (metadata.loading && lyrics.isEmpty && _timelineId == id) return;
    if (identical(lyrics, _timelineLyrics) && _timelineId == id) return;
    _timelineLyrics = lyrics;
    _timelineId = id;
    _timeline = lyrics.synced && lyrics.lines.isNotEmpty
        ? LockScreenLyricTimeline(lyrics.lines, offset: _offset)
        : null;
    _update();
  }

  void _clearTimeline() {
    _timeline = null;
    _timelineLyrics = null;
    _timelineId = null;
  }

  /// Shows the line for now and waits for the next one.
  void _update() {
    _nextLine?.cancel();
    _nextLine = null;
    _show(_currentLine());
  }

  String? _currentLine() {
    final item = _item?.mediaItem;
    final state = _state;
    final timeline = _timeline;
    if (!_active ||
        item == null ||
        state == null ||
        timeline == null ||
        _timelineId != item.id ||
        !state.playing) {
      return null;
    }
    final advancing =
        state.processingState == AudioProcessingStateMessage.ready &&
        state.speed > 0;
    // While buffering the position holds, and so does the line.
    if (!advancing &&
        state.processingState != AudioProcessingStateMessage.buffering) {
      return null;
    }
    final position = advancing
        ? _positionAt(state, _now())
        : state.updatePosition;
    final (:line, :next) = timeline.at(position);
    if (advancing && next != null) {
      _nextLine = Timer((next - position) * (1 / state.speed), _update);
    }
    return line;
  }

  /// Where [state] has advanced to at [now], as the system works it out.
  static Duration _positionAt(PlaybackStateMessage state, DateTime now) {
    final elapsed = now.difference(state.updateTime);
    if (elapsed <= Duration.zero) return state.updatePosition;
    return state.updatePosition + elapsed * state.speed;
  }

  void _show(String? line) {
    if (line == _line) return;
    _line = line;
    if (_publishing != null) return;
    final since = _publishedAt == null
        ? null
        : _now().difference(_publishedAt!);
    if (since == null || since >= minimumInterval) {
      _publish();
      return;
    }
    _publishing = Timer(minimumInterval - since, () {
      _publishing = null;
      _publish();
    });
  }

  void _publish() {
    final item = _item;
    if (item == null) return;
    final now = _publishedAt = _now();
    final state = _state;
    final sends = [
      // Both go out now, in order, so no newer item can come between them.
      if (restatePosition && state != null)
        platform.setState(
          SetStateRequest(state: _state = _restated(state, now)),
        ),
      platform.setMediaItem(_shown(item)),
    ];
    unawaited(
      Future.wait(sends).then<void>(
        (_) {},
        onError: (Object error) => _log.w('Could not show lyrics: $error'),
      ),
    );
  }

  SetMediaItemRequest _shown(SetMediaItemRequest request) {
    final line = _line;
    if (line == null) return request;
    final item = request.mediaItem;
    // The system shows the display fields first where an item has them.
    final keep = _keepTitle;
    return SetMediaItemRequest(
      mediaItem: MediaItemMessage(
        id: item.id,
        title: keep ? item.title : line,
        album: item.album,
        artist: keep ? line : item.artist,
        genre: item.genre,
        duration: item.duration,
        artUri: item.artUri,
        playable: item.playable,
        displayTitle: keep || item.displayTitle == null
            ? item.displayTitle
            : line,
        displaySubtitle: keep && item.displaySubtitle != null
            ? line
            : item.displaySubtitle,
        displayDescription: item.displayDescription,
        rating: item.rating,
        isLive: item.isLive,
        extras: item.extras,
      ),
    );
  }

  /// [state] at the position it has reached at [now].
  static PlaybackStateMessage _restated(
    PlaybackStateMessage state,
    DateTime now,
  ) => PlaybackStateMessage(
    processingState: state.processingState,
    playing: state.playing,
    controls: state.controls,
    androidCompactActionIndices: state.androidCompactActionIndices,
    systemActions: state.systemActions,
    updatePosition:
        state.playing &&
            state.processingState == AudioProcessingStateMessage.ready
        ? _positionAt(state, now)
        : state.updatePosition,
    bufferedPosition: state.bufferedPosition,
    speed: state.speed,
    updateTime: now,
    errorCode: state.errorCode,
    errorMessage: state.errorMessage,
    repeatMode: state.repeatMode,
    shuffleMode: state.shuffleMode,
    captioningEnabled: state.captioningEnabled,
    queueIndex: state.queueIndex,
  );

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) {
    final previous = _item?.mediaItem.id;
    _item = request;
    if (previous != request.mediaItem.id) {
      // Another song shows its own title until its lyrics are read.
      _nextLine?.cancel();
      _nextLine = null;
      _line = null;
      _clearTimeline();
    }
    _publishedAt = _now();
    final sent = platform.setMediaItem(_shown(request));
    _load();
    return sent;
  }

  @override
  Future<void> setState(SetStateRequest request) {
    _state = request.state;
    final sent = platform.setState(request);
    if (_enabled) _update();
    return sent;
  }

  @override
  Future<void> stopService(StopServiceRequest request) {
    _item = null;
    _state = null;
    _line = null;
    _nextLine?.cancel();
    _nextLine = null;
    _publishing?.cancel();
    _publishing = null;
    _loadedId = null;
    _clearTimeline();
    return platform.stopService(request);
  }

  @override
  Future<void> configure(ConfigureRequest request) =>
      platform.configure(request);

  @override
  Future<void> setQueue(SetQueueRequest request) => platform.setQueue(request);

  @override
  Future<void> setAndroidPlaybackInfo(SetAndroidPlaybackInfoRequest request) =>
      platform.setAndroidPlaybackInfo(request);

  @override
  Future<void> androidForceEnableMediaButtons(
    AndroidForceEnableMediaButtonsRequest request,
  ) => platform.androidForceEnableMediaButtons(request);

  @override
  Future<void> notifyChildrenChanged(NotifyChildrenChangedRequest request) =>
      platform.notifyChildrenChanged(request);

  @override
  void setHandlerCallbacks(AudioHandlerCallbacks callbacks) =>
      platform.setHandlerCallbacks(callbacks);
}

LockScreenLyrics? _installed;
bool _enabled = false;
bool _keepTitle = false;

/// Installs [LockScreenLyrics] before `installMediaSessionFilter` and
/// `AudioService.init`, which reads the platform instance once. Android and
/// iOS only: elsewhere no lock screen shows the session.
void installLockScreenLyrics() {
  if (_installed != null) return;
  final ios = defaultTargetPlatform == TargetPlatform.iOS;
  if (!ios && defaultTargetPlatform != TargetPlatform.android) return;
  final installed = _installed = LockScreenLyrics(
    AudioServicePlatform.instance,
    restatePosition: ios,
  );
  AudioServicePlatform.instance = installed;
  installed
    ..keepTitle = _keepTitle
    ..enabled = _enabled;
}

/// Turns lyrics on the lock screen on or off, and sets whether the line
/// takes the artist's place ([keepTitle]), before or after installing.
void configureLockScreenLyrics({
  required bool enabled,
  bool keepTitle = false,
}) {
  _enabled = enabled;
  _keepTitle = keepTitle;
  _installed
    ?..keepTitle = keepTitle
    ..enabled = enabled;
}
