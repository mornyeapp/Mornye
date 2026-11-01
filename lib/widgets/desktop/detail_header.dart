import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/player_artwork_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/sliver_layout_info_builder.dart';

/// Space below a desktop detail page, so its last rows clear the floating
/// player.
const double desktopDetailBottomInset = 90;

const double _toolbarHeight = 52;

/// The header artwork side for a content column: about a third of it, from
/// 200 to 300.
double desktopDetailArtworkSize(double contentWidth) =>
    (contentWidth * 0.32).clamp(200.0, 300.0);

/// The artist line under a desktop detail title: large and in the accent
/// color, like the album pages of Apple Music.
///
/// Pass a [context] inside the header (a `Builder` around the subtitle), so
/// a Material header takes the accent of its artwork scheme.
TextStyle desktopDetailSubtitleStyle(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return context.isMornye
      ? TextStyle(
          color: scheme.primary,
          fontSize: 24,
          fontWeight: FontWeight.w400,
          height: 1.2,
        )
      : (Theme.of(context).textTheme.titleLarge ?? const TextStyle()).copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w500,
        );
}

/// The desktop header of album, playlist, folder and artist pages.
///
/// The artwork sits on the left edge of the list below, with the title,
/// [subtitle] and [meta] centered beside it and [actions] along its bottom
/// edge. The page background stays plain. Mornye floats a glass back button
/// and a capsule of [appBarActions] over the pane; Material keeps a toolbar
/// that shows the title once the header scrolls away. [moreMenu] adds a
/// "More" button that opens those groups as a menu.
///
/// In Material, the artwork and details take the scheme of [paletteSource]
/// (a cover URL or local path) through [PlayerArtworkTheme] and
/// [HeaderPalette]; the toolbar and the page below keep the app scheme.
List<Widget> desktopDetailHeaderSlivers(
  BuildContext context, {
  required String title,
  required Widget Function(BuildContext context, double size) artwork,
  String? paletteSource,
  bool circularArtwork = false,
  Widget? subtitle,
  Widget? meta,
  Widget? actions,
  List<Widget>? appBarActions,
  List<List<ContextMenuAction>> Function()? moreMenu,
  String? appBarTitle,
  Widget? leading,
  Color? backgroundColor,
}) {
  final theme = Theme.of(context);
  final mornye = context.isMornye;
  // Lines the artwork up with the description and track table below.
  final inset = wideListInset(context) + 20;
  final more = moreMenu == null ? null : _MoreButton(groups: moreMenu);
  final trailing = [...?appBarActions, ?more];

  Widget details(BuildContext context, BoxConstraints constraints) {
    final side = desktopDetailArtworkSize(constraints.maxWidth);
    const gap = 28.0;
    final textWidth = (constraints.maxWidth - side - gap).clamp(
      0.0,
      double.infinity,
    );
    final radius = circularArtwork ? side / 2 : (mornye ? 12.0 : 20.0);
    // Mornye draws Apple's continuous corner, as Music does on its covers.
    final continuous = mornye && !circularArtwork;
    final corners = BorderRadius.circular(radius);
    final shadows = [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.18),
        blurRadius: 18,
        offset: const Offset(0, 6),
      ),
    ];
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: mornye
              ? const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  height: 1.15,
                )
              // The text theme keeps the app's on-surface color, so the
              // title reads the header scheme directly.
              : Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
        ),
        if (subtitle != null) ...[const SizedBox(height: 2), subtitle],
        if (meta != null) ...[const SizedBox(height: 8), meta],
      ],
    );
    return SizedBox(
      height: side,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: side,
            height: side,
            decoration: continuous
                ? ShapeDecoration(
                    shape: RoundedSuperellipseBorder(borderRadius: corners),
                    shadows: shadows,
                  )
                : BoxDecoration(borderRadius: corners, boxShadow: shadows),
            child: continuous
                ? ClipRSuperellipse(
                    borderRadius: corners,
                    child: artwork(context, side),
                  )
                : ClipRRect(
                    borderRadius: corners,
                    child: artwork(context, side),
                  ),
          ),
          const SizedBox(width: gap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    // Large text scales down instead of overflowing the
                    // artwork's height.
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: SizedBox(width: textWidth, child: text),
                    ),
                  ),
                ),
                if (actions != null)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: actions,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  final back =
      leading ??
      (Navigator.canPop(context)
          ? (mornye
                ? HeaderCircleButton(
                    icon: CupertinoIcons.back,
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    onPressed: () => Navigator.maybePop(context),
                  )
                : AppIconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    icon: const AppIcon(Icons.arrow_back),
                    onPressed: () => Navigator.maybePop(context),
                  ))
          : null);

  return [
    SliverLayoutInfoBuilder(
      select: (constraints) =>
          appBarTitle != null || (!mornye && constraints.scrollOffset > 200),
      builder: (context, showTitle) {
        return SliverAppBar(
          pinned: true,
          automaticallyImplyLeading: false,
          toolbarHeight: _toolbarHeight,
          // Mornye controls float over the pane, as in Apple Music.
          backgroundColor: mornye
              ? Colors.transparent
              : backgroundColor ?? theme.colorScheme.surface,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: mornye ? 0 : null,
          titleSpacing: 0,
          title: AnimatedOpacity(
            opacity: showTitle ? 1 : 0,
            duration: context.tokens.motionFast,
            child: Text(
              appBarTitle ?? title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          leadingWidth: _toolbarHeight + 12,
          leading: back == null
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsetsDirectional.only(start: 16),
                  child: Center(child: back),
                ),
          actionsPadding: const EdgeInsetsDirectional.only(end: 16),
          actions: trailing.isEmpty
              ? null
              : mornye
              ? [_ActionCapsule(children: trailing)]
              : trailing,
        );
      },
    ),
    SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(inset, 4, inset, 28),
        child: mornye
            ? LayoutBuilder(builder: details)
            // Kept without a source too, so artwork that arrives later
            // moves the scheme instead of rebuilding the header.
            : PlayerArtworkTheme(
                artUri: paletteSource,
                child: Builder(
                  builder: (context) => HeaderPalette(
                    scheme: Theme.of(context).colorScheme,
                    child: LayoutBuilder(builder: details),
                  ),
                ),
              ),
      ),
    ),
  ];
}

/// Mornye page actions grouped in one glass capsule.
class _ActionCapsule extends ConsumerWidget {
  const _ActionCapsule({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      widthFactor: 1,
      child: MornyeGlass.navigation(
        radius: 18,
        tintColor: dark ? Colors.black : Colors.white,
        tintOpacity: dark ? 0.45 : 0.55,
        blurEnabled: ref.watch(mornyeBlurEnabledProvider),
        child: HeaderActionGroup(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ),
    );
  }
}

class _MoreButton extends StatelessWidget {
  const _MoreButton({required this.groups});

  final List<List<ContextMenuAction>> Function() groups;

  @override
  Widget build(BuildContext context) => HeaderCircleButton(
    icon: context.isMornye ? CupertinoIcons.ellipsis : Icons.more_horiz,
    tooltip: MaterialLocalizations.of(context).showMenuTooltip,
    onPressed: () => showContextMenu(
      context,
      position:
          contextMenuPositionBelow(context) ??
          contextMenuOriginOf(context) ??
          Offset.zero,
      groups: groups(),
    ),
  );
}
