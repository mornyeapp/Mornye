import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassAccessibilityScope, LiquidGlassWidgets;
import 'package:mornye/controllers/mornye_glass_warmup.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';

/// Starts the one-time preparation when the full glass theme is enabled,
/// including switching to Mornye or enabling blur after the app has started.
class MornyeGlassPreparation extends ConsumerWidget {
  const MornyeGlassPreparation({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contrastBlocked = ref.watch(
      mornyeGlassContrastBlockedProvider(MediaQuery.highContrastOf(context)),
    );
    if (!MornyeGlassWarmup.isReady &&
        context.isMornye &&
        ref.watch(mornyeGlassLevelProvider) == MornyeGlassLevel.liquid &&
        MornyeTheme.glassClarityOf(context) > 0.2 &&
        !contrastBlocked) {
      unawaited(MornyeGlassWarmup.prepare(View.of(context)));
    }
    // The glass package follows the app's theme rather than the system's,
    // and the app's own rule for when contrast turns glass off.
    return LiquidGlassWidgets.wrap(
      brightnessResolver: Theme.maybeBrightnessOf,
      child: GlassAccessibilityScope(
        reduceTransparency: contrastBlocked,
        child: child,
      ),
    );
  }
}
