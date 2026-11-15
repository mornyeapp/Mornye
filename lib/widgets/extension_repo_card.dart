import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/mornye_chrome.dart';

/// Repo cards share the Mornye glass material, including their detail pages.
class ExtensionRepoCard extends ConsumerWidget {
  const ExtensionRepoCard({
    super.key,
    required this.child,
    this.color,
    this.radius = 20,
    this.margin = const EdgeInsets.all(4),
  });

  final Widget child;
  final Color? color;
  final double radius;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!context.isMornye) {
      return AppContentCard(
        elevation: 0,
        color: color,
        margin: margin,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        child: child,
      );
    }
    return Padding(
      padding: margin,
      // Repo pages scroll these cards over the plain page background, where a
      // backdrop blur is invisible but re-filters the whole card every frame.
      child: MornyeGlass.navigation(
        radius: 24,
        blurEnabled: ref.watch(mornyeBlurEnabledProvider),
        samplesBackdrop: false,
        child: Material(color: Colors.transparent, child: child),
      ),
    );
  }
}
