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

  @override
  Widget build(BuildContext context) => _WordHighlightedLyricLine(
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
  bool _tickerEnabled = true;
  bool _useInitialPosition = true;
  Duration _visualEnd = Duration.zero;

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
    return interpolatedSyncedLyricsPosition(
      anchorPosition: _anchorPosition,
      elapsedSinceAnchor: Duration(
        microseconds:
            ((_elapsedClock.elapsed - _anchorElapsed).inMicroseconds * _speed)
                .round(),
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
    if (oldWidget.line != widget.line ||
        oldWidget.initialPosition != widget.initialPosition) {
      _anchorAt(widget.initialPosition);
      _updateVisualEnd();
      _syncAnimationClock();
    }
    if (oldWidget.animate != widget.animate) {
      _syncSubscriptions();
    }
  }

  Duration _currentPosition() =>
      widget.seekPreview.value ?? _positionAt(advance: _advancing);

  void _previewChanged() {
    if (!mounted || !_visible) return;
    _anchorAt(widget.seekPreview.value ?? ref.read(playbackPositionProvider));
    _syncAnimationClock();
    setState(() {});
  }

  void _anchorAt(Duration position) {
    _anchorPosition = position;
    _anchorElapsed = _elapsedClock.elapsed;
  }

  void _updateReportedPosition(Duration position) {
    if (!mounted || widget.seekPreview.value != null) return;
    final predicted = _currentPosition();
    _anchorAt(
      _advancing
          ? reconcileSyncedLyricsPosition(
              predictedPosition: predicted,
              reportedPosition: position,
            )
          : position,
    );
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
    final position = _currentPosition();
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
    final decorativeMotion = !MediaQuery.disableAnimationsOf(context);
    final glow = context.isMornye;
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
      timedText: _buildTimedText,
      timedSupplementText: (text, words, style) =>
          _buildTimedText(text, words, style, lift: false),
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
      textAlign: widget.textAlign,
      pendingColor: pendingColor,
      highlightedColor: highlightedColor,
      semanticsLabel: text,
      // Sung words rise in both styles; the glow behind held words belongs
      // to Mornye's look.
      liftEnabled: lift && !MediaQuery.disableAnimationsOf(context),
      glowEnabled: mornye,
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

  List<List<Rect>> _segmentBoxes(double minWidth, double maxWidth) {
    if (_cachedSegmentBoxes != null &&
        _cachedMinWidth == minWidth &&
        _cachedMaxWidth == maxWidth &&
        listEquals(_cachedSegments, widget.segments)) {
      return _cachedSegmentBoxes!;
    }

    final segmentBoxes = <List<Rect>>[];
    var segmentOffset = 0;
    for (final segment in widget.segments) {
      final segmentEnd = segmentOffset + segment.length;
      // Select the whole timed word, keeping paragraph shaping and wrapping
      // intact. All of its text runs share the same vertical movement.
      final boxes = _highlightedPainter!
          .getBoxesForSelection(
            TextSelection(baseOffset: segmentOffset, extentOffset: segmentEnd),
            boxHeightStyle: BoxHeightStyle.max,
          )
          .map((box) => box.toRect())
          .toList();
      boxes.sort((a, b) {
        final row = a.top.compareTo(b.top);
        return row == 0 ? a.left.compareTo(b.left) : row;
      });
      segmentBoxes.add(boxes);
      segmentOffset = segmentEnd;
    }
    // Snapshot contents: callers can rebuild equal lists or mutate boundaries
    // without changing the joined text. Timing is supplied separately below.
    _cachedSegments = List<String>.of(widget.segments);
    _cachedMinWidth = minWidth;
    _cachedMaxWidth = maxWidth;
    return _cachedSegmentBoxes = segmentBoxes;
  }

  @override
  void dispose() {
    _pendingPainter?.dispose();
    _highlightedPainter?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textDirection = Directionality.of(context);
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
        final segmentBoxes = _segmentBoxes(minWidth, maxWidth);

        return Semantics(
          label: widget.semanticsLabel,
          child: CustomPaint(
            size: Size(width, height),
            painter: _TimedLyricSweepPainter(
              segmentBoxes: segmentBoxes,
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
        );
      },
    );
  }
}

class _TimedLyricSweepPainter extends CustomPainter {
  final List<List<Rect>> segmentBoxes;
  final List<Duration> starts;
  final List<Duration> ends;
  final Duration Function() currentPosition;
  final TextPainter pendingPainter;
  final TextPainter highlightedPainter;
  final double highlightLift;

  /// Blur radius of the glow behind held words; 0 disables it.
  final double glowSigma;

  _TimedLyricSweepPainter({
    required this.segmentBoxes,
    required this.starts,
    required this.ends,
    required this.currentPosition,
    required Listenable repaint,
    required this.pendingPainter,
    required this.highlightedPainter,
    required this.highlightLift,
    required this.glowSigma,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final pendingPaths = <double, Path>{};
    final completedPaths = <double, Path>{};
    final partialBoxes = <(Rect, double, double, double)>[];
    final glows = <(Path, double, double)>[];
    final position = currentPosition();
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
      final width = boxes.fold<double>(0, (sum, box) => sum + box.width);
      final lift = highlightLift > 0 && timed
          ? highlightLift *
                syncedLyricSegmentLift(
                  position: position,
                  start: starts[index],
                  end: ends[index],
                )
          : 0.0;
      final glow = glowSigma > 0 && timed && value > 0
          ? syncedLyricSegmentGlow(
              position: position,
              start: starts[index],
              end: ends[index],
            )
          : 0.0;
      final glowPath = glow > 0.01 ? Path() : null;
      var consumed = 0.0;
      for (final box in boxes) {
        if (box.width <= 0) continue;
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
          glowPath.addRect(
            Rect.fromLTRB(
              box.left,
              box.top,
              box.left + revealWidth.clamp(0.0, box.width),
              box.bottom,
            ),
          );
        }
        if (value > 0 && revealWidth >= box.width) {
          completedPaths.putIfAbsent(lift, Path.new).addRect(box);
        } else if (value > 0 && revealWidth > -feather) {
          partialBoxes.add((box, revealWidth / box.width, lift, feather));
        }
        consumed += box.width;
      }
      if (glowPath != null) glows.add((glowPath, lift, glow));
    }

    // Move both colors together, so a raised highlight never leaves a dim
    // duplicate behind. Most words share the resting or completed position.
    if (highlightLift > 0) {
      for (final entry in pendingPaths.entries) {
        _paintLiftedText(canvas, pendingPainter, entry.value, entry.key);
      }
    } else {
      pendingPainter.paint(canvas, Offset.zero);
    }

    // A blurred copy of the sung letters behind them. Usually at most one
    // held word glows, so the extra layer stays cheap.
    for (final (clip, lift, glow) in glows) {
      final bounds = clip.getBounds().inflate(glowSigma * 3);
      canvas.save();
      canvas.translate(0, -lift);
      canvas.saveLayer(
        bounds,
        Paint()
          ..color = Color.fromRGBO(0, 0, 0, 0.55 * glow)
          ..imageFilter = ImageFilter.blur(
            sigmaX: glowSigma,
            sigmaY: glowSigma,
          ),
      );
      canvas.clipPath(clip, doAntiAlias: false);
      highlightedPainter.paint(canvas, Offset.zero);
      canvas.restore();
      canvas.restore();
    }
    for (final entry in completedPaths.entries) {
      _paintLiftedText(canvas, highlightedPainter, entry.value, entry.key);
    }

    for (final (box, value, lift, feather) in partialBoxes) {
      // Feather the leading edge so the highlight flows through each letter
      // while the word rises as a single unit.
      final boundary = box.left + box.width * value;
      final revealRight = (boundary + feather).clamp(box.left, box.right);
      final revealRect = Rect.fromLTRB(
        box.left,
        box.top,
        revealRight,
        box.bottom,
      );
      canvas.save();
      canvas.translate(0, -lift);
      canvas.clipRect(revealRect);
      canvas.saveLayer(revealRect, Paint());
      highlightedPainter.paint(canvas, Offset.zero);
      final mask = Paint()
        ..blendMode = BlendMode.dstIn
        ..shader =
            LinearGradient(
              colors: const [Colors.white, Colors.transparent],
            ).createShader(
              Rect.fromLTRB(boundary, box.top, boundary + feather, box.bottom),
            );
      canvas.drawRect(revealRect, mask);
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
        oldDelegate.starts != starts ||
        oldDelegate.ends != ends ||
        oldDelegate.currentPosition != currentPosition ||
        oldDelegate.highlightLift != highlightLift ||
        oldDelegate.glowSigma != glowSigma ||
        oldDelegate.pendingPainter != pendingPainter ||
        oldDelegate.highlightedPainter != highlightedPainter;
  }
}
