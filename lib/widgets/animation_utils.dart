import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:material_3_expressive/material_3_expressive.dart'
    show M3EMotion;
import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/page_transitions.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/decorative_phase.dart';
import 'package:mornye/widgets/desktop/track_table.dart';
import 'package:mornye/widgets/loaded_sliver_fade_in.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/track_card.dart';

/// Wraps a child in a staggered fade-in + slide-up animation.
///
/// [index] controls the stagger delay (each item delayed by [staggerDelay]).
/// Set [animate] to false to skip the animation. Only the list's first
/// reveal animates: a lazy list builds rows again as they scroll into view,
/// and those appear at once, so no row replays it or animates while others
/// do not.
class StaggeredListItem extends StatelessWidget {
  static const int _maxAnimatedItems = 10;

  final int index;
  final Widget child;
  final Duration duration;
  final Duration staggerDelay;
  final bool animate;

  const StaggeredListItem({
    super.key,
    required this.index,
    required this.child,
    this.duration = const Duration(milliseconds: 250),
    this.staggerDelay = const Duration(milliseconds: 40),
    this.animate = true,
  });

  static bool _hasScrolled(ScrollableState? scrollable) {
    final position = scrollable?.position;
    return position != null &&
        position.hasContentDimensions &&
        position.pixels > position.minScrollExtent;
  }

  @override
  Widget build(BuildContext context) {
    if (!animate ||
        index >= _maxAnimatedItems ||
        context.isMornye ||
        MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    // A shelf scrolls sideways inside a page that builds its shelves lazily
    // while it scrolls down, so a moved page skips the reveal as well.
    final scrolled =
        _hasScrolled(Scrollable.maybeOf(context)) ||
        _hasScrolled(Scrollable.maybeOf(context, axis: Axis.vertical));
    if (scrolled) {
      return child;
    }
    final cappedIndex = index.clamp(0, _maxAnimatedItems - 1);
    final delay = MotionPace.duration(staggerDelay) * cappedIndex;
    // Expressive: each item springs up after its own delay and may
    // overshoot slightly, while its opacity follows the effects spring.
    final rise = AppMotion.spatial(
      context,
      AppMotionSpec(duration, Curves.easeOutCubic),
    );
    final fade = AppMotion.effectsFast(
      context,
      AppMotionSpec(duration, Curves.easeOutCubic),
    );
    final distance = materialExpressiveEnabled(context) ? 16.0 : 12.0;
    final span = rise.duration > fade.duration ? rise.duration : fade.duration;
    final total = (span + delay).inMicroseconds.toDouble();
    // The skeleton leaves in the frame these rows arrive, so the reveal
    // starts one frame in and the first row already shows.
    final start = math.min(
      loadedFadeFirstFrame.inMicroseconds.toDouble(),
      total,
    );
    double progress(double elapsed, Duration length) =>
        (elapsed / length.inMicroseconds).clamp(0.0, 1.0);

    return TweenAnimationBuilder<double>(
      key: ValueKey('stagger_$index'),
      tween: Tween(begin: start, end: total),
      duration: Duration(microseconds: (total - start).round()),
      builder: (context, time, child) {
        final elapsed = time - delay.inMicroseconds;
        final moved = rise.curve.transform(progress(elapsed, rise.duration));
        final opacity = fade.curve.transform(progress(elapsed, fade.duration));
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, distance * (1 - moved)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// Creates a platform-aware material route.
///
/// This intentionally defers route transitions to Flutter's material route and
/// theme so Android predictive back and platform-default animations remain
/// intact.
Route<T> slidePageRoute<T>({required Widget page}) {
  return SteadyPageRoute<T>(builder: (context) => page);
}

/// A shimmer effect widget that can wrap skeleton placeholders. Its sweep
/// advances on a [DecorativePhase], at most 30 times a second, like the
/// other continuous decorations.
class ShimmerLoading extends StatefulWidget {
  final Widget child;

  /// The surface the placeholders sit on; defaults to the page surface. Pass
  /// a card or group color so the placeholders keep their contrast on it.
  final Color? surface;

  const ShimmerLoading({super.key, required this.child, this.surface});

  @override
  State<ShimmerLoading> createState() => _ShimmerLoadingState();
}

class _ShimmerLoadingState extends State<ShimmerLoading>
    with WidgetsBindingObserver {
  final _phase = DecorativePhase(const Duration(milliseconds: 1200));
  bool _motionAllowed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motionAllowed =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _syncPhase();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _syncPhase();
  }

  void _syncPhase() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final resumed = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    if (_motionAllowed && resumed) {
      _phase.start();
    } else {
      _phase.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.surface == null
        ? widget.child
        : _SkeletonSurface(color: widget.surface!, child: widget.child);
    if (MediaQuery.disableAnimationsOf(context)) return content;
    final surface = widget.surface ?? Theme.of(context).colorScheme.surface;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final baseColor = isDark
        ? Color.alphaBlend(Colors.white.withValues(alpha: 0.08), surface)
        : Color.alphaBlend(Colors.black.withValues(alpha: 0.10), surface);
    final highlightColor = isDark
        ? Color.alphaBlend(Colors.white.withValues(alpha: 0.14), surface)
        : Color.alphaBlend(Colors.black.withValues(alpha: 0.01), surface);

    // Outer RepaintBoundary keeps 30Hz shimmer ticks from dirtying enclosing
    // grids/lists; inner RepaintBoundary keeps the static skeleton cached.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _phase,
        builder: (context, child) {
          final phase = _phase.value;
          return ShaderMask(
            shaderCallback: (bounds) {
              return LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [baseColor, highlightColor, baseColor],
                stops: [
                  (phase - 0.3).clamp(0.0, 1.0),
                  phase,
                  (phase + 0.3).clamp(0.0, 1.0),
                ],
                tileMode: TileMode.clamp,
              ).createShader(bounds);
            },
            blendMode: BlendMode.srcATop,
            child: child,
          );
        },
        // The mask moves every frame; the skeleton beneath it does not.
        child: RepaintBoundary(child: content),
      ),
    );
  }
}

/// The surface a [ShimmerLoading] declared, so still placeholders (reduced
/// motion) keep their contrast on a card or group as well.
class _SkeletonSurface extends InheritedWidget {
  const _SkeletonSurface({required this.color, required super.child});

  final Color color;

  static Color? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SkeletonSurface>()?.color;

  @override
  bool updateShouldNotify(_SkeletonSurface oldWidget) =>
      color != oldWidget.color;
}

/// A skeleton placeholder box used inside [ShimmerLoading].
class SkeletonBox extends StatelessWidget {
  final double width;
  final double height;
  final double borderRadius;

  const SkeletonBox({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius = 8,
  });

  static Color colorFor(BuildContext context) {
    final surface =
        _SkeletonSurface.maybeOf(context) ??
        Theme.of(context).colorScheme.surface;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark
        ? Color.alphaBlend(Colors.white.withValues(alpha: 0.08), surface)
        : Color.alphaBlend(Colors.black.withValues(alpha: 0.06), surface);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: colorFor(context),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }
}

/// Track list skeleton – mimics a list of track items while loading.
class TrackListSkeleton extends StatelessWidget {
  final int itemCount;

  /// Mornye only; Material loading screens show the real header.
  final bool showCoverHeader;

  /// The Material rows start below a collection header, as on a playlist
  /// page. A list under its own section title passes false.
  final bool underHeader;

  const TrackListSkeleton({
    super.key,
    this.itemCount = 8,
    this.showCoverHeader = false,
    this.underHeader = true,
  });

  @override
  Widget build(BuildContext context) {
    if (isDesktopPlatform) {
      return _DesktopTrackListSkeleton(itemCount: itemCount, showArtwork: true);
    }
    if (context.isMornye) {
      return ShimmerLoading(
        child: SingleChildScrollView(
          child: Column(
            children: [
              if (showCoverHeader)
                const _CollectionHeaderSkeleton(showSubtitle: false),
              for (var index = 0; index < itemCount; index++)
                _MornyeTrackSkeleton(
                  numbered: false,
                  index: index,
                  showPreview: true,
                ),
            ],
          ),
        ),
      );
    }
    return _MaterialTrackSkeletonRun(
      itemCount: itemCount,
      underHeader: underHeader,
      leading: const SkeletonBox(width: 48, height: 48, borderRadius: 8),
    );
  }
}

/// The Material song rows of a list that is loading: a connected run, inset
/// like the loaded list and, [underHeader], set off from a collection header.
class _MaterialTrackSkeletonRun extends StatelessWidget {
  const _MaterialTrackSkeletonRun({
    required this.itemCount,
    required this.leading,
    required this.underHeader,
  });

  final int itemCount;
  final Widget leading;
  final bool underHeader;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    physics: const NeverScrollableScrollPhysics(),
    padding: EdgeInsets.symmetric(
      horizontal: wideListInset(context),
    ).copyWith(top: underHeader ? collectionRunTopGap(context) : 0),
    child: Column(
      children: [
        for (var index = 0; index < itemCount; index++)
          _MaterialTrackSkeleton(
            index: index,
            count: itemCount,
            leading: leading,
          ),
      ],
    ),
  );
}

/// One Material track row as [TrackListTile] lays it out: a filled row of a
/// connected list with leading art or number, two text lines and the preview
/// and options buttons. Only the placeholders shimmer.
class _MaterialTrackSkeleton extends StatelessWidget {
  const _MaterialTrackSkeleton({
    required this.index,
    required this.count,
    required this.leading,
  });

  final int index;
  final int count;
  final Widget leading;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final first = index == 0;
    final last = index == count - 1;
    final fill = settingsGroupColor(context);
    return Container(
      // The margin, fill and corners of a [TrackCardSegment] row.
      margin: EdgeInsets.fromLTRB(
        tokens.gapLg,
        first ? tokens.gapXs : 1,
        tokens.gapLg,
        last ? tokens.gapXs : 1,
      ),
      padding: EdgeInsets.all(tokens.gapMd),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: connectedRowRadius(context, first: first, last: last),
      ),
      child: ShimmerLoading(
        surface: fill,
        child: Row(
          children: [
            leading,
            SizedBox(width: tokens.gapMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FractionallySizedBox(
                    alignment: AlignmentDirectional.centerStart,
                    widthFactor: 0.45 + (index % 3) * 0.1,
                    child: const SkeletonBox(
                      width: double.infinity,
                      height: 16,
                      borderRadius: 4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Flexible(
                        child: SkeletonBox(
                          width: 80 + (index % 2) * 24,
                          height: 13,
                          borderRadius: 4,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const SkeletonBox(width: 38, height: 13, borderRadius: 6),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(width: tokens.gapSm),
            // Preview and options icon buttons: 24dp glyphs in 48dp targets.
            const SizedBox(
              width: 48,
              child: Center(
                child: SkeletonBox(width: 24, height: 24, borderRadius: 12),
              ),
            ),
            const SizedBox(
              width: 48,
              child: Center(
                child: SkeletonBox(width: 6, height: 20, borderRadius: 3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Album track list skeleton – mimics the album screen track list layout
/// (track number + title + artist + trailing icon, no cover art thumbnail).
class AlbumTrackListSkeleton extends StatelessWidget {
  final int itemCount;
  final bool showQuality;

  /// Mornye only; Material loading screens show the real header.
  final bool showCoverHeader;

  const AlbumTrackListSkeleton({
    super.key,
    this.itemCount = 10,
    this.showCoverHeader = false,
    this.showQuality = false,
  });

  @override
  Widget build(BuildContext context) {
    if (isDesktopPlatform) {
      return _DesktopTrackListSkeleton(
        itemCount: itemCount,
        albumLayout: context.isMornye,
        showQuality: showQuality,
      );
    }
    if (context.isMornye) {
      return ShimmerLoading(
        child: SingleChildScrollView(
          child: Column(
            children: [
              if (showCoverHeader) const _CollectionHeaderSkeleton(),
              for (var index = 0; index < itemCount; index++)
                _MornyeTrackSkeleton(
                  numbered: true,
                  index: index,
                  showPreview: true,
                ),
            ],
          ),
        ),
      );
    }
    return _MaterialTrackSkeletonRun(
      itemCount: itemCount,
      underHeader: true,
      leading: const SizedBox(
        width: 32,
        child: Center(
          child: SkeletonBox(width: 16, height: 14, borderRadius: 4),
        ),
      ),
    );
  }
}

/// Uses the loaded desktop table's columns and row density. The collection
/// header is already visible above these rows, including in the Mornye style.
class _DesktopTrackListSkeleton extends StatelessWidget {
  const _DesktopTrackListSkeleton({
    required this.itemCount,
    this.showArtwork = false,
    this.albumLayout = false,
    this.showQuality = false,
  });

  final int itemCount;
  final bool showArtwork;
  final bool albumLayout;
  final bool showQuality;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final scaler = MediaQuery.textScalerOf(context);
    final style = Theme.of(context).textTheme.bodyMedium;
    final lineHeight =
        scaler.scale(style?.fontSize ?? 14) * (style?.height ?? 1.4);
    final columns = [
      TrackTableColumn.number,
      TrackTableColumn.title,
      TrackTableColumn.artist,
      if (showArtwork) TrackTableColumn.album,
      if (showQuality) TrackTableColumn.quality,
      TrackTableColumn.duration,
    ];

    Widget bar(double fraction, {bool end = false}) => Align(
      alignment: end
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: FractionallySizedBox(
        widthFactor: fraction,
        child: SkeletonBox(
          width: double.infinity,
          height: scaler.scale(12),
          borderRadius: 4,
        ),
      ),
    );

    Widget cell(TrackTableColumn column, int index, {bool header = false}) {
      final key = ValueKey(
        'track-table-skeleton-${header ? 'header' : index}-${column.name}',
      );
      if (!header && column == TrackTableColumn.title && showArtwork) {
        return Row(
          key: key,
          children: [
            const SkeletonBox(width: 32, height: 32, borderRadius: 4),
            const SizedBox(width: 10),
            Expanded(child: bar(0.6 + (index % 3) * 0.1)),
          ],
        );
      }
      return KeyedSubtree(
        key: key,
        child: bar(
          column == TrackTableColumn.number ? 0.25 : 0.55 + (index % 3) * 0.1,
          end: TrackTableLayout.alignEnd(column),
        ),
      );
    }

    Widget row(int index) {
      if (albumLayout) {
        return Padding(
          key: ValueKey('track-table-skeleton-row-$index'),
          padding: EdgeInsetsDirectional.only(start: tokens.gapXs),
          child: Row(
            children: [
              SizedBox(
                width: TrackTableLayout.albumNumber,
                child: bar(0.4, end: true),
              ),
              const SizedBox(width: TrackTableLayout.albumTitleGap),
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(
                    minHeight: TrackTableLayout.albumRowHeight,
                  ),
                  decoration: index == itemCount - 1
                      ? null
                      : BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: Theme.of(context)
                                  .colorScheme
                                  .outlineVariant
                                  .withValues(alpha: 0.6),
                              width: 0.5,
                            ),
                          ),
                        ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SizedBox(height: lineHeight, child: bar(0.6)),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: scaler.scale(32),
                        child: bar(1, end: true),
                      ),
                      SizedBox(width: 8 + 32 + tokens.gapXs),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }
      return Padding(
        key: ValueKey('track-table-skeleton-row-$index'),
        padding: EdgeInsets.symmetric(
          horizontal: tokens.gapXs * 2,
          vertical: 1,
        ),
        child: SizedBox(
          height: lineHeight > TrackTableLayout.rowMinHeightFor(context)
              ? lineHeight
              : TrackTableLayout.rowMinHeightFor(context),
          child: Row(
            children: TrackTableLayout.layout(
              columns: columns,
              hasTrailing: true,
              cell: (column) => cell(column, index),
            ),
          ),
        ),
      );
    }

    return ExcludeSemantics(
      child: ShimmerLoading(
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
            child: Column(
              children: [
                if (!albumLayout)
                  SizedBox(
                    height: TrackTableLayout.headerHeightFor(context),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: tokens.gapSm),
                      child: Row(
                        children: TrackTableLayout.layout(
                          columns: columns,
                          hasTrailing: true,
                          cell: (column) => cell(column, 0, header: true),
                        ),
                      ),
                    ),
                  ),
                for (var index = 0; index < itemCount; index++) row(index),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Mirrors Mornye's collection header: full-width square artwork and a
/// compact primary action between two circular controls. Material loading
/// screens show the real [AlbumDetailHeader] instead.
class _CollectionHeaderSkeleton extends StatelessWidget {
  const _CollectionHeaderSkeleton({this.showSubtitle = true});

  final bool showSubtitle;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final coverSize = constraints.maxWidth.clamp(0.0, 440.0);
        return Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Center(
                child: SizedBox(
                  width: coverSize,
                  height: coverSize,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0, 0.48, 1],
                        colors: [
                          SkeletonBox.colorFor(context),
                          SkeletonBox.colorFor(context),
                          SkeletonBox.colorFor(context).withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                (coverSize - 20).clamp(0.0, double.infinity),
                20,
                28,
              ),
              child: Column(
                children: [
                  const FractionallySizedBox(
                    widthFactor: 0.75,
                    child: SkeletonBox(
                      width: double.infinity,
                      height: 28,
                      borderRadius: 6,
                    ),
                  ),
                  if (showSubtitle) ...[
                    const SizedBox(height: 5),
                    const FractionallySizedBox(
                      widthFactor: 0.5,
                      child: SkeletonBox(
                        width: double.infinity,
                        height: 24,
                        borderRadius: 5,
                      ),
                    ),
                  ],
                  const SizedBox(height: 5),
                  const SkeletonBox(width: 140, height: 16, borderRadius: 4),
                  const SizedBox(height: 16),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      spacing: 16,
                      children: [
                        SkeletonBox(width: 44, height: 44, borderRadius: 22),
                        Flexible(
                          child: SkeletonBox(
                            width: 172,
                            height: 50,
                            borderRadius: 25,
                          ),
                        ),
                        SkeletonBox(width: 44, height: 44, borderRadius: 22),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Placeholders for the Material collection header's unloaded rows: artist,
/// meta and the action group (two circular buttons around the wide primary
/// action), sized like the real [AlbumDetailHeader] content.
class CollectionHeaderSkeletonRows {
  const CollectionHeaderSkeletonRows._();

  static Widget subtitle(BuildContext context) => ShimmerLoading(
    child: SkeletonBox(
      width: 140,
      height: MediaQuery.textScalerOf(
        context,
      ).scale(isDesktopPlatform ? 24 : 18),
      borderRadius: 4,
    ),
  );

  static Widget meta() => const ShimmerLoading(
    child: Wrap(
      spacing: 10,
      runSpacing: 6,
      children: [
        SkeletonBox(width: 40, height: 14, borderRadius: 6),
        SkeletonBox(width: 76, height: 14, borderRadius: 6),
        SkeletonBox(width: 84, height: 14, borderRadius: 6),
      ],
    ),
  );

  static Widget actions(BuildContext context) {
    if (isDesktopPlatform) {
      final target = context.isMornye ? 36.0 : 40.0;
      return ShimmerLoading(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: context.isMornye ? 10 : 8,
          children: [
            if (context.isMornye)
              SkeletonBox(
                width: target,
                height: target,
                borderRadius: target / 2,
              ),
            SkeletonBox(
              width: context.isMornye ? 130 : 112,
              height: context.isMornye ? 36 : 40,
              borderRadius: 20,
            ),
            SkeletonBox(
              width: target,
              height: target,
              borderRadius: target / 2,
            ),
            if (!context.isMornye)
              SkeletonBox(
                width: target,
                height: target,
                borderRadius: target / 2,
              ),
          ],
        ),
      );
    }
    final target = context.tokens.minTouchTarget;
    return ShimmerLoading(
      child: Row(
        spacing: 12,
        children: [
          SkeletonBox(width: target, height: target, borderRadius: target / 2),
          Expanded(
            child: SkeletonBox(
              width: double.infinity,
              height: target,
              borderRadius: target / 2,
            ),
          ),
          SkeletonBox(width: target, height: target, borderRadius: target / 2),
        ],
      ),
    );
  }
}

/// Mirrors the larger primary action and two smaller artist header actions.
class ArtistHeaderActionsSkeleton extends StatelessWidget {
  const ArtistHeaderActionsSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const Row(
    mainAxisAlignment: MainAxisAlignment.center,
    mainAxisSize: MainAxisSize.min,
    spacing: 24,
    children: [
      SkeletonBox(width: 50, height: 50, borderRadius: 25),
      SkeletonBox(width: 74, height: 74, borderRadius: 37),
      SkeletonBox(width: 50, height: 50, borderRadius: 25),
    ],
  );
}

/// Artist screen skeleton shown below the SliverAppBar header while the
/// discography loads: optional cover placeholder, "Popular" section, and the
/// horizontal album sections.
class ArtistScreenSkeleton extends StatelessWidget {
  static const int _popularCount = 5;

  final int albumCount;
  final bool showCoverHeader;
  final bool showPopularSection;

  const ArtistScreenSkeleton({
    super.key,
    this.albumCount = 5,
    this.showCoverHeader = true,
    this.showPopularSection = true,
  });

  @override
  Widget build(BuildContext context) {
    if (context.isMornye) {
      return ShimmerLoading(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showCoverHeader && !isDesktopPlatform)
                LayoutBuilder(
                  builder: (context, constraints) => Stack(
                    children: [
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              stops: const [0, 0.48, 1],
                              colors: [
                                SkeletonBox.colorFor(context),
                                SkeletonBox.colorFor(context),
                                SkeletonBox.colorFor(
                                  context,
                                ).withValues(alpha: 0),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          24,
                          (constraints.maxWidth * 0.76).clamp(240.0, 340.0) + 4,
                          24,
                          32,
                        ),
                        child: const Column(
                          children: [
                            Center(child: SkeletonBox(width: 220, height: 36)),
                            SizedBox(height: 16),
                            ArtistHeaderActionsSkeleton(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Row(
                    spacing: 14,
                    children: [
                      SkeletonBox(width: 76, height: 76, borderRadius: 5),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          spacing: 6,
                          children: [
                            SkeletonBox(width: 38, height: 12, borderRadius: 4),
                            FractionallySizedBox(
                              widthFactor: 0.9,
                              child: SkeletonBox(
                                width: double.infinity,
                                height: 18,
                                borderRadius: 4,
                              ),
                            ),
                            SkeletonBox(width: 62, height: 12, borderRadius: 4),
                          ],
                        ),
                      ),
                      SkeletonBox(width: 10, height: 14, borderRadius: 4),
                    ],
                  ),
                ),
              ),
              if (showPopularSection) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 24, 20, 12),
                  child: SkeletonBox(width: 110, height: 24, borderRadius: 4),
                ),
                for (var index = 0; index < _popularCount; index++)
                  _MornyeTrackSkeleton(numbered: false, index: index),
              ],
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 24, 20, 12),
                child: SkeletonBox(width: 120, height: 24, borderRadius: 4),
              ),
              _ArtistAlbumShelfSkeleton(itemCount: albumCount),
              const SizedBox(height: 24),
            ],
          ),
        ),
      );
    }
    // The Popular rows carry the fill of the loaded connected list, so each
    // part shimmers by itself and the fill stays still.
    Widget title(double width, EdgeInsetsGeometry padding) => ShimmerLoading(
      child: Padding(
        padding: padding,
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: SkeletonBox(width: width, height: 22, borderRadius: 4),
        ),
      ),
    );
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showCoverHeader && !isDesktopPlatform)
            ShimmerLoading(
              child: LayoutBuilder(
                builder: (context, constraints) => SkeletonBox(
                  width: constraints.maxWidth,
                  height: constraints.maxWidth * 0.75,
                  borderRadius: 0,
                ),
              ),
            ),
          if (showPopularSection) ...[
            title(
              110,
              const EdgeInsetsDirectional.fromSTEB(
                connectedRunTitleInset,
                24,
                16,
                12,
              ),
            ),
            for (var index = 0; index < _popularCount; index++)
              _MaterialPopularSkeleton(index: index, count: _popularCount),
            const SizedBox(height: 16),
          ],
          title(120, const EdgeInsets.fromLTRB(16, 8, 16, 12)),
          ShimmerLoading(
            child: _ArtistAlbumShelfSkeleton(itemCount: albumCount),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// One Material Popular row of the artist page: rank, cover, two text lines
/// and the options button on the fill of the loaded connected list.
class _MaterialPopularSkeleton extends StatelessWidget {
  const _MaterialPopularSkeleton({required this.index, required this.count});

  final int index;
  final int count;

  @override
  Widget build(BuildContext context) {
    final last = index == count - 1;
    final fill = settingsGroupColor(context);
    return Container(
      margin: EdgeInsets.fromLTRB(16, 0, 16, last ? 0 : 2),
      padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: connectedRowRadius(
          context,
          first: index == 0,
          last: last,
        ),
      ),
      child: ShimmerLoading(
        surface: fill,
        child: Row(
          children: [
            const SizedBox(
              width: 24,
              child: Center(
                child: SkeletonBox(width: 12, height: 14, borderRadius: 4),
              ),
            ),
            const SizedBox(width: 12),
            const SkeletonBox(width: 48, height: 48, borderRadius: 4),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(
                    width: 120 + (index % 4) * 30,
                    height: 14,
                    borderRadius: 4,
                  ),
                  const SizedBox(height: 8),
                  const SkeletonBox(width: 64, height: 14, borderRadius: 4),
                ],
              ),
            ),
            // The options button: a 20dp glyph in a 48dp target.
            const SizedBox(
              width: 48,
              child: Center(
                child: SkeletonBox(width: 6, height: 20, borderRadius: 3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtistAlbumShelfSkeleton extends StatelessWidget {
  const _ArtistAlbumShelfSkeleton({required this.itemCount});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    final tileSize = artistAlbumTileSize(context);
    final scaler = MediaQuery.textScalerOf(context);
    return SizedBox(
      height: artistAlbumSectionHeight(context),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: itemCount,
        itemBuilder: (_, index) => Container(
          width: tileSize,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBox(width: tileSize, height: tileSize, borderRadius: 8),
              const SizedBox(height: 8),
              SkeletonBox(
                width: tileSize * (0.6 + (index % 3) * 0.1),
                height: scaler.scale(14),
                borderRadius: 4,
              ),
              const SizedBox(height: 2),
              SkeletonBox(
                width: tileSize * 0.4,
                height: scaler.scale(12),
                borderRadius: 4,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MornyeTrackSkeleton extends StatelessWidget {
  const _MornyeTrackSkeleton({
    required this.numbered,
    required this.index,
    this.showPreview = false,
  });

  final bool numbered;
  final int index;
  final bool showPreview;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              if (numbered)
                const SizedBox(
                  width: 32,
                  child: Center(
                    child: SkeletonBox(width: 14, height: 16, borderRadius: 4),
                  ),
                )
              else
                const SkeletonBox(width: 48, height: 48, borderRadius: 4),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FractionallySizedBox(
                      widthFactor: 0.7 + (index % 3) * 0.1,
                      child: const SkeletonBox(
                        width: double.infinity,
                        height: 18,
                        borderRadius: 4,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const FractionallySizedBox(
                      widthFactor: 0.5,
                      child: SkeletonBox(
                        width: double.infinity,
                        height: 14,
                        borderRadius: 4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              if (showPreview) ...[
                const SkeletonBox(width: 20, height: 20, borderRadius: 10),
                const SizedBox(width: 24),
              ],
              const SkeletonBox(width: 20, height: 6, borderRadius: 3),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsetsDirectional.only(
            start: numbered ? 64 : 80,
            end: 20,
          ),
          child: const Divider(height: 1, thickness: 0.5),
        ),
      ],
    );
  }
}

/// The loaded search layout a [HomeSearchSkeleton] stands in for.
enum HomeSearchSkeletonLayout {
  /// Phone rows: an Artists section of avatars, then Albums.
  rows,

  /// A wide song, album or playlist filter: a grid of covers.
  coverGrid,

  /// A wide artist filter: a grid of avatars.
  artistGrid,

  /// The wide All view: a song shelf, then an artist and an album shelf.
  overview,
}

/// Home search skeleton – mimics the sectioned results (an Artists section of
/// round avatars, then an Albums section of covers). The real filter chips
/// stay visible above it, so it draws none of its own. Wide layouts mirror
/// their cover grids and shelves instead.
class HomeSearchSkeleton extends StatelessWidget {
  const HomeSearchSkeleton({
    super.key,
    this.layout = HomeSearchSkeletonLayout.rows,
  });

  final HomeSearchSkeletonLayout layout;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: switch (layout) {
        HomeSearchSkeletonLayout.rows => [
          _sectionSkeleton(context, 70, 2, round: true),
          const SizedBox(height: 8),
          _sectionSkeleton(context, 65, 4, round: false),
        ],
        HomeSearchSkeletonLayout.coverGrid => [
          _headerSkeleton(context, 65),
          _CoverGridSkeleton(round: false),
        ],
        HomeSearchSkeletonLayout.artistGrid => [
          _headerSkeleton(context, 70),
          _CoverGridSkeleton(round: true),
        ],
        HomeSearchSkeletonLayout.overview => [
          _headerSkeleton(context, 60),
          if (context.isMornye)
            const _TopResultsSkeleton()
          else
            const _CoverShelfSkeleton(round: false),
          _headerSkeleton(context, 70),
          const _CoverShelfSkeleton(round: true),
          _headerSkeleton(context, 65),
          const _CoverShelfSkeleton(round: false),
        ],
      },
    );
  }

  /// A section title and its trailing action, inset like the loaded header.
  static Widget _headerSkeleton(BuildContext context, double width) {
    return Padding(
      padding:
          (context.isMornye
                  ? const EdgeInsetsDirectional.fromSTEB(20, 16, 12, 10)
                  : const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8))
              .add(EdgeInsets.symmetric(horizontal: wideListInset(context))),
      child: ShimmerLoading(
        child: Row(
          children: [
            SkeletonBox(width: width, height: 16, borderRadius: 4),
            const Spacer(),
            const SkeletonBox(width: 50, height: 14, borderRadius: 4),
          ],
        ),
      ),
    );
  }

  /// One section: its header and a grouped list centered like the results.
  /// Only the placeholders shimmer; the group keeps the results' surface.
  static Widget _sectionSkeleton(
    BuildContext context,
    double headerWidth,
    int itemCount, {
    required bool round,
  }) {
    final mornye = context.isMornye;
    final colorScheme = Theme.of(context).colorScheme;
    final inset = wideListInset(context);
    final rows = List.generate(itemCount, (index) {
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: mornye ? 12 : 16,
          vertical: context.tokens.trackRowPaddingV,
        ),
        child: Row(
          children: [
            SkeletonBox(width: 56, height: 56, borderRadius: round ? 28 : 8),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(
                    width: 100 + (index % 3) * 40,
                    height: 14,
                    borderRadius: 4,
                  ),
                  const SizedBox(height: 6),
                  SkeletonBox(
                    width: 60 + (index % 2) * 25,
                    height: 12,
                    borderRadius: 4,
                  ),
                ],
              ),
            ),
            if (!mornye)
              const SkeletonBox(width: 10, height: 16, borderRadius: 4),
          ],
        ),
      );
    });
    // Material uses the result groups' own container tier; Mornye's glass
    // results keep a faint neutral wash.
    final groupColor = mornye
        ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.3)
        : colorScheme.surfaceContainer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _headerSkeleton(context, headerWidth),
        if (mornye)
          Container(
            margin: EdgeInsets.symmetric(horizontal: 16 + inset),
            decoration: BoxDecoration(
              color: groupColor,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              children: [
                for (var index = 0; index < rows.length; index++) ...[
                  if (index > 0)
                    const Divider(height: 1, indent: 80, endIndent: 12),
                  ShimmerLoading(surface: groupColor, child: rows[index]),
                ],
              ],
            ),
          )
        else
          // Matches the connected result list: one surface per row.
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16 + inset),
            child: Column(
              children: [
                for (var index = 0; index < rows.length; index++) ...[
                  if (index > 0) const SizedBox(height: 2),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: groupColor,
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(index == 0 ? 20 : 4),
                        bottom: Radius.circular(
                          index == rows.length - 1 ? 20 : 4,
                        ),
                      ),
                    ),
                    child: ShimmerLoading(
                      surface: groupColor,
                      child: rows[index],
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// One search result cover with its title and subtitle lines.
class _CoverCellSkeleton extends StatelessWidget {
  const _CoverCellSkeleton({
    required this.extent,
    required this.round,
    required this.index,
  });

  final double extent;
  final bool round;
  final int index;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return Column(
      crossAxisAlignment: round
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        SkeletonBox(
          width: extent,
          height: extent,
          borderRadius: round ? extent / 2 : (context.isMornye ? 8 : 12),
        ),
        const SizedBox(height: 8),
        SkeletonBox(
          width: extent * (0.6 + (index % 3) * 0.1),
          height: scaler.scale(14),
          borderRadius: 4,
        ),
        const SizedBox(height: 4),
        SkeletonBox(
          width: extent * 0.4,
          height: scaler.scale(12),
          borderRadius: 4,
        ),
      ],
    );
  }
}

/// Two rows of the search result cover grid, with its columns.
class _CoverGridSkeleton extends StatelessWidget {
  const _CoverGridSkeleton({required this.round});

  final bool round;

  @override
  Widget build(BuildContext context) {
    final edge = searchCoverEdge(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: edge),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = searchCoverGridColumns(constraints.maxWidth);
          final extent = searchCoverGridExtent(constraints.maxWidth);
          final height = extent + searchCoverTextHeight(context);
          return ExcludeSemantics(
            child: ShimmerLoading(
              child: Column(
                children: [
                  for (var row = 0; row < 2; row++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: searchCoverGap),
                      child: SizedBox(
                        height: height,
                        child: Row(
                          spacing: searchCoverGap,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (var column = 0; column < columns; column++)
                              _CoverCellSkeleton(
                                extent: extent,
                                round: round,
                                index: row * columns + column,
                              ),
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
    );
  }
}

/// A search result shelf of covers.
class _CoverShelfSkeleton extends StatelessWidget {
  const _CoverShelfSkeleton({required this.round});

  final bool round;

  @override
  Widget build(BuildContext context) {
    final edge = searchCoverEdge(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final extent = searchShelfExtentFor(
          context,
          constraints.maxWidth,
          round: round,
        );
        return SizedBox(
          height: extent + searchCoverTextHeight(context) + 8,
          child: ExcludeSemantics(
            child: ShimmerLoading(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.symmetric(horizontal: edge),
                itemCount: 8,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: searchCoverGap),
                itemBuilder: (_, index) => SizedBox(
                  width: extent,
                  child: _CoverCellSkeleton(
                    extent: extent,
                    round: round,
                    index: index,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Mornye's mixed result preview cards while the search loads.
class _TopResultsSkeleton extends StatelessWidget {
  const _TopResultsSkeleton();

  @override
  Widget build(BuildContext context) {
    final edge = searchCoverEdge(context);
    final fill = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.08);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: edge),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = searchTopResultColumns(constraints.maxWidth);
          final height = MediaQuery.textScalerOf(
            context,
          ).scale(searchTopResultHeight);
          return ExcludeSemantics(
            child: Column(
              spacing: searchCoverGap,
              children: [
                for (var row = 0; row < 2; row++)
                  Row(
                    spacing: searchCoverGap,
                    children: [
                      for (var column = 0; column < columns; column++)
                        Expanded(
                          child: Container(
                            height: height,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              color: fill,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            alignment: AlignmentDirectional.centerStart,
                            child: const ShimmerLoading(
                              child: SkeletonBox(
                                width: 42,
                                height: 42,
                                borderRadius: 5,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Crossfades when the child's runtime type changes: used to swap a loading
/// skeleton for the loaded screen without a single-frame hard cut.
class SkeletonCrossfade extends StatelessWidget {
  final Widget child;

  const SkeletonCrossfade({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    // A dissolve, so it stays with reduced motion as well.
    final fade = AppMotion.effects(
      context,
      const AppMotionSpec(Duration(milliseconds: 250), Curves.linear),
    );
    return AnimatedSwitcher(
      duration: fade.duration,
      switchInCurve: fade.curve,
      switchOutCurve: fade.leaving,
      // Loading and loaded screens may carry the same Hero tag (both render
      // the header cover); mute the outgoing child's heroes so a pop during
      // the fade doesn't find duplicate tags.
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: AnimatedBuilder(
          animation: animation,
          child: child,
          builder: (context, child) => HeroMode(
            enabled:
                animation.status == AnimationStatus.forward ||
                animation.status == AnimationStatus.completed,
            child: child!,
          ),
        ),
      ),
      child: child,
    );
  }
}

/// An animated selection indicator that crossfades the checked/unchecked
/// state.
class AnimatedSelectionCheckbox extends StatelessWidget {
  final bool selected;
  final ColorScheme colorScheme;
  final double size;

  /// Background color when not selected. Defaults to `Colors.transparent`.
  final Color? unselectedColor;

  const AnimatedSelectionCheckbox({
    super.key,
    required this.selected,
    required this.colorScheme,
    this.size = 20,
    this.unselectedColor,
  });

  @override
  Widget build(BuildContext context) {
    final fill = AppMotion.effectsFast(
      context,
      const AppMotionSpec(Duration(milliseconds: 200), Curves.linear),
    );
    final tick = AppMotion.effectsFast(
      context,
      const AppMotionSpec(Duration(milliseconds: 150), Curves.linear),
    );
    return AnimatedContainer(
      duration: fill.duration,
      curve: fill.curve,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: selected
            ? colorScheme.primary
            : unselectedColor ?? Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? colorScheme.primary : colorScheme.outline,
          width: 2,
        ),
      ),
      child: AnimatedSwitcher(
        duration: tick.duration,
        switchInCurve: tick.curve,
        switchOutCurve: tick.leaving,
        child: selected
            ? Icon(
                Icons.check,
                key: const ValueKey('checked'),
                size: size - 6,
                color: colorScheme.onPrimary,
              )
            : SizedBox(
                key: const ValueKey('unchecked'),
                width: size - 6,
                height: size - 6,
              ),
      ),
    );
  }
}

/// Wraps a [Badge] child and plays a brief scale-bump whenever [count] grows.
///
/// The bump is a push on a spring at rest at scale 1: it rises to about
/// 1.15 and settles back, on Material's fast spatial spring (which dips
/// slightly below 1 on the way) or on Mornye's fast spring (which does
/// not). A count that grows again mid-bump pushes from the scale and speed
/// on screen instead of starting over. Reduced motion shows the new count
/// without one.
class AnimatedBadge extends StatefulWidget {
  final int count;
  final Widget child;

  const AnimatedBadge({super.key, required this.count, required this.child});

  /// How far above 1 a bump from rest reaches.
  static const bumpHeight = 0.15;

  @override
  State<AnimatedBadge> createState() => _AnimatedBadgeState();
}

class _AnimatedBadgeState extends State<AnimatedBadge>
    with SingleTickerProviderStateMixin {
  static final _materialSpring = M3EMotion.expressiveSpatialFast
      .toDescription();

  /// The push of each style's spring, by Animation speed: a slower spring
  /// reaches the same height on a gentler push.
  static final _pushes = <(bool mornye, double timeScale), double>{};

  /// The speed, in scale units a second, at which a push from rest on
  /// [spring] peaks at [AnimatedBadge.bumpHeight].
  static double _pushFor(SpringDescription spring) {
    final probe = SpringSimulation(spring, 0, 0, 1);
    var peak = 0.0;
    for (var t = 0.0; t < 1; t += 1 / 1000) {
      peak = math.max(peak, probe.x(t));
    }
    return AnimatedBadge.bumpHeight / peak;
  }

  // The controller holds the scale itself; at rest it is 1.
  late final AnimationController _controller = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  int _previousCount = 0;

  @override
  void initState() {
    super.initState();
    _previousCount = widget.count;
  }

  @override
  void didUpdateWidget(AnimatedBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.count > _previousCount &&
        !MediaQuery.disableAnimationsOf(context)) {
      final mornye = context.isMornye;
      final spring = mornye
          ? MornyeMotion.fastSpring
          : MotionPace.spring(_materialSpring);
      final push = _pushes[(mornye, MotionPace.timeScale)] ??= _pushFor(spring);
      // A badge already rising faster than a push keeps its speed.
      _controller.animateWith(
        SpringSimulation(
          spring,
          _controller.value,
          1,
          math.max(_controller.velocity, push),
          // Rests at exactly 1, so the badge is not left a hair off scale.
          snapToEnd: true,
        ),
      );
    }
    _previousCount = widget.count;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(scale: _controller, child: widget.child);
  }
}
