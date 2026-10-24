import 'dart:async';
import 'dart:collection';
import 'dart:ui' show BoxHeightStyle, ImageFilter;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter/rendering.dart'
    show OverflowBoxFit, RenderAbstractViewport, ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/lyrics_timeline.dart';
import 'package:mornye/utils/synced_lyrics_scroll.dart';
import 'package:mornye/widgets/aligned_lyric_pronunciation.dart';
import 'package:mornye/widgets/lyric_blur.dart';
import 'package:mornye/widgets/lyric_supplement_transition.dart';
import 'package:mornye/widgets/lyric_scroll_motion.dart';
import 'package:mornye/widgets/lyric_gap_indicator.dart';
import 'package:mornye/widgets/mornye_player_slider.dart';
import 'package:mornye/widgets/lyrics_text_scale.dart';

part 'player_lyrics_line_style.dart';
part 'player_lyrics_word_sweep.dart';

const _mornyeLyricFontSize = 34.0;

/// Material lyric sizes on desktop, where the lyrics panel is far wider than
/// a phone. Null keeps the text theme's size (phones and tablets).
double? get _materialLyricFontSize => isDesktopPlatform ? 32 : null;
double get _materialBackgroundLyricFontSize => isDesktopPlatform ? 24 : 18;
const mornyeLyricsContentInset = 28.0 + MornyePlayerSlider.horizontalInset;

/// How much of the lyrics area's bottom the player's controls cover. The
/// Mornye phone player lays lyrics out under its controls so they can grow
/// when the controls hide; content that is not a scrolling lyric list keeps
/// clear of this part.
class LyricsCoveredBottom extends InheritedWidget {
  const LyricsCoveredBottom({
    super.key,
    required this.height,
    required super.child,
  });

  final double height;

  static double of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<LyricsCoveredBottom>()
          ?.height ??
      0;

  @override
  bool updateShouldNotify(LyricsCoveredBottom oldWidget) =>
      height != oldWidget.height;
}

class SyncedLyricsView extends ConsumerStatefulWidget {
  final ParsedLyrics lyrics;
  final ValueListenable<Duration?> seekPreview;
  final LyricsCredits? credits;
  final ColorScheme colorScheme;
  final bool isActive;
  final bool showPronunciation;
  final bool showTranslation;

  /// Hidden retained panels keep line positions current without word frames.
  final bool animateWords;

  /// Long-pressing a sung line starts sharing it.
  final ValueChanged<LyricLine>? onLongPressLine;

  const SyncedLyricsView({
    super.key,
    required this.lyrics,
    required this.seekPreview,
    this.credits,
    required this.colorScheme,
    required this.isActive,
    required this.showPronunciation,
    required this.showTranslation,
    this.animateWords = true,
    this.onLongPressLine,
  });

  @override
  ConsumerState<SyncedLyricsView> createState() => _SyncedLyricsViewState();
}

class _SyncedLyricsViewState extends ConsumerState<SyncedLyricsView>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final ScrollController _scroll = ScrollController();
  ProviderSubscription<Duration>? _positionSubscription;
  ProviderSubscription<bool>? _playingSubscription;
  ProviderSubscription<bool>? _loadingSubscription;
  Timer? _lineBoundaryTimer;
  Timer? _userScrollIdleTimer;
  late List<LyricLine> _lines;
  late LyricTimelineIndex _timeline;
  late LyricDisplayLayout _displayLayout;
  late List<GlobalKey> _lineKeys;
  int _active = -1;
  Set<int> _activeLines = {};

  /// The line the view scrolls to; see [_focusFor].
  int _focus = -1;
  Duration _activeTransitionPosition = Duration.zero;
  bool _playing = false;
  bool _loading = false;
  bool _hasStarted = false;
  bool _userScrolling = false;

  /// Hides the list until it first lands on the playing line. A view that
  /// opens on screen would otherwise paint the start of the lyrics, then an
  /// estimated offset, before settling on the line.
  bool _awaitingFirstScroll = false;
  bool _tickerEnabled = true;
  // An inactive app is still on screen: a desktop window behind another
  // app's window, or a phone under a system overlay.
  bool get _visible =>
      widget.isActive &&
      _tickerEnabled &&
      switch (WidgetsBinding.instance.lifecycleState) {
        null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
        _ => false,
      };
  static const double _estimatedLyricExtent = 64;
  _LyricExtentSnapshot? _lineExtents;
  List<(double, double, double)> _lineMeasurements = [];
  List<LyricPronunciationLayout?> _pronunciationLayouts = [];
  Object? _lineLayoutKey;
  final Set<int> _unmeasuredRows = {};
  final Set<int> _changedMeasurementRows = {};
  TextPainter? _measurementPainter;
  void Function(int)? _measureRow;
  Timer? _measurementTimer;
  int _measurementRevision = 0;
  int _layoutMeasurementRevision = 0;
  bool _measurementFramePending = false;
  double? _viewportHeight;
  Offset? _layoutVisibility;
  late final AnimationController _rowReveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  )..addListener(_revealTick);
  List<double> _revealFrom = [];
  List<double> _revealTo = [];
  _LyricExtentSnapshot? _targetLineExtents;
  _LyricExtentGeometry? _extentGeometry;
  Object? _extentGeometryKey;
  bool _preserveRevealAnchor = false;
  late final AnimationController _scrollMotion = AnimationController(
    vsync: this,
    duration: LyricScrollMotion.duration,
    value: 1,
  );
  double _scrollMotionDistance = 0;
  int _scrollMotionFocus = 0;

  void _stopScrollMotion() {
    _scrollMotion.stop();
    _scrollMotion.value = 1;
  }

  void _startScrollMotion(int row, double distance) {
    if (distance.abs() < 0.5 ||
        widget.seekPreview.value != null ||
        MediaQuery.disableAnimationsOf(context)) {
      _stopScrollMotion();
      return;
    }
    setState(() {
      _scrollMotionDistance = distance;
      _scrollMotionFocus = row;
    });
    _scrollMotion.forward(from: 0);
  }

  void _revealTick() {
    if (mounted) setState(() {});
  }

  List<double> get _rowVisibility {
    final progress = Curves.easeInOutCubic.transform(_rowReveal.value);
    if (progress == 1 || identical(_revealFrom, _revealTo)) return _revealTo;
    return _LyricRowVisibility(_revealFrom, _revealTo, progress);
  }

  void _updateRowVisibility({bool immediate = false, bool sameFocus = false}) {
    _preserveRevealAnchor = sameFocus;
    final target = List.generate(_lines.length, (index) {
      final line = _lines[index];
      if (line.text.isEmpty) return _activeLines.contains(index) ? 1.0 : 0.0;
      if (line.isBackground) return index <= _active ? 1.0 : 0.0;
      return 1.0;
    });
    if (immediate || MediaQuery.disableAnimationsOf(context)) {
      _rowReveal.stop();
      _revealFrom = target;
      _revealTo = target;
      return;
    }
    if (listEquals(target, _revealTo)) return;
    _revealFrom = List.of(_rowVisibility);
    _revealTo = target;
    _rowReveal.forward(from: 0);
  }

  // The header stays fixed when controls collapse. Anchor lyrics to it, not
  // to a fraction of the growing viewport, including during the transition.
  double get _focusInset =>
      (MediaQuery.sizeOf(context).height * 0.06).clamp(16.0, 48.0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resetLineKeys();
    widget.seekPreview.addListener(_previewChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Appearance can rebuild when transport controls fade (for example with
    // custom glass clarity). Keep the existing playback subscription and the
    // user's scroll ownership; only new lyrics/page activation should reset it.
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    if ((_positionSubscription != null) != _visible) {
      _syncPositionSubscription(resetUserScroll: false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Focus moving between windows keeps the lyrics running as they are.
    if ((_positionSubscription != null) != _visible) {
      _syncPositionSubscription(resetUserScroll: false);
    }
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant SyncedLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.seekPreview != widget.seekPreview) {
      oldWidget.seekPreview.removeListener(_previewChanged);
      widget.seekPreview.addListener(_previewChanged);
    }
    if (oldWidget.lyrics != widget.lyrics) {
      _resetLineKeys();
    }
    if (oldWidget.showPronunciation != widget.showPronunciation ||
        oldWidget.showTranslation != widget.showTranslation) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_userScrolling && _scroll.hasClients) {
          // Cancel a pending line-scroll once, then let layout preserve the
          // current anchor throughout the supplement animation.
          _scroll.jumpTo(_scroll.offset);
        }
      });
    }
    if (oldWidget.isActive != widget.isActive ||
        oldWidget.lyrics != widget.lyrics) {
      _syncPositionSubscription();
    }
  }

  void _resetLineKeys() {
    _stopScrollMotion();
    _measurementTimer?.cancel();
    _measurementTimer = null;
    _measurementPainter?.dispose();
    _measurementPainter = null;
    _measureRow = null;
    _unmeasuredRows.clear();
    _changedMeasurementRows.clear();
    _hasStarted = false;
    _lineExtents = null;
    _lineLayoutKey = null;
    _lines = lyricsWithDisplayEnds(lyricsTimelineWithGaps(widget.lyrics.lines));
    _timeline = LyricTimelineIndex(_lines);
    _rowReveal.stop();
    _revealFrom = _revealTo = [
      for (final line in _lines)
        if (line.isBackground || line.text.isEmpty) 0.0 else 1.0,
    ];
    _targetLineExtents = null;
    _extentGeometry = null;
    _extentGeometryKey = null;
    _displayLayout = LyricDisplayLayout(_lines);
    _lineKeys = List<GlobalKey>.generate(
      _lines.length,
      (index) => GlobalKey(debugLabel: 'lyric-line-$index'),
      growable: false,
    );
  }

  void _syncPositionSubscription({bool resetUserScroll = true}) {
    _positionSubscription?.close();
    _playingSubscription?.close();
    _loadingSubscription?.close();
    _lineBoundaryTimer?.cancel();
    _positionSubscription = null;
    _playingSubscription = null;
    _loadingSubscription = null;
    if (!_visible) {
      _userScrollIdleTimer?.cancel();
      _measurementTimer?.cancel();
      _measurementTimer = null;
      _stopScrollMotion();
      _rowReveal.stop();
      return;
    }
    _userScrollIdleTimer?.cancel();
    if (resetUserScroll) _userScrolling = false;
    if (_userScrolling) _scheduleUserScrollReturn();
    _scheduleLineMeasurements();

    final position = _displayPosition;
    _playing = ref.read(playbackPlayingProvider);
    _loading = ref.read(playbackLoadingProvider);
    _active = _activeIndexAt(position);
    _activeLines = _timeline.activeIndices(position, _active);
    _focus = _focusFor(_active, _activeLines, position);
    _updateRowVisibility(immediate: true);
    _activeTransitionPosition = position;
    // Only before the first layout: a list already on screen keeps its
    // lines while it moves.
    _awaitingFirstScroll = !_scroll.hasClients && _focus >= 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final scrolled = _visible
          ? _maybeAutoScroll(_active, immediate: true)
          : Future<void>.value();
      unawaited(scrolled.whenComplete(_endFirstScroll));
    });
    _scheduleNextLine(position);
    _positionSubscription = ref.listenManual<Duration>(
      playbackPositionProvider,
      (previous, next) {
        if (widget.seekPreview.value != null) return;
        final active = _activeIndexAt(next);
        _setActiveLine(active, position: next);
        _scheduleNextLine(next);
      },
    );
    _playingSubscription = ref.listenManual<bool>(playbackPlayingProvider, (
      previous,
      next,
    ) {
      _playing = next;
      final position = _displayPosition;
      _setActiveLine(_activeIndexAt(position), position: position);
      _scheduleNextLine(position);
    });
    _loadingSubscription = ref.listenManual<bool>(playbackLoadingProvider, (
      previous,
      next,
    ) {
      _loading = next;
      final position = _displayPosition;
      _setActiveLine(_activeIndexAt(position), position: position);
      _scheduleNextLine(position);
    });
  }

  void _endFirstScroll() {
    if (!mounted || !_awaitingFirstScroll) return;
    setState(() => _awaitingFirstScroll = false);
  }

  Duration get _displayPosition =>
      widget.seekPreview.value ??
      ref.read(playbackStateProvider).value?.position ??
      Duration.zero;

  void _scheduleUserScrollReturn() {
    _userScrollIdleTimer?.cancel();
    if (!_visible) return;
    _userScrollIdleTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || !_visible) return;
      _userScrolling = false;
      unawaited(_maybeAutoScroll(_active));
    });
  }

  void _previewChanged() {
    if (!mounted || !_visible) return;
    final position = _displayPosition;
    final wasUserScrolling = _userScrolling;
    _userScrolling = false;
    _userScrollIdleTimer?.cancel();
    final active = _activeIndexAt(position);
    if (active == _active && (wasUserScrolling || active < 0)) {
      unawaited(_maybeAutoScroll(active));
    }
    _setActiveLine(active, position: position);
    _scheduleNextLine(position);
  }

  int _activeIndexAt(Duration position) {
    // Scrubbing is an explicit preview, even at zero or while audio buffers.
    if (widget.seekPreview.value != null) {
      return LyricsParser.activeIndex(_lines, position);
    }
    if (context.isMornye) {
      // Read one transport snapshot: playing/loading derived providers can
      // notify separately during the same playback event.
      final playback = ref.read(playbackStateProvider).value;
      if (playback?.processingState == AudioProcessingState.loading ||
          playback?.processingState == AudioProcessingState.buffering) {
        return -1;
      }
      _hasStarted =
          _hasStarted || playback?.playing == true || position > Duration.zero;
      if (!_hasStarted) return -1;
    }
    return LyricsParser.activeIndex(_lines, position);
  }

  /// The scroll anchor for [active]. When the next line starts while the
  /// previous one is still being sung, the view holds on the earlier line
  /// until its timed end, so both stay fully visible instead of the unfinished
  /// one scrolling away. Only the directly preceding lead line can hold.
  int _focusFor(int active, Set<int> activeLines, Duration position) {
    if (active < 0) return -1;
    final focus = _displayLayout.focusForLine[active];
    final start = _lines[focus].time;
    for (var i = focus - 1; i >= 0; i--) {
      final line = _lines[i];
      if (line.isBackground || line.time >= start) continue;
      if (line.text.isEmpty) return focus;
      final end = line.end;
      final held = _displayLayout.focusForLine[i];
      return activeLines.contains(i) && end != null && end > position
          ? held
          : focus;
    }
    return focus;
  }

  void _setActiveLine(int active, {required Duration position}) {
    if (!mounted) return;
    final activeLines = _timeline.activeIndices(position, active);
    final indexChanged = active != _active;
    final previousFocus = _focus;
    if (!indexChanged &&
        activeLines.length == _activeLines.length &&
        activeLines.containsAll(_activeLines)) {
      return;
    }
    final focus = _focusFor(active, activeLines, position);
    setState(() {
      _active = active;
      _activeLines = activeLines;
      _focus = focus;
      _activeTransitionPosition = position;
      _updateRowVisibility(sameFocus: focus >= 0 && focus == previousFocus);
    });
    if (focus == previousFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _visible && active == _active) {
        unawaited(_maybeAutoScroll(active));
      }
    });
  }

  void _scheduleNextLine(Duration position) {
    _lineBoundaryTimer?.cancel();
    if (!_visible ||
        !_playing ||
        _loading ||
        widget.seekPreview.value != null) {
      return;
    }

    final lines = _lines;
    final dueIndex = syncedLyricsDueLineIndex(
      lineStarts: _timeline.starts,
      currentIndex: _active,
      position: position,
    );
    _setActiveLine(dueIndex, position: position);

    final nextIndex = dueIndex + 1;
    Duration? nextBoundary = nextIndex < lines.length
        ? lines[nextIndex].time
        : null;
    for (final index in _activeLines) {
      final end = lines[index].end;
      if ((index != dueIndex ||
              lines[index].voice != null ||
              lines[index].isBackground) &&
          end != null &&
          end > position &&
          (nextBoundary == null || end < nextBoundary)) {
        nextBoundary = end;
      }
    }
    if (nextBoundary == null) return;
    final boundary = nextBoundary;
    final remaining = boundary - position;
    final speed = ref.read(playbackStateProvider).value?.speed ?? 1.0;
    final delay = speed.isFinite && speed > 0
        ? Duration(microseconds: (remaining.inMicroseconds / speed).ceil())
        : remaining;
    _lineBoundaryTimer = Timer(delay, () {
      if (!mounted || !_visible || !_playing || _loading) return;
      // A delayed callback must catch up to the audio clock, rather than
      // treating its scheduled boundary as the current playback position.
      _scheduleNextLine(_displayPosition);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.seekPreview.removeListener(_previewChanged);
    _positionSubscription?.close();
    _playingSubscription?.close();
    _loadingSubscription?.close();
    _lineBoundaryTimer?.cancel();
    _userScrollIdleTimer?.cancel();
    _measurementTimer?.cancel();
    _measurementPainter?.dispose();
    _scroll.dispose();
    _rowReveal.dispose();
    _scrollMotion.dispose();
    super.dispose();
  }

  void _measureMornyeLines(BuildContext context, double width) {
    final style = _primaryLyricStyle(context);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    final key = (width, style, scaler, direction, locale);
    if (_lineLayoutKey == key) {
      _measureVisibleRows();
      _scheduleLineMeasurements();
      return;
    }
    _lineLayoutKey = key;
    _measurementTimer?.cancel();
    _measurementTimer = null;
    _measurementPainter?.dispose();
    final painter = _measurementPainter = TextPainter(
      textDirection: direction,
      textScaler: scaler,
      locale: locale,
    );
    _lineMeasurements = List.filled(_lines.length, (
      _estimatedLyricExtent,
      0.0,
      0.0,
    ));
    _pronunciationLayouts = List.filled(_lines.length, null);
    _unmeasuredRows
      ..clear()
      ..addAll(Iterable.generate(_lines.length));
    _changedMeasurementRows.clear();
    _measurementRevision++;
    _measureRow = (row) {
      if (!_unmeasuredRows.remove(row)) return;
      _changedMeasurementRows.add(row);
      final index = _displayLayout.lineOrder[row];
      final line = _lines[index];
      if (line.text.isEmpty) {
        _lineMeasurements[row] = (56, 0, 0);
        _measurementRevision++;
        return;
      }
      painter.text = TextSpan(
        text: line.text,
        style: _primaryLyricStyle(context, background: line.isBackground),
      );
      painter.layout(maxWidth: width);
      final padding = _linePadding(index).vertical;
      var height = painter.height + padding;
      var pronunciationHeight = 0.0;
      var translationHeight = 0.0;
      LyricPronunciationLayout? pronunciationLayout;
      for (final (text, style, _, translation) in _lyricSupplements(
        context,
        line,
      )) {
        painter.text = TextSpan(text: text, style: style);
        painter.layout(maxWidth: width);
        if (translation) {
          translationHeight = 6 + painter.height;
        } else {
          pronunciationHeight = 6 + painter.height;
          final aligned = LyricPronunciationLayout.measure(
            line: line,
            primaryStyle: _primaryLyricStyle(
              context,
              background: line.isBackground,
            ),
            pronunciationStyle: style,
            maxWidth: width,
            textScaler: scaler,
            textDirection: direction,
            locale: locale,
          );
          if (aligned != null) {
            pronunciationLayout = aligned;
            height = aligned.primaryHeight + padding;
            pronunciationHeight = aligned.pronunciationHeight;
          }
        }
      }
      _lineMeasurements[row] = (height, pronunciationHeight, translationHeight);
      _pronunciationLayouts[index] = pronunciationLayout;
      _measurementRevision++;
    };
    if (_lines.length <= 128) {
      while (_unmeasuredRows.isNotEmpty) {
        _measureRow!(_unmeasuredRows.first);
      }
    } else {
      _measureVisibleRows();
    }
    _scheduleLineMeasurements();
  }

  void _measureVisibleRows() {
    final measure = _measureRow;
    if (measure == null || _unmeasuredRows.isEmpty) return;
    final extents = _lineExtents;
    final anchor = _scroll.hasClients && extents != null
        ? _rowAtScrollOffset(extents, _scroll.offset)
        : _focus < 0
        ? 0
        : _displayLayout.rowForLine[_focus];
    // Exact geometry for the viewport and a small overscan. The rest is
    // prepared in bounded idle batches, including hidden supplements.
    final first = (anchor - 4).clamp(0, _lines.length);
    final last = (anchor + 28).clamp(0, _lines.length);
    for (var row = first; row < last; row++) {
      measure(row);
    }
  }

  void _scheduleLineMeasurements() {
    if (!_visible || _measurementTimer != null || _unmeasuredRows.isEmpty) {
      return;
    }
    _measurementTimer = Timer(const Duration(milliseconds: 16), () {
      _measurementTimer = null;
      if (!mounted || !_visible || _unmeasuredRows.isEmpty) return;
      if ((_scroll.hasClients && _scroll.position.isScrollingNotifier.value) ||
          _rowReveal.isAnimating ||
          _scrollMotion.isAnimating) {
        _scheduleLineMeasurements();
        return;
      }
      final budget = Stopwatch()..start();
      var measured = 0;
      while (_unmeasuredRows.isNotEmpty &&
          measured < 32 &&
          (measured == 0 || budget.elapsedMicroseconds < 2000)) {
        _measureRow!(_unmeasuredRows.first);
        measured++;
      }
      setState(() {});
      _scheduleLineMeasurements();
    });
  }

  void _scheduleVisibleMeasurements(double offset) {
    final extents = _lineExtents;
    if (_unmeasuredRows.isEmpty ||
        extents == null ||
        _measurementFramePending ||
        !_visible) {
      return;
    }
    final first = _rowAtScrollOffset(extents, offset);
    final last = (first + 28).clamp(0, _lines.length);
    if (!Iterable.generate(
      last - first,
      (index) => first + index,
    ).any(_unmeasuredRows.contains)) {
      return;
    }
    _measurementFramePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementFramePending = false;
      if (mounted && _visible) setState(() {});
    });
  }

  int _rowAtScrollOffset(_LyricExtentSnapshot extents, double offset) =>
      extents.rowAtOffset((offset - _focusInset).clamp(0.0, double.infinity));

  /// Jumps a viewport at a time toward the line at [index] until the list
  /// builds it. Rows taller than the estimate, such as lines with
  /// pronunciation or translation, leave an estimated jump short of a far
  /// line, which would otherwise stay off screen. Returns whether it is
  /// built.
  Future<bool> _scrollUntilBuilt(int index) async {
    final target = _displayLayout.rowForLine[index];
    for (var step = 0; step < 32; step++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || _userScrolling || !_scroll.hasClients) return false;
      if (_lineKeys[index].currentContext != null) return true;
      int? first;
      int? last;
      for (var line = 0; line < _lineKeys.length; line++) {
        if (_lineKeys[line].currentContext == null) continue;
        final row = _displayLayout.rowForLine[line];
        if (first == null || row < first) first = row;
        if (last == null || row > last) last = row;
      }
      if (first == null || last == null) return false;
      final position = _scroll.position;
      final next =
          (position.pixels +
                  (target > last
                      ? position.viewportDimension
                      : -position.viewportDimension))
              .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (next == position.pixels) return false;
      _scroll.jumpTo(next);
    }
    return false;
  }

  Future<void> _maybeAutoScroll(int index, {bool immediate = false}) async {
    // A short intro may have no countdown row. Still return to the first
    // upcoming lyric when the user scrubs back before any vocals.
    if (index < 0 && widget.seekPreview.value != null) index = 0;
    if (!_visible ||
        _userScrolling ||
        index < 0 ||
        index >= _lines.length ||
        !_scroll.hasClients) {
      return;
    }
    index = index == _active && _focus >= 0
        ? _focus
        : _displayLayout.focusForLine[index];
    final row = _displayLayout.rowForLine[index];
    final seeking = widget.seekPreview.value != null;
    final duration = immediate || MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : seeking
        ? const Duration(milliseconds: 220)
        : LyricScrollMotion.scrollDuration;
    // Scrubbing follows the finger quickly; playback eases between lines.
    final curve = seeking ? Curves.easeOutCubic : LyricScrollMotion.scrollCurve;
    if (duration == Duration.zero) _stopScrollMotion();
    final extents = _targetLineExtents;
    if (context.isMornye && extents != null && row < extents.length) {
      final position = _scroll.position;
      final target = extents.offsetForRow(row);
      final offset = target.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (duration == Duration.zero) {
        _scroll.jumpTo(offset);
      } else {
        _startScrollMotion(row, offset - position.pixels);
        await _scroll.animateTo(offset, duration: duration, curve: curve);
      }
      return;
    }
    if (index < _lineKeys.length) {
      final lineContext = _lineKeys[index].currentContext;
      if (lineContext != null) {
        final object = lineContext.findRenderObject();
        final viewport = object == null
            ? null
            : RenderAbstractViewport.maybeOf(object);
        if (duration != Duration.zero && viewport != null) {
          _startScrollMotion(
            row,
            viewport.getOffsetToReveal(object!, 0.5).offset - _scroll.offset,
          );
        }
        await Scrollable.ensureVisible(
          lineContext,
          alignment: 0.5,
          alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
          duration: duration,
          curve: curve,
        );
        return;
      }
    }

    final position = _scroll.position;
    final target = syncedLyricsEstimatedOffset(
      index: row,
      estimatedLineExtent: _estimatedLyricExtent,
    );
    final clamped = target.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (duration == Duration.zero) {
      _scroll.jumpTo(clamped.toDouble());
    } else {
      _startScrollMotion(row, clamped - position.pixels);
      await _scroll.animateTo(
        clamped.toDouble(),
        duration: duration,
        curve: curve,
      );
    }
    if (!mounted ||
        _userScrolling ||
        (_active >= 0 && index != _focus) ||
        index >= _lineKeys.length ||
        !await _scrollUntilBuilt(index)) {
      return;
    }
    final lineContext = _lineKeys[index].currentContext;
    if (lineContext != null && lineContext.mounted) {
      await Scrollable.ensureVisible(
        lineContext,
        alignment: 0.5,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        duration: duration == Duration.zero
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) => LyricsTextScale(
    child: TweenAnimationBuilder<Offset>(
      tween: Tween(
        end: Offset(
          widget.showPronunciation ? 1 : 0,
          widget.showTranslation ? 1 : 0,
        ),
      ),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 420),
      curve: Curves.easeInOutCubic,
      builder: (context, visibility, _) => _buildLyrics(context, visibility),
    ),
  );

  Widget _buildLyrics(BuildContext context, Offset visibility) {
    final lines = _lines;
    final active = _active;
    final rowVisibility = _rowVisibility;
    final loading = _visible
        ? ref.watch(playbackLoadingProvider)
        : ref.read(playbackLoadingProvider);
    final mornye = context.isMornye;
    final highContrast = MediaQuery.highContrastOf(context);
    final blurLyrics =
        mornye &&
        !highContrast &&
        // Defocused lines are filtered on every frame while their focus eases.
        ref.watch(mornyeLiquidGlassProvider);
    // Line emphasis eases over most of the scroll, so the new line brightens
    // as it arrives instead of switching ahead of the movement.
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 420);

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth != 0 ||
            notification.metrics.axis != Axis.vertical) {
          return false;
        }
        if (notification is ScrollUpdateNotification) {
          _scheduleVisibleMeasurements(notification.metrics.pixels);
        }
        final dragging =
            (notification is ScrollStartNotification &&
                notification.dragDetails != null) ||
            (notification is ScrollUpdateNotification &&
                notification.dragDetails != null) ||
            (notification is UserScrollNotification &&
                notification.direction != ScrollDirection.idle);
        if (dragging) {
          _stopScrollMotion();
          _userScrolling = true;
          _userScrollIdleTimer?.cancel();
        } else if (notification is ScrollEndNotification && _userScrolling) {
          // Start the return-to-playback timeout only after the drag and its
          // momentum finish. A direction notification is not an idle event:
          // a long drag can keep that direction while controls fade in/out.
          _scheduleUserScrollReturn();
        }
        return false;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final inset = mornye ? mornyeLyricsContentInset : 24.0;
          final contentWidth = (constraints.maxWidth - inset * 2).clamp(
            0.0,
            double.infinity,
          );
          // Lay out at the existing lyric width, then fit the whole line to
          // the timeline. Scaling text, phrase gaps and supplements together
          // preserves wrapping instead of pushing extra words onto a new row.
          final layoutWidth = (constraints.maxWidth - 48).clamp(
            0.0,
            double.infinity,
          );
          final lyricScale = mornye && layoutWidth > 0
              ? contentWidth / layoutWidth
              : 1.0;
          if (mornye) {
            final previousExtents = _lineExtents;
            final previousScrollAnchor =
                previousExtents != null && _scroll.hasClients
                ? _rowAtScrollOffset(previousExtents, _scroll.offset)
                : 0;
            final focusAnchor = _focus < 0
                ? 0
                : _displayLayout.rowForLine[_focus];
            final previousScrollOffset =
                previousExtents?.offsetForRow(previousScrollAnchor) ?? 0;
            final previousFocusOffset =
                previousExtents?.offsetForRow(focusAnchor) ?? 0;
            _measureMornyeLines(context, layoutWidth);
            // Reuse text measurements; only interpolate row heights as the
            // supplements fade. Scrolling follows the same animation clock.
            final geometryKey = (
              _lineMeasurements,
              lyricScale,
              _revealFrom,
              _revealTo,
            );
            if (_extentGeometryKey != geometryKey) {
              _extentGeometryKey = geometryKey;
              _extentGeometry = _LyricExtentGeometry(
                _lineMeasurements,
                _displayLayout.lineOrder,
                _revealFrom,
                _revealTo,
                (index) => _lines[index].text.isEmpty ? 1.0 : lyricScale,
                (index) => _linePadding(index).vertical,
              );
            } else {
              for (final row in _changedMeasurementRows) {
                _extentGeometry!.updateRow(row, _lineMeasurements[row]);
              }
            }
            _changedMeasurementRows.clear();
            _lineExtents = _LyricExtentSnapshot(
              _extentGeometry!,
              visibility,
              Curves.easeInOutCubic.transform(_rowReveal.value),
            );
            _targetLineExtents = _LyricExtentSnapshot(
              _extentGeometry!,
              visibility,
              1,
            );
            if (previousExtents != null &&
                ((_layoutMeasurementRevision != _measurementRevision) ||
                    (_layoutVisibility != null &&
                        _layoutVisibility != visibility) ||
                    (_preserveRevealAnchor &&
                        previousExtents.progress != _lineExtents!.progress)) &&
                previousExtents.length == _lineExtents!.length &&
                _scroll.hasClients) {
              final preserveScroll =
                  _userScrolling ||
                  _layoutMeasurementRevision != _measurementRevision;
              final anchor = preserveScroll
                  ? previousScrollAnchor
                  : focusAnchor;
              final correction =
                  _lineExtents!.offsetForRow(anchor) -
                  (preserveScroll ? previousScrollOffset : previousFocusOffset);
              // Correct before the ListView lays out/paints. A post-frame
              // jump leaves every painted frame one animation step behind.
              if (correction != 0) _scroll.position.correctBy(correction);
            }
          }
          _layoutVisibility = visibility;
          _layoutMeasurementRevision = _measurementRevision;
          if (_viewportHeight != constraints.maxHeight) {
            _viewportHeight = constraints.maxHeight;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                unawaited(_maybeAutoScroll(_active, immediate: true));
              }
            });
          }
          final topPadding = mornye
              ? _focusInset
              : syncedLyricsCenterPadding(
                  viewportDimension: constraints.maxHeight,
                  estimatedLineExtent: _estimatedLyricExtent,
                );
          // Leave enough trailing space for the final line to reach the same
          // upper focus position as every other line.
          final bottomPadding = mornye && _lineExtents!.isNotEmpty
              ? (constraints.maxHeight - _lineExtents!.last - topPadding).clamp(
                  topPadding,
                  double.infinity,
                )
              : topPadding;
          final list = ListView.builder(
            controller: _scroll,
            itemExtentBuilder: mornye
                ? (index, _) => index < lines.length
                      ? _lineExtents![index]
                      : widget.credits!.heightFor(context, contentWidth)
                : null,
            padding: EdgeInsets.fromLTRB(
              inset,
              topPadding,
              inset,
              bottomPadding,
            ),
            itemCount: lines.length + (widget.credits == null ? 0 : 1),
            itemBuilder: (context, row) {
              if (row == lines.length) return widget.credits!;
              final index = _displayLayout.lineOrder[row];
              final line = lines[index];
              final leadIndex = _displayLayout.leadForLine[index];
              final textAlign = _lyricTextAlign(context, lines[leadIndex]);
              final reveal = rowVisibility[index];
              if (reveal == 0) return SizedBox.shrink(key: _lineKeys[index]);
              final isActive = _activeLines.contains(index);
              final isPast = index < active;

              final color = mornye
                  ? Colors.white
                  : isActive
                  ? widget.colorScheme.onSurface
                  : isPast
                  ? widget.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
                  : widget.colorScheme.onSurfaceVariant.withValues(alpha: 0.8);

              if (line.text.isEmpty) {
                return _revealRow(
                  index,
                  reveal,
                  textAlign,
                  Padding(
                    padding: EdgeInsets.symmetric(
                      vertical: context.tokens.lyricsLinePaddingV,
                    ),
                    child: SizedBox(
                      height: 24,
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child:
                            isActive &&
                                _visible &&
                                (!loading || widget.seekPreview.value != null)
                            ? ValueListenableBuilder<Duration?>(
                                valueListenable: widget.seekPreview,
                                builder: (context, preview, _) =>
                                    LyricGapIndicator(
                                      key: ValueKey(line.time),
                                      start: line.time,
                                      end: line.end!,
                                      color: color,
                                      position: preview,
                                    ),
                              )
                            : null,
                      ),
                    ),
                  ),
                );
              }

              final timed =
                  isActive &&
                  (line.hasWordTiming || line.romanizationWords.isNotEmpty);
              Widget content;
              if (timed) {
                content = _WordHighlightedLyricLine(
                  line: line,
                  colorScheme: widget.colorScheme,
                  animate: _visible && widget.animateWords,
                  initialPosition: _activeTransitionPosition,
                  seekPreview: widget.seekPreview,
                  supplementVisibility: visibility,
                  pronunciationLayout: mornye
                      ? _pronunciationLayouts[index]
                      : null,
                  textAlign: textAlign,
                );
              } else {
                content = Text(
                  line.text,
                  textAlign: textAlign,
                  style: _primaryLyricStyle(
                    context,
                    background: line.isBackground,
                  ).copyWith(color: color),
                );
                content = _withLyricSupplements(
                  context,
                  line,
                  content,
                  color,
                  visibility: visibility,
                  pronunciationLayout: mornye
                      ? _pronunciationLayouts[index]
                      : null,
                  textAlign: textAlign,
                );
              }
              content = AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                reverseDuration: const Duration(milliseconds: 260),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: mornye
                    ? LyricBlur.fadeTransition
                    : AnimatedSwitcher.defaultTransitionBuilder,
                child: KeyedSubtree(
                  key: ValueKey(timed),
                  child: SizedBox(width: double.infinity, child: content),
                ),
              );
              if (mornye) {
                final activeLead = active < 0 ? -1 : _focus;
                final distance = activeLead < 0
                    ? row + 1
                    : (_displayLayout.rowForLine[leadIndex] -
                              _displayLayout.rowForLine[activeLead])
                          .abs();
                // Nearby lines need visible defocus at the larger lyric size;
                // progressively soften lines further from the current one.
                final sigma = !blurLyrics || isActive || leadIndex == activeLead
                    ? 0.0
                    : active < 0
                    ? 4.8
                    : distance == 1
                    ? 2.4
                    : distance == 2
                    ? 3.6
                    : 4.8;
                content = TweenAnimationBuilder<double>(
                  tween: Tween(end: sigma),
                  duration: motion,
                  curve: Curves.easeInOutCubic,
                  child: content,
                  builder: (context, value, child) => LyricBlur(
                    sigma: value,
                    settled: value == sigma,
                    child: child!,
                  ),
                );
                content = FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.topStart,
                  child: SizedBox(width: layoutWidth, child: content),
                );
              }

              content = LyricScrollMotion(
                progress: _scrollMotion,
                distance: _scrollMotionDistance,
                rowsAfterFocus: row - _scrollMotionFocus,
                enabled: !isActive,
                child: content,
              );
              return _revealRow(
                index,
                reveal,
                textAlign,
                Padding(
                  padding: _linePadding(index),
                  child: GestureDetector(
                    onTap: () =>
                        ref.read(musicPlayerControllerProvider).seek(line.time),
                    onLongPress: widget.onLongPressLine == null
                        ? null
                        : () {
                            HapticFeedback.mediumImpact();
                            widget.onLongPressLine!(line);
                          },
                    child: AnimatedScale(
                      // Focus changes paint scale, never font metrics or
                      // wrapping shared by the plain and word-timed line.
                      scale: isActive ? 1.0 : 0.96,
                      alignment:
                          (textAlign == TextAlign.end
                                  ? AlignmentDirectional.centerEnd
                                  : AlignmentDirectional.centerStart)
                              .resolve(Directionality.of(context)),
                      duration: motion,
                      curve: Curves.easeOutCubic,
                      child: AnimatedOpacity(
                        opacity: mornye
                            ? (isActive || highContrast ? 1 : 0.48)
                            : (isActive ? 1.0 : (isPast ? 0.55 : 0.85)),
                        duration: motion,
                        curve: Curves.easeInOutCubic,
                        child: content,
                      ),
                    ),
                  ),
                ),
              );
            },
          );
          // Laid out but not painted while it finds the playing line.
          return Opacity(opacity: _awaitingFirstScroll ? 0 : 1, child: list);
        },
      ),
    );
  }

  Widget _revealRow(
    int index,
    double visibility,
    TextAlign align,
    Widget child,
  ) {
    final AlignmentGeometry alignment = align == TextAlign.end
        ? AlignmentDirectional.topEnd
        : align == TextAlign.center
        ? Alignment.topCenter
        : AlignmentDirectional.topStart;
    // A fixed-extent row is already shrinking. Measure its contents at full
    // height so fitting does not scale it twice.
    final fullHeight = OverflowBox(
      minHeight: 0,
      maxHeight: double.infinity,
      fit: OverflowBoxFit.deferToChild,
      alignment: Alignment.topCenter,
      child: child,
    );
    return KeyedSubtree(
      key: _lineKeys[index],
      child: !_lines[index].isBackground && _lines[index].text.isNotEmpty
          ? child
          : IgnorePointer(
              ignoring: visibility < 1,
              child: _lines[index].isBackground
                  ? LyricBackingTransition(
                      visibility: visibility,
                      alignment: alignment,
                      child: fullHeight,
                    )
                  : LyricSupplementTransition(
                      visibility: visibility,
                      alignment: alignment,
                      child: fullHeight,
                    ),
            ),
    );
  }

  EdgeInsets _linePadding(int index) {
    final row = _displayLayout.rowForLine[index];
    final order = _displayLayout.lineOrder;
    final hasBackingBelow =
        row + 1 < order.length &&
        _lines[order[row + 1]].isBackground &&
        _displayLayout.leadForLine[order[row + 1]] ==
            _displayLayout.leadForLine[index];
    return EdgeInsets.only(
      top: _lines[index].isBackground ? 6 : context.tokens.lyricsLinePaddingV,
      bottom: hasBackingBelow ? 0 : context.tokens.lyricsLinePaddingV,
    );
  }
}

class _LyricRowVisibility extends ListBase<double> {
  _LyricRowVisibility(this.from, this.to, this.progress);

  final List<double> from;
  final List<double> to;
  final double progress;

  @override
  int get length => from.length;

  @override
  set length(int value) => throw UnsupportedError('Immutable lyric visibility');

  @override
  double operator [](int index) =>
      from[index] + (to[index] - from[index]) * progress;

  @override
  void operator []=(int index, double value) =>
      throw UnsupportedError('Immutable lyric visibility');
}

/// Prefix coefficients separate text geometry from the three animation values.
/// Row reads are constant time; a Fenwick tree updates measured rows and finds
/// anchor offsets without copying the entire document on each frame/batch.
class _LyricExtentGeometry {
  _LyricExtentGeometry(
    List<(double, double, double)> measurements,
    this.order,
    this.revealFrom,
    this.revealTo,
    this.scaleForLine,
    this.paddingForLine,
  ) : starts = List.filled(measurements.length, (0, 0, 0)),
      changes = List.filled(measurements.length, (0, 0, 0)),
      prefixStarts = List.filled(measurements.length + 1, (0, 0, 0)),
      prefixChanges = List.filled(measurements.length + 1, (0, 0, 0)) {
    for (var row = 0; row < measurements.length; row++) {
      updateRow(row, measurements[row], updatePrefix: false);
      prefixStarts[row + 1] = starts[row];
      prefixChanges[row + 1] = changes[row];
    }
    for (var node = 1; node < prefixStarts.length; node++) {
      final parent = node + (node & -node);
      if (parent >= prefixStarts.length) continue;
      for (final tree in [prefixStarts, prefixChanges]) {
        final value = tree[node];
        final previous = tree[parent];
        tree[parent] = (
          previous.$1 + value.$1,
          previous.$2 + value.$2,
          previous.$3 + value.$3,
        );
      }
    }
  }

  final List<int> order;
  final List<double> revealFrom;
  final List<double> revealTo;
  final double Function(int) scaleForLine;
  final double Function(int) paddingForLine;
  final List<(double, double, double)> starts;
  final List<(double, double, double)> changes;
  final List<(double, double, double)> prefixStarts;
  final List<(double, double, double)> prefixChanges;

  void updateRow(
    int row,
    (double, double, double) measurement, {
    bool updatePrefix = true,
  }) {
    final index = order[row];
    final (primary, pronunciation, translation) = measurement;
    final scale = scaleForLine(index);
    final padding = paddingForLine(index);
    final base = padding + (primary - padding) * scale;
    final from = revealFrom[index];
    final delta = revealTo[index] - from;
    final start = (
      base * from,
      pronunciation * scale * from,
      translation * scale * from,
    );
    final change = (
      base * delta,
      pronunciation * scale * delta,
      translation * scale * delta,
    );
    if (updatePrefix) {
      _updatePrefix(prefixStarts, row, starts[row], start);
      _updatePrefix(prefixChanges, row, changes[row], change);
    }
    starts[row] = start;
    changes[row] = change;
  }

  void _updatePrefix(
    List<(double, double, double)> tree,
    int row,
    (double, double, double) previous,
    (double, double, double) next,
  ) {
    for (var node = row + 1; node < tree.length; node += node & -node) {
      final value = tree[node];
      tree[node] = (
        value.$1 + next.$1 - previous.$1,
        value.$2 + next.$2 - previous.$2,
        value.$3 + next.$3 - previous.$3,
      );
    }
  }

  (double, double, double) prefix(
    List<(double, double, double)> tree,
    int row,
  ) {
    var result = (0.0, 0.0, 0.0);
    for (var node = row; node > 0; node -= node & -node) {
      final value = tree[node];
      result = (
        result.$1 + value.$1,
        result.$2 + value.$2,
        result.$3 + value.$3,
      );
    }
    return result;
  }
}

class _LyricExtentSnapshot extends ListBase<double> {
  _LyricExtentSnapshot(this.geometry, this.visibility, this.progress);

  final _LyricExtentGeometry geometry;
  final Offset visibility;
  final double progress;

  double _value(
    (double, double, double) from,
    (double, double, double) change,
  ) =>
      from.$1 +
      change.$1 * progress +
      (from.$2 + change.$2 * progress) * visibility.dx +
      (from.$3 + change.$3 * progress) * visibility.dy;

  double offsetForRow(int row) => _value(
    geometry.prefix(geometry.prefixStarts, row),
    geometry.prefix(geometry.prefixChanges, row),
  );

  int rowAtOffset(double offset) {
    var low = 0;
    var high = length;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (offsetForRow(middle) <= offset) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return low;
  }

  @override
  int get length => geometry.starts.length;

  @override
  set length(int value) => throw UnsupportedError('Immutable lyric extents');

  @override
  double operator [](int index) =>
      _value(geometry.starts[index], geometry.changes[index]);

  @override
  void operator []=(int index, double value) =>
      throw UnsupportedError('Immutable lyric extents');
}

class LyricsCredits extends StatelessWidget {
  const LyricsCredits({super.key, this.writers, this.provider});

  final String? writers;
  final String? provider;

  String _text(BuildContext context) => [
    if (writers != null) context.l10n.nowPlayingWrittenBy(writers!),
    if (provider != null) context.l10n.nowPlayingLyricsProvider(provider!),
  ].join('\n');

  TextStyle _style(BuildContext context) =>
      Theme.of(context).textTheme.bodyMedium!.copyWith(
        fontSize: context.isMornye ? 17 : 14,
        fontWeight: FontWeight.w600,
        height: 1.4,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.48),
      );

  double heightFor(BuildContext context, double width) {
    final painter = TextPainter(
      text: TextSpan(text: _text(context), style: _style(context)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: width.clamp(0, double.infinity));
    final height = painter.height + 32;
    painter.dispose();
    return height;
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Text(_text(context), style: _style(context)),
  );
}
