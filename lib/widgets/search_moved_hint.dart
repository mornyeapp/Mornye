import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Points at the Search destination for people who had the search field on
/// the Material Home. The settings migration notes that it is owed; it is
/// settled once the hint has stayed up long enough to be read.
abstract final class SearchMovedHint {
  static bool _shown = false;
  static final ValueNotifier<int> _requests = ValueNotifier(0);

  /// Asks the Search destination to show the hint while it is still owed,
  /// at most once per app run.
  static Future<void> showIfOwed() async {
    if (_shown) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(searchMovedHintOwedKey) ?? false) _requests.value++;
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

  /// How long the hint has to stay up to count as read.
  static const readAfter = Duration(seconds: 2);

  @override
  State<SearchMovedHintAnchor> createState() => _SearchMovedHintAnchorState();
}

class _SearchMovedHintAnchorState extends State<SearchMovedHintAnchor> {
  final _tooltip = GlobalKey<TooltipState>();
  Timer? _hide;
  Timer? _read;

  @override
  void initState() {
    super.initState();
    SearchMovedHint._requests.addListener(_show);
  }

  @override
  void dispose() {
    SearchMovedHint._requests.removeListener(_show);
    _hide?.cancel();
    _stopWaitingForRead();
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
    // Any touch dismisses a tooltip. One that comes this early leaves the
    // hint owed, so the next launch shows it again.
    _read = Timer(SearchMovedHintAnchor.readAfter, _settle);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) _stopWaitingForRead();
  }

  void _stopWaitingForRead() {
    if (_read == null) return;
    _read!.cancel();
    _read = null;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
  }

  Future<void> _settle() async {
    _stopWaitingForRead();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(searchMovedHintOwedKey);
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
