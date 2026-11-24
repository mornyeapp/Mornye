import 'dart:async';

import 'package:material_ui/material_ui.dart';

/// Reveals overflowing content without making the mini player's text draggable.
class OverflowMarquee extends StatefulWidget {
  const OverflowMarquee({
    super.key,
    required this.resetKey,
    required this.child,
    this.maxCycles,
    this.playing = true,
  });

  final Object resetKey;
  final Widget child;

  /// Stops at the start after this many passes; null scrolls indefinitely.
  /// A new [resetKey], width or lifecycle resume starts a fresh count.
  final int? maxCycles;

  /// False finishes the pass in flight and rests at the start until playback
  /// resumes, which waits the usual pause and keeps the pass count.
  final bool playing;

  @override
  State<OverflowMarquee> createState() => _OverflowMarqueeState();
}

class _OverflowMarqueeState extends State<OverflowMarquee>
    with WidgetsBindingObserver {
  static const _gap = 32.0;

  final _scroll = ScrollController();
  final _contentKey = GlobalKey();
  Timer? _pause;
  int _generation = 0;
  int _cycles = 0;
  bool _restartQueued = false;
  bool _motionEnabled = false;
  bool _appActive = true;
  bool _looping = false;
  bool _passInFlight = false;
  double _loopDistance = 0;
  double? _viewport;
  double? _extent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appActive = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motionEnabled =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _queueRestart();
  }

  @override
  void didUpdateWidget(OverflowMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.resetKey != oldWidget.resetKey ||
        widget.maxCycles != oldWidget.maxCycles) {
      _queueRestart();
    } else if (widget.playing != oldWidget.playing) {
      _pause?.cancel();
      if (_looping &&
          !_restartQueued &&
          !_passInFlight &&
          _canScroll(_generation)) {
        _scheduleCycle(_generation);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _queueRestart();
  }

  void _queueRestart() {
    _pause?.cancel();
    _generation++;
    _cycles = 0;
    _passInFlight = false;
    if (_restartQueued) return;
    _restartQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restartQueued = false;
      if (!mounted || !_scroll.hasClients) return;
      // Also cancels an in-flight animation after a track/width change.
      _scroll.jumpTo(0);
      final content = _contentKey.currentContext?.findRenderObject();
      if (content is! RenderBox || !content.hasSize) return;
      final overflowing =
          content.size.width > _scroll.position.viewportDimension + 0.5;
      _loopDistance = content.size.width + _gap;
      if (_looping != overflowing) {
        setState(() => _looping = overflowing);
        _queueRestart();
        return;
      }
      if (_motionEnabled && _appActive && _looping) {
        _scheduleCycle(_generation);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _canScroll(int generation) =>
      mounted &&
      generation == _generation &&
      _motionEnabled &&
      _appActive &&
      _scroll.hasClients;

  void _scheduleCycle(int generation) {
    final maxCycles = widget.maxCycles;
    if (!widget.playing || (maxCycles != null && _cycles >= maxCycles)) return;
    _pause = Timer(const Duration(seconds: 3), () => _scrollCycle(generation));
  }

  Future<void> _scrollCycle(int generation) async {
    if (!_canScroll(generation)) return;
    _passInFlight = true;
    await _scroll.animateTo(
      _loopDistance,
      duration: Duration(milliseconds: (_loopDistance / 28 * 1000).round()),
      curve: Curves.linear,
    );
    // A restart has already reset the offset and the flag.
    if (!_canScroll(generation)) return;
    _passInFlight = false;
    // The next copy is now exactly where the first started, so resetting
    // the offset changes neither the visible text nor its direction.
    _scroll.jumpTo(0);
    _cycles++;
    _scheduleCycle(generation);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pause?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_motionEnabled) return widget.child;

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        final metrics = notification.metrics;
        if (_viewport != metrics.viewportDimension ||
            _extent != metrics.maxScrollExtent) {
          _viewport = metrics.viewportDimension;
          _extent = metrics.maxScrollExtent;
          _queueRestart();
        }
        return false;
      },
      child: SingleChildScrollView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        // The viewport repaints as it scrolls; retain the unchanged content.
        child: RepaintBoundary(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              KeyedSubtree(key: _contentKey, child: widget.child),
              if (_looping) ...[
                const SizedBox(width: _gap),
                ExcludeSemantics(child: IgnorePointer(child: widget.child)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
