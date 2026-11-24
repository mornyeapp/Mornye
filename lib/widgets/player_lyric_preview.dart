import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/song_lyrics_offset_provider.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/lyrics_timeline.dart';
import 'package:mornye/utils/synced_lyrics_scroll.dart';
import 'package:mornye/utils/text_direction.dart';
import 'package:mornye/widgets/lyric_line_scroller.dart';
import 'package:mornye/widgets/player_lyrics.dart';

/// The synced line being sung, under the track title on the player. Tapping
/// it opens the full lyrics. Off unless `playerShowLyricSnippet` is on, and
/// then it builds nothing until the song has synced lyrics.
class PlayerLyricPreview extends ConsumerWidget {
  const PlayerLyricPreview({
    super.key,
    required this.metadata,
    required this.seekPreview,
    required this.colorScheme,
    this.onTap,
  });

  final PlayerMetadataController metadata;
  final ValueListenable<Duration?> seekPreview;
  final ColorScheme colorScheme;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(
      settingsProvider.select((settings) => settings.playerShowLyricSnippet),
    );
    if (!enabled) return const SizedBox.shrink();
    return _LyricPreviewLine(
      metadata: metadata,
      seekPreview: seekPreview,
      colorScheme: colorScheme,
      onTap: onTap,
    );
  }
}

class _LyricPreviewLine extends ConsumerStatefulWidget {
  const _LyricPreviewLine({
    required this.metadata,
    required this.seekPreview,
    required this.colorScheme,
    required this.onTap,
  });

  final PlayerMetadataController metadata;
  final ValueListenable<Duration?> seekPreview;
  final ColorScheme colorScheme;
  final VoidCallback? onTap;

  @override
  ConsumerState<_LyricPreviewLine> createState() => _LyricPreviewLineState();
}

class _LyricPreviewLineState extends ConsumerState<_LyricPreviewLine> {
  /// The next line shows this early, so its fade ends as its first word
  /// starts.
  static const _lineLead = Duration(milliseconds: 80);

  /// A finished line stays this long before the gap placeholder replaces it.
  static const _lineHold = Duration(seconds: 2);

  /// How long a song known to have no synced lyrics keeps the row before it
  /// closes. A document still being resolved reports none before it loads.
  static const _closeGrace = Duration(milliseconds: 600);

  static const _placeholder = '•••';

  /// Whether the row holds its height; see [_syncRow].
  bool _open = false;
  Timer? _closeTimer;

  /// The synced lyrics last shown and their song, kept on screen while the
  /// same song's lyrics load again (the file after its catalog entry, a
  /// saved translation).
  String? _heldTrack;
  ParsedLyrics? _heldLyrics;

  Timer? _nextLine;
  ParsedLyrics? _timelineSource;
  int? _timelineOffsetMs;
  List<LyricLine> _timeline = const [];

  /// The line last shown, by index into [_shownLines].
  int _shownIndex = -1;
  List<LyricLine>? _shownLines;

  @override
  void initState() {
    super.initState();
    widget.seekPreview.addListener(_refresh);
  }

  @override
  void didUpdateWidget(covariant _LyricPreviewLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.seekPreview != widget.seekPreview) {
      oldWidget.seekPreview.removeListener(_refresh);
      widget.seekPreview.addListener(_refresh);
    }
  }

  @override
  void dispose() {
    widget.seekPreview.removeListener(_refresh);
    _nextLine?.cancel();
    _closeTimer?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  /// Opens the row for a song with synced lyrics and keeps it while the
  /// next song's lyrics are [pending], so a change between two songs with
  /// lyrics moves nothing around it. Before, each step of loading (the
  /// catalog entry, then the file) dropped the row and brought it back,
  /// and the title and cover jumped down and up with it. The row closes,
  /// once, when the song turns out to have none.
  void _syncRow({required bool hasLines, required bool pending}) {
    if (hasLines || pending) {
      _closeTimer?.cancel();
      _closeTimer = null;
      if (hasLines) _open = true;
    } else if (_open && _closeTimer == null) {
      _closeTimer = Timer(_closeGrace, () {
        _closeTimer = null;
        if (mounted) setState(() => _open = false);
      });
    }
  }

  /// Lines with the listener's timing offset, instrumental gaps and display
  /// ends, rebuilt only when the lyrics or the offset change.
  List<LyricLine> _timelineFor(ParsedLyrics lyrics, int offsetMs) {
    if (!identical(lyrics, _timelineSource) || offsetMs != _timelineOffsetMs) {
      _timelineSource = lyrics;
      _timelineOffsetMs = offsetMs;
      _timeline = lyrics.synced && lyrics.lines.isNotEmpty
          ? lyricsWithDisplayEnds(
              lyricsTimelineWithGaps(
                lyricsShiftedBy(lyrics.lines, Duration(milliseconds: offsetMs)),
              ),
            )
          : const [];
    }
    return _timeline;
  }

  /// Playback reports its position only when its state changes, so a timer
  /// rebuilds the line when the next one starts or the current one ends.
  void _scheduleNextLine(
    List<LyricLine> lines,
    int index,
    Duration probe,
    PlaybackState? state, {
    required bool visible,
  }) {
    _nextLine?.cancel();
    if (widget.seekPreview.value != null ||
        !visible ||
        state == null ||
        !state.playing ||
        state.processingState != AudioProcessingState.ready ||
        !state.speed.isFinite ||
        state.speed <= 0) {
      return;
    }
    Duration? at;
    final end = index >= 0 ? lines[index].end : null;
    if (end != null && end + _lineHold > probe) at = end + _lineHold;
    if (index + 1 < lines.length) {
      final nextStart = lines[index + 1].time;
      if (at == null || nextStart < at) at = nextStart;
    }
    if (at == null) return;
    final wait = at - probe;
    _nextLine = Timer(
      Duration(microseconds: (wait.inMicroseconds / state.speed).ceil()),
      _refresh,
    );
  }

  /// Steady position reports are already followed by [_nextLine]; only
  /// transport changes, seeks and clock jumps rebuild the line.
  static bool _shouldRebuildForPlayback(
    PlaybackState? previous,
    PlaybackState? next,
  ) {
    if (previous == null || next == null) return previous != next;
    if (previous.playing != next.playing ||
        previous.processingState != next.processingState ||
        previous.speed != next.speed ||
        previous.queueIndex != next.queueIndex) {
      return true;
    }
    if (!next.playing) {
      return previous.updatePosition != next.updatePosition;
    }
    return (next.position - previous.position).abs() >
        const Duration(milliseconds: 350);
  }

  @override
  Widget build(BuildContext context) {
    // The line reads as sung unless its own setting asks for the
    // translation; the full lyrics' translation switch does not apply here.
    final showTranslation = ref.watch(
      settingsProvider.select(
        (settings) => settings.playerLyricSnippetTranslation,
      ),
    );
    final appOffsetMs = ref.watch(
      themeProvider.select((theme) => theme.lyricsOffsetMs),
    );
    // The song is only known inside the builder below, which follows the
    // metadata; a change of any song's offset is rare.
    final songOffsets = ref.watch(songLyricsOffsetsProvider);
    ref.watch(lyricsTranslationProvider.select((state) => state.results));
    ref.watch(
      settingsProvider.select(
        (settings) => (
          settings.lyricsRomanize,
          settings.lyricsRomanizedMainLine,
          // The app language decides which scripts stay unromanized.
          settings.locale,
        ),
      ),
    );
    // An offstage or covered player keeps no line timer running and avoids
    // 2 Hz position-tick rebuilds while hidden. Even while visible, listen
    // selectively so steady 2 Hz position reports do not rebuild the row.
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible) {
      ref.listen<AsyncValue<PlaybackState>>(playbackStateProvider, (
        previous,
        next,
      ) {
        if (_shouldRebuildForPlayback(previous?.value, next.value)) {
          _refresh();
        }
      });
    }
    final state = ref.read(playbackStateProvider).value;
    final translation = ref.read(lyricsTranslationProvider.notifier);
    return ListenableBuilder(
      listenable: widget.metadata,
      builder: (context, _) {
        final metadata = widget.metadata;
        final track = metadata.item?.id;
        final pending = metadata.loading || metadata.searchingOnline;
        ParsedLyrics? lyrics;
        if (!metadata.loading && metadata.lyrics.synced) {
          lyrics = metadata.lyrics;
          _heldTrack = track;
          _heldLyrics = lyrics;
        } else if (pending && track != null && track == _heldTrack) {
          lyrics = _heldLyrics;
        } else {
          _heldTrack = null;
          _heldLyrics = null;
        }
        final offsetMs =
            appOffsetMs +
            (songOffsets[songLyricsOffsetKeyOf(metadata.item)]?.offsetMs ?? 0);
        final lines = lyrics == null
            ? const <LyricLine>[]
            : _timelineFor(translation.shown(lyrics), offsetMs);
        _syncRow(hasLines: lines.isNotEmpty, pending: pending);
        if (lines.isEmpty) {
          _nextLine?.cancel();
          return _row(context, blank: true);
        }
        final position =
            widget.seekPreview.value ?? state?.position ?? Duration.zero;
        final probe = position + _lineLead;
        final speed = state?.speed ?? 1;
        final advancing =
            widget.seekPreview.value == null &&
            state != null &&
            state.playing &&
            state.processingState == AudioProcessingState.ready &&
            speed.isFinite &&
            speed > 0;
        var index = LyricsParser.activeIndex(lines, probe);
        // The timer moves to a line at its start; a late position report
        // must not step back to the line before for a moment.
        if (advancing &&
            identical(lines, _shownLines) &&
            _shownIndex >= 0 &&
            _shownIndex < lines.length) {
          index = steadySyncedLyricsIndex(
            index: index,
            shown: _shownIndex,
            shownStart: lines[_shownIndex].time,
            position: probe,
          );
        }
        _shownLines = lines;
        _shownIndex = index;
        _scheduleNextLine(lines, index, probe, state, visible: visible);
        return _row(
          context,
          line: _sungLine(lines, index, probe),
          nextStart: index + 1 < lines.length ? lines[index + 1].time : null,
          position: position,
          showTranslation: showTranslation,
          advancing: advancing,
          speed: speed,
        );
      },
    );
  }

  /// The line at [index] while it is sung or just finished; null in a gap.
  LyricLine? _sungLine(List<LyricLine> lines, int index, Duration probe) {
    if (index < 0) return null;
    final line = lines[index];
    if (line.text.trim().isEmpty) return null;
    final end = line.end;
    if (end != null && probe > end + _lineHold) return null;
    return line;
  }

  /// The row: the sung [line], the gap placeholder when it is null, or
  /// with [blank] its bare height while the next song's lyrics load.
  Widget _row(
    BuildContext context, {
    LyricLine? line,
    Duration? nextStart,
    Duration position = Duration.zero,
    bool showTranslation = false,
    bool advancing = false,
    double speed = 1,
    bool blank = false,
  }) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    AppMotionSpec eased(int milliseconds, Curve curve) => AppMotionSpec(
      reduceMotion ? Duration.zero : Duration(milliseconds: milliseconds),
      curve,
    );
    // Size is spatial and stops at its target: an overshoot would move the
    // cover and title past their place and back. Opacity uses the effects
    // springs, and a line leaves faster than the next one arrives.
    final resize = AppMotion.spatialSlow(
      context,
      eased(300, Curves.easeInOutCubic),
    );
    final enter = AppMotion.effects(context, eased(180, Curves.easeOutQuad));
    final exit = AppMotion.effectsFast(context, eased(120, Curves.easeInQuad));
    final mornye = context.isMornye;
    final colorScheme = widget.colorScheme;
    final textColor = mornye
        ? colorScheme.onSurface.withValues(alpha: 0.88)
        : colorScheme.onSurfaceVariant;
    final style = Theme.of(context).textTheme.bodyLarge!.copyWith(
      fontWeight: FontWeight.w500,
      color: textColor,
    );
    final translated = line?.translation?.trim() ?? '';
    // A shown translation is the line, with its own word timing if it has
    // some, so it sweeps as it does in the full lyrics.
    final shown = line == null || !showTranslation || translated.isEmpty
        ? line
        : LyricLine(
            time: line.time,
            end: line.end,
            text: translated,
            words: line.translationWords,
          );
    final text = shown?.text.trim() ?? '';

    final Widget child;
    if (blank) {
      // An empty line is as tall as a written one.
      child = Text('', key: const ValueKey('blank'), maxLines: 1, style: style);
    } else if (shown == null) {
      child = Text(
        _placeholder,
        key: const ValueKey(_placeholder),
        maxLines: 1,
        style: style.copyWith(
          letterSpacing: 2,
          color: textColor.withValues(alpha: 0.55),
        ),
      );
    } else if (shown.hasWordTiming) {
      // A long line slides to keep the sung words in view.
      child = RepaintBoundary(
        key: ValueKey('word-${shown.time.inMilliseconds}-$text'),
        child: Directionality(
          textDirection:
              strongTextDirection(text) ?? Directionality.of(context),
          child: ClipRect(
            child: LyricLineScroller(
              text: shown.words.map((word) => word.text).join(),
              words: shown.words,
              style: style,
              start: shown.time,
              end: shown.end,
              nextStart: nextStart,
              position: position,
              advancing: advancing,
              speed: speed,
              child: WordTimedLyricLine(
                line: shown,
                initialPosition: position,
                seekPreview: widget.seekPreview,
                style: style,
                maxLines: 1,
              ),
            ),
          ),
        ),
      );
    } else {
      // The line reads, and a long one slides, in its own direction: a
      // right-to-left line starts at its right edge and moves rightwards.
      child = RepaintBoundary(
        key: ValueKey('line-${shown.time.inMilliseconds}-$text'),
        child: Directionality(
          textDirection:
              strongTextDirection(text) ?? Directionality.of(context),
          child: LyricLineScroller(
            text: text,
            style: style,
            start: shown.time,
            end: shown.end,
            nextStart: nextStart,
            position: position,
            advancing: advancing,
            speed: speed,
            child: Text(
              text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ),
      );
    }

    final onTap = blank ? null : widget.onTap;
    final shownKey = child.key;
    final row = Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: ExcludeSemantics(
        excluding: blank,
        child: Semantics(
          container: true,
          button: onTap != null,
          label: context.l10n.trackLyrics,
          value: text,
          excludeSemantics: true,
          onTap: onTap,
          child: InkWell(
            onTap: onTap == null
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    onTap();
                  },
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: AnimatedSwitcher(
                      duration: enter.duration,
                      reverseDuration: exit.duration,
                      switchInCurve: enter.curve,
                      switchOutCurve: exit.leaving,
                      layoutBuilder: (current, previous) => Stack(
                        alignment: AlignmentDirectional.centerStart,
                        children: [...previous, ?current],
                      ),
                      // The arriving line rises into place as it fades in.
                      // The one it replaces fades where it is: sliding it
                      // back down read as the row bouncing.
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: child.key == shownKey
                              ? Tween<Offset>(
                                  begin: const Offset(0, 0.25),
                                  end: Offset.zero,
                                ).animate(animation)
                              : const AlwaysStoppedAnimation(Offset.zero),
                          child: child,
                        ),
                      ),
                      child: child,
                    ),
                  ),
                  const SizedBox(width: 4),
                  AnimatedOpacity(
                    opacity: blank ? 0 : 1,
                    duration: blank ? exit.duration : enter.duration,
                    curve: blank ? exit.curve : enter.curve,
                    child: Icon(
                      mornye ? CupertinoIcons.forward : Icons.chevron_right,
                      size: mornye ? 14 : 16,
                      color: mornye
                          ? colorScheme.onSurface.withValues(alpha: 0.55)
                          : colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(end: _open ? 1 : 0),
      duration: resize.duration,
      curve: resize.curve,
      builder: (context, shown, row) {
        final factor = shown.clamp(0.0, 1.0);
        if (factor == 0) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            alignment: AlignmentDirectional.topStart,
            widthFactor: 1,
            heightFactor: factor,
            child: Opacity(opacity: factor, child: row),
          ),
        );
      },
      child: row,
    );
  }
}
