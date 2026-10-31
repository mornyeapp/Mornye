import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/scroll_edge_fade.dart';

/// The highlights of [AppInfo.whatsNewRelease], shown once after an update
/// and again from About. Pages list only what this device can use.
class WhatsNewScreen extends ConsumerStatefulWidget {
  const WhatsNewScreen({super.key});

  @override
  ConsumerState<WhatsNewScreen> createState() => _WhatsNewScreenState();
}

class _WhatsNewScreenState extends ConsumerState<WhatsNewScreen> {
  final _pageController = PageController();
  // Pages already revealed keep their rows when swiped back to.
  final _revealed = <int>{0};
  int _page = 0;

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
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
    );
  }

  void _next(int count) => _page < count - 1 ? _goTo(_page + 1) : _finish();

  void _previous() {
    if (_page > 0) _goTo(_page - 1);
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
    final l10n = context.l10n;
    final pages = whatsNewHighlights(l10n);
    final isLast = _page == pages.length - 1;
    final mornye = context.isMornye;
    final tokens = context.tokens;
    final textTheme = Theme.of(context).textTheme;

    final scaffold = Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              children: [
                _TopBar(
                  showBack: _page > 0,
                  showSkip: !isLast,
                  onBack: _previous,
                  onSkip: _finish,
                ),
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: pages.length,
                    onPageChanged: (page) => setState(() {
                      _page = page;
                      _revealed.add(page);
                    }),
                    itemBuilder: (context, index) => _HighlightPage(
                      highlight: pages[index],
                      revealed: _revealed.contains(index),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(
                    tokens.gapXl,
                    tokens.gapSm,
                    tokens.gapXl,
                    tokens.gapXl,
                  ),
                  child: Column(
                    children: [
                      _PageDots(count: pages.length, current: _page),
                      SizedBox(height: tokens.gapXl),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 400),
                        child: SizedBox(
                          width: double.infinity,
                          child: ExpressiveButton(
                            onPressed: () => _next(pages.length),
                            // Mornye keeps its theme's capsule and label.
                            style: FilledButton.styleFrom(
                              minimumSize: Size(64, mornye ? 50 : 56),
                              shape: mornye ? null : const StadiumBorder(),
                            ),
                            child: Text(
                              isLast ? l10n.whatsNewDone : l10n.setupNext,
                              textAlign: TextAlign.center,
                              style: mornye
                                  ? null
                                  : textTheme.titleMedium?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onPrimary,
                                      fontWeight: FontWeight.w700,
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
      ),
    );

    // Back steps through the pages, then leaves the tour as Skip does.
    final tour = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _page > 0 ? _previous() : _finish();
      },
      child: scaffold,
    );
    if (!isDesktopPlatform) return tour;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    void forward() => _next(pages.length);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): forward,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): forward,
        const SingleActivator(LogicalKeyboardKey.arrowRight): rtl
            ? _previous
            : forward,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): rtl
            ? forward
            : _previous,
        const SingleActivator(LogicalKeyboardKey.escape): _finish,
      },
      child: Focus(autofocus: true, child: tour),
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
      icon: Icons.computer,
      title: l10n.whatsNewLinkTitle,
      description: l10n.whatsNewLinkDesc,
      features: [
        WhatsNewFeature(
          Icons.play_circle,
          l10n.whatsNewLinkPlayTitle,
          l10n.whatsNewLinkPlayBody,
        ),
        WhatsNewFeature(
          Icons.swap_horiz,
          l10n.whatsNewLinkTransferTitle,
          l10n.whatsNewLinkTransferBody,
        ),
        WhatsNewFeature(
          Icons.sync,
          l10n.whatsNewLinkSyncTitle,
          l10n.whatsNewLinkSyncBody,
        ),
      ],
    ),
    WhatsNewHighlight(
      icon: Icons.auto_awesome,
      title: l10n.whatsNewHomeTitle,
      description: l10n.whatsNewHomeDesc,
      features: [
        WhatsNewFeature(
          Icons.playlist_play,
          l10n.whatsNewHomeMixesTitle,
          l10n.whatsNewHomeMixesBody,
        ),
        WhatsNewFeature(
          Icons.favorite,
          l10n.whatsNewHomeAutoplayTitle,
          l10n.whatsNewHomeAutoplayBody,
        ),
        WhatsNewFeature(
          Icons.graphic_eq,
          l10n.whatsNewHomeAnalysisTitle,
          l10n.whatsNewHomeAnalysisBody,
        ),
      ],
    ),
    WhatsNewHighlight(
      icon: Icons.lyrics,
      title: l10n.whatsNewPlayerTitle,
      description: l10n.whatsNewPlayerDesc,
      features: [
        WhatsNewFeature(
          Icons.album,
          l10n.whatsNewPlayerGaplessTitle,
          l10n.whatsNewPlayerGaplessBody,
        ),
        WhatsNewFeature(
          Icons.translate,
          l10n.whatsNewPlayerTranslateTitle,
          l10n.whatsNewPlayerTranslateBody,
        ),
        WhatsNewFeature(
          Icons.timer_outlined,
          l10n.whatsNewPlayerTimingTitle,
          l10n.whatsNewPlayerTimingBody,
        ),
        if (showAndroidAuto)
          WhatsNewFeature(
            Icons.directions_car,
            l10n.whatsNewPlayerAutoTitle,
            l10n.whatsNewPlayerAutoBody,
          ),
        if (showExclusiveOutput)
          WhatsNewFeature(
            Icons.high_quality,
            l10n.whatsNewPlayerExclusiveTitle,
            l10n.whatsNewPlayerExclusiveBody,
          ),
      ],
    ),
    WhatsNewHighlight(
      icon: Icons.library_music,
      title: l10n.whatsNewLibraryTitle,
      description: l10n.whatsNewLibraryDesc,
      features: [
        WhatsNewFeature(
          Icons.folder_open,
          l10n.whatsNewLibraryFoldersTitle,
          l10n.whatsNewLibraryFoldersBody,
        ),
        WhatsNewFeature(
          Icons.lightbulb_outline,
          l10n.whatsNewLibrarySuggestionsTitle,
          l10n.whatsNewLibrarySuggestionsBody,
        ),
        WhatsNewFeature(
          Icons.mic,
          l10n.whatsNewLibraryRecognizeTitle,
          l10n.whatsNewLibraryRecognizeBody,
        ),
        WhatsNewFeature(
          Icons.playlist_add,
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
          Icons.library_music_outlined,
          l10n.whatsNewFasterLibraryTitle,
          l10n.whatsNewFasterLibraryBody,
        ),
        WhatsNewFeature(
          Icons.lan_outlined,
          l10n.whatsNewFasterNetworkTitle,
          l10n.whatsNewFasterNetworkBody,
        ),
        WhatsNewFeature(
          Icons.history,
          l10n.whatsNewFasterQueueTitle,
          l10n.whatsNewFasterQueueBody,
        ),
        WhatsNewFeature(
          Icons.timer,
          l10n.whatsNewFasterBackgroundTitle,
          l10n.whatsNewFasterBackgroundBody,
        ),
      ],
    ),
  ];
  return [
    WhatsNewHighlight(
      icon: Icons.new_releases,
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

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.showBack,
    required this.showSkip,
    required this.onBack,
    required this.onSkip,
  });

  final bool showBack;
  final bool showSkip;
  final VoidCallback onBack;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colorScheme = Theme.of(context).colorScheme;
    final backTooltip = MaterialLocalizations.of(context).backButtonTooltip;
    final Widget back;
    final Widget skip;
    if (context.isMornye) {
      back = Tooltip(
        message: backTooltip,
        child: CupertinoButton(
          onPressed: onBack,
          child: Icon(
            CupertinoIcons.back,
            color: colorScheme.primary,
            semanticLabel: backTooltip,
          ),
        ),
      );
      skip = CupertinoButton(
        onPressed: onSkip,
        child: Text(
          l10n.setupSkip,
          style: Theme.of(
            context,
          ).textTheme.bodyLarge?.copyWith(color: colorScheme.primary),
        ),
      );
    } else {
      back = AppIconButton.filledTonal(
        onPressed: onBack,
        tooltip: backTooltip,
        icon: const Icon(Icons.arrow_back),
      );
      skip = ExpressiveButton(
        text: true,
        onPressed: onSkip,
        child: Text(l10n.setupSkip),
      );
    }
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.tokens.gapLg,
        vertical: context.tokens.gapSm,
      ),
      child: Row(
        children: [
          _Shown(visible: showBack, child: back),
          SizedBox(width: context.tokens.gapSm),
          // Large text wraps the label instead of pushing it off screen.
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: _Shown(visible: showSkip, child: skip),
            ),
          ),
        ],
      ),
    );
  }
}

/// Keeps a hidden control's space so the bar does not shift between pages.
class _Shown extends StatelessWidget {
  const _Shown({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: visible ? 1 : 0,
    duration: context.tokens.motionMedium,
    child: IgnorePointer(
      ignoring: !visible,
      child: ExcludeSemantics(excluding: !visible, child: child),
    ),
  );
}

class _HighlightPage extends StatelessWidget {
  const _HighlightPage({required this.highlight, required this.revealed});

  final WhatsNewHighlight highlight;
  final bool revealed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tokens = context.tokens;
    final mornye = context.isMornye;
    final titleStyle = mornye
        ? theme.textTheme.headlineLarge
        : theme.textTheme.headlineMedium;
    final features = highlight.features;
    return ScrollEdgeFade(
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: tokens.gapXl),
        child: Column(
          children: [
            SizedBox(height: tokens.gapLg),
            _HeroIcon(icon: highlight.icon, revealed: revealed),
            SizedBox(height: tokens.gapXl),
            Text(
              highlight.title,
              textAlign: TextAlign.center,
              style: titleStyle?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: tokens.gapMd),
            Text(
              highlight.description,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: tokens.gapXl + tokens.gapSm),
            for (var i = 0; i < features.length; i++)
              _Reveal(
                index: i,
                revealed: revealed,
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom: mornye ? tokens.gapXl : tokens.gapLg,
                  ),
                  child: _FeatureRow(feature: features[i]),
                ),
              ),
            SizedBox(height: tokens.gapLg),
          ],
        ),
      ),
    );
  }
}

/// Material sets the symbol on a tonal circle; Mornye shows the accent
/// symbol on its own, as Apple's welcome screens do.
class _HeroIcon extends StatelessWidget {
  const _HeroIcon({required this.icon, required this.revealed});

  final IconData icon;
  final bool revealed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final motion = AppMotion.spatial(
      context,
      const AppMotionSpec(Duration(milliseconds: 350), Curves.easeOutCubic),
    );
    final Widget symbol = context.isMornye
        ? AppIcon(mornyeIconFor(icon), size: 64, color: colorScheme.primary)
        : Container(
            padding: EdgeInsets.all(context.tokens.gapXl),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: AppIcon(
              icon,
              size: 48,
              color: colorScheme.onPrimaryContainer,
            ),
          );
    return AnimatedScale(
      scale: revealed || MediaQuery.disableAnimationsOf(context) ? 1 : 0.85,
      duration: motion.duration,
      curve: motion.curve,
      child: ExcludeSemantics(child: symbol),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({required this.feature});

  final WhatsNewFeature feature;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tokens = context.tokens;
    final mornye = context.isMornye;
    final body = feature.body;
    final Widget symbol = mornye
        ? SizedBox(
            width: tokens.minTouchTarget,
            child: AppIcon(
              mornyeIconFor(feature.icon),
              size: 30,
              color: colorScheme.primary,
            ),
          )
        : Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(tokens.radiusControl),
            ),
            child: AppIcon(feature.icon, size: 24, color: colorScheme.primary),
          );
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: body == null
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: symbol),
          SizedBox(width: tokens.gapLg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  feature.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (body != null) ...[
                  SizedBox(height: tokens.gapXs / 2),
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
    );
  }
}

/// Rows fade and rise in order the first time their page shows. Reduced
/// motion shows them at once.
class _Reveal extends StatelessWidget {
  const _Reveal({
    required this.index,
    required this.revealed,
    required this.child,
  });

  final int index;
  final bool revealed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final start = (index * 0.12).clamp(0.0, 0.6);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: revealed ? 1 : 0),
      duration: const Duration(milliseconds: 650),
      curve: Interval(start, 1, curve: Curves.easeOutCubic),
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 16 * (1 - value)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// Material stretches the current dot into a pill; Mornye keeps round dots
/// that differ by tone, like a page control.
class _PageDots extends StatelessWidget {
  const _PageDots({required this.count, required this.current});

  final int count;
  final int current;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final mornye = context.isMornye;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : context.tokens.motionMedium;
    return ExcludeSemantics(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: duration,
              curve: Curves.easeOutCubic,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              height: 8,
              width: !mornye && i == current ? 28 : 8,
              decoration: BoxDecoration(
                color: i == current
                    ? (mornye ? colorScheme.onSurface : colorScheme.primary)
                    // Visible on AMOLED black, unlike surfaceContainerHighest.
                    : colorScheme.onSurfaceVariant.withValues(
                        alpha: mornye ? 0.3 : 0.4,
                      ),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
        ],
      ),
    );
  }
}
