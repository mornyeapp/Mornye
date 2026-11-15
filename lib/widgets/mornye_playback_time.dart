import 'package:material_ui/material_ui.dart';
import 'package:mornye/utils/string_utils.dart';

/// Rolls only the changed digits, keeping the timeline labels steady in width.
class MornyePlaybackTime extends StatefulWidget {
  const MornyePlaybackTime({
    super.key,
    required this.seconds,
    required this.style,
    this.remaining = false,
  });

  final int seconds;
  final TextStyle? style;
  final bool remaining;

  @override
  State<MornyePlaybackTime> createState() => _MornyePlaybackTimeState();
}

class _MornyePlaybackTimeState extends State<MornyePlaybackTime> {
  bool _increasing = true;

  @override
  void didUpdateWidget(MornyePlaybackTime oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.seconds != oldWidget.seconds) {
      _increasing = widget.seconds > oldWidget.seconds;
    }
  }

  @override
  Widget build(BuildContext context) {
    final clock = formatClock(widget.seconds);
    final label = '${widget.remaining ? '-' : ''}$clock';
    final style = (widget.style ?? const TextStyle()).copyWith(
      fontFeatures: [
        ...?widget.style?.fontFeatures,
        const FontFeature.tabularFigures(),
      ],
    );
    if (MediaQuery.disableAnimationsOf(context)) {
      return Text(label, style: style);
    }

    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        textDirection: TextDirection.ltr,
        children: [
          if (widget.remaining) Text('-', style: style),
          for (var index = 0; index < clock.length; index++)
            ClipRect(
              // Anchor digit slots from the seconds end when minutes grow.
              key: ValueKey(clock.length - index),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  final entering = child.key == ValueKey(clock[index]);
                  final direction = _increasing ? 0.7 : -0.7;
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: Offset(0, entering ? direction : -direction),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  );
                },
                child: Text(
                  clock[index],
                  key: ValueKey(clock[index]),
                  style: style,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
