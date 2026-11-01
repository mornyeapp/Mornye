import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

/// Updates time labels at media-second boundaries between engine reports.
class PlaybackTimeBuilder extends StatefulWidget {
  const PlaybackTimeBuilder({
    super.key,
    required this.position,
    required this.duration,
    required this.playback,
    required this.builder,
    this.preview,
  });

  final Duration position;
  final Duration duration;
  final PlaybackState? playback;
  final Duration? preview;
  final Widget Function(BuildContext context, int seconds) builder;

  @override
  State<PlaybackTimeBuilder> createState() => _PlaybackTimeBuilderState();
}

class _PlaybackTimeBuilderState extends State<PlaybackTimeBuilder>
    with WidgetsBindingObserver {
  Timer? _timer;
  int _seconds = 0;
  bool _visible = false;
  bool _foreground = true;

  bool _playing(PlaybackState? state) =>
      state != null &&
      state.playing &&
      state.processingState == AudioProcessingState.ready;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground = _isForeground(WidgetsBinding.instance.lifecycleState);
  }

  bool _isForeground(AppLifecycleState? state) =>
      state != AppLifecycleState.paused &&
      state != AppLifecycleState.hidden &&
      state != AppLifecycleState.detached;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didUpdateWidget(PlaybackTimeBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync(previous: oldWidget);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = _isForeground(state);
    setState(_sync);
  }

  void _sync({PlaybackTimeBuilder? previous}) {
    _timer?.cancel();
    _timer = null;
    final playback = widget.playback;
    var position = widget.preview ?? playback?.position ?? widget.position;
    if (position < Duration.zero) position = Duration.zero;
    if (widget.duration > Duration.zero && position > widget.duration) {
      position = widget.duration;
    }
    final seconds = position.inSeconds;
    // A late sample near a second boundary must not roll the clock back.
    // Scrubbing, paused updates and larger position changes remain immediate.
    final smallCorrection =
        previous != null &&
        widget.preview == null &&
        previous.preview == null &&
        _playing(playback) &&
        _playing(previous.playback) &&
        playback!.speed == previous.playback!.speed &&
        (playback.position - previous.playback!.position).abs() <
            const Duration(milliseconds: 500);
    if (!smallCorrection || seconds >= _seconds) _seconds = seconds;

    if (!_visible ||
        !_foreground ||
        widget.preview != null ||
        !_playing(playback) ||
        !playback!.speed.isFinite ||
        playback.speed <= 0 ||
        (widget.duration > Duration.zero && position >= widget.duration)) {
      return;
    }
    final remaining =
        Duration.microsecondsPerSecond -
        position.inMicroseconds % Duration.microsecondsPerSecond;
    final delay = Duration(microseconds: (remaining / playback.speed).ceil());
    _timer = Timer(
      delay < const Duration(milliseconds: 1)
          ? const Duration(milliseconds: 1)
          : delay,
      () => setState(_sync),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _seconds);
}
