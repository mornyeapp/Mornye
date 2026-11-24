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

class _LyricGapIndicatorState extends ConsumerState<LyricGapIndicator> {
  final _pulse = DecorativePhase(const Duration(milliseconds: 3600));

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Duration position =
        widget.position ?? ref.watch(playbackPositionProvider);
    final progress = syncedLyricSegmentProgress(
      position: position,
      start: widget.start,
      end: widget.end,
    );
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final animate =
        ref.watch(playbackPlayingProvider) &&
        !ref.watch(playbackLoadingProvider) &&
        !reduceMotion &&
        widget.position == null &&
        position >= widget.start &&
        position < widget.end;
    // A hidden indicator holds its pulse, as a muted ticker did.
    if (animate && TickerMode.valuesOf(context).enabled) {
      _pulse.start();
    } else {
      _pulse.stop();
    }
    return Semantics(
      label: context.l10n.nowPlayingInstrumental,
      value: '${(progress * 100).round()}%',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < 3; index++) ...[
            if (index > 0) const SizedBox(width: 8),
            AnimatedBuilder(
              animation: _pulse,
              builder: (context, child) {
                // All three dots breathe together; only their fill advances
                // independently with the playback position.
                final breath = math.sin(math.pi * _pulse.value);
                return Transform.scale(
                  scale: reduceMotion || widget.position != null
                      ? 1
                      : 1 + 0.24 * breath * breath,
                  child: child,
                );
              },
              child: AnimatedContainer(
                key: ValueKey('lyric-gap-dot-$index'),
                duration: animate
                    ? const Duration(milliseconds: 120)
                    : Duration.zero,
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
            ),
          ],
        ],
      ),
    );
  }
}
