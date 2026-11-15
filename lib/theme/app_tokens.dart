import 'package:material_ui/material_ui.dart';

/// Single source of truth for the app's visual scale.
///
/// Reusable radii, spacing, artwork metrics and motion durations belong here.
///
/// Read it through [AppTokensContext.tokens] rather than
/// `Theme.of(context).extension<AppTokens>()`, so a widget rendered outside a
/// themed subtree (tests, isolated previews) still gets [AppTokens.standard].
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.radiusBadge,
    required this.radiusThumb,
    required this.radiusCover,
    required this.radiusControl,
    required this.radiusCard,
    required this.radiusSheet,
    required this.gapXs,
    required this.gapSm,
    required this.gapMd,
    required this.gapLg,
    required this.gapXl,
    required this.coverMini,
    required this.coverCompact,
    required this.coverList,
    required this.badgeFontSize,
    required this.badgePadding,
    required this.minTouchTarget,
    required this.headerExpandedHeight,
    required this.headerCollapsedTitleSize,
    required this.headerExpandedTitleSize,
    required this.motionFast,
    required this.motionMedium,
    required this.motionSlow,
    this.rowPaddingH = 20,
    this.rowPaddingV = 16,
    this.rowPaddingVCompact = 12,
    this.rowIconGap = 16,
    this.rowIconDividerIndent = 56,
    this.rowChevronSize = 24,
    this.rowMinHeight = 0,
    this.trackRowPaddingV = 10,
    this.headerSubtitleSize = 16,
    this.lyricsLineHeight = 1.4,
    this.lyricsLinePaddingV = 10,
    this.playerControlGap = 20,
    this.dialogInsetH = 40,
  });

  /// The values every theme in the app uses today. Kept as the single
  /// definition so a future "compact"/"expressive" theme only overrides the
  /// handful of tokens it actually changes.
  static const AppTokens standard = AppTokens(
    radiusBadge: 6,
    radiusThumb: 8,
    radiusCover: 12,
    radiusControl: 16,
    radiusCard: 20,
    radiusSheet: 28,
    gapXs: 4,
    gapSm: 8,
    gapMd: 12,
    gapLg: 16,
    gapXl: 24,
    coverMini: 44,
    coverCompact: 48,
    coverList: 56,
    badgeFontSize: 11,
    badgePadding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    minTouchTarget: 48,
    headerExpandedHeight: 120,
    headerCollapsedTitleSize: 20,
    headerExpandedTitleSize: 28,
    motionFast: Duration(milliseconds: 150),
    motionMedium: Duration(milliseconds: 250),
    motionSlow: Duration(milliseconds: 400),
  );

  /// Material on desktop. Pointer input needs less row height than touch, so
  /// rows, row artwork and the page header tighten (M3 density -2) while
  /// radii, motion and the 48dp control target stay the same. Mornye registers
  /// its own copy of the tokens and is unaffected.
  static final AppTokens desktop = standard.copyWith(
    coverCompact: 40,
    coverList: 44,
    headerExpandedHeight: 96,
    rowPaddingH: 16,
    rowPaddingV: 10,
    rowPaddingVCompact: 6,
    rowIconGap: 12,
    rowIconDividerIndent: 52,
    rowChevronSize: 20,
    trackRowPaddingV: 6,
  );

  /// Quality/source pills and other inline chips drawn inside dense rows.
  final double radiusBadge;

  /// Small square artwork in list rows and grid cells.
  final double radiusThumb;

  /// Large artwork: detail headers, now playing, grid covers.
  final double radiusCover;

  /// Buttons, text fields and other interactive controls. Matches the radius
  /// already baked into [ThemeData.filledButtonTheme] and friends.
  final double radiusControl;

  /// Grouped containers: settings groups, section cards, info cards.
  final double radiusCard;

  /// Modal bottom sheets and the search fields styled to match them.
  final double radiusSheet;

  final double gapXs;
  final double gapSm;
  final double gapMd;
  final double gapLg;
  final double gapXl;

  /// Mini player artwork.
  final double coverMini;

  /// Dense rows (album track lists, pickers).
  final double coverCompact;

  /// Standard list row artwork.
  final double coverList;

  /// Floor for badge text. Anything smaller stops being legible at the default
  /// system font scale.
  final double badgeFontSize;

  final EdgeInsets badgePadding;

  /// Material's minimum interactive size. Applied to icon buttons and pills
  /// that were previously shrunk to 28-32dp.
  final double minTouchTarget;

  /// Expanded height of the collapsing headers shared by the tab roots and the
  /// settings-style sub-pages.
  final double headerExpandedHeight;

  final double headerCollapsedTitleSize;

  /// Material 3 large top app bar headline size used by collapsing headers.
  final double headerExpandedTitleSize;

  final Duration motionFast;
  final Duration motionMedium;
  final Duration motionSlow;

  /// Horizontal inset of settings-style rows; also their divider end indent.
  final double rowPaddingH;

  /// Vertical inset of tappable settings rows.
  final double rowPaddingV;

  /// Vertical inset of rows that already carry a tall trailing control
  /// (switches).
  final double rowPaddingVCompact;

  /// Space between a row's leading icon and its text.
  final double rowIconGap;

  /// Divider start indent for rows with a leading icon, so the line starts
  /// under the text instead of under the icon.
  final double rowIconDividerIndent;

  /// Disclosure chevron shown on navigable rows.
  final double rowChevronSize;

  /// Minimum content height of a settings row.
  final double rowMinHeight;

  /// Vertical inset of track rows in feeds, search results and their
  /// loading skeletons.
  final double trackRowPaddingV;

  /// Artist line under the title in album/collection headers.
  final double headerSubtitleSize;

  /// Line height multiplier for synced lyrics.
  final double lyricsLineHeight;

  /// Vertical space around each synced lyric line.
  final double lyricsLinePaddingV;

  /// Gap between the previous / play / next transport controls.
  final double playerControlGap;

  /// Horizontal screen inset of app dialogs.
  final double dialogInsetH;

  BorderRadius get borderRadiusBadge => BorderRadius.circular(radiusBadge);
  BorderRadius get borderRadiusThumb => BorderRadius.circular(radiusThumb);
  BorderRadius get borderRadiusCover => BorderRadius.circular(radiusCover);
  BorderRadius get borderRadiusCard => BorderRadius.circular(radiusCard);

  /// Top-rounded shape for modal bottom sheets.
  RoundedRectangleBorder get sheetShape => RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(radiusSheet)),
  );

  @override
  AppTokens copyWith({
    double? radiusBadge,
    double? radiusThumb,
    double? radiusCover,
    double? radiusControl,
    double? radiusCard,
    double? radiusSheet,
    double? gapXs,
    double? gapSm,
    double? gapMd,
    double? gapLg,
    double? gapXl,
    double? coverMini,
    double? coverCompact,
    double? coverList,
    double? badgeFontSize,
    EdgeInsets? badgePadding,
    double? minTouchTarget,
    double? headerExpandedHeight,
    double? headerCollapsedTitleSize,
    double? headerExpandedTitleSize,
    Duration? motionFast,
    Duration? motionMedium,
    Duration? motionSlow,
    double? rowPaddingH,
    double? rowPaddingV,
    double? rowPaddingVCompact,
    double? rowIconGap,
    double? rowIconDividerIndent,
    double? rowChevronSize,
    double? rowMinHeight,
    double? trackRowPaddingV,
    double? headerSubtitleSize,
    double? lyricsLineHeight,
    double? lyricsLinePaddingV,
    double? playerControlGap,
    double? dialogInsetH,
  }) {
    return AppTokens(
      radiusBadge: radiusBadge ?? this.radiusBadge,
      radiusThumb: radiusThumb ?? this.radiusThumb,
      radiusCover: radiusCover ?? this.radiusCover,
      radiusControl: radiusControl ?? this.radiusControl,
      radiusCard: radiusCard ?? this.radiusCard,
      radiusSheet: radiusSheet ?? this.radiusSheet,
      gapXs: gapXs ?? this.gapXs,
      gapSm: gapSm ?? this.gapSm,
      gapMd: gapMd ?? this.gapMd,
      gapLg: gapLg ?? this.gapLg,
      gapXl: gapXl ?? this.gapXl,
      coverMini: coverMini ?? this.coverMini,
      coverCompact: coverCompact ?? this.coverCompact,
      coverList: coverList ?? this.coverList,
      badgeFontSize: badgeFontSize ?? this.badgeFontSize,
      badgePadding: badgePadding ?? this.badgePadding,
      minTouchTarget: minTouchTarget ?? this.minTouchTarget,
      headerExpandedHeight: headerExpandedHeight ?? this.headerExpandedHeight,
      headerCollapsedTitleSize:
          headerCollapsedTitleSize ?? this.headerCollapsedTitleSize,
      headerExpandedTitleSize:
          headerExpandedTitleSize ?? this.headerExpandedTitleSize,
      motionFast: motionFast ?? this.motionFast,
      motionMedium: motionMedium ?? this.motionMedium,
      motionSlow: motionSlow ?? this.motionSlow,
      rowPaddingH: rowPaddingH ?? this.rowPaddingH,
      rowPaddingV: rowPaddingV ?? this.rowPaddingV,
      rowPaddingVCompact: rowPaddingVCompact ?? this.rowPaddingVCompact,
      rowIconGap: rowIconGap ?? this.rowIconGap,
      rowIconDividerIndent: rowIconDividerIndent ?? this.rowIconDividerIndent,
      rowChevronSize: rowChevronSize ?? this.rowChevronSize,
      rowMinHeight: rowMinHeight ?? this.rowMinHeight,
      trackRowPaddingV: trackRowPaddingV ?? this.trackRowPaddingV,
      headerSubtitleSize: headerSubtitleSize ?? this.headerSubtitleSize,
      lyricsLineHeight: lyricsLineHeight ?? this.lyricsLineHeight,
      lyricsLinePaddingV: lyricsLinePaddingV ?? this.lyricsLinePaddingV,
      playerControlGap: playerControlGap ?? this.playerControlGap,
      dialogInsetH: dialogInsetH ?? this.dialogInsetH,
    );
  }

  @override
  AppTokens lerp(covariant AppTokens? other, double t) {
    if (other == null) return this;
    return AppTokens(
      radiusBadge: lerpDouble(radiusBadge, other.radiusBadge, t),
      radiusThumb: lerpDouble(radiusThumb, other.radiusThumb, t),
      radiusCover: lerpDouble(radiusCover, other.radiusCover, t),
      radiusControl: lerpDouble(radiusControl, other.radiusControl, t),
      radiusCard: lerpDouble(radiusCard, other.radiusCard, t),
      radiusSheet: lerpDouble(radiusSheet, other.radiusSheet, t),
      gapXs: lerpDouble(gapXs, other.gapXs, t),
      gapSm: lerpDouble(gapSm, other.gapSm, t),
      gapMd: lerpDouble(gapMd, other.gapMd, t),
      gapLg: lerpDouble(gapLg, other.gapLg, t),
      gapXl: lerpDouble(gapXl, other.gapXl, t),
      coverMini: lerpDouble(coverMini, other.coverMini, t),
      coverCompact: lerpDouble(coverCompact, other.coverCompact, t),
      coverList: lerpDouble(coverList, other.coverList, t),
      badgeFontSize: lerpDouble(badgeFontSize, other.badgeFontSize, t),
      badgePadding:
          EdgeInsets.lerp(badgePadding, other.badgePadding, t) ?? badgePadding,
      minTouchTarget: lerpDouble(minTouchTarget, other.minTouchTarget, t),
      headerExpandedHeight: lerpDouble(
        headerExpandedHeight,
        other.headerExpandedHeight,
        t,
      ),
      headerCollapsedTitleSize: lerpDouble(
        headerCollapsedTitleSize,
        other.headerCollapsedTitleSize,
        t,
      ),
      headerExpandedTitleSize: lerpDouble(
        headerExpandedTitleSize,
        other.headerExpandedTitleSize,
        t,
      ),
      motionFast: t < 0.5 ? motionFast : other.motionFast,
      motionMedium: t < 0.5 ? motionMedium : other.motionMedium,
      motionSlow: t < 0.5 ? motionSlow : other.motionSlow,
      rowPaddingH: lerpDouble(rowPaddingH, other.rowPaddingH, t),
      rowPaddingV: lerpDouble(rowPaddingV, other.rowPaddingV, t),
      rowPaddingVCompact: lerpDouble(
        rowPaddingVCompact,
        other.rowPaddingVCompact,
        t,
      ),
      rowIconGap: lerpDouble(rowIconGap, other.rowIconGap, t),
      rowIconDividerIndent: lerpDouble(
        rowIconDividerIndent,
        other.rowIconDividerIndent,
        t,
      ),
      rowChevronSize: lerpDouble(rowChevronSize, other.rowChevronSize, t),
      rowMinHeight: lerpDouble(rowMinHeight, other.rowMinHeight, t),
      trackRowPaddingV: lerpDouble(trackRowPaddingV, other.trackRowPaddingV, t),
      headerSubtitleSize: lerpDouble(
        headerSubtitleSize,
        other.headerSubtitleSize,
        t,
      ),
      lyricsLineHeight: lerpDouble(lyricsLineHeight, other.lyricsLineHeight, t),
      lyricsLinePaddingV: lerpDouble(
        lyricsLinePaddingV,
        other.lyricsLinePaddingV,
        t,
      ),
      playerControlGap: lerpDouble(playerControlGap, other.playerControlGap, t),
      dialogInsetH: lerpDouble(dialogInsetH, other.dialogInsetH, t),
    );
  }

  static double lerpDouble(double a, double b, double t) => a + (b - a) * t;
}

extension AppTokensContext on BuildContext {
  /// The active [AppTokens]. Falls back to [AppTokens.standard] when the widget
  /// is built outside a theme that registered the extension.
  AppTokens get tokens =>
      Theme.of(this).extension<AppTokens>() ?? AppTokens.standard;
}
