import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/app_bar_layout.dart';

/// The collapsing header used by every top-level tab and every settings-style
/// sub-page.
///
/// Expanded titles use [AppTokens.headerExpandedTitleSize].
class AppSliverHeader extends StatelessWidget {
  /// Root of a navigation tab: no back button, and the title stays aligned with
  /// the content margin at every collapse ratio.
  const AppSliverHeader.tabRoot({
    super.key,
    required this.title,
    this.actions,
    this.alignToContent = false,
  }) : leading = null,
       _showLeading = false;

  /// A pushed page: shows [leading] (a back button by default) and slides the
  /// title clear of it as the header collapses.
  const AppSliverHeader.page({
    super.key,
    required this.title,
    this.actions,
    this.leading,
    this.alignToContent = true,
  }) : _showLeading = true;

  final String title;
  final List<Widget>? actions;

  /// Overrides the default back button. Only used by the page variant.
  final Widget? leading;

  /// Lines the expanded title up with content centered by [wideListInset] on
  /// tablets. Full-bleed pages (carousels, grids) keep it at the screen edge.
  final bool alignToContent;

  final bool _showLeading;

  /// Left inset of the collapsed title when a leading button is present: enough
  /// to clear a 48dp icon button plus the 8dp toolbar margin.
  static const double _leadingClearance = 56;

  /// Content margin the expanded title aligns to.
  static const double _contentMargin = 24;

  static bool _isNestedNavigatorRoot(BuildContext context) {
    if (ModalRoute.of(context)?.canPop ?? true) return false;
    final navigator = Navigator.maybeOf(context);
    return navigator != null &&
        !identical(navigator, Navigator.maybeOf(context, rootNavigator: true));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final colorScheme = Theme.of(context).colorScheme;
    final topPadding = normalizedHeaderTopPadding(context);
    // A page at the root of a nested navigator, such as the desktop settings
    // detail pane, has nothing to go back to.
    final showLeading =
        _showLeading && (leading != null || !_isNestedNavigatorRoot(context));
    // Short landscape windows give the large title less headroom so content
    // starts higher. Portrait phones, even small ones, keep the full header.
    final screenSize = MediaQuery.sizeOf(context);
    final shortened =
        screenSize.height < screenSize.width && screenSize.height < 720
        ? tokens.headerExpandedHeight - 24
        : tokens.headerExpandedHeight;
    // A back button needs the full phone header: the shorter desktop and
    // landscape headers left the large title touching it.
    final expandedHeight = showLeading
        ? math.max(shortened, AppTokens.standard.headerExpandedHeight)
        : shortened;
    final maxHeight = expandedHeight + topPadding;
    final edgeInset = detailHeaderEdgeInset(context);

    return SliverAppBar(
      expandedHeight: maxHeight,
      collapsedHeight: kToolbarHeight,
      floating: false,
      pinned: true,
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      automaticallyImplyLeading: false,
      leadingWidth: showLeading ? kToolbarHeight + edgeInset : null,
      leading: showLeading
          ? Padding(
              padding: EdgeInsetsDirectional.only(start: edgeInset),
              child:
                  leading ??
                  (context.isMornye
                      ? AppIconButton(
                          tooltip: MaterialLocalizations.of(
                            context,
                          ).backButtonTooltip,
                          icon: const AppIcon(Icons.chevron_left),
                          onPressed: () => Navigator.pop(context),
                        )
                      // Expressive app bars hold navigation in a tonal circle.
                      : AppIconButton.filledTonal(
                          tooltip: MaterialLocalizations.of(
                            context,
                          ).backButtonTooltip,
                          icon: const AppIcon(Icons.arrow_back),
                          style: ButtonStyle(
                            backgroundColor: WidgetStatePropertyAll(
                              colorScheme.surfaceContainerHighest,
                            ),
                            foregroundColor: WidgetStatePropertyAll(
                              colorScheme.onSurface,
                            ),
                          ),
                          onPressed: () => Navigator.pop(context),
                        )),
            )
          : null,
      actionsPadding: EdgeInsetsDirectional.only(end: edgeInset),
      actions: actions,
      flexibleSpace: LayoutBuilder(
        builder: (context, constraints) {
          // SliverAppBar adds the platform's actual top safe-area inset to its
          // extents. Deriving the collapse ratio from our requested heights
          // left notched iPhones looking almost fully expanded even after the
          // toolbar had collapsed, so the large title occupied the back
          // button's space. Read the resolved sliver geometry instead.
          final settings = context
              .dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
          final minExtent = settings?.minExtent ?? kToolbarHeight;
          final maxExtent = settings?.maxExtent ?? maxHeight;
          final currentExtent =
              settings?.currentExtent ?? constraints.maxHeight;
          final extentDelta = maxExtent - minExtent;
          final expandRatio = extentDelta > 0
              ? ((currentExtent - minExtent) / extentDelta).clamp(0.0, 1.0)
              : 0.0;
          final contentMargin =
              _contentMargin + (alignToContent ? wideListInset(context) : 0);
          final leftPadding = showLeading
              ? (_leadingClearance + edgeInset) -
                    (((_leadingClearance + edgeInset) - contentMargin) *
                        expandRatio)
              : contentMargin;
          final fontSize =
              tokens.headerCollapsedTitleSize +
              (tokens.headerExpandedTitleSize -
                      tokens.headerCollapsedTitleSize) *
                  expandRatio;

          final bar = FlexibleSpaceBar(
            centerTitle: false,
            expandedTitleScale: 1.0,
            titlePadding: EdgeInsetsDirectional.only(
              start: leftPadding,
              end: tokens.gapLg,
              bottom: tokens.gapLg,
            ),
            title: Semantics(
              header: true,
              child: Text(
                title,
                // The title grows as the header expands; without a cap a long
                // localized title overflowed instead of ellipsizing.
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.bold,
                  letterSpacing: context.isMornye ? -0.7 * expandRatio : null,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
          );
          if (context.isMornye) return bar;
          // Collapsed expressive bars sit on a container tone, like a
          // scrolled-under app bar, and fade back to the surface on expand.
          return ColoredBox(
            color: Color.lerp(
              colorScheme.surfaceContainer,
              colorScheme.surface,
              expandRatio,
            )!,
            child: bar,
          );
        },
      ),
    );
  }
}
