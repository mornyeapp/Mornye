import 'package:material_ui/material_ui.dart';

/// Hides the desktop scrollbars below it, for panes that read as chrome
/// (settings, side panels, the sidebar) rather than long lists. Scrolling
/// and its physics are unchanged.
class NoScrollbars extends StatelessWidget {
  const NoScrollbars({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ScrollConfiguration(
    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
    child: child,
  );
}
