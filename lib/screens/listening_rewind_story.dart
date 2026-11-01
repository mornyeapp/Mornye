part of 'listening_rewind_screen.dart';

enum _Slide {
  intro,
  minutes,
  yearNumbers,
  months,
  topArtist,
  artists,
  monthlyArtists,
  loyal,
  topTrack,
  tracks,
  album,
  firstSong,
  discoveries,
  rhythm,
  replay,
  outro,
}

/// A calendar-year Rewind adds its year-in-review slides between the regular
/// highlights.
List<_Slide> _slidesFor(ListeningRewind rewind) {
  final year = rewind.year;
  return [
    _Slide.intro,
    _Slide.minutes,
    if (year != null) _Slide.yearNumbers,
    if (year != null && rewind.monthlyMilliseconds.length >= 2) _Slide.months,
    if (rewind.topArtists.isNotEmpty) _Slide.topArtist,
    if (rewind.topArtists.length >= 3) _Slide.artists,
    if (year != null && year.monthlyTopArtists.length >= 2)
      _Slide.monthlyArtists,
    if (year != null && year.loyalArtist != null && year.loyalArtistDays > 1)
      _Slide.loyal,
    if (rewind.summary.tracks.isNotEmpty) _Slide.topTrack,
    if (rewind.summary.tracks.length >= 3) _Slide.tracks,
    if (rewind.topAlbums.isNotEmpty) _Slide.album,
    if (year?.firstPlay != null) _Slide.firstSong,
    if (rewind.newArtists.isNotEmpty) _Slide.discoveries,
    if (rewind.peakDay != null) _Slide.rhythm,
    if (rewind.replay != null) _Slide.replay,
    _Slide.outro,
  ];
}

/// Full-screen story of Rewind slides. Slides advance on their own unless the
/// system asks for reduced motion; tapping the left third goes back, the rest
/// goes forward, holding pauses, and swiping pages manually.
class _RewindStory extends StatefulWidget {
  const _RewindStory({required this.rewind, required this.period});

  final ListeningRewind rewind;
  final ListeningRewindPeriod period;

  @override
  State<_RewindStory> createState() => _RewindStoryState();
}

class _RewindStoryState extends State<_RewindStory>
    with WidgetsBindingObserver {
  static const _slideDuration = Duration(seconds: 6);

  late final List<_Slide> _slides = _slidesFor(widget.rewind);
  final _pages = PageController();
  final _progress = ValueNotifier(0.0);
  final _progressTicks = DecorativePhase(_slideDuration);
  late final _elapsed = WidgetsBinding.instance.samplingClock.stopwatch();
  Timer? _advanceTimer;
  final _captureKey = GlobalKey();
  var _index = 0;
  var _autoAdvance = false;
  var _tickersEnabled = true;
  var _sharing = false;
  var _capturing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _progressTicks.addListener(_updateProgress);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickersEnabled = TickerMode.valuesOf(context).enabled;
    final autoAdvance = !MediaQuery.disableAnimationsOf(context);
    if (autoAdvance != _autoAdvance) {
      _autoAdvance = autoAdvance;
      _restartProgress();
    } else {
      _syncProgress();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _syncProgress();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _advanceTimer?.cancel();
    _elapsed.stop();
    _progressTicks.dispose();
    _progress.dispose();
    _pages.dispose();
    super.dispose();
  }

  void _updateProgress() => _progress.value =
      (_elapsed.elapsed.inMicroseconds / _slideDuration.inMicroseconds).clamp(
        0.0,
        1.0,
      );

  void _restartProgress() {
    _pauseProgress();
    if (!_autoAdvance) return;
    _elapsed.reset();
    _progress.value = 0;
    if (_index < _slides.length - 1) {
      _resumeProgress();
    } else {
      _progress.value = 1;
    }
  }

  void _pauseProgress() {
    _elapsed.stop();
    _advanceTimer?.cancel();
    _progressTicks.stop();
  }

  void _resumeProgress() {
    if (!_autoAdvance || _index == _slides.length - 1) return;
    _elapsed.start();
    _syncProgress();
  }

  void _syncProgress() {
    _advanceTimer?.cancel();
    if (!_elapsed.isRunning ||
        !_tickersEnabled ||
        !WidgetsBinding.instance.framesEnabled) {
      _progressTicks.stop();
      return;
    }
    _updateProgress();
    _progressTicks.start();
    // Muted tickers catch up on return, but do not navigate while hidden.
    final remaining = _slideDuration - _elapsed.elapsed;
    _advanceTimer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      _pauseProgress();
      _progress.value = 1;
      _go(_index + 1);
    });
  }

  void _go(int index) {
    if (index < 0 || index >= _slides.length) return;
    final motion = AppMotion.spatialSlow(
      context,
      AppMotionSpec(
        MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 320),
        Curves.easeOutCubic,
      ),
    );
    if (motion.duration == Duration.zero) {
      _pages.jumpToPage(index);
    } else {
      _pages.animateToPage(
        index,
        duration: motion.duration,
        curve: motion.curve,
      );
    }
  }

  /// Shares the visible slide, without the story controls, as an image.
  Future<void> _share() async {
    if (_sharing) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    setState(() => _sharing = true);
    try {
      final file = await _capture(pixelRatio);
      if (file == null) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'image/png')],
          text: l10n.listeningRewindIntroTitle,
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.listeningRewindShareError)),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  /// Captures the slide with the backdrop blurred live for one frame, as its
  /// settled blur is drawn from a quarter-resolution image.
  Future<File?> _capture(double pixelRatio) async {
    setState(() => _capturing = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      return await captureBoundaryToPngFile(
        _captureKey,
        pixelRatio: pixelRatio,
        fileName: 'mornye_rewind.png',
      );
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palettes = [
      for (var i = 0; i < _slides.length; i++)
        _RewindPalette.of(context, i, widget.rewind),
    ];
    final palette = palettes[_index];
    final lastSlide = _index == _slides.length - 1;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value:
          ThemeData.estimateBrightnessForColor(palette.background) ==
              Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: Semantics(
        customSemanticsActions: {
          CustomSemanticsAction(label: l10n.listeningRewindNext): () =>
              _go(_index + 1),
          CustomSemanticsAction(label: l10n.listeningRewindPrevious): () =>
              _go(_index - 1),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            final width = context.size?.width ?? 0;
            _go(details.localPosition.dx < width / 3 ? _index - 1 : _index + 1);
          },
          onLongPressStart: (_) => _pauseProgress(),
          onLongPressEnd: (_) => _resumeProgress(),
          child: Stack(
            children: [
              RepaintBoundary(
                key: _captureKey,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _RewindBackdrop(
                        pages: _pages,
                        palettes: palettes,
                        artworks: [
                          for (final slide in _slides)
                            _slideArtwork(slide, widget.rewind),
                        ],
                        capturing: _capturing,
                      ),
                    ),
                    PageView.builder(
                      controller: _pages,
                      itemCount: _slides.length,
                      onPageChanged: (index) {
                        setState(() => _index = index);
                        _restartProgress();
                      },
                      itemBuilder: (context, index) => Semantics(
                        label: l10n.listeningRewindSlide(
                          index + 1,
                          _slides.length,
                        ),
                        child: _RewindSlide(
                          slide: _slides[index],
                          rewind: widget.rewind,
                          period: widget.period,
                          palette: palettes[index],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (lastSlide)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Center(
                        child: _Reveal(
                          order: 4,
                          child: AppActionButton(
                            onPressed: _sharing ? null : _share,
                            icon: const Icon(Icons.share),
                            label: Text(l10n.listeningRewindShare),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 4, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: AnimatedBuilder(
                          animation: _progress,
                          builder: (context, _) => _StoryProgress(
                            count: _slides.length,
                            index: _index,
                            value: _autoAdvance ? _progress.value : 1,
                            color: palette.foreground,
                          ),
                        ),
                      ),
                      _CloseButton(color: palette.foreground),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StoryProgress extends StatelessWidget {
  const _StoryProgress({
    required this.count,
    required this.index,
    required this.value,
    required this.color,
  });

  final int count;
  final int index;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Row(
      children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Expanded(
            child: Container(
              height: 4,
              decoration: ShapeDecoration(
                color: color.withValues(alpha: 0.28),
                shape: const StadiumBorder(),
              ),
              alignment: AlignmentDirectional.centerStart,
              child: FractionallySizedBox(
                heightFactor: 1,
                widthFactor: i < index
                    ? 1
                    : i == index
                    ? value.clamp(0.0, 1.0)
                    : 0,
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: color,
                    shape: const StadiumBorder(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}
