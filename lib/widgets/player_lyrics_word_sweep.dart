part of 'player_lyrics.dart';

/// A compact timed line using the full player's word sweep and playback clock.
/// Supplements stay in the full lyrics view.
class WordTimedLyricLine extends StatelessWidget {
  const WordTimedLyricLine({
    super.key,
    required this.line,
    required this.initialPosition,
    required this.seekPreview,
    required this.style,
    this.maxLines,
  });

  final LyricLine line;
  final Duration initialPosition;
  final ValueListenable<Duration?> seekPreview;
  final TextStyle style;
  final int? maxLines;

  /// The line reads and sweeps in its own direction.
  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: strongTextDirection(line.text) ?? Directionality.of(context),
    child: _WordHighlightedLyricLine(
      line: line,
      colorScheme: Theme.of(context).colorScheme,
      animate: true,
      initialPosition: initialPosition,
      seekPreview: seekPreview,
      supplementVisibility: Offset.zero,
      pronunciationLayout: null,
      textAlign: TextAlign.start,
      textStyle: style,
      maxLines: maxLines,
    ),
  );
}

class _WordHighlightedLyricLine extends ConsumerStatefulWidget {
  final LyricLine line;
  final ColorScheme colorScheme;
  final bool animate;
  final Duration initialPosition;
  final ValueListenable<Duration?> seekPreview;
  final Offset supplementVisibility;
  final LyricPronunciationLayout? pronunciationLayout;
  final TextAlign textAlign;
  final TextStyle? textStyle;
  final int? maxLines;

  const _WordHighlightedLyricLine({
    required this.line,
    required this.colorScheme,
    required this.animate,
    required this.initialPosition,
    required this.seekPreview,
    required this.supplementVisibility,
    required this.pronunciationLayout,
    required this.textAlign,
    this.textStyle,
    this.maxLines,
  });

  @override
  ConsumerState<_WordHighlightedLyricLine> createState() =>
      _WordHighlightedLyricLineState();
}

class _WordHighlightedLyricLineState
    extends ConsumerState<_WordHighlightedLyricLine>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _animationClock;
  final Stopwatch _elapsedClock = Stopwatch();
  ProviderSubscription<Duration>? _positionSubscription;
  ProviderSubscription<bool>? _playingSubscription;
  ProviderSubscription<bool>? _loadingSubscription;
  ProviderSubscription<double>? _speedSubscription;

  late Duration _anchorPosition;
  Duration _anchorElapsed = Duration.zero;
  bool _playing = false;
  bool _loading = false;
  double _speed = 1;

  /// Runs the clock a little fast or slow toward the reported position;
  /// see [_follow].
  double _catchUp = 1;
  bool _tickerEnabled = true;
  bool _useInitialPosition = true;
  Duration _visualEnd = Duration.zero;
  Duration _displayLead = Duration.zero;

  // An inactive app is still on screen, as in [SyncedLyricsView]: the sweep
  // keeps pace with the lines behind another app's window.
  bool get _visible =>
      widget.animate &&
      _tickerEnabled &&
      switch (WidgetsBinding.instance.lifecycleState) {
        null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
        _ => false,
      };

  bool get _advancing =>
      _visible &&
      _playing &&
      !_loading &&
      _speed > 0 &&
      widget.seekPreview.value == null;

  bool get _shouldAnimate => _advancing && _currentPosition() < _visualEnd;

  Duration _positionAt({required bool advance}) {
    final elapsed = (_elapsedClock.elapsed - _anchorElapsed).inMicroseconds;
    // The catch-up pace has closed its gap after the window. Reports come
    // every half second; without one the clock keeps playback's pace.
    final paced = elapsed.clamp(0, syncedLyricsCatchUpWindow.inMicroseconds);
    return interpolatedSyncedLyricsPosition(
      anchorPosition: _anchorPosition,
      elapsedSinceAnchor: Duration(
        microseconds: ((elapsed + paced * (_catchUp - 1)) * _speed).round(),
      ),
      isPlaying: advance,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _elapsedClock.start();
    _anchorElapsed = _elapsedClock.elapsed;
    _anchorPosition = widget.initialPosition;
    _playing = ref.read(playbackPlayingProvider);
    _loading = ref.read(playbackLoadingProvider);
    _animationClock = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..addListener(_animationTick);
    widget.seekPreview.addListener(_previewChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _displayLead = lyricsDisplayLead(
      displayOf(View.maybeOf(context))?.refreshRate,
    );
    _updateVisualEnd();
    _syncSubscriptions();
  }

  void _syncSubscriptions() {
    if (!_visible) {
      _useInitialPosition = false;
      _positionSubscription?.close();
      _playingSubscription?.close();
      _loadingSubscription?.close();
      _speedSubscription?.close();
      _positionSubscription = null;
      _playingSubscription = null;
      _loadingSubscription = null;
      _speedSubscription = null;
      _animationClock.stop();
      return;
    }
    if (_positionSubscription != null) {
      _syncAnimationClock();
      return;
    }
    _playing = ref.read(playbackPlayingProvider);
    _loading = ref.read(playbackLoadingProvider);
    final speed = ref.read(playbackStateProvider).value?.speed ?? 1;
    _speed = speed.isFinite && speed > 0 ? speed : 0;
    if (!_useInitialPosition) {
      _anchorAt(widget.seekPreview.value ?? ref.read(playbackPositionProvider));
    }
    _useInitialPosition = false;
    _positionSubscription = ref.listenManual<Duration>(
      playbackPositionProvider,
      (previous, next) => _updateReportedPosition(next),
    );
    _playingSubscription = ref.listenManual<bool>(
      playbackPlayingProvider,
      (previous, next) => _updateTransportState(playing: next),
    );
    _loadingSubscription = ref.listenManual<bool>(
      playbackLoadingProvider,
      (previous, next) => _updateTransportState(loading: next),
    );
    _speedSubscription = ref.listenManual<double>(
      playbackStateProvider.select((state) => state.value?.speed ?? 1),
      (previous, next) => _updateTransportState(speed: next),
    );
    _syncAnimationClock();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _syncSubscriptions();
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _WordHighlightedLyricLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.seekPreview != widget.seekPreview) {
      oldWidget.seekPreview.removeListener(_previewChanged);
      widget.seekPreview.addListener(_previewChanged);
      _previewChanged();
    }
    if (oldWidget.line != widget.line) {
      _anchorAt(widget.initialPosition);
      _updateVisualEnd();
      _syncAnimationClock();
    } else if (oldWidget.initialPosition != widget.initialPosition &&
        widget.seekPreview.value == null) {
      // A parent rebuilding passes the position again, like a playback
      // report.
      _follow(widget.initialPosition);
      _syncAnimationClock();
    }
    if (oldWidget.animate != widget.animate) {
      _syncSubscriptions();
    }
  }

  /// The audio position, which anchors and playback reports are kept in.
  Duration _audioPosition() =>
      widget.seekPreview.value ?? _positionAt(advance: _advancing);

  /// The position the sweep is drawn for: while it advances, the audio
  /// position plus the time a frame takes to reach the screen.
  Duration _currentPosition() {
    final position = _audioPosition();
    return _advancing ? position + _displayLead * _speed : position;
  }

  void _previewChanged() {
    if (!mounted || !_visible) return;
    _anchorAt(widget.seekPreview.value ?? ref.read(playbackPositionProvider));
    _syncAnimationClock();
    setState(() {});
  }

  void _anchorAt(Duration position) {
    _anchorPosition = position;
    _anchorElapsed = _elapsedClock.elapsed;
    _catchUp = 1;
  }

  /// Brings the clock to [reported]: at once for a seek or while it stands
  /// still, else from where it is at a slightly different pace, so the
  /// sweep never steps back.
  void _follow(Duration reported) {
    final predicted = _audioPosition();
    final rate = _advancing
        ? syncedLyricsCatchUpRate(
            predictedPosition: predicted,
            reportedPosition: reported,
          )
        : null;
    _anchorAt(rate == null ? reported : predicted);
    if (rate != null) _catchUp = rate;
  }

  void _updateReportedPosition(Duration position) {
    if (!mounted || widget.seekPreview.value != null) return;
    final predicted = _currentPosition();
    _follow(position);
    _syncAnimationClock();
    // A held line stays visible through an instrumental/outro. Once every
    // envelope has settled, later position reports cannot change its pixels.
    if (!_animationClock.isAnimating &&
        (predicted < _visualEnd || _currentPosition() < _visualEnd)) {
      setState(() {});
    }
  }

  void _updateTransportState({bool? playing, bool? loading, double? speed}) {
    if (!mounted) return;
    final position = _audioPosition();
    if (playing != null) _playing = playing;
    if (loading != null) _loading = loading;
    if (speed != null) _speed = speed.isFinite && speed > 0 ? speed : 0;
    _anchorAt(
      widget.seekPreview.value ??
          (_advancing ? position : ref.read(playbackPositionProvider)),
    );
    _syncAnimationClock();
    setState(() {});
  }

  void _syncAnimationClock() {
    if (_shouldAnimate) {
      if (!_animationClock.isAnimating) {
        _animationClock.repeat();
      }
    } else {
      _animationClock.stop();
    }
  }

  void _animationTick() {
    if (_currentPosition() >= _visualEnd) _animationClock.stop();
  }

  void _updateVisualEnd() {
    final decorativeMotion =
        !MediaQuery.disableAnimationsOf(context) &&
        !ref.read(lowEndDeviceProvider);
    final glow = context.isMornye && ref.read(mornyeLiquidGlassProvider);
    var end = Duration.zero;
    for (final words in [
      widget.line.words,
      widget.line.romanizationWords,
      widget.line.translationWords,
    ]) {
      for (var index = 0; index < words.length; index++) {
        var wordEnd = _segmentEnd(words, index);
        if (decorativeMotion && identical(words, widget.line.words)) {
          // Glow fades for 500ms after a held word; short-word lift may finish
          // later than the color sweep (start + 540ms).
          if (glow) wordEnd += const Duration(milliseconds: 500);
          final liftEnd = words[index].time + const Duration(milliseconds: 540);
          if (liftEnd > wordEnd) wordEnd = liftEnd;
        }
        if (wordEnd > end) end = wordEnd;
      }
    }
    _visualEnd = end;
  }

  Duration _segmentEnd(List<LyricWord> words, int index) {
    final word = words[index];
    final start = word.time;
    if (word.end != null && word.end! >= start) return word.end!;
    if (index + 1 < words.length) {
      final next = words[index + 1].time;
      if (next > start) return next;
    }
    final lineEnd = widget.line.end;
    if (lineEnd != null && lineEnd > start) return lineEnd;
    return start + const Duration(milliseconds: 650);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.seekPreview.removeListener(_previewChanged);
    _positionSubscription?.close();
    _playingSubscription?.close();
    _loadingSubscription?.close();
    _speedSubscription?.close();
    _animationClock.dispose();
    _elapsedClock.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The line's own direction, which its row is laid out in.
    final lineDirection = Directionality.of(context);
    final style =
        widget.textStyle ??
        _primaryLyricStyle(context, background: widget.line.isBackground);
    final primary = widget.line.hasWordTiming
        ? _buildTimedText(widget.line.text, widget.line.words, style)
        : Text(
            widget.line.text,
            textAlign: widget.textAlign,
            style: style.copyWith(color: widget.colorScheme.onSurface),
            maxLines: widget.maxLines,
            overflow: widget.maxLines == null ? null : TextOverflow.ellipsis,
          );
    // Both scripts share this state's position interpolation and animation
    // clock, including pause, seek and track changes.
    return _withLyricSupplements(
      context,
      widget.line,
      primary,
      widget.colorScheme.onSurface,
      direction: lineDirection,
      timedText: _buildTimedText,
      timedSupplementText: (text, words, style) {
        final direction = strongTextDirection(text) ?? lineDirection;
        return _buildTimedText(
          text,
          words,
          style,
          lift: false,
          textDirection: direction,
          textAlign: _supplementTextAlign(
            widget.textAlign,
            lineDirection,
            direction,
          ),
        );
      },
      visibility: widget.supplementVisibility,
      pronunciationLayout: widget.pronunciationLayout,
      textAlign: widget.textAlign,
    );
  }

  Widget _buildTimedText(
    String text,
    List<LyricWord> words,
    TextStyle style, {
    bool lift = true,
    TextDirection? textDirection,
    TextAlign? textAlign,
  }) {
    final highlightedColor = widget.colorScheme.onSurface;
    final mornye = context.isMornye;
    final pendingColor = mornye
        ? Colors.white.withValues(alpha: 0.4)
        : widget.colorScheme.onSurfaceVariant.withValues(alpha: 0.6);
    return _SweepingTimedLyricText(
      segments: [for (final word in words) word.text],
      starts: [for (final word in words) word.time],
      ends: [
        for (var index = 0; index < words.length; index++)
          _segmentEnd(words, index),
      ],
      currentPosition: _currentPosition,
      repaint: _animationClock,
      style: style,
      textDirection: textDirection,
      textAlign: textAlign ?? widget.textAlign,
      pendingColor: pendingColor,
      highlightedColor: highlightedColor,
      semanticsLabel: text,
      // Sung words rise in both styles; the glow behind held words belongs
      // to Mornye's look. Each risen word paints the line again on every
      // frame and the glow filters it, so a low-end device skips the rise,
      // and the glow needs a device that draws filtered lyrics (like the
      // blur of the lines around the current one).
      liftEnabled:
          lift &&
          !MediaQuery.disableAnimationsOf(context) &&
          !ref.watch(lowEndDeviceProvider),
      glowEnabled: mornye && ref.watch(mornyeLiquidGlassProvider),
      maxLines: widget.maxLines,
    );
  }
}

class _SweepingTimedLyricText extends StatefulWidget {
  final List<String> segments;
  final List<Duration> starts;
  final List<Duration> ends;
  final Duration Function() currentPosition;
  final Listenable repaint;
  final TextStyle style;

  /// The text's direction when it differs from its row's: a translation
  /// under a line in another script.
  final TextDirection? textDirection;
  final TextAlign textAlign;
  final Color pendingColor;
  final Color highlightedColor;
  final String semanticsLabel;
  final bool liftEnabled;

  /// Glows behind held words while [liftEnabled].
  final bool glowEnabled;
  final int? maxLines;

  const _SweepingTimedLyricText({
    required this.segments,
    required this.starts,
    required this.ends,
    required this.currentPosition,
    required this.repaint,
    required this.style,
    this.textDirection,
    required this.textAlign,
    required this.pendingColor,
    required this.highlightedColor,
    required this.semanticsLabel,
    required this.liftEnabled,
    required this.glowEnabled,
    this.maxLines,
  });

  @override
  State<_SweepingTimedLyricText> createState() =>
      _SweepingTimedLyricTextState();
}

class _SweepingTimedLyricTextState extends State<_SweepingTimedLyricText> {
  TextPainter? _pendingPainter;
  TextPainter? _highlightedPainter;
  String? _cachedText;
  TextStyle? _cachedStyle;
  TextAlign? _cachedAlignment;
  TextDirection? _cachedDirection;
  TextScaler? _cachedScaler;
  Locale? _cachedLocale;
  Color? _cachedPendingColor;
  Color? _cachedHighlightedColor;
  int? _cachedMaxLines;
  List<String>? _cachedSegments;
  List<List<Rect>>? _cachedSegmentBoxes;
  List<List<TextDirection>>? _cachedSegmentDirections;
  double? _cachedMinWidth;
  double? _cachedMaxWidth;

  void _ensurePainters(
    String text,
    TextDirection textDirection,
    TextScaler textScaler,
    Locale? locale,
  ) {
    if (_cachedText == text &&
        _cachedStyle == widget.style &&
        _cachedAlignment == widget.textAlign &&
        _cachedDirection == textDirection &&
        _cachedScaler == textScaler &&
        _cachedLocale == locale &&
        _cachedMaxLines == widget.maxLines &&
        _cachedPendingColor == widget.pendingColor &&
        _cachedHighlightedColor == widget.highlightedColor) {
      return;
    }

    _pendingPainter?.dispose();
    _highlightedPainter?.dispose();
    _cachedSegmentBoxes = null;
    _cachedSegmentDirections = null;
    _pendingPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: widget.style.copyWith(color: widget.pendingColor),
      ),
      textAlign: widget.textAlign,
      textDirection: textDirection,
      textScaler: textScaler,
      locale: locale,
      maxLines: widget.maxLines,
      ellipsis: widget.maxLines == null ? null : '\u2026',
    );
    _highlightedPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: widget.style.copyWith(color: widget.highlightedColor),
      ),
      textAlign: widget.textAlign,
      textDirection: textDirection,
      textScaler: textScaler,
      locale: locale,
      maxLines: widget.maxLines,
      ellipsis: widget.maxLines == null ? null : '\u2026',
    );
    _cachedText = text;
    _cachedStyle = widget.style;
    _cachedAlignment = widget.textAlign;
    _cachedDirection = textDirection;
    _cachedScaler = textScaler;
    _cachedLocale = locale;
    _cachedMaxLines = widget.maxLines;
    _cachedPendingColor = widget.pendingColor;
    _cachedHighlightedColor = widget.highlightedColor;
  }

  (List<List<Rect>>, List<List<TextDirection>>) _segmentBoxes(
    double minWidth,
    double maxWidth,
  ) {
    if (_cachedSegmentBoxes != null &&
        _cachedSegmentDirections != null &&
        _cachedMinWidth == minWidth &&
        _cachedMaxWidth == maxWidth &&
        listEquals(_cachedSegments, widget.segments)) {
      return (_cachedSegmentBoxes!, _cachedSegmentDirections!);
    }

    final segmentBoxes = <List<Rect>>[];
    final segmentDirections = <List<TextDirection>>[];
    // Each run sweeps in the direction it is laid out in: a Latin word or a
    // number in an Arabic line reads left to right, an Arabic word in a
    // Latin line right to left. A word split into several runs on one row
    // (a font change) takes them in its own reading order, else in the
    // line's.
    final lineRightToLeft = _cachedDirection == TextDirection.rtl;
    var segmentOffset = 0;
    for (final segment in widget.segments) {
      final segmentEnd = segmentOffset + segment.length;
      // Select the whole timed word, keeping paragraph shaping and wrapping
      // intact. All of its text runs share the same vertical movement.
      final textBoxes = _highlightedPainter!
          .getBoxesForSelection(
            TextSelection(baseOffset: segmentOffset, extentOffset: segmentEnd),
            boxHeightStyle: BoxHeightStyle.max,
          )
          .toList();
      final direction = textBoxes.firstOrNull?.direction;
      final rightToLeft = textBoxes.every((box) => box.direction == direction)
          ? direction == TextDirection.rtl
          : lineRightToLeft;
      textBoxes.sort((a, b) {
        final row = a.top.compareTo(b.top);
        if (row != 0) return row;
        return rightToLeft
            ? b.left.compareTo(a.left)
            : a.left.compareTo(b.left);
      });
      segmentBoxes.add([for (final box in textBoxes) box.toRect()]);
      segmentDirections.add([for (final box in textBoxes) box.direction]);
      segmentOffset = segmentEnd;
    }
    // Snapshot contents: callers can rebuild equal lists or mutate boundaries
    // without changing the joined text. Timing is supplied separately below.
    _cachedSegments = List<String>.of(widget.segments);
    _cachedMinWidth = minWidth;
    _cachedMaxWidth = maxWidth;
    _cachedSegmentBoxes = segmentBoxes;
    _cachedSegmentDirections = segmentDirections;
    return (segmentBoxes, segmentDirections);
  }

  @override
  void dispose() {
    _pendingPainter?.dispose();
    _highlightedPainter?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textDirection = widget.textDirection ?? Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);
    final text = widget.segments.join();
    _ensurePainters(text, textDirection, textScaler, locale);

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : double.infinity;
        final minWidth = constraints.hasBoundedWidth ? maxWidth : 0.0;
        final pendingPainter = _pendingPainter!
          ..layout(minWidth: minWidth, maxWidth: maxWidth);
        final highlightedPainter = _highlightedPainter!
          ..layout(minWidth: minWidth, maxWidth: maxWidth);
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : pendingPainter.width;
        final height = pendingPainter.height;
        final (segmentBoxes, segmentDirections) = _segmentBoxes(
          minWidth,
          maxWidth,
        );

        return RepaintBoundary(
          child: Semantics(
            label: widget.semanticsLabel,
            child: CustomPaint(
              size: Size(width, height),
              painter: _TimedLyricSweepPainter(
                segmentBoxes: segmentBoxes,
                segmentDirections: segmentDirections,
                starts: widget.starts,
                ends: widget.ends,
                currentPosition: widget.currentPosition,
                repaint: widget.repaint,
                pendingPainter: pendingPainter,
                highlightedPainter: highlightedPainter,
                highlightLift: widget.liftEnabled
                    ? (textScaler.scale(widget.style.fontSize ?? 24) * 0.05)
                          .clamp(0.0, 2.0)
                    : 0,
                glowSigma: widget.liftEnabled && widget.glowEnabled
                    ? textScaler.scale(widget.style.fontSize ?? 24) * 0.2
                    : 0,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TimedLyricSweepPainter extends CustomPainter {
  final List<List<Rect>> segmentBoxes;
  final List<List<TextDirection>> segmentDirections;
  final List<Duration> starts;
  final List<Duration> ends;
  final Duration Function() currentPosition;
  final TextPainter pendingPainter;
  final TextPainter highlightedPainter;
  final double highlightLift;

  /// Blur radius of the glow behind held words; 0 disables it.
  final double glowSigma;
  late final ImageFilter? _glowFilter = glowSigma > 0
      ? ImageFilter.blur(sigmaX: glowSigma, sigmaY: glowSigma)
      : null;

  _TimedLyricSweepPainter({
    required this.segmentBoxes,
    required this.segmentDirections,
    required this.starts,
    required this.ends,
    required this.currentPosition,
    required Listenable repaint,
    required this.pendingPainter,
    required this.highlightedPainter,
    required this.highlightLift,
    required this.glowSigma,
  }) : super(repaint: repaint);

  static final Paint _layerPaint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final pendingPaths = <double, Path>{};
    final completedPaths = <double, Path>{};
    final partialBoxes = <(Rect, double, double, double, bool)>[];
    final glows = <(Path, double, double)>[];
    final position = currentPosition();
    var hasLift = false;
    for (var index = 0; index < segmentBoxes.length; index++) {
      final timed = index < starts.length && index < ends.length;
      final value = timed
          ? syncedLyricSegmentProgress(
              position: position,
              start: starts[index],
              end: ends[index],
            )
          : 0.0;
      final boxes = segmentBoxes[index];
      final directions = index < segmentDirections.length
          ? segmentDirections[index]
          : const <TextDirection>[];
      final width = boxes.fold<double>(0, (sum, box) => sum + box.width);
      final rawLift = highlightLift > 0 && timed
          ? highlightLift *
                syncedLyricSegmentLift(
                  position: position,
                  start: starts[index],
                  end: ends[index],
                )
          : 0.0;
      // Quantize lift to quarter-pixel buckets so words at matching heights
      // coalesce into a single TextPainter draw pass.
      final lift = rawLift == 0 ? 0.0 : (rawLift * 4).round() * 0.25;
      if (lift != 0) hasLift = true;
      final glow = glowSigma > 0 && timed && value > 0
          ? syncedLyricSegmentGlow(
              position: position,
              start: starts[index],
              end: ends[index],
            )
          : 0.0;
      final glowPath = glow > 0.01 ? Path() : null;
      var consumed = 0.0;
      for (var boxIndex = 0; boxIndex < boxes.length; boxIndex++) {
        final box = boxes[boxIndex];
        if (box.width <= 0) continue;
        final rtl =
            boxIndex < directions.length &&
            directions[boxIndex] == TextDirection.rtl;
        if (highlightLift > 0) {
          pendingPaths.putIfAbsent(lift, Path.new).addRect(box);
        }
        // Keep the color sweep continuous across wrapping and font fallback,
        // independently of the movement shared by the whole word.
        final revealWidth = width * value - consumed;
        // A wide, soft leading edge reads as a smooth flow, not a wipe.
        final feather = ((highlightLift > 0 ? width : box.width) * 0.3).clamp(
          4.0,
          16.0,
        );
        // Only the sung part glows, so unsung letters never light up early.
        if (glowPath != null && revealWidth > 0) {
          final clampedReveal = revealWidth.clamp(0.0, box.width);
          glowPath.addRect(
            rtl
                ? Rect.fromLTRB(
                    box.right - clampedReveal,
                    box.top,
                    box.right,
                    box.bottom,
                  )
                : Rect.fromLTRB(
                    box.left,
                    box.top,
                    box.left + clampedReveal,
                    box.bottom,
                  ),
          );
        }
        if (value > 0 && revealWidth >= box.width) {
          completedPaths.putIfAbsent(lift, Path.new).addRect(box);
        } else if (value > 0 && revealWidth > -feather) {
          partialBoxes.add((box, revealWidth / box.width, lift, feather, rtl));
        }
        consumed += box.width;
      }
      if (glowPath != null) glows.add((glowPath, lift, glow));
    }

    // Move both colors together, so a raised highlight never leaves a dim
    // duplicate behind. Most words share the resting or completed position.
    if (highlightLift > 0 && hasLift) {
      for (final entry in pendingPaths.entries) {
        _paintLiftedText(canvas, pendingPainter, entry.value, entry.key);
      }
    } else {
      pendingPainter.paint(canvas, Offset.zero);
    }

    // A blurred copy of the sung letters behind them. Usually at most one
    // held word glows, so the extra layer stays cheap.
    final glowFilter = _glowFilter;
    if (glowFilter != null) {
      for (final (clip, lift, glow) in glows) {
        final bounds = clip.getBounds().inflate(glowSigma * 3);
        canvas.save();
        canvas.translate(0, -lift);
        canvas.saveLayer(
          bounds,
          Paint()
            ..color = Color.fromRGBO(0, 0, 0, 0.55 * glow)
            ..imageFilter = glowFilter,
        );
        canvas.clipPath(clip, doAntiAlias: false);
        highlightedPainter.paint(canvas, Offset.zero);
        canvas.restore();
        canvas.restore();
      }
    }

    // Add each partial box's solid prefix into completedPaths so saveLayer
    // only allocates an offscreen buffer for the narrow feather strip.
    final featherStrips = <(Rect, Rect, double, bool)>[];
    for (final (box, value, lift, feather, rtl) in partialBoxes) {
      final boundary = rtl
          ? box.right - box.width * value
          : box.left + box.width * value;
      final solidRect = rtl
          ? Rect.fromLTRB(
              boundary.clamp(box.left, box.right),
              box.top,
              box.right,
              box.bottom,
            )
          : Rect.fromLTRB(
              box.left,
              box.top,
              boundary.clamp(box.left, box.right),
              box.bottom,
            );
      if (solidRect.width > 0) {
        completedPaths.putIfAbsent(lift, Path.new).addRect(solidRect);
      }
      final shaderRect = rtl
          ? Rect.fromLTRB(boundary - feather, box.top, boundary, box.bottom)
          : Rect.fromLTRB(boundary, box.top, boundary + feather, box.bottom);
      // Half a pixel over the solid prefix, so no column falls between them.
      final featherRect =
          (rtl
                  ? Rect.fromLTRB(
                      shaderRect.left,
                      box.top,
                      boundary + 0.5,
                      box.bottom,
                    )
                  : Rect.fromLTRB(
                      boundary - 0.5,
                      box.top,
                      shaderRect.right,
                      box.bottom,
                    ))
              .intersect(box);
      if (featherRect.width > 0 && featherRect.height > 0) {
        featherStrips.add((featherRect, shaderRect, lift, rtl));
      }
    }

    for (final entry in completedPaths.entries) {
      _paintLiftedText(canvas, highlightedPainter, entry.value, entry.key);
    }

    for (final (featherRect, shaderRect, lift, rtl) in featherStrips) {
      canvas.save();
      canvas.translate(0, -lift);
      canvas.clipRect(featherRect);
      canvas.saveLayer(featherRect, _layerPaint);
      highlightedPainter.paint(canvas, Offset.zero);
      final mask = Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = LinearGradient(
          colors: rtl
              ? const [Colors.transparent, Colors.white]
              : const [Colors.white, Colors.transparent],
        ).createShader(shaderRect);
      canvas.drawRect(featherRect, mask);
      canvas.restore();
      canvas.restore();
    }
  }

  void _paintLiftedText(
    Canvas canvas,
    TextPainter painter,
    Path clip,
    double lift,
  ) {
    canvas.save();
    canvas.translate(0, -lift);
    canvas.clipPath(clip, doAntiAlias: false);
    painter.paint(canvas, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TimedLyricSweepPainter oldDelegate) {
    return oldDelegate.segmentBoxes != segmentBoxes ||
        oldDelegate.segmentDirections != segmentDirections ||
        oldDelegate.starts != starts ||
        oldDelegate.ends != ends ||
        oldDelegate.currentPosition != currentPosition ||
        oldDelegate.highlightLift != highlightLift ||
        oldDelegate.glowSigma != glowSigma ||
        oldDelegate.pendingPainter != pendingPainter ||
        oldDelegate.highlightedPainter != highlightedPainter;
  }
}
