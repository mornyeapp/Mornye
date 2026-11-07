import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/lyrics_timeline.dart';
import 'package:mornye/utils/synced_lyrics_scroll.dart';
import 'package:mornye/widgets/player_lyrics.dart';

/// Single-line real-time lyric preview shown beneath track metadata on the
/// main player screen. Tapping opens full synchronized lyrics.
class PlayerLyricPreview extends ConsumerStatefulWidget {
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
  ConsumerState<PlayerLyricPreview> createState() => _PlayerLyricPreviewState();
}

class _PlayerLyricPreviewState extends ConsumerState<PlayerLyricPreview> {
  ParsedLyrics? _lastLyrics;
  List<LyricLine> _lines = const [];
  Timer? _lineBoundaryTimer;
  final Stopwatch _elapsedClock = Stopwatch();
  Duration _anchorPosition = Duration.zero;
  bool _playing = false;
  ProviderSubscription<Duration>? _positionSub;
  ProviderSubscription<bool>? _playingSub;

  @override
  void initState() {
    super.initState();
    widget.seekPreview.addListener(_onSeekPreviewChanged);
    _positionSub = ref.listenManual<Duration>(playbackPositionProvider, (
      previous,
      next,
    ) {
      if (widget.seekPreview.value != null) return;
      _anchorPosition = next;
      _elapsedClock.reset();
      if (_playing) _elapsedClock.start();
      _scheduleNextLine();
      if (mounted) setState(() {});
    });
    _playingSub = ref.listenManual<bool>(playbackPlayingProvider, (
      previous,
      playing,
    ) {
      _playing = playing;
      if (playing) {
        _elapsedClock.start();
      } else {
        _elapsedClock.stop();
      }
      _scheduleNextLine();
      if (mounted) setState(() {});
    });
    _playing = _playingSub?.read() ?? false;
    _anchorPosition = _positionSub?.read() ?? Duration.zero;
    if (_playing) _elapsedClock.start();
  }

  @override
  void didUpdateWidget(covariant PlayerLyricPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.seekPreview != widget.seekPreview) {
      oldWidget.seekPreview.removeListener(_onSeekPreviewChanged);
      widget.seekPreview.addListener(_onSeekPreviewChanged);
    }
  }

  @override
  void dispose() {
    widget.seekPreview.removeListener(_onSeekPreviewChanged);
    _lineBoundaryTimer?.cancel();
    _positionSub?.close();
    _playingSub?.close();
    _elapsedClock.stop();
    super.dispose();
  }

  void _onSeekPreviewChanged() {
    if (!mounted) return;
    _lineBoundaryTimer?.cancel();
    _anchorPosition = widget.seekPreview.value ?? _anchorPosition;
    _elapsedClock.reset();
    _scheduleNextLine();
    setState(() {});
  }

  Duration get _displayPosition {
    if (widget.seekPreview.value != null) return widget.seekPreview.value!;
    if (!_playing) return _anchorPosition;
    return interpolatedSyncedLyricsPosition(
      anchorPosition: _anchorPosition,
      elapsedSinceAnchor: _elapsedClock.elapsed,
      isPlaying: _playing,
    );
  }

  void _scheduleNextLine() {
    _lineBoundaryTimer?.cancel();
    if (!mounted ||
        _lines.isEmpty ||
        !_playing ||
        widget.seekPreview.value != null) {
      return;
    }

    final pos = _displayPosition;
    final index = LyricsParser.activeIndex(_lines, pos);

    Duration? nextTrigger;
    if (index >= 0 && index < _lines.length) {
      final line = _lines[index];
      if (line.end != null && line.end! > pos) {
        nextTrigger = line.end;
      }
    }

    final nextIndex = index + 1;
    if (nextIndex < _lines.length) {
      final nextStart = _lines[nextIndex].time;
      // Slight 80ms lead time so the animation completes just as the first word sings.
      const leadTime = Duration(milliseconds: 80);
      final lineEarly = nextStart > leadTime
          ? nextStart - leadTime
          : Duration.zero;
      if (nextTrigger == null || lineEarly < nextTrigger) {
        nextTrigger = lineEarly;
      }
    }

    if (nextTrigger == null) return;
    final remaining = nextTrigger - pos;
    final delay = remaining.isNegative ? Duration.zero : remaining;
    _lineBoundaryTimer = Timer(delay, () {
      if (!mounted || !_playing) return;
      setState(() {});
      _scheduleNextLine();
    });
  }

  void _syncLines(ParsedLyrics lyrics) {
    if (identical(_lastLyrics, lyrics)) return;
    _lastLyrics = lyrics;
    if (!lyrics.synced || lyrics.lines.isEmpty) {
      _lines = const [];
    } else {
      _lines = lyricsWithDisplayEnds(lyricsTimelineWithGaps(lyrics.lines));
    }
    _scheduleNextLine();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(
      settingsProvider.select((s) => s.playerShowLyricSnippet),
    );
    if (!enabled) return const SizedBox.shrink();

    return ListenableBuilder(
      listenable: widget.metadata,
      builder: (context, _) {
        if (widget.metadata.loading ||
            widget.metadata.lyrics.isEmpty ||
            !widget.metadata.lyrics.synced) {
          return const SizedBox.shrink();
        }

        final showTranslation = ref.watch(
          settingsProvider.select((s) => s.playerShowTranslation),
        );
        ref.watch(lyricsTranslationProvider.select((s) => s.results));
        final translation = ref.read(lyricsTranslationProvider.notifier);
        final effectiveLyrics = translation.display(widget.metadata.lyrics);

        _syncLines(effectiveLyrics);
        if (_lines.isEmpty) return const SizedBox.shrink();

        final Duration position = _displayPosition;
        final index = LyricsParser.activeIndex(_lines, position);

        LyricLine? activeLine;
        String currentText = '•••';
        if (index >= 0 && index < _lines.length) {
          final line = _lines[index];
          final candidate =
              (showTranslation &&
                  line.translation != null &&
                  line.translation!.trim().isNotEmpty)
              ? line.translation!.trim()
              : line.text.trim();
          if (candidate.isNotEmpty) {
            final end = line.end;
            if (end == null || position <= end + const Duration(seconds: 2)) {
              currentText = candidate;
              activeLine = line;
            }
          }
        }

        final mornye = context.isMornye;
        final textColor = mornye
            ? widget.colorScheme.onSurface.withValues(alpha: 0.88)
            : widget.colorScheme.onSurfaceVariant;
        final iconColor = mornye
            ? widget.colorScheme.onSurface.withValues(alpha: 0.55)
            : widget.colorScheme.onSurfaceVariant.withValues(alpha: 0.7);

        final textStyle = TextStyle(
          fontSize: mornye ? 17 : 15,
          fontWeight: FontWeight.w500,
          color: textColor,
          letterSpacing: mornye ? -0.2 : 0,
        );

        Widget lyricWidget;
        final isWordTimed =
            activeLine != null &&
            activeLine.hasWordTiming &&
            (!showTranslation ||
                activeLine.translationWords.isNotEmpty ||
                activeLine.translation == null);

        if (currentText == '•••' || activeLine == null) {
          lyricWidget = Text(
            '•••',
            key: const ValueKey('•••'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textStyle.copyWith(
              letterSpacing: 2.0,
              color: textColor.withValues(alpha: 0.55),
            ),
          );
        } else if (isWordTimed) {
          lyricWidget = ClipRect(
            key: ValueKey('word-${activeLine.time.inMilliseconds}'),
            child: WordTimedLyricLine(
              line: activeLine,
              initialPosition: position,
              seekPreview: widget.seekPreview,
              style: textStyle,
              maxLines: 1,
            ),
          );
        } else {
          lyricWidget = Text(
            currentText,
            key: ValueKey(
              'line-${activeLine.time.inMilliseconds}-$currentText',
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textStyle,
          );
        }

        return Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Semantics(
            button: true,
            label: 'Lyrics: $currentText',
            child: InkWell(
              onTap: widget.onTap == null
                  ? null
                  : () {
                      HapticFeedback.selectionClick();
                      widget.onTap!();
                    },
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        switchInCurve: Curves.easeOutQuad,
                        switchOutCurve: Curves.easeInQuad,
                        layoutBuilder: (currentChild, previousChildren) =>
                            Stack(
                              alignment: Alignment.centerLeft,
                              children: [
                                ...previousChildren,
                                if (currentChild != null) currentChild,
                              ],
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
                        child: lyricWidget,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      mornye
                          ? CupertinoIcons.chevron_right
                          : Icons.chevron_right,
                      size: mornye ? 14 : 16,
                      color: iconColor,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
