import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// The press feedback of a large desktop Material row: table rows, rail
/// items and the player bar summary show a press as a 10% state layer of
/// [content] instead of a ripple spreading across a wide surface, like the
/// wide search cells. Buttons keep their own press.
///
/// Elsewhere (phones, tablets, Mornye) both fields are null, so the
/// [InkWell] keeps the theme's ink.
({InteractiveInkFeatureFactory? splashFactory, Color? highlightColor})
desktopRowInk(BuildContext context, {Color? content}) {
  if (!isDesktopPlatform || context.isMornye) {
    return (splashFactory: null, highlightColor: null);
  }
  final layer = content ?? Theme.of(context).colorScheme.onSurface;
  return (
    splashFactory: NoSplash.splashFactory,
    highlightColor: layer.withValues(alpha: 0.1),
  );
}
