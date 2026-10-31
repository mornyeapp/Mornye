import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_3_expressive/material_3_expressive.dart'
    show
        M3EShapeKind,
        Morph,
        MorphToPathExtension,
        RoundedPolygonToPathExtension;
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_shape.dart';
import 'package:mornye/widgets/expressive_button.dart';

/// The highlights of [AppInfo.whatsNewRelease] on phones and tablets, shown
/// once after an update and again from About. It keeps the look of the
/// 5.2 rebrand tour; pages list only what this device can use. Desktop uses
/// [showWhatsNewDialog] instead.
class WhatsNewScreen extends ConsumerStatefulWidget {
  const WhatsNewScreen({super.key});

  @override
  ConsumerState<WhatsNewScreen> createState() => _WhatsNewScreenState();
}

class _WhatsNewScreenState extends ConsumerState<WhatsNewScreen> {
  final _pages = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _goTo(int page) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _pages.jumpToPage(page);
    } else {
      _pages.animateToPage(
        page,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeInOutCubicEmphasized,
      );
    }
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
    final scheme = Theme.of(context).colorScheme;
    final mornye = context.isMornye;
    final pages = whatsNewHighlights(l10n);
    final last = _page == pages.length - 1;
    // Back steps through the pages, then leaves the tour as Skip does.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _page > 0 ? _previous() : _finish();
      },
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        if (_page > 0)
                          AppIconButton(
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).backButtonTooltip,
                            onPressed: _previous,
                            color: scheme.primary,
                            icon: Icon(
                              mornye
                                  ? CupertinoIcons.chevron_back
                                  : Icons.arrow_back,
                            ),
                          )
                        else
                          const SizedBox(width: 48, height: 48),
                        // Large text shrinks the dots instead of pushing
                        // Skip off screen.
                        Expanded(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: _PageIndicator(
                              count: pages.length,
                              page: _page,
                            ),
                          ),
                        ),
                        // Capped so large text cannot push it off screen;
                        // the dots keep the rest of the row.
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 160),
                          child: ExpressiveButton(
                            text: true,
                            onPressed: _finish,
                            child: Text(
                              l10n.setupSkip,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: PageView.builder(
                      controller: _pages,
                      itemCount: pages.length,
                      onPageChanged: (page) => setState(() => _page = page),
                      itemBuilder: (context, index) =>
                          _TourPage(index: index, highlight: pages[index]),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
                    child: SizedBox(
                      width: double.infinity,
                      child: ExpressiveButton(
                        onPressed: () => _next(pages.length),
                        icon: last
                            ? null
                            : Icon(
                                mornye
                                    ? CupertinoIcons.arrow_right
                                    : Icons.arrow_forward,
                              ),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(56),
                          shape: mornye
                              ? RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                )
                              : null,
                          textStyle: Theme.of(context).textTheme.titleMedium,
                        ),
                        child: Text(
                          last ? l10n.whatsNewDone : l10n.upgradeIntroContinue,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
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
/// one, Skip and Continue in the footer. Closing it any way marks it seen.
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
    final scheme = theme.colorScheme;
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AppShapeBadge(
                      // Sections keep the hero shape they have on phones.
                      kind: _heroShapes[_selected + 1].$1,
                      size: 56,
                      color: scheme.primaryContainer,
                      child: Icon(
                        context.adaptiveIcon(section.icon),
                        size: 28,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                    SizedBox(width: tokens.gapLg),
                    Expanded(
                      child: Text(
                        section.title,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: context.isMornye
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: tokens.gapMd),
                Text(
                  section.description,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    height: 1.4,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                SizedBox(height: tokens.gapXl),
                _FeatureList(features: section.features),
              ],
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
              Flexible(child: SizedBox(height: 500, child: body)),
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
                      child: Text(
                        isLast ? l10n.whatsNewDone : l10n.upgradeIntroContinue,
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
    final scheme = theme.colorScheme;
    final tokens = context.tokens;
    final foreground = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.gapXs),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? scheme.secondaryContainer : Colors.transparent,
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
                    Icon(
                      context.adaptiveIcon(highlight.icon),
                      size: 20,
                      color: foreground,
                    ),
                    SizedBox(width: tokens.gapMd),
                    Expanded(
                      child: Text(
                        highlight.title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: selected ? foreground : scheme.onSurface,
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

/// The hero shape and its small accent for each page, by index.
const _heroShapes = [
  (M3EShapeKind.cookie12Sided, M3EShapeKind.sunny),
  (M3EShapeKind.flower, M3EShapeKind.pill),
  (M3EShapeKind.softBurst, M3EShapeKind.clover4Leaf),
  (M3EShapeKind.clover8Leaf, M3EShapeKind.gem),
  (M3EShapeKind.cookie9Sided, M3EShapeKind.sunny),
  (M3EShapeKind.puffy, M3EShapeKind.pill),
];

/// Dots that stretch into a pill for the current page.
class _PageIndicator extends StatelessWidget {
  const _PageIndicator({required this.count, required this.page});

  final int count;
  final int page;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 360);
    return Semantics(
      label: '${page + 1} / $count',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < count; index++)
              AnimatedContainer(
                duration: duration,
                curve: Curves.easeOutBack,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: index == page ? 24 : 8,
                height: 8,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  color: index == page
                      ? scheme.primary
                      : index < page
                      ? scheme.primary.withValues(alpha: 0.38)
                      : scheme.outlineVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TourPage extends StatelessWidget {
  const _TourPage({required this.index, required this.highlight});

  final int index;
  final WhatsNewHighlight highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mornye = context.isMornye;
    final (shape, accent) = _heroShapes[index % _heroShapes.length];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: _TourHero(
              shape: shape,
              accent: accent,
              icon: highlight.icon,
              logo: index == 0,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            highlight.title,
            style: mornye
                ? theme.textTheme.headlineLarge?.copyWith(
                    fontSize: 36,
                    height: 1.08,
                    letterSpacing: -1.2,
                    fontWeight: FontWeight.w700,
                  )
                : theme.textTheme.displaySmall?.copyWith(
                    height: 1.1,
                    letterSpacing: -0.4,
                    fontWeight: FontWeight.w500,
                  ),
          ),
          const SizedBox(height: 12),
          Text(
            highlight.description,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 17,
              height: 1.4,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 28),
          _FeatureList(features: highlight.features),
        ],
      ),
    );
  }
}

/// A large expressive shape with two smaller ones beside it. It springs in
/// with its page, morphs once on its own, and morphs into the next shape on
/// each tap.
class _TourHero extends StatefulWidget {
  const _TourHero({
    required this.shape,
    required this.accent,
    required this.icon,
    this.logo = false,
  });

  final M3EShapeKind shape;
  final M3EShapeKind accent;
  final IconData icon;
  final bool logo;

  @override
  State<_TourHero> createState() => _TourHeroState();
}

class _TourHeroState extends State<_TourHero> with TickerProviderStateMixin {
  /// Shapes the hero morphs through, after the page's own shape.
  static const _cycle = [
    M3EShapeKind.cookie12Sided,
    M3EShapeKind.flower,
    M3EShapeKind.softBurst,
    M3EShapeKind.cookie9Sided,
    M3EShapeKind.puffy,
    M3EShapeKind.clover8Leaf,
    M3EShapeKind.sunny,
    M3EShapeKind.cookie6Sided,
  ];

  late final _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  late final _morph = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
    value: 1,
  );
  late M3EShapeKind _to = widget.shape;
  Morph? _shapeMorph;
  int _turns = 0;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _entrance.value = 1;
      return;
    }
    // One unprompted morph shows the shape can change.
    _entrance.forward().whenComplete(() {
      if (mounted) _next();
    });
  }

  @override
  void dispose() {
    _entrance.dispose();
    _morph.dispose();
    super.dispose();
  }

  void _next() {
    if (context.isMornye || MediaQuery.disableAnimationsOf(context)) return;
    final from = _to;
    _to = _cycle[(_cycle.indexOf(from) + 1) % _cycle.length];
    _shapeMorph = Morph(from.polygon, _to.polygon);
    _turns++;
    _morph.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mornye = context.isMornye;
    // The logo asset is the bare white mark, tinted like the icons.
    final glyph = widget.logo
        ? Image.asset(
            'assets/images/logo-transparent.png',
            height: 64,
            color: scheme.onPrimaryContainer,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          )
        : Icon(
            context.adaptiveIcon(widget.icon),
            size: 56,
            color: scheme.onPrimaryContainer,
          );
    // Decorative: tapping to morph is a small extra, not a control.
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: Listenable.merge([_entrance, _morph]),
        child: glyph,
        builder: (context, glyph) {
          final t = Curves.elasticOut.transform(_entrance.value);
          final morph = Curves.easeInOutCubicEmphasized.transform(_morph.value);
          // Each morph adds an eighth of a turn, settling with a spring.
          final turn =
              (_turns - 1 + Curves.elasticOut.transform(_morph.value)) *
              math.pi /
              4;
          final shape = GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              _next();
            },
            child: Transform.rotate(
              angle: (1 - t) * -0.35 + turn,
              child: Transform.scale(
                scale: 0.6 + 0.4 * t,
                child: SizedBox.square(
                  dimension: 132,
                  child: CustomPaint(
                    painter: _MorphPainter(
                      morph: mornye ? null : _shapeMorph,
                      kind: mornye ? M3EShapeKind.circle : _to,
                      progress: morph,
                      color: scheme.primaryContainer,
                    ),
                    // Keep the glyph upright while the shape turns.
                    child: Transform.rotate(
                      angle: -turn,
                      child: Center(child: glyph),
                    ),
                  ),
                ),
              ),
            ),
          );
          return _heroStage(scheme, t, shape);
        },
      ),
    );
  }

  Widget _heroStage(ColorScheme scheme, double t, Widget child) => SizedBox(
    width: 220,
    height: 172,
    child: Stack(
      alignment: Alignment.center,
      children: [
        child,
        Positioned(
          right: 18,
          top: 8,
          child: Transform.scale(
            scale: t,
            child: AppShapeBadge(
              kind: widget.accent,
              size: 44,
              color: scheme.tertiaryContainer,
              child: const SizedBox.shrink(),
            ),
          ),
        ),
        Positioned(
          left: 30,
          bottom: 16,
          child: Transform.scale(
            scale: t,
            child: AppShapeBadge(
              kind: M3EShapeKind.circle,
              size: 20,
              color: scheme.secondaryContainer,
              child: const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Fills the shape between two expressive polygons; [morph] null draws [kind].
class _MorphPainter extends CustomPainter {
  const _MorphPainter({
    required this.morph,
    required this.kind,
    required this.progress,
    required this.color,
  });

  final Morph? morph;
  final M3EShapeKind kind;
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Catalog polygons are normalized to the unit square.
    final unit = morph?.toPath(progress: progress) ?? kind.polygon.toPath();
    final scale = Matrix4.diagonal3Values(size.width, size.height, 1);
    canvas.drawPath(
      unit.transform(scale.storage),
      Paint()
        ..color = color
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_MorphPainter oldDelegate) =>
      morph != oldDelegate.morph ||
      kind != oldDelegate.kind ||
      progress != oldDelegate.progress ||
      color != oldDelegate.color;
}

/// Feature rows as one connected list: large outer corners, small inner
/// ones.
class _FeatureList extends StatelessWidget {
  const _FeatureList({required this.features});

  final List<WhatsNewFeature> features;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var index = 0; index < features.length; index++)
        _FeatureRow(
          feature: features[index],
          first: index == 0,
          last: index == features.length - 1,
        ),
    ],
  );
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.feature,
    required this.first,
    required this.last,
  });

  final WhatsNewFeature feature;
  final bool first;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final outer = Radius.circular(context.isMornye ? 18 : 24);
    const inner = Radius.circular(6);
    final body = feature.body;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 2),
      child: MergeSemantics(
        child: Material(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.vertical(
            top: first ? outer : inner,
            bottom: last ? outer : inner,
          ),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 20, 16),
            child: Row(
              crossAxisAlignment: body == null
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.start,
              children: [
                // Icon containers in one list share the plain circle;
                // abstract shapes are reserved for the decorative hero.
                AppShapeBadge(
                  kind: M3EShapeKind.circle,
                  size: 44,
                  color: scheme.secondaryContainer,
                  child: Icon(
                    context.adaptiveIcon(feature.icon),
                    size: 22,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        feature.title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (body != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          body,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            height: 1.35,
                            color: scheme.onSurfaceVariant,
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
    );
  }
}
