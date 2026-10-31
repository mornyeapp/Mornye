import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/scroll_edge_fade.dart';

/// The highlights of [AppInfo.whatsNewRelease] on phones and tablets, shown
/// once after an update and again from About. It shares the tutorial's
/// layout and motion, so the app's tours look alike; pages list only what
/// this device can use. Desktop uses [showWhatsNewDialog] instead.
class WhatsNewScreen extends ConsumerStatefulWidget {
  const WhatsNewScreen({super.key});

  @override
  ConsumerState<WhatsNewScreen> createState() => _WhatsNewScreenState();
}

class _WhatsNewScreenState extends ConsumerState<WhatsNewScreen> {
  final _pageController = PageController();
  int _currentPage = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goTo(int page) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _pageController.jumpToPage(page);
      return;
    }
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutQuart,
    );
  }

  void _nextPage(int count) =>
      _currentPage < count - 1 ? _goTo(_currentPage + 1) : _finish();

  void _prevPage() {
    if (_currentPage > 0) _goTo(_currentPage - 1);
  }

  /// Done and Skip both mark the tour seen. Opened from About, the tour
  /// closes back to it; after an update, the router moves on to the app.
  void _finish() {
    ref.read(settingsProvider.notifier).setWhatsNewSeen();
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      context.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final pages = whatsNewHighlights(l10n);
    final totalPages = pages.length;
    final isLastPage = _currentPage == totalPages - 1;
    final scale = responsiveScale(context: context, min: 0.86, max: 1.05);
    final textScale = effectiveTextScale(context);
    final bottomGap = (32 * scale) + ((textScale - 1) * 8);
    final actionButtonHeight = (56 * scale) + ((textScale - 1) * 6);

    final scaffold = Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: _desktopColumn(
          Column(
            children: [
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 24 * scale,
                  vertical: 16 * scale,
                ),
                child: Row(
                  children: [
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 300),
                      opacity: _currentPage > 0 ? 1.0 : 0.0,
                      child: AppIconButton.filledTonal(
                        onPressed: _currentPage > 0 ? _prevPage : null,
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).backButtonTooltip,
                        icon: const Icon(Icons.arrow_back),
                        style: IconButton.styleFrom(
                          backgroundColor: colorScheme.surfaceContainerHighest,
                          foregroundColor: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Large text wraps Skip instead of pushing it off screen.
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 300),
                          opacity: isLastPage ? 0.0 : 1.0,
                          child: IgnorePointer(
                            ignoring: isLastPage,
                            child: ExpressiveButton(
                              text: true,
                              onPressed: _finish,
                              style: TextButton.styleFrom(
                                foregroundColor: colorScheme.onSurfaceVariant,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                              ),
                              child: Text(
                                l10n.setupSkip,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: totalPages,
                  onPageChanged: (page) => setState(() => _currentPage = page),
                  itemBuilder: (context, index) => _WhatsNewPage(
                    index: index,
                    currentIndex: _currentPage,
                    highlight: pages[index],
                  ),
                ),
              ),

              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    ExcludeSemantics(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(totalPages, (index) {
                          final isActive = _currentPage == index;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOutBack,
                            margin: EdgeInsets.symmetric(horizontal: 4 * scale),
                            height: 8 * scale,
                            width: isActive ? 32 * scale : 8 * scale,
                            decoration: BoxDecoration(
                              color: isActive
                                  ? colorScheme.primary
                                  // Visible on AMOLED black, unlike
                                  // surfaceContainerHighest.
                                  : colorScheme.onSurfaceVariant.withValues(
                                      alpha: 0.4,
                                    ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          );
                        }),
                      ),
                    ),
                    SizedBox(height: bottomGap),
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 400),
                        child: SizedBox(
                          width: double.infinity,
                          height: actionButtonHeight,
                          child: ExpressiveButton(
                            onPressed: () => _nextPage(totalPages),
                            style: FilledButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(28),
                              ),
                            ),
                            child: Text(
                              isLastPage ? l10n.whatsNewDone : l10n.setupNext,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
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
    );

    // Back steps through the pages, then leaves the tour as Skip does.
    final tour = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _currentPage > 0 ? _prevPage() : _finish();
      },
      child: scaffold,
    );
    if (!isDesktopPlatform) return tour;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    void forward() => _nextPage(totalPages);
    // Enter moves on, as the default button of a desktop window would.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): forward,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): forward,
        const SingleActivator(LogicalKeyboardKey.arrowRight): rtl
            ? _prevPage
            : forward,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): rtl
            ? forward
            : _prevPage,
        const SingleActivator(LogicalKeyboardKey.escape): _finish,
      },
      child: Focus(autofocus: true, child: tour),
    );
  }

  /// Desktop windows keep the tour in one centered column.
  Widget _desktopColumn(Widget child) => isDesktopPlatform
      ? Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: child,
          ),
        )
      : child;
}

/// Desktop shows the tour once over the app, as the dialog of
/// [showWhatsNewDialog], instead of the phone's full-screen pages.
Future<void> maybeShowWhatsNewDialog(BuildContext context, WidgetRef ref) {
  if (!isDesktopPlatform ||
      ref.read(settingsProvider).whatsNewSeen == AppInfo.whatsNewRelease) {
    return Future.value();
  }
  return showWhatsNewDialog(context);
}

/// The tour as a desktop dialog: the sections listed beside the selected
/// one, Skip and Next in the footer. Closing it any way marks it seen.
Future<void> showWhatsNewDialog(BuildContext context) async {
  final settings = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(settingsProvider.notifier);
  await showAppSheetDialog<void>(
    context: context,
    isScrollControlled: true,
    dialogSize: AppDialogSize.wide,
    builder: (_) => const _WhatsNewDialog(),
  );
  settings.setWhatsNewSeen();
}

class _WhatsNewDialog extends StatefulWidget {
  const _WhatsNewDialog();

  @override
  State<_WhatsNewDialog> createState() => _WhatsNewDialogState();
}

class _WhatsNewDialogState extends State<_WhatsNewDialog> {
  int _selected = 0;

  void _select(int index, int count) {
    if (index < 0 || index >= count) return;
    setState(() => _selected = index);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // The header already says what the opening page would.
    final sections = whatsNewHighlights(l10n).skip(1).toList();
    final section = sections[_selected];
    final isLast = _selected == sections.length - 1;
    void close() => Navigator.of(context).pop();
    void forward() =>
        isLast ? close() : _select(_selected + 1, sections.length);

    final body = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 220,
          child: ListView(
            padding: EdgeInsetsDirectional.fromSTEB(
              tokens.gapMd,
              tokens.gapSm,
              0,
              tokens.gapMd,
            ),
            children: [
              for (var i = 0; i < sections.length; i++)
                _SectionTab(
                  highlight: sections[i],
                  selected: i == _selected,
                  onTap: () => _select(i, sections.length),
                ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsetsDirectional.fromSTEB(
              tokens.gapXl,
              tokens.gapSm,
              tokens.gapXl,
              tokens.gapLg,
            ),
            child: KeyedSubtree(
              // Rows rise in again for each section.
              key: ValueKey(_selected),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          section.icon,
                          size: 28,
                          color: colorScheme.primary,
                        ),
                      ),
                      SizedBox(width: tokens.gapLg),
                      Expanded(
                        child: Text(
                          section.title,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: tokens.gapMd),
                  Text(
                    section.description,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  SizedBox(height: tokens.gapXl),
                  _FeatureList(features: section.features),
                ],
              ),
            ),
          ),
        ),
      ],
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): forward,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): forward,
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _select(_selected + 1, sections.length),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _select(_selected - 1, sections.length),
      },
      child: Focus(
        autofocus: true,
        child: AppBottomSheet(
          title: l10n.whatsNewIntroTitle(AppInfo.whatsNewRelease),
          subtitle: l10n.whatsNewIntroDesc,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // One height for every section, so the dialog does not jump.
              Flexible(child: SizedBox(height: 440, child: body)),
              Padding(
                padding: EdgeInsetsDirectional.fromSTEB(
                  tokens.gapXl,
                  tokens.gapMd,
                  tokens.gapXl,
                  tokens.gapXl,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (!isLast) ...[
                      ExpressiveButton(
                        text: true,
                        onPressed: close,
                        child: Text(l10n.setupSkip),
                      ),
                      SizedBox(width: tokens.gapSm),
                    ],
                    ExpressiveButton(
                      onPressed: forward,
                      child: Text(isLast ? l10n.whatsNewDone : l10n.setupNext),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A section in the dialog's list, filled while it is shown.
class _SectionTab extends StatelessWidget {
  const _SectionTab({
    required this.highlight,
    required this.selected,
    required this.onTap,
  });

  final WhatsNewHighlight highlight;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tokens = context.tokens;
    final mornye = context.isMornye;
    final fill = mornye
        ? colorScheme.primary.withValues(alpha: 0.14)
        : colorScheme.secondaryContainer;
    final foreground = selected
        ? (mornye ? colorScheme.primary : colorScheme.onSecondaryContainer)
        : colorScheme.onSurfaceVariant;
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.gapXs),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? fill : Colors.transparent,
          borderRadius: BorderRadius.circular(tokens.radiusControl),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: tokens.minTouchTarget),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: tokens.gapMd,
                  vertical: tokens.gapSm,
                ),
                child: Row(
                  children: [
                    Icon(highlight.icon, size: 20, color: foreground),
                    SizedBox(width: tokens.gapMd),
                    Expanded(
                      child: Text(
                        highlight.title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: selected ? foreground : colorScheme.onSurface,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One page of the tour: a symbol, a title, a line and its feature rows.
@visibleForTesting
class WhatsNewHighlight {
  const WhatsNewHighlight({
    required this.icon,
    required this.title,
    required this.description,
    required this.features,
  });

  final IconData icon;
  final String title;
  final String description;
  final List<WhatsNewFeature> features;
}

@visibleForTesting
class WhatsNewFeature {
  const WhatsNewFeature(this.icon, this.title, [this.body]);

  final IconData icon;
  final String title;

  /// Null for the opening page, which lists the sections by title.
  final String? body;
}

/// The tour for [AppInfo.whatsNewRelease]: an overview, then one page per
/// area. Android Auto and exclusive output appear only where they exist.
@visibleForTesting
List<WhatsNewHighlight> whatsNewHighlights(
  AppLocalizations l10n, {
  bool? androidPhone,
  bool? desktop,
}) {
  final showAndroidAuto = androidPhone ?? (Platform.isAndroid && !isAndroidTv);
  final showExclusiveOutput = desktop ?? isDesktopPlatform;
  final sections = [
    WhatsNewHighlight(
      icon: Icons.devices_rounded,
      title: l10n.whatsNewLinkTitle,
      description: l10n.whatsNewLinkDesc,
      features: [
        WhatsNewFeature(
          Icons.play_circle_rounded,
          l10n.whatsNewLinkPlayTitle,
          l10n.whatsNewLinkPlayBody,
        ),
        WhatsNewFeature(
          Icons.swap_horiz_rounded,
          l10n.whatsNewLinkTransferTitle,
          l10n.whatsNewLinkTransferBody,
        ),
        WhatsNewFeature(
          Icons.sync_rounded,
          l10n.whatsNewLinkSyncTitle,
          l10n.whatsNewLinkSyncBody,
        ),
      ],
    ),
    WhatsNewHighlight(
      icon: Icons.auto_awesome_rounded,
      title: l10n.whatsNewHomeTitle,
      description: l10n.whatsNewHomeDesc,
      features: [
        WhatsNewFeature(
          Icons.queue_music_rounded,
          l10n.whatsNewHomeMixesTitle,
          l10n.whatsNewHomeMixesBody,
        ),
        WhatsNewFeature(
          Icons.favorite_rounded,
          l10n.whatsNewHomeAutoplayTitle,
          l10n.whatsNewHomeAutoplayBody,
        ),
        WhatsNewFeature(
          Icons.graphic_eq_rounded,
          l10n.whatsNewHomeAnalysisTitle,
          l10n.whatsNewHomeAnalysisBody,
        ),
      ],
    ),
    WhatsNewHighlight(
      icon: Icons.lyrics_rounded,
      title: l10n.whatsNewPlayerTitle,
      description: l10n.whatsNewPlayerDesc,
      features: [
        WhatsNewFeature(
          Icons.album_rounded,
          l10n.whatsNewPlayerGaplessTitle,
          l10n.whatsNewPlayerGaplessBody,
        ),
        WhatsNewFeature(
          Icons.translate_rounded,
          l10n.whatsNewPlayerTranslateTitle,
          l10n.whatsNewPlayerTranslateBody,
        ),
        WhatsNewFeature(
          Icons.timer_rounded,
          l10n.whatsNewPlayerTimingTitle,
          l10n.whatsNewPlayerTimingBody,
        ),
        if (showAndroidAuto)
          WhatsNewFeature(
            Icons.directions_car_rounded,
            l10n.whatsNewPlayerAutoTitle,
            l10n.whatsNewPlayerAutoBody,
          ),
        if (showExclusiveOutput)
          WhatsNewFeature(
            Icons.high_quality_rounded,
            l10n.whatsNewPlayerExclusiveTitle,
            l10n.whatsNewPlayerExclusiveBody,
          ),
      ],
    ),
    WhatsNewHighlight(
      icon: Icons.library_music_rounded,
      title: l10n.whatsNewLibraryTitle,
      description: l10n.whatsNewLibraryDesc,
      features: [
        WhatsNewFeature(
          Icons.folder_open_rounded,
          l10n.whatsNewLibraryFoldersTitle,
          l10n.whatsNewLibraryFoldersBody,
        ),
        WhatsNewFeature(
          Icons.lightbulb_rounded,
          l10n.whatsNewLibrarySuggestionsTitle,
          l10n.whatsNewLibrarySuggestionsBody,
        ),
        WhatsNewFeature(
          Icons.mic_rounded,
          l10n.whatsNewLibraryRecognizeTitle,
          l10n.whatsNewLibraryRecognizeBody,
        ),
        WhatsNewFeature(
          Icons.playlist_add_rounded,
          l10n.whatsNewLibraryPlaylistsTitle,
          l10n.whatsNewLibraryPlaylistsBody,
        ),
      ],
    ),
    WhatsNewHighlight(
      icon: Icons.speed_rounded,
      title: l10n.whatsNewFasterTitle,
      description: l10n.whatsNewFasterDesc,
      features: [
        WhatsNewFeature(
          Icons.grid_view_rounded,
          l10n.whatsNewFasterLibraryTitle,
          l10n.whatsNewFasterLibraryBody,
        ),
        WhatsNewFeature(
          Icons.lan_rounded,
          l10n.whatsNewFasterNetworkTitle,
          l10n.whatsNewFasterNetworkBody,
        ),
        WhatsNewFeature(
          Icons.history_rounded,
          l10n.whatsNewFasterQueueTitle,
          l10n.whatsNewFasterQueueBody,
        ),
        WhatsNewFeature(
          Icons.bolt_rounded,
          l10n.whatsNewFasterBackgroundTitle,
          l10n.whatsNewFasterBackgroundBody,
        ),
      ],
    ),
  ];
  return [
    WhatsNewHighlight(
      icon: Icons.celebration_rounded,
      title: l10n.whatsNewIntroTitle(AppInfo.whatsNewRelease),
      description: l10n.whatsNewIntroDesc,
      features: [
        for (final section in sections)
          WhatsNewFeature(section.icon, section.title),
      ],
    ),
    ...sections,
  ];
}

/// The tutorial's page layout: the symbol on a tinted circle, the title and
/// line fading in while the page is current, then the feature rows.
class _WhatsNewPage extends StatelessWidget {
  const _WhatsNewPage({
    required this.index,
    required this.currentIndex,
    required this.highlight,
  });

  final int index;
  final int currentIndex;
  final WhatsNewHighlight highlight;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final shortestSide = MediaQuery.sizeOf(context).shortestSide;
    final textScale = MediaQuery.textScalerOf(
      context,
    ).scale(1.0).clamp(1.0, 1.4);
    final scale = (shortestSide / 390).clamp(0.86, 1.05);
    final isActive = currentIndex == index;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Shrink vertical rhythm on short viewports so a page fits with
        // little or no scrolling.
        final heightScale = (constraints.maxHeight / 640).clamp(0.6, 1.0);
        final topGap = (24 * scale).clamp(16.0, 24.0) * heightScale;
        final iconPadding = (24 * scale).clamp(18.0, 24.0) * heightScale;
        final iconSize = (56 * scale).clamp(44.0, 56.0) * heightScale;
        final iconTextGap = (48 * scale).clamp(28.0, 48.0) * heightScale;
        final descriptionGap = (20 * scale).clamp(12.0, 20.0) * heightScale;
        final contentGap =
            ((56 * scale) + ((textScale - 1) * 10)) * heightScale;
        final bottomGap = (32 * scale).clamp(20.0, 32.0) * heightScale;

        return ScrollEdgeFade(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            physics: const BouncingScrollPhysics(),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  children: [
                    SizedBox(height: topGap),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeOutBack,
                      transform: Matrix4.translationValues(
                        0,
                        isActive ? 0 : -20,
                        0,
                      ),
                      padding: EdgeInsets.all(iconPadding),
                      decoration: BoxDecoration(
                        color: colorScheme.primary.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        highlight.icon,
                        size: iconSize,
                        color: colorScheme.primary,
                      ),
                    ),
                    SizedBox(height: iconTextGap),
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 500),
                      opacity: isActive ? 1.0 : 0.0,
                      curve: Curves.easeOut,
                      child: Text(
                        highlight.title,
                        style: Theme.of(context).textTheme.headlineLarge
                            ?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurface,
                              letterSpacing: -0.5,
                            ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    SizedBox(height: descriptionGap),
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 500),
                      opacity: isActive ? 1.0 : 0.0,
                      curve: Curves.easeOut,
                      child: Text(
                        highlight.description,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          height: 1.5,
                          fontSize: 16 * (1 + ((textScale - 1) * 0.1)),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    SizedBox(height: contentGap),
                    _FeatureList(features: highlight.features),
                    SizedBox(height: bottomGap),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The tutorial's feature list: a tinted tile with the symbol, then the
/// text, each row rising in after the one before it.
class _FeatureList extends StatelessWidget {
  const _FeatureList({required this.features});

  final List<WhatsNewFeature> features;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Column(
      children: [
        for (var index = 0; index < features.length; index++)
          TweenAnimationBuilder<double>(
            tween: Tween(begin: reduceMotion ? 1 : 0, end: 1),
            duration: Duration(milliseconds: 600 + (index * 200)),
            curve: Curves.easeOutQuart,
            builder: (context, value, child) => Transform.translate(
              offset: Offset(0, 20 * (1 - value)),
              child: Opacity(opacity: value, child: child),
            ),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: MergeSemantics(
                child: Row(
                  crossAxisAlignment: features[index].body == null
                      ? CrossAxisAlignment.center
                      : CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        features[index].icon,
                        size: 24,
                        color: colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            features[index].title,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: colorScheme.onSurface,
                              fontWeight: features[index].body == null
                                  ? FontWeight.w500
                                  : FontWeight.w600,
                            ),
                          ),
                          if (features[index].body case final body?) ...[
                            const SizedBox(height: 2),
                            Text(
                              body,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
