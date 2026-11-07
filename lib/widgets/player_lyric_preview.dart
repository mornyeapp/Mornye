import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/lyrics_timeline.dart';
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

  static const _placeholder = '•••';

  Timer? _nextLine;
  ParsedLyrics? _timelineSource;
  int? _timelineOffsetMs;
  List<LyricLine> _timeline = const [];

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
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
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

  @override
  Widget build(BuildContext context) {
    final showTranslation = ref.watch(
      settingsProvider.select((settings) => settings.playerShowTranslation),
    );
    final offsetMs = ref.watch(
      themeProvider.select((theme) => theme.lyricsOffsetMs),
    );
    ref.watch(lyricsTranslationProvider.select((state) => state.results));
    final state = ref.watch(playbackStateProvider).value;
    final translation = ref.read(lyricsTranslationProvider.notifier);
    // An offstage or covered player keeps no line timer running.
    final visible = TickerMode.valuesOf(context).enabled;
    return ListenableBuilder(
      listenable: widget.metadata,
      builder: (context, _) {
        final metadata = widget.metadata;
        if (metadata.loading || !metadata.lyrics.synced) {
          _nextLine?.cancel();
          return const SizedBox.shrink();
        }
        final lines = _timelineFor(
          translation.display(metadata.lyrics),
          offsetMs,
        );
        if (lines.isEmpty) {
          _nextLine?.cancel();
          return const SizedBox.shrink();
        }
        final position =
            widget.seekPreview.value ?? state?.position ?? Duration.zero;
        final probe = position + _lineLead;
        final index = LyricsParser.activeIndex(lines, probe);
        _scheduleNextLine(lines, index, probe, state, visible: visible);
        final speed = state?.speed ?? 1;
        return _buildLine(
          context,
          line: _sungLine(lines, index, probe),
          nextStart: index + 1 < lines.length ? lines[index + 1].time : null,
          position: position,
          showTranslation: showTranslation,
          advancing:
              widget.seekPreview.value == null &&
              state != null &&
              state.playing &&
              state.processingState == AudioProcessingState.ready &&
              speed.isFinite &&
              speed > 0,
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

  Widget _buildLine(
    BuildContext context, {
    required LyricLine? line,
    required Duration? nextStart,
    required Duration position,
    required bool showTranslation,
    required bool advancing,
    required double speed,
  }) {
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
    final text = line == null
        ? ''
        : showTranslation && translated.isNotEmpty
        ? translated
        : line.text.trim();

    final Widget child;
    if (line == null) {
      child = Text(
        _placeholder,
        key: const ValueKey(_placeholder),
        maxLines: 1,
        style: style.copyWith(
          letterSpacing: 2,
          color: textColor.withValues(alpha: 0.55),
        ),
      );
    } else if (text == line.text.trim() && line.hasWordTiming) {
      // A long line slides to keep the sung words in view.
      child = ClipRect(
        key: ValueKey('word-${line.time.inMilliseconds}'),
        child: LyricLineScroller(
          text: line.words.map((word) => word.text).join(),
          words: line.words,
          style: style,
          start: line.time,
          end: line.end,
          nextStart: nextStart,
          position: position,
          advancing: advancing,
          speed: speed,
          child: WordTimedLyricLine(
            line: line,
            initialPosition: position,
            seekPreview: widget.seekPreview,
            style: style,
            maxLines: 1,
          ),
        ),
      );
    } else {
      child = LyricLineScroller(
        key: ValueKey('line-${line.time.inMilliseconds}-$text'),
        text: text,
        style: style,
        start: line.time,
        end: line.end,
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
      );
    }

    final onTap = widget.onTap;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
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
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOutQuad,
                    switchOutCurve: Curves.easeInQuad,
                    layoutBuilder: (current, previous) => Stack(
                      alignment: AlignmentDirectional.centerStart,
                      children: [...previous, ?current],
                    ),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.2),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: child,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  mornye ? CupertinoIcons.forward : Icons.chevron_right,
                  size: mornye ? 14 : 16,
                  color: mornye
                      ? colorScheme.onSurface.withValues(alpha: 0.55)
                      : colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
