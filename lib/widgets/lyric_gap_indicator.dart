import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/utils/synced_lyrics_scroll.dart';
import 'package:mornye/widgets/decorative_phase.dart';

/// Playback controls the fill; a gentle pulse accompanies instrumental gaps.
class LyricGapIndicator extends ConsumerStatefulWidget {
  const LyricGapIndicator({
    super.key,
    required this.start,
    required this.end,
    required this.color,
    this.position,
  });

  final Duration start;
  final Duration end;
  final Color color;
  final Duration? position;

  @override
  ConsumerState<LyricGapIndicator> createState() => _LyricGapIndicatorState();
}

class _LyricGapIndicatorState extends ConsumerState<LyricGapIndicator>
    with WidgetsBindingObserver {
  final _pulse = DecorativePhase(const Duration(milliseconds: 3600));

  bool get _appVisible => switch (WidgetsBinding.instance.lifecycleState) {
    null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
    _ => false,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_appVisible) {
      _pulse.stop();
    } else if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = TickerMode.valuesOf(context).enabled && _appVisible;
    final Duration position =
        widget.position ??
        (visible
            ? ref.watch(playbackPositionProvider)
            : ref.read(playbackPositionProvider));
    final progress = syncedLyricSegmentProgress(
      position: position,
      start: widget.start,
      end: widget.end,
    );
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final playing = visible
        ? ref.watch(playbackPlayingProvider)
        : ref.read(playbackPlayingProvider);
    final loading = visible
        ? ref.watch(playbackLoadingProvider)
        : ref.read(playbackLoadingProvider);
    final animate =
        playing &&
        !loading &&
        !reduceMotion &&
        widget.position == null &&
        position >= widget.start &&
        position < widget.end;
    // A hidden indicator holds its pulse, as a muted ticker did.
    if (animate && visible) {
      _pulse.start();
    } else {
      _pulse.stop();
    }
    final dotDuration = animate
        ? const Duration(milliseconds: 120)
        : Duration.zero;
    final dots = List<Widget>.generate(
      3,
      (index) => AnimatedContainer(
        key: ValueKey('lyric-gap-dot-$index'),
        duration: dotDuration,
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Color.lerp(
            widget.color.withValues(alpha: 0.25),
            widget.color,
            (progress * 3 - index).clamp(0.0, 1.0),
          ),
        ),
      ),
      growable: false,
    );
    return RepaintBoundary(
      child: Semantics(
        label: context.l10n.nowPlayingInstrumental,
        value: '${(progress * 100).round()}%',
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, _) {
            // All three dots breathe together; only their fill advances
            // independently with the playback position.
            final breath = math.sin(math.pi * _pulse.value);
            final scale = reduceMotion || widget.position != null
                ? 1.0
                : 1 + 0.24 * breath * breath;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Transform.scale(scale: scale, child: dots[0]),
                const SizedBox(width: 8),
                Transform.scale(scale: scale, child: dots[1]),
                const SizedBox(width: 8),
                Transform.scale(scale: scale, child: dots[2]),
              ],
            );
          },
        ),
      ),
    );
  }
}
