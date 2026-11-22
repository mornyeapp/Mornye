import 'package:flutter/widgets.dart';

/// Tells whether [child] is on the screen as the page around it scrolls, for
/// decoration that should stand still while nobody can see it.
///
/// A box in a page that is not built lazily stays alive when it is scrolled
/// away, and an animation on it would go on asking for frames.
class OnScreenListener extends StatefulWidget {
  const OnScreenListener({
    super.key,
    required this.onChanged,
    required this.child,
  });

  /// Called when [child] leaves the screen and when it is back. It counts as
  /// on screen until the first call.
  final ValueChanged<bool> onChanged;
  final Widget child;

  @override
  State<OnScreenListener> createState() => _OnScreenListenerState();
}

class _OnScreenListenerState extends State<OnScreenListener> {
  ScrollPosition? _page;
  Size _view = Size.zero;
  bool _onScreen = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view = MediaQuery.sizeOf(context);
    final page = Scrollable.maybeOf(context)?.position;
    if (!identical(page, _page)) {
      _page?.removeListener(_check);
      _page = page?..addListener(_check);
    }
    // A page may come back already scrolled past the child.
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  void _check() {
    if (!mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final onScreen = rect.overlaps(Offset.zero & _view);
    if (onScreen == _onScreen) return;
    _onScreen = onScreen;
    widget.onChanged(onScreen);
  }

  @override
  void dispose() {
    _page?.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
