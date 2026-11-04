import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderProxySliver;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_glass_press.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/expressive_button_group.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/desktop/detail_header.dart';
import 'package:mornye/widgets/settled_blur.dart';
import 'package:mornye/widgets/sliver_layout_info_builder.dart';

/// Collapsing album-detail header shared by the album, local-album, and
/// downloaded-album screens: full-bleed [background] (optionally blurred and
/// scrimmed), bottom gradient, centered square cover, title, optional
/// subtitle/meta/actions rows, and a circular back button. Content fades out
/// below 30% expansion; the [title] fades into the toolbar instead.
///
/// Colours come from a scheme derived from [paletteSource] (see [CoverPalette])
/// and are published to descendants through [HeaderPalette], so the header
/// follows both the artwork and the app's light/dark mode instead of assuming a
/// black backdrop with white text. The Material desktop header scopes the same
/// scheme to its artwork and details (see [desktopDetailHeaderSlivers]).
class AlbumDetailHeader extends StatelessWidget {
  const AlbumDetailHeader({
    super.key,
    required this.title,
    required this.expandedHeight,
    required this.showTitleInAppBar,
    this.showTitleListenable,
    required this.background,
    this.paletteSource,
    this.blurAndScrimBackground = true,
    this.coverBuilder,
    this.subtitle,
    this.meta,
    this.actions,
    this.appBarActions,
    this.appBarTitle,
    this.leading,
    this.backgroundColor,
    this.immersive = false,
    this.squareArtwork = true,
    this.moreMenu,
  });

  /// Desktop only: page actions behind a "More" button in the toolbar.
  final List<List<ContextMenuAction>> Function()? moreMenu;

  final String title;
  final double expandedHeight;
  final bool showTitleInAppBar;

  /// Replaces [showTitleInAppBar] when set; see [headerToolbarTitle].
  final ValueListenable<bool>? showTitleListenable;

  /// Full-bleed background content (cover image, motion banner, placeholder).
  final Widget background;

  /// Cover URL or local path the header palette is derived from. Null keeps the
  /// app's own colour scheme.
  final String? paletteSource;

  /// Blur the background and dim it 35%; disable for motion banners and
  /// placeholder backgrounds.
  final bool blurAndScrimBackground;

  /// Builds the centered square cover for the given side length; null hides
  /// the cover block (the header wraps it in the shared shadow + rounding).
  final Widget Function(BuildContext context, double coverSize)? coverBuilder;

  /// Artist line under the title (plain text or a clickable artist widget).
  final Widget? subtitle;

  /// "•"-joined meta row under the subtitle.
  final Widget? meta;

  /// Action row (play/shuffle, download-all, ...) under the meta row.
  final Widget? actions;

  /// Extra toolbar actions (top-right).
  final List<Widget>? appBarActions;

  /// Toolbar title when it should differ from [title] (e.g. a selection
  /// count); defaults to [title].
  final String? appBarTitle;

  /// Replaces the default circular back button.
  final Widget? leading;

  final Color? backgroundColor;
  final bool immersive;

  /// Ordinary cover art stays 1:1; provider-supplied banners may fill a header.
  final bool squareArtwork;

  /// Shrinks long titles so up to three lines fit the header.
  double _titleFontSize() {
    final length = title.trim().length;
    if (length > 45) return 18;
    if (length > 30) return 21;
    return 24;
  }

  @override
  Widget build(BuildContext context) {
    if (isDesktopPlatform ||
        (context.isMornye && (coverBuilder != null || immersive))) {
      final scheme = Theme.of(context).colorScheme;
      return HeaderPalette(
        scheme: scheme,
        child: Builder(
          builder: (context) =>
              SliverMainAxisGroup(slivers: buildSlivers(context)),
        ),
      );
    }
    return CoverPaletteBuilder(
      imageSource: paletteSource,
      builder: (context, headerScheme) => _buildAppBar(context, headerScheme),
    );
  }

  /// Keep the toolbar at the collection scroll-view level so it stays pinned
  /// after the dynamically sized artwork and metadata have scrolled away.
  List<Widget> buildSlivers(BuildContext context) {
    if (isDesktopPlatform) return _buildDesktopSlivers(context);
    if (!context.isMornye || (coverBuilder == null && !immersive)) {
      return [this];
    }
    final scheme = Theme.of(context).colorScheme;
    final edgeInset = detailHeaderEdgeInset(context);
    final screenSize = MediaQuery.sizeOf(context);
    // Landscape tablets are short: the artwork also yields to the height so
    // the title and actions stay on the first screen.
    final artworkSize = math.min(
      screenSize.width.clamp(0.0, 440.0),
      math.max(240.0, screenSize.height * 0.55),
    );
    final details = _buildMornyeDetails(context);
    // Built once, so toolbar rebuilds keep the same glass button element.
    final back = Padding(
      padding: EdgeInsetsDirectional.only(start: edgeInset),
      child:
          leading ??
          HeaderCircleButton(
            icon: CupertinoIcons.back,
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: () => Navigator.pop(context),
          ),
    );
    Widget toolbar({bool collapsed = true}) => SliverAppBar(
      pinned: true,
      backgroundColor: collapsed ? scheme.surface : Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      title: headerToolbarTitle(
        showTitleListenable,
        showTitleInAppBar,
        (showTitle) => AnimatedOpacity(
          opacity: showTitle || appBarTitle != null || (immersive && collapsed)
              ? 1
              : 0,
          duration: const Duration(milliseconds: 180),
          child: Text(
            appBarTitle ?? title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      leadingWidth: kToolbarHeight + edgeInset,
      leading: back,
      actionsPadding: EdgeInsetsDirectional.only(end: edgeInset),
      actions: appBarActions,
    );
    if (immersive) {
      final detailsTop = (artworkSize - 20).clamp(0.0, double.infinity);
      final artwork = Stack(
        fit: StackFit.expand,
        children: [
          background,
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0, 0.48, 1],
                colors: [
                  Colors.black.withValues(alpha: 0.12),
                  scheme.surface.withValues(alpha: 0),
                  scheme.surface,
                ],
              ),
            ),
          ),
        ],
      );
      return [
        // The toolbar paints above the header without reserving a second
        // status-bar inset. Metadata still has its natural, scrollable height.
        Builder(
          builder: (context) {
            final toolbarHeight =
                kToolbarHeight + MediaQuery.paddingOf(context).top;
            final collapseOffset = detailsTop - toolbarHeight;
            return SliverLayoutInfoBuilder(
              select: (constraints) =>
                  constraints.scrollOffset >= collapseOffset,
              builder: (context, collapsed) =>
                  _AlbumOverlayToolbar(child: toolbar(collapsed: collapsed)),
            );
          },
        ),
        SliverToBoxAdapter(
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              Positioned.fill(
                child: squareArtwork
                    ? Align(
                        alignment: Alignment.topCenter,
                        child: SizedBox.square(
                          dimension: artworkSize,
                          child: _AlbumStretchArtwork(child: artwork),
                        ),
                      )
                    : _AlbumStretchArtwork(child: artwork),
              ),
              Column(
                children: [
                  SizedBox(height: detailsTop),
                  details,
                ],
              ),
            ],
          ),
        ),
      ];
    }
    return [
      Builder(builder: (_) => toolbar()),
      SliverToBoxAdapter(child: details),
    ];
  }

  List<Widget> _buildDesktopSlivers(BuildContext context) =>
      desktopDetailHeaderSlivers(
        context,
        title: title,
        artwork: (context, size) =>
            coverBuilder?.call(context, size) ?? background,
        paletteSource: paletteSource,
        subtitle: subtitle,
        meta: meta,
        actions: actions,
        appBarActions: appBarActions,
        moreMenu: moreMenu,
        appBarTitle: appBarTitle,
        leading: leading,
        backgroundColor: backgroundColor,
      );

  Widget _buildMornyeDetails(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(20, immersive ? 0 : 20, 20, 28),
    child: Column(
      children: [
        if (!immersive)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: AspectRatio(
              aspectRatio: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.16),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: LayoutBuilder(
                    builder: (context, constraints) =>
                        coverBuilder!(context, constraints.maxWidth),
                  ),
                ),
              ),
            ),
          ),
        if (!immersive) const SizedBox(height: 22),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (subtitle != null) ...[const SizedBox(height: 5), subtitle!],
        if (meta != null) ...[const SizedBox(height: 5), meta!],
        if (actions != null) ...[
          SizedBox(height: immersive ? 16 : 24),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: actions!,
          ),
        ],
      ],
    ),
  );

  Widget _buildAppBar(BuildContext context, ColorScheme headerScheme) {
    final tokens = context.tokens;
    final plainArtworkHeader = context.isMornye && coverBuilder != null;
    // iOS does not add horizontal safe-area padding in portrait. Give toolbar
    // controls and header content an explicit inset so circular actions do not
    // sit against the glass edge on either iPhone or iPad. Android uses a
    // smaller inset for the same reason.
    final iosEdgeInset = detailHeaderEdgeInset(context);
    // Scrim and gradient are drawn from the palette surface instead of black,
    // so a light theme gets a light header with dark text and a dark theme
    // keeps the familiar dark treatment — both tinted by the artwork.
    final scrimColor = headerScheme.surface;
    final onHeader = headerScheme.onSurface;
    final expressive = materialExpressiveEnabled(context);
    final fallbackMotion = AppMotionSpec(tokens.motionFast, Curves.linear);
    final titleSlide = AppMotion.spatial(context, fallbackMotion);
    final titleFade = AppMotion.effects(context, fallbackMotion);
    Widget toolbarTitle(bool showTitle) {
      final fading = AnimatedOpacity(
        duration: titleFade.duration,
        curve: titleFade.curve,
        opacity: showTitle ? 1.0 : 0.0,
        child: Text(
          appBarTitle ?? title,
          style: TextStyle(
            color: onHeader,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
      if (!expressive) return fading;
      return AnimatedSlide(
        duration: titleSlide.duration,
        curve: titleSlide.curve,
        offset: showTitle ? Offset.zero : const Offset(0, 0.6),
        child: fading,
      );
    }

    return SliverAppBar(
      expandedHeight: expandedHeight,
      pinned: true,
      stretch: true,
      backgroundColor: backgroundColor ?? headerScheme.surface,
      surfaceTintColor: Colors.transparent,
      title: headerToolbarTitle(
        showTitleListenable,
        showTitleInAppBar,
        toolbarTitle,
      ),
      flexibleSpace: LayoutBuilder(
        builder: (context, constraints) {
          final collapseRatio =
              (constraints.maxHeight - kToolbarHeight) /
              (expandedHeight - kToolbarHeight);
          final showContent = collapseRatio > 0.3;
          // Expressive headers shrink and fade the hero content with the
          // scroll instead of hiding it at one threshold.
          final contentProgress = Curves.easeOut.transform(
            ((collapseRatio - 0.3) / 0.5).clamp(0.0, 1.0),
          );
          final content = Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (coverBuilder != null) ...[
                Builder(
                  builder: (context) {
                    // Landscape headers are short: the cover also yields to
                    // the height left below the toolbar once the title,
                    // details and actions are placed, so it never rises
                    // into the status bar or toolbar buttons.
                    final toolbarBottom =
                        MediaQuery.paddingOf(context).top + kToolbarHeight;
                    final detailsHeight =
                        40 +
                        20 +
                        58 +
                        (subtitle == null ? 0 : 28) +
                        (meta == null ? 0 : 34) +
                        (actions == null ? 0 : 64);
                    final coverSize = math.min(
                      (constraints.maxWidth * 0.5).clamp(150.0, 210.0),
                      math.max(
                        96.0,
                        expandedHeight - toolbarBottom - detailsHeight,
                      ),
                    );
                    // Material uses the expressive extra-large corner.
                    final coverRadius = context.isMornye
                        ? tokens.radiusControl
                        : 28.0;
                    return Container(
                      width: coverSize,
                      height: coverSize,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(
                          plainArtworkHeader ? tokens.radiusCover : coverRadius,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: headerScheme.shadow.withValues(alpha: 0.45),
                            blurRadius: 24,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(coverRadius),
                        child: coverBuilder!(context, coverSize),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 20),
              ],
              Text(
                title,
                style: TextStyle(
                  color: onHeader,
                  fontSize: _titleFontSize(),
                  fontWeight: FontWeight.bold,
                  height: 1.2,
                ),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle != null) ...[const SizedBox(height: 6), subtitle!],
              if (meta != null) ...[const SizedBox(height: 12), meta!],
              if (actions != null) ...[const SizedBox(height: 16), actions!],
            ],
          );

          return FlexibleSpaceBar(
            collapseMode: CollapseMode.pin,
            background: Stack(
              fit: StackFit.expand,
              children: [
                if (plainArtworkHeader)
                  ColoredBox(color: headerScheme.surface)
                else if (blurAndScrimBackground)
                  SettledBlur(sigma: 32, child: background)
                else
                  background,
                if (!plainArtworkHeader && blurAndScrimBackground)
                  ColoredBox(color: scrimColor.withValues(alpha: 0.4)),
                if (!plainArtworkHeader)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: expandedHeight * 0.65,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            scrimColor.withValues(alpha: 0),
                            scrimColor.withValues(alpha: 0.92),
                          ],
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 20 + iosEdgeInset,
                  right: 20 + iosEdgeInset,
                  bottom: 40,
                  child: expressive
                      ? IgnorePointer(
                          ignoring: contentProgress == 0,
                          child: Opacity(
                            opacity: contentProgress,
                            child: Transform.scale(
                              scale: 0.9 + 0.1 * contentProgress,
                              alignment: Alignment.bottomCenter,
                              child: content,
                            ),
                          ),
                        )
                      : AnimatedOpacity(
                          duration: tokens.motionFast,
                          opacity: showContent ? 1.0 : 0.0,
                          child: content,
                        ),
                ),
              ],
            ),
            stretchModes: const [StretchMode.zoomBackground],
          );
        },
      ),
      leadingWidth: kToolbarHeight + iosEdgeInset,
      leading: Padding(
        padding: EdgeInsetsDirectional.only(start: iosEdgeInset),
        child:
            leading ??
            // Centered so the tight leading slot cannot stretch the circle.
            Center(
              child: AppIconButton.filledTonal(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: AppIcon(
                  context.isMornye ? Icons.chevron_left : Icons.arrow_back,
                ),
                style: IconButton.styleFrom(
                  minimumSize: Size.square(tokens.minTouchTarget),
                  backgroundColor: headerScheme.surfaceContainerHigh.withValues(
                    alpha: 0.75,
                  ),
                  foregroundColor: headerScheme.onSurfaceVariant,
                ),
                onPressed: () => Navigator.pop(context),
              ),
            ),
      ),
      actionsPadding: EdgeInsetsDirectional.only(end: iosEdgeInset),
      actions: appBarActions,
    );
  }
}

/// Marks header buttons grouped in one glass capsule, where they drop their
/// own glass circle.
class HeaderActionGroup extends InheritedWidget {
  const HeaderActionGroup({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HeaderActionGroup>() != null;

  @override
  bool updateShouldNotify(HeaderActionGroup oldWidget) => false;
}

/// Mornye page actions grouped in one glass capsule.
class MornyeActionCapsule extends ConsumerWidget {
  const MornyeActionCapsule({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Level with the round back button beside it.
    const radius = 22.0;
    return Center(
      widthFactor: 1,
      child: MornyeGlassPress(
        radius: radius,
        child: MornyeGlass.navigation(
          radius: radius,
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
      ),
    );
  }
}

class _AlbumStretchArtwork extends StatelessWidget {
  const _AlbumStretchArtwork({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final position = Scrollable.of(context).position;
    return LayoutBuilder(
      builder: (context, constraints) => AnimatedBuilder(
        animation: position,
        child: RepaintBoundary(child: child),
        builder: (context, artwork) {
          final overscroll = position.hasContentDimensions
              ? (position.minScrollExtent - position.pixels).clamp(
                  0.0,
                  double.infinity,
                )
              : 0.0;
          final height = constraints.maxHeight;
          final scale = height > 0 ? 1 + overscroll / height : 1.0;
          // The viewport moves the details down during a pull. Keep the image
          // at the top and enlarge it without changing the scrollable layout.
          return Transform.translate(
            offset: Offset(0, -overscroll),
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topCenter,
              child: artwork,
            ),
          );
        },
      ),
    );
  }
}

/// Builds a collapsing toolbar title with [showTitle], or with [listenable]'s
/// value when one is given, so crossing the threshold rebuilds only the title.
Widget headerToolbarTitle(
  ValueListenable<bool>? listenable,
  bool showTitle,
  Widget Function(bool showTitle) builder,
) => listenable == null
    ? builder(showTitle)
    : ValueListenableBuilder<bool>(
        valueListenable: listenable,
        builder: (_, showTitle, _) => builder(showTitle),
      );

/// Keeps the pinned toolbar above the artwork without shifting the artwork or
/// metadata down by the toolbar's safe-area height.
class _AlbumOverlayToolbar extends SingleChildRenderObjectWidget {
  const _AlbumOverlayToolbar({required super.child});

  @override
  RenderProxySliver createRenderObject(BuildContext context) =>
      _RenderAlbumOverlayToolbar();
}

class _RenderAlbumOverlayToolbar extends RenderProxySliver {
  @override
  void performLayout() {
    super.performLayout();
    final childGeometry = geometry!;
    if (childGeometry.scrollOffsetCorrection != null) return;
    geometry = childGeometry.copyWith(
      scrollExtent: 0,
      layoutExtent: 0,
      cacheExtent: 0,
    );
  }
}

/// Primary "play" pill + shuffle circle used by the local and downloaded album
/// headers. Colours follow the [HeaderPalette].
class AlbumPlayActions extends StatelessWidget {
  const AlbumPlayActions({
    super.key,
    required this.playLabel,
    required this.shuffleTooltip,
    required this.onPlay,
    required this.onShuffle,
    this.isPlaying = false,
    this.onAddToPlaylist,
    this.onDownload,
  });

  final String playLabel;
  final String shuffleTooltip;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;
  final bool isPlaying;

  /// Desktop only: a round "+" after Play that adds the songs to a playlist.
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final scheme = HeaderPalette.of(context);
    if (isDesktopPlatform) return _buildDesktop(context, scheme);
    if (context.isMornye) {
      return Row(
        children: [
          if (onDownload != null) ...[
            HeaderCircleButton(
              icon: Icons.download_for_offline_outlined,
              tooltip: context.l10n.offlineSave,
              onPressed: onDownload,
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: HeaderFilledButton(
              icon: isPlaying
                  ? CupertinoIcons.pause_fill
                  : CupertinoIcons.play_fill,
              label: playLabel,
              onPressed: onPlay,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _MornyeHeaderButton(
              icon: CupertinoIcons.shuffle,
              label: shuffleTooltip,
              onPressed: onShuffle,
            ),
          ),
        ],
      );
    }
    return ExpressiveButtonGroup(
      flexible: {onDownload == null ? 0 : 1},
      spacing: tokens.gapMd,
      slotWidth: tokens.minTouchTarget,
      children: [
        if (onDownload != null)
          HeaderCircleButton(
            icon: Icons.download_for_offline_outlined,
            tooltip: context.l10n.offlineSave,
            onPressed: onDownload,
          ),
        ExpressiveButton(
          onPressed: onPlay,
          icon: AppIcon(isPlaying ? Icons.pause : Icons.play_arrow, size: 20),
          style: FilledButton.styleFrom(
            backgroundColor: scheme.primary,
            foregroundColor: scheme.onPrimary,
            minimumSize: Size(0, tokens.minTouchTarget),
            shape: const StadiumBorder(),
          ),
          child: Text(playLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        ExpressiveIconButton(
          tooltip: shuffleTooltip,
          onPressed: onShuffle,
          icon: const AppIcon(Icons.shuffle),
          size: tokens.minTouchTarget,
          backgroundColor: scheme.secondaryContainer.withValues(alpha: 0.8),
          foregroundColor: scheme.onSecondaryContainer,
        ),
      ],
    );
  }

  /// Shuffle, Play and "+" at their own widths along the artwork's bottom
  /// edge: round gray buttons around the Play capsule in Mornye, a filled
  /// Play button with tonal icon buttons in Material.
  Widget _buildDesktop(BuildContext context, ColorScheme scheme) {
    final addLabel = context.l10n.collectionAddToPlaylist;
    if (context.isMornye) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 10,
        children: [
          if (onDownload != null)
            HeaderCircleButton(
              icon: Icons.download_for_offline_outlined,
              tooltip: context.l10n.offlineSave,
              onPressed: onDownload,
            ),
          HeaderCircleButton(
            icon: CupertinoIcons.shuffle,
            tooltip: shuffleTooltip,
            tonal: true,
            onPressed: onShuffle,
          ),
          _MornyeHeaderButton(
            icon: isPlaying
                ? CupertinoIcons.pause_fill
                : CupertinoIcons.play_fill,
            label: playLabel,
            onPressed: onPlay,
          ),
          if (onAddToPlaylist != null)
            HeaderCircleButton(
              icon: CupertinoIcons.add,
              tooltip: addLabel,
              tonal: true,
              onPressed: onAddToPlaylist,
            ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        if (onDownload != null)
          HeaderCircleButton(
            icon: Icons.download_for_offline_outlined,
            tooltip: context.l10n.offlineSave,
            onPressed: onDownload,
          ),
        FilledButton.icon(
          onPressed: onPlay,
          icon: AppIcon(isPlaying ? Icons.pause : Icons.play_arrow, size: 20),
          label: Text(playLabel),
          style: FilledButton.styleFrom(minimumSize: const Size(112, 40)),
        ),
        IconButton.filledTonal(
          tooltip: shuffleTooltip,
          onPressed: onShuffle,
          icon: const AppIcon(Icons.shuffle),
        ),
        if (onAddToPlaylist != null)
          IconButton.filledTonal(
            tooltip: addLabel,
            onPressed: onAddToPlaylist,
            icon: const AppIcon(Icons.playlist_add),
          ),
      ],
    );
  }
}

/// Primary action pill in a detail header (download all, play all). Reads its
/// colours from [HeaderPalette] so it works on light and dark headers alike.
class HeaderFilledButton extends StatelessWidget {
  const HeaderFilledButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tonal = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool tonal;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final scheme = HeaderPalette.of(context);
    if (context.isMornye) {
      return _MornyeHeaderButton(
        icon: mornyeIconFor(icon),
        label: label,
        onPressed: onPressed,
        prominent: !tonal,
      );
    }
    return ExpressiveButton(
      onPressed: onPressed,
      icon: AppIcon(icon, size: 18),
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        disabledBackgroundColor: scheme.primary.withValues(alpha: 0.4),
        disabledForegroundColor: scheme.onPrimary.withValues(alpha: 0.7),
        minimumSize: Size(0, tokens.minTouchTarget),
        shape: const StadiumBorder(),
      ),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

/// Circular header icon button (add-to-playlist, love-all, ...). Sized to the
/// minimum touch target and tinted from the [HeaderPalette].
class HeaderCircleButton extends ConsumerWidget {
  const HeaderCircleButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.iconColor,
    this.tonal = false,
    this.glassTintColor,
    this.glassTintOpacity,
    this.buttonSize,
    this.iconSize = 22,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// Overrides the palette foreground, e.g. to mark an active "loved" state.
  final Color? iconColor;

  /// Uses the same translucent fill as the local album's Play/Shuffle pills.
  final bool tonal;

  /// Optional tint for controls floating over artwork-colored surfaces.
  final Color? glassTintColor;
  final double? glassTintOpacity;
  final double? buttonSize;
  final double iconSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    final scheme = HeaderPalette.of(context);
    // Desktop headers use pointer-sized controls.
    final desktop = isDesktopPlatform;
    // Tonal circles stay level with the action pills beside them.
    final toolbarGlass = context.isMornye && !tonal;
    final buttonSize =
        this.buttonSize ??
        (desktop ? (context.isMornye ? (tonal ? 36.0 : 44.0) : 40.0) : null);
    final iconSize = desktop && this.iconSize == 22 && !toolbarGlass
        ? 18.0
        : this.iconSize;
    if (context.isMornye && HeaderActionGroup.of(context)) {
      return IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        icon: AppIcon(mornyeIconFor(icon), size: iconSize),
        style: IconButton.styleFrom(
          // Pointer controls use a compact width within the shared capsule.
          minimumSize: desktop
              ? Size(42, buttonSize ?? 44)
              : Size.square(buttonSize ?? 44),
          padding: desktop ? EdgeInsets.zero : null,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: iconColor ?? scheme.onSurface,
        ),
      );
    }
    if (context.isMornye) {
      if (tonal) {
        return Tooltip(
          message: tooltip,
          child: SizedBox.square(
            dimension: buttonSize ?? 44,
            child: MornyeGlassPress(
              radius: (buttonSize ?? 44) / 2,
              enabled: onPressed != null,
              child: CupertinoButton(
                padding: EdgeInsets.zero,
                minimumSize: Size.square(buttonSize ?? 44),
                borderRadius: BorderRadius.circular((buttonSize ?? 48) / 2),
                color: scheme.onSurface.withValues(
                  alpha: scheme.brightness == Brightness.dark ? 0.10 : 0.06,
                ),
                onPressed: onPressed,
                child: AppIcon(
                  mornyeIconFor(icon),
                  size: iconSize,
                  color: onPressed == null
                      ? scheme.onSurfaceVariant
                      : iconColor ?? scheme.primary,
                ),
              ),
            ),
          ),
        );
      }
      final blurEnabled = ref.watch(mornyeBlurEnabledProvider);
      final button = IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        icon: AppIcon(mornyeIconFor(icon), size: iconSize),
        style: IconButton.styleFrom(
          minimumSize: Size.square(buttonSize ?? 44),
          // Keep the glass circle at the button's size for the pointer.
          tapTargetSize: desktop ? MaterialTapTargetSize.shrinkWrap : null,
          foregroundColor: iconColor ?? scheme.onSurface,
        ),
      );
      return Center(
        widthFactor: 1,
        child: MornyeGlassPress(
          radius: (buttonSize ?? 48) / 2,
          enabled: onPressed != null,
          child: MornyeGlass.navigation(
            radius: (buttonSize ?? 48) / 2,
            tintColor:
                glassTintColor ??
                (scheme.brightness == Brightness.dark
                    ? Colors.black
                    : Colors.white),
            tintOpacity:
                glassTintOpacity ??
                (scheme.brightness == Brightness.dark ? 0.45 : 0.55),
            blurEnabled: blurEnabled,
            child: button,
          ),
        ),
      );
    }
    return ExpressiveIconButton(
      onPressed: onPressed,
      icon: AppIcon(icon, size: iconSize),
      tooltip: tooltip,
      size: buttonSize ?? tokens.minTouchTarget,
      backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
      foregroundColor: iconColor ?? scheme.onSurfaceVariant,
    );
  }
}

/// The page's More button, opening [groups] below itself.
class HeaderMoreButton extends StatelessWidget {
  const HeaderMoreButton({super.key, required this.groups});

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

class _MornyeHeaderButton extends StatelessWidget {
  const _MornyeHeaderButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.prominent = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final scheme = HeaderPalette.of(context);
    // Desktop action pills use a compact, neutral fill.
    final desktop = isDesktopPlatform;
    final filled = prominent && !desktop;
    final foreground = onPressed == null
        ? scheme.onSurfaceVariant
        : filled
        ? scheme.onPrimary
        : scheme.primary;
    return ConstrainedBox(
      constraints: desktop
          ? const BoxConstraints(minHeight: 36, maxHeight: 36, minWidth: 130)
          : const BoxConstraints(minHeight: 50),
      child: MornyeGlassPress(
        radius: desktop ? 18 : 28,
        enabled: onPressed != null,
        child: CupertinoButton(
          padding: desktop
              ? const EdgeInsets.symmetric(horizontal: 18)
              : const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          minimumSize: desktop ? const Size(130, 36) : null,
          borderRadius: BorderRadius.circular(desktop ? 18 : 28),
          color: filled
              ? scheme.primary
              : scheme.onSurface.withValues(
                  alpha: scheme.brightness == Brightness.dark ? 0.10 : 0.06,
                ),
          onPressed: onPressed,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(icon, size: desktop ? 16 : 20, color: foreground),
              SizedBox(width: desktop ? 6 : 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: desktop ? 15 : 17,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "•"-joined row of [HeaderMetaItem]s shown under the header subtitle
/// (track count, duration, quality, ...).
class HeaderMetaRow extends StatelessWidget {
  const HeaderMetaRow({super.key, required this.items});

  final List<Widget> items;

  @override
  Widget build(BuildContext context) {
    final scheme = HeaderPalette.of(context);
    final parts = <Widget>[];
    for (final item in items) {
      if (parts.isNotEmpty) {
        parts.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              '•',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ),
        );
      }
      parts.add(item);
    }

    return Wrap(
      alignment: isDesktopPlatform ? WrapAlignment.start : WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 4,
      children: parts,
    );
  }
}

/// Single meta label (optional leading icon) for [HeaderMetaRow].
class HeaderMetaItem extends StatelessWidget {
  const HeaderMetaItem(this.label, {super.key, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = HeaderPalette.of(context);
    final desktop = isDesktopPlatform;
    final textStyle = TextStyle(
      color: context.isMornye || desktop
          ? scheme.onSurfaceVariant
          : scheme.onSurface,
      fontSize: desktop && context.isMornye ? 12 : 13,
      fontWeight: desktop ? FontWeight.w600 : FontWeight.w500,
    );
    if (icon == null) return Text(label, style: textStyle);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppIcon(
          icon,
          size: 15,
          color: desktop ? scheme.onSurfaceVariant : scheme.onSurface,
        ),
        const SizedBox(width: 4),
        Text(label, style: textStyle),
      ],
    );
  }
}
