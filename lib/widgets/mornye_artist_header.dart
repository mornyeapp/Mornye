import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/sliver_layout_info_builder.dart';

/// Share the same artwork-derived dark surface while loading and after the
/// artist metadata arrives, including when the app itself uses light mode.
class MornyeArtistSurface extends StatefulWidget {
  const MornyeArtistSurface({
    super.key,
    required this.imageSource,
    required this.child,
    this.logoSource,
    this.neutralActions = false,
  });

  final String? imageSource;
  final String? logoSource;
  final Widget child;

  /// Album and playlist actions use white controls over the artwork tint.
  final bool neutralActions;

  @override
  State<MornyeArtistSurface> createState() => _MornyeArtistSurfaceState();
}

class _MornyeArtistSurfaceState extends State<MornyeArtistSurface> {
  // Page rebuilds reuse the derived themes while their inputs are unchanged.
  ThemeData? _baseTheme;
  TargetPlatform? _basePlatform;
  late ThemeData _darkTheme;
  late ThemeData _outerTheme;
  (Color, Color, Color, bool)? _innerKey;
  late ThemeData _innerTheme;

  @override
  void dispose() {
    ShellNavigationService.clearChromeBrightness(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Desktop album and playlist pages keep the plain pane background and
    // app accent; artist pages keep their artwork tint, as in Apple Music.
    if (isDesktopPlatform && widget.neutralActions) return widget.child;
    final baseTheme = Theme.of(context);
    if (!identical(baseTheme, _baseTheme) ||
        defaultTargetPlatform != _basePlatform) {
      _baseTheme = baseTheme;
      _basePlatform = defaultTargetPlatform;
      _innerKey = null;
      _darkTheme = MornyeTheme.fromContext(
        context,
        brightness: Brightness.dark,
      );
      _outerTheme = _darkTheme.copyWith(
        colorScheme: _darkTheme.colorScheme.copyWith(primary: Colors.grey),
      );
    }
    final darkTheme = _darkTheme;
    return Theme(
      data: _outerTheme,
      child: CoverPaletteBuilder(
        imageSource: widget.imageSource,
        builder: (context, palette) {
          final source = widget.imageSource;
          final dominant = HSLColor.fromColor(
            source == null
                ? Colors.grey
                : CoverPalette.sourceColor(source, Brightness.dark) ??
                      Colors.grey,
          );
          // Averaging a portrait mixes its highlights and foliage into gray.
          // Artist pages use the extracted accent at a deeper tone instead;
          // album surfaces and monochrome artwork keep their neutral shading.
          final useAccent =
              !widget.neutralActions && dominant.saturation >= 0.08;
          final accent = HSLColor.fromColor(palette.primary);
          final surface = useAccent
              ? accent
                    .withSaturation((accent.saturation * 0.9).clamp(0.0, 0.88))
                    .withLightness(0.14 + dominant.lightness * 0.05)
                    .toColor()
              : dominant
                    .withSaturation(
                      (dominant.saturation * 0.45).clamp(0.0, 0.22),
                    )
                    .withLightness(0.24 + dominant.lightness * 0.20)
                    .toColor();
          final route = ModalRoute.of(context);
          if (route != null) {
            ShellNavigationService.setChromeBrightness(
              owner: this,
              route: route,
              brightness: Brightness.dark,
              surface: surface,
            );
          }
          return CoverPaletteBuilder(
            imageSource: widget.neutralActions ? null : widget.logoSource,
            builder: (context, _) {
              final logo = widget.logoSource;
              // Use the logo's original pixels, including white lettering,
              // without Material's pastel accent mapping.
              final logoColor = logo == null
                  ? null
                  : CoverPalette.sourceColor(logo, Brightness.dark);
              // Keep the artwork accent for colorful portraits. A neutral
              // portrait can acquire a blue Material accent; use white there,
              // while allowing an explicit logo color to take precedence.
              final primary = widget.neutralActions
                  ? Colors.white
                  : logoColor ?? (useAccent ? palette.primary : Colors.white);
              final primaryLuminance = primary.computeLuminance();
              final surfaceContrast =
                  (primaryLuminance + 0.05) /
                  (surface.computeLuminance() + 0.05);
              final onPrimary = widget.neutralActions
                  ? Colors.black
                  : logoColor == null && useAccent
                  ? palette.onPrimary
                  : surfaceContrast >= 4.5
                  ? surface
                  : primaryLuminance > 0.179
                  ? Colors.black
                  : Colors.white;
              final innerKey = (
                surface,
                primary,
                onPrimary,
                widget.neutralActions,
              );
              if (innerKey != _innerKey) {
                _innerKey = innerKey;
                _innerTheme = darkTheme.copyWith(
                  scaffoldBackgroundColor: surface,
                  colorScheme: darkTheme.colorScheme.copyWith(
                    primary: primary,
                    onPrimary: onPrimary,
                    onSurfaceVariant: widget.neutralActions
                        ? Colors.white70
                        : null,
                    surface: surface,
                    surfaceContainer: Color.alphaBlend(
                      Colors.white.withValues(alpha: 0.08),
                      surface,
                    ),
                    surfaceContainerHigh: Color.alphaBlend(
                      Colors.white.withValues(alpha: 0.12),
                      surface,
                    ),
                  ),
                );
              }
              return Theme(
                data: _innerTheme,
                child: HeaderPalette(
                  scheme: _innerTheme.colorScheme,
                  child: widget.child,
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Portrait and centered identity from Mornye's MobileArtistView. Actions stay
/// supplied by the screen so remote artists retain download/favorite behavior.
class MornyeArtistHeader extends StatelessWidget {
  const MornyeArtistHeader({
    super.key,
    required this.name,
    required this.artwork,
    required this.actions,
    required this.showTitle,
    this.showTitleListenable,
    this.listeners,
    this.logoUrl,
    this.badge,
  });

  final String name;
  final Widget artwork;
  final List<Widget> actions;
  final bool showTitle;

  /// Replaces [showTitle] when set; see [headerToolbarTitle].
  final ValueListenable<bool>? showTitleListenable;
  final String? listeners;
  final String? logoUrl;
  final Widget? badge;

  // A SliverMainAxisGroup clamps negative overlap, preventing this header from
  // receiving the overscroll used for its stretch animation.
  @override
  Widget build(BuildContext context) => buildSlivers(context).single;

  List<Widget> buildSlivers(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final back = Padding(
      padding: EdgeInsetsDirectional.only(start: isDesktopPlatform ? 16 : 12),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        widthFactor: 1,
        child: HeaderCircleButton(
          icon: Icons.arrow_back,
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => Navigator.pop(context),
        ),
      ),
    );
    return [
      // Keep safe-area dependencies inside this sliver: folding the shell
      // navigation must not rebuild the artist's entire discography.
      SliverLayoutInfoBuilder(
        select: (constraints) => (
          constraints.crossAxisExtent,
          isDesktopPlatform ? constraints.viewportMainAxisExtent : 0.0,
        ),
        builder: (context, extents) {
          final (width, viewportHeight) = extents;
          final textWidth = (width - 48).clamp(0.0, double.infinity);
          final textScaler = MediaQuery.textScalerOf(context);
          double textHeight(String text, TextStyle style) {
            final painter = TextPainter(
              text: TextSpan(
                text: text,
                style: DefaultTextStyle.of(context).style.merge(style),
              ),
              textDirection: Directionality.of(context),
              textScaler: textScaler,
              textAlign: TextAlign.center,
            )..layout(maxWidth: textWidth);
            final height = painter.height;
            painter.dispose();
            return height;
          }

          final nameHeight = textHeight(
            name,
            TextStyle(fontSize: _nameSize, fontWeight: FontWeight.bold),
          );
          final hasLogo = logoUrl?.trim().isNotEmpty == true;
          final identityHeight = hasLogo
              ? nameHeight.clamp(_logoSize.height, double.infinity)
              : nameHeight;
          final listenersHeight = listeners == null
              ? 0.0
              : 7 + textHeight(listeners!, const TextStyle(fontSize: 13));
          final photoHeight = (width * 0.76).clamp(240.0, 340.0);
          final contentHeight =
              identityHeight +
              listenersHeight +
              (actions.isEmpty ? 0 : 94) +
              32;
          // Desktop: the portrait fills most of the pane, as in Apple Music
          // on the Mac.
          final expandedHeight = isDesktopPlatform
              ? math.max(
                  contentHeight + 160,
                  (viewportHeight * 0.82).clamp(420.0, 820.0),
                )
              : photoHeight + contentHeight;
          return SliverAppBar(
            pinned: true,
            stretch: !MediaQuery.disableAnimationsOf(context),
            expandedHeight: expandedHeight - MediaQuery.paddingOf(context).top,
            backgroundColor: surface,
            surfaceTintColor: Colors.transparent,
            leadingWidth: 64,
            leading: back,
            title: headerToolbarTitle(
              showTitleListenable,
              showTitle,
              (showTitle) => AnimatedOpacity(
                opacity: showTitle ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            flexibleSpace: FlexibleSpaceBar(
              collapseMode: CollapseMode.pin,
              stretchModes: const [StretchMode.zoomBackground],
              background: Stack(
                fit: StackFit.expand,
                children: [
                  _ArtistCollapsingArtwork(surface: surface, child: artwork),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (badge != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: badge,
                            ),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: identityHeight,
                            ),
                            child: _buildIdentity(context),
                          ),
                          if (listeners != null) ...[
                            const SizedBox(height: 7),
                            Text(
                              listeners!,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.white.withValues(alpha: 0.7),
                              ),
                            ),
                          ],
                          if (actions.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            SizedBox(
                              height: 74,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                spacing: 24,
                                children: actions,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ];
  }

  /// The name and logo are larger over the wide desktop portrait.
  static double get _nameSize => isDesktopPlatform ? 44 : 30;
  static Size get _logoSize =>
      isDesktopPlatform ? const Size(440, 128) : const Size(320, 96);

  Widget _buildIdentity(BuildContext context) {
    final fallback = Text(
      name,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: _nameSize,
        fontWeight: FontWeight.bold,
        color: Colors.white,
      ),
    );
    final logoSize = _logoSize;
    final logo = logoUrl?.trim();
    if (logo == null || logo.isEmpty) return fallback;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return Semantics(
      label: name,
      image: true,
      excludeSemantics: true,
      child: Image(
        image: ResizeImage(
          cachedCoverImageProvider(logo),
          width: (logoSize.width * pixelRatio).ceil(),
          height: (logoSize.height * pixelRatio).ceil(),
          policy: ResizeImagePolicy.fit,
        ),
        fit: BoxFit.contain,
        frameBuilder: (_, child, frame, _) => frame == null
            ? fallback
            : ConstrainedBox(
                constraints: BoxConstraints.loose(logoSize),
                child: child,
              ),
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

/// Follow the sliver's actual collapse extent so scrolling back restores the
/// same artwork immediately, without a timer or rebuilding the discography.
class _ArtistCollapsingArtwork extends ConsumerWidget {
  const _ArtistCollapsingArtwork({required this.surface, required this.child});

  final Color surface;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = context
        .dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
    final range = settings == null
        ? 0.0
        : settings.maxExtent - settings.minExtent;
    final collapse = range <= 0
        ? 0.0
        : ((settings!.maxExtent - settings.currentExtent) / range).clamp(
            0.0,
            1.0,
          );
    final fade = const Interval(
      0.30,
      0.88,
      curve: Curves.easeInOut,
    ).transform(collapse);
    final blur = 18 * Curves.easeOut.transform(collapse);
    final blurEnabled =
        !MediaQuery.disableAnimationsOf(context) &&
        // The collapse blur and masked backdrop re-filter on every scroll frame.
        ref.watch(mornyeLiquidGlassProvider);

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          TickerMode(
            enabled: fade < 1,
            child: ImageFiltered(
              enabled: blurEnabled && blur > 0 && fade < 1,
              imageFilter: ImageFilter.blur(
                sigmaX: blur,
                sigmaY: blur,
                tileMode: TileMode.clamp,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final height = settings?.maxExtent ?? constraints.maxHeight;
                  final zoom = height > 0
                      ? (constraints.maxHeight / height).clamp(
                          1.0,
                          double.infinity,
                        )
                      : 1.0;
                  // Stretch the photograph uniformly around its top edge.
                  // Identity and actions remain outside this transform, moving
                  // down with the sliver without growing along with the image.
                  return OverflowBox(
                    alignment: Alignment.topCenter,
                    minHeight: height,
                    maxHeight: height,
                    child: Transform.scale(
                      scale: zoom,
                      alignment: Alignment.topCenter,
                      child: RepaintBoundary(child: child),
                    ),
                  );
                },
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0, 0.48, 0.82, 1],
                colors: [
                  Colors.black.withValues(alpha: 0.15),
                  surface.withValues(alpha: 0),
                  surface.withValues(alpha: 0.55),
                  surface,
                ],
              ),
            ),
          ),
          ColoredBox(
            key: const ValueKey('artist-artwork-fade'),
            color: surface.withValues(alpha: fade),
          ),
        ],
      ),
    );
  }
}
