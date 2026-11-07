import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/lyrics_timeline.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('LockScreenLyrics');

/// Synced lyrics as the lock screen shows them: the lead line being sung,
/// and no line before the first one, in a break of [minimumBreak] or more,
/// or after the last line's known end. Backing vocals never replace it.
class LockScreenLyricTimeline {
  LockScreenLyricTimeline(
    List<LyricLine> lines, {
    Duration offset = Duration.zero,
  }) : _rows = _rowsOf(lyricsShiftedBy(lines, offset));

  /// The shortest silence that shows the song's own title again. Shorter
  /// pauses keep the line, so the title does not flicker between lines.
  static const minimumBreak = Duration(seconds: 3);

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
    for (final line in lines) {
      if (line.isBackground) continue;
      final text = line.text.replaceAll(_whitespace, ' ').trim();
      if (text.isEmpty) {
        silentFrom ??= line.time;
        continue;
      }
      if (silentFrom != null && line.time - silentFrom >= minimumBreak) {
        rows.add(LyricLine(time: silentFrom, text: ''));
      }
      rows.add(LyricLine(time: line.time, text: text));
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

Future<Duration> _storedLyricsOffset() async {
  final prefs = await SharedPreferences.getInstance();
  return Duration(
    milliseconds: normalizeLyricsOffsetMs(prefs.getInt(kLyricsOffsetKey)),
  );
}

/// Shows the line being sung in place of the song's title on the lock
/// screen, while the listener has it on.
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
    Future<Duration> Function()? lyricsOffset,
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
  final Future<Duration> Function() _lyricsOffset;
  final DateTime Function() _now;

  bool _enabled = false;
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

  /// The line the system shows in place of the title, or null for the title.
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

  bool get _active => _enabled && _showing;

  void _setShowing(bool showing) {
    if (showing == _showing) return;
    _showing = showing;
    if (showing) {
      _load();
      // The timing setting can only change while the screen is unlocked.
      unawaited(
        _lyricsOffset().then((offset) {
          if (offset == _offset) return;
          _offset = offset;
          _timelineLyrics = null;
          _lyricsChanged();
        }, onError: (Object error) => _log.w('No lyrics offset: $error')),
      );
    }
    _update();
  }

  /// Reads the current item's lyrics. A controller already reading the
  /// same item keeps what it has.
  void _load() {
    final item = _item?.mediaItem;
    if (!_active || item == null) return;
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
    return SetMediaItemRequest(
      mediaItem: MediaItemMessage(
        id: item.id,
        title: line,
        album: item.album,
        artist: item.artist,
        genre: item.genre,
        duration: item.duration,
        artUri: item.artUri,
        playable: item.playable,
        displayTitle: item.displayTitle == null ? null : line,
        displaySubtitle: item.displaySubtitle,
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
  installed.enabled = _enabled;
}

/// Turns lyrics on the lock screen on or off, before or after installing.
void configureLockScreenLyrics({required bool enabled}) {
  _enabled = enabled;
  _installed?.enabled = enabled;
}
