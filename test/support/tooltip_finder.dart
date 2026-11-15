import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Finds tooltips showing [message], as `find.byTooltip` does.
///
/// `find.byTooltip` only knows the Tooltip of Flutter's built-in Material
/// library, so it misses a `material_ui` tooltip that is left out of
/// semantics. This is the finder `material_ui` uses in its own tests until
/// flutter_test is ported (flutter/flutter issue 186966).
Finder findByTooltip(Pattern message, {bool skipOffstage = true}) {
  return find.byWidgetPredicate((widget) {
    if (widget is Tooltip) {
      final text = widget.message ?? widget.richMessage!.toPlainText();
      if ((widget.excludeFromSemantics ?? false) || text.isEmpty) {
        return message is RegExp ? message.hasMatch(text) : text == message;
      }
    }
    return widget is RawTooltip &&
        (message is RegExp
            ? message.hasMatch(widget.semanticsTooltip ?? '')
            : widget.semanticsTooltip == message);
  }, skipOffstage: skipOffstage);
}
