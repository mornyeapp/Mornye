import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Shares pointer activity with lyrics options, including buttons outside the
/// lyric list in a landscape header. Listening does not claim lyric gestures.
class LyricsOptionsActivity extends StatefulWidget {
  const LyricsOptionsActivity({super.key, required this.child});

  final Widget child;

  static ValueListenable<(int, bool)>? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_LyricsOptionsActivityScope>()
      ?.activity;

  @override
  State<LyricsOptionsActivity> createState() => _LyricsOptionsActivityState();
}

class _LyricsOptionsActivityState extends State<LyricsOptionsActivity> {
  final _activity = ValueNotifier<(int, bool)>((0, false));
  final _pointers = <int>{};

  void _notify() =>
      _activity.value = (_activity.value.$1 + 1, _pointers.isNotEmpty);

  void _endPointer(int pointer) {
    _pointers.remove(pointer);
    _notify();
  }

  @override
  void dispose() {
    _activity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The full player supplies one region for its controls and lyrics pane.
    // A standalone desktop inspector supplies its own around the lyric list.
    if (LyricsOptionsActivity.maybeOf(context) != null) return widget.child;
    return _LyricsOptionsActivityScope(
      activity: _activity,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          _pointers.add(event.pointer);
          _notify();
        },
        onPointerUp: (event) => _endPointer(event.pointer),
        onPointerCancel: (event) => _endPointer(event.pointer),
        onPointerHover: (_) => _notify(),
        onPointerSignal: (_) => _notify(),
        child: widget.child,
      ),
    );
  }
}

class _LyricsOptionsActivityScope extends InheritedWidget {
  const _LyricsOptionsActivityScope({
    required this.activity,
    required super.child,
  });

  final ValueListenable<(int, bool)> activity;

  @override
  bool updateShouldNotify(_LyricsOptionsActivityScope oldWidget) =>
      activity != oldWidget.activity;
}
