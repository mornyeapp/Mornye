import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_3_expressive/material_3_expressive.dart'
    show M3EShapeKind;
import 'package:share_plus/share_plus.dart' show ShareParams, SharePlus, XFile;
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/listening_rewind_provider.dart';
import 'package:mornye/services/listening_rewind.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/widget_capture.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_shape.dart';
import 'package:mornye/widgets/decorative_phase.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/settled_blur.dart';

export 'package:mornye/providers/listening_rewind_provider.dart';

part 'listening_rewind_story.dart';
part 'listening_rewind_slides.dart';
part 'listening_rewind_widgets.dart';

String listeningRewindPeriodLabel(
  BuildContext context,
  ListeningRewindPeriod period,
) => switch (period) {
  ListeningRewindPeriod.weeks => context.l10n.listeningRewindLastWeeks(4),
  ListeningRewindPeriod.quarter => context.l10n.listeningRewindLastMonths(3),
  ListeningRewindPeriod.halfYear => context.l10n.listeningRewindLastMonths(6),
  ListeningRewindPeriod.year => context.l10n.listeningRewindThisYear(
    DateTime.now().year,
  ),
};

/// Asks for a window, then plays its Rewind.
Future<void> showListeningRewind(BuildContext context) async {
  const icons = {
    ListeningRewindPeriod.weeks: Icons.today,
    ListeningRewindPeriod.quarter: Icons.date_range,
    ListeningRewindPeriod.halfYear: Icons.event_outlined,
    ListeningRewindPeriod.year: Icons.auto_awesome,
  };
  // Opened from the Library tab: the sheet and the story cover the shell
  // chrome instead of sliding beneath the tab bar and mini player.
  final period = await showAppBottomSheet<ListeningRewindPeriod>(
    context: context,
    useRootNavigator: true,
    title: context.l10n.listeningRewindChoosePeriod,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(bottom: sheetContext.tokens.gapLg),
      child: SettingsGroup(
        children: [
          for (final period in ListeningRewindPeriod.values)
            SettingsItem(
              icon: icons[period],
              showIconInMornye: true,
              title: listeningRewindPeriodLabel(sheetContext, period),
              showDivider: period != ListeningRewindPeriod.values.last,
              onTap: () => Navigator.pop(sheetContext, period),
            ),
        ],
      ),
    ),
  );
  if (period == null || !context.mounted) return;
  await openListeningRewind(context, period);
}

/// Plays the Rewind of [period] above the shell chrome.
Future<void> openListeningRewind(
  BuildContext context,
  ListeningRewindPeriod period,
) => Navigator.of(context, rootNavigator: true).push(
  MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => ListeningRewindScreen(period: period),
  ),
);

/// The permanent way in, on the listening statistics screen: a row that asks
/// for any window.
class ListeningRewindEntry extends StatelessWidget {
  const ListeningRewindEntry({super.key});

  @override
  Widget build(BuildContext context) => SettingsGroup(
    children: [
      SettingsItem(
        icon: Icons.auto_awesome,
        showIconInMornye: true,
        title: context.l10n.listeningRewind,
        subtitle: context.l10n.listeningRewindDescription,
        showDivider: false,
        onTap: () => showListeningRewind(context),
      ),
    ],
  );
}

/// The Library's seasonal Rewind banner. It shows only while
/// [listeningRewindSpotlightProvider] has a Rewind to offer and opens that
/// window directly.
class ListeningRewindBanner extends ConsumerWidget {
  const ListeningRewindBanner({super.key, this.margin});

  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spotlight = ref.watch(listeningRewindSpotlightProvider).value;
    final child = switch (spotlight) {
      null => null,
      ListeningRewindSpotlight.monthly => _MonthlyRewindBanner(margin: margin),
      ListeningRewindSpotlight.yearly => _YearlyRewindBanner(margin: margin),
    };
    // Grows in rather than shifting the list when the check completes.
    return AnimatedSize(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: child ?? const SizedBox(width: double.infinity),
    );
  }
}

/// The four-weekly invitation: a quiet tonal card.
class _MonthlyRewindBanner extends StatelessWidget {
  const _MonthlyRewindBanner({this.margin});

  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final mornye = context.isMornye;
    // Mornye keeps its neutral control fill and accent tint. Material keeps
    // the card neutral too: the statistics hero is the strong container.
    final foreground = colors.onSurface;
    final accent = mornye ? colors.primary : colors.tertiary;
    final onAccent = mornye ? colors.onPrimary : colors.onTertiary;
    return AppContentCard(
      margin: margin,
      color: colors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: context.tokens.borderRadiusCard,
      ),
      onTap: () => openListeningRewind(context, ListeningRewindPeriod.weeks),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            AppShapeBadge(
              kind: AppShapes.badge,
              size: 48,
              color: accent,
              child: AppIcon(Icons.auto_awesome, color: onAccent),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.listeningRewind,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: foreground,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l10n.listeningRewindMonthlyReady,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium?.copyWith(color: foreground),
                  ),
                ],
              ),
            ),
            AppIcon(Icons.chevron_right, color: foreground),
          ],
        ),
      ),
    );
  }
}

/// The once-a-year invitation: a gradient poster with the year set large
/// behind the title and expressive shapes scattered around it.
class _YearlyRewindBanner extends StatelessWidget {
  const _YearlyRewindBanner({this.margin});

  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final year = '${DateTime.now().year}';
    final foreground = colors.onPrimary;
    final radius = context.isMornye
        ? BorderRadius.circular(28)
        : context.tokens.borderRadiusCard;
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: Material(
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [colors.primary, colors.tertiary],
            ),
          ),
          child: InkWell(
            onTap: () =>
                openListeningRewind(context, ListeningRewindPeriod.year),
            child: Stack(
              children: [
                PositionedDirectional(
                  end: -8,
                  bottom: -28,
                  child: ExcludeSemantics(
                    child: Text(
                      year,
                      style: textTheme.displayLarge?.copyWith(
                        fontSize: 112,
                        height: 1,
                        fontWeight: FontWeight.w900,
                        color: foreground.withValues(alpha: 0.16),
                      ),
                    ),
                  ),
                ),
                PositionedDirectional(
                  end: 96,
                  top: -18,
                  child: AppShapeBadge(
                    kind: AppShapes.badge,
                    size: 64,
                    color: foreground.withValues(alpha: 0.12),
                    child: const SizedBox.shrink(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                AppIcon(
                                  Icons.auto_awesome,
                                  size: 18,
                                  color: foreground,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  l10n.listeningRewindYearEyebrow,
                                  style: textTheme.labelLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.4,
                                    color: foreground,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              l10n.listeningRewindYearTitle(year),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: foreground,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              l10n.listeningRewindYearBanner,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodyMedium?.copyWith(
                                color: foreground.withValues(alpha: 0.9),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      DecoratedBox(
                        decoration: ShapeDecoration(
                          color: foreground,
                          shape: const CircleBorder(),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: AppIcon(
                            Icons.play_arrow_rounded,
                            color: colors.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ListeningRewindScreen extends ConsumerWidget {
  const ListeningRewindScreen({super.key, required this.period});

  final ListeningRewindPeriod period;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rewind = ref.watch(listeningRewindProvider(period));
    final mornye = context.isMornye;
    final colors = Theme.of(context).colorScheme;
    final background = mornye ? Colors.black : colors.surface;
    final foreground = mornye ? Colors.white : colors.onSurface;
    Widget message(String text) =>
        _RewindMessage(text: text, foreground: foreground);
    return Scaffold(
      backgroundColor: background,
      body: rewind.when(
        loading: () => Center(child: AppLoadingIndicator(color: foreground)),
        error: (_, _) => message(context.l10n.listeningRewindLoadError),
        data: (rewind) => rewind.isEmpty
            ? message(context.l10n.listeningRewindEmpty)
            : _RewindStory(rewind: rewind, period: period),
      ),
    );
  }
}

class _RewindMessage extends StatelessWidget {
  const _RewindMessage({required this.text, required this.foreground});

  final String text;
  final Color foreground;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Stack(
      children: [
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: foreground),
            ),
          ),
        ),
        PositionedDirectional(
          top: 8,
          end: 8,
          child: _CloseButton(color: foreground),
        ),
      ],
    ),
  );
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => AppIconButton(
    tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
    color: color,
    icon: AppIcon.adaptive(Icons.close, color: color),
    onPressed: () => Navigator.of(context).maybePop(),
  );
}
