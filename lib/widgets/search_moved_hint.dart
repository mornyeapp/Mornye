import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';

/// Points at the Search destination when someone taps where the Material
/// Home's search field used to be. It shows once per app run, so it never
/// nags; the next launch may show it again.
abstract final class SearchMovedHint {
  static bool _shown = false;
  static final ValueNotifier<int> _requests = ValueNotifier(0);

  /// Asks the Search destination to show the hint, unless it already has.
  static void request() {
    if (!_shown) _requests.value++;
  }

  @visibleForTesting
  static bool get debugShown => _shown;

  @visibleForTesting
  static void debugReset() => _shown = false;
}

/// Wraps the Search destination's icon and shows [SearchMovedHint] above it.
class SearchMovedHintAnchor extends StatefulWidget {
  const SearchMovedHintAnchor({super.key, required this.child});

  final Widget child;

  /// How long the hint stays when nothing dismisses it first.
  static const showFor = Duration(seconds: 5);

  @override
  State<SearchMovedHintAnchor> createState() => _SearchMovedHintAnchorState();
}

class _SearchMovedHintAnchorState extends State<SearchMovedHintAnchor> {
  final _tooltip = GlobalKey<TooltipState>();
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    SearchMovedHint._requests.addListener(_show);
  }

  @override
  void dispose() {
    SearchMovedHint._requests.removeListener(_show);
    _hide?.cancel();
    super.dispose();
  }

  void _show() {
    if (SearchMovedHint._shown || !mounted) return;
    // Only an anchor on screen counts the hint as shown.
    if (!TickerMode.valuesOf(context).enabled) return;
    if (_tooltip.currentState?.ensureTooltipVisible() != true) return;
    SearchMovedHint._shown = true;
    _hide?.cancel();
    _hide = Timer(SearchMovedHintAnchor.showFor, Tooltip.dismissAllToolTips);
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    key: _tooltip,
    message: context.l10n.searchMovedHint,
    triggerMode: TooltipTriggerMode.manual,
    preferBelow: false,
    // Clear of the bar's top edge, above the icon and its indicator.
    verticalOffset: 36,
    excludeFromSemantics: true,
    child: widget.child,
  );
}
