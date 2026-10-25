import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/scroll_edge_fade.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_search_field.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/tv_navigation.dart';

class TutorialScreen extends ConsumerStatefulWidget {
  const TutorialScreen({super.key});

  @override
  ConsumerState<TutorialScreen> createState() => _TutorialScreenState();
}

class _TutorialScreenState extends ConsumerState<TutorialScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  static const int _totalPages = 6;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage < _totalPages - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutQuart,
      );
    } else {
      _completeTutorial();
    }
  }

  void _prevPage() {
    _pageController.previousPage(
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutQuart,
    );
  }

  void _completeTutorial() {
    ref.read(settingsProvider.notifier).setTutorialComplete();
    context.go('/');
  }

  void _skipTutorial() {
    ref.read(settingsProvider.notifier).setTutorialComplete();
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final isLastPage = _currentPage == _totalPages - 1;
    final scale = responsiveScale(context: context, min: 0.86, max: 1.05);
    final textScale = effectiveTextScale(context);
    final topBarPaddingH = 24 * scale;
    final topBarPaddingV = 16 * scale;
    final pageIndicatorHeight = 8 * scale;
    final pageIndicatorWidth = 8 * scale;
    final activeIndicatorWidth = 32 * scale;
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
                  horizontal: topBarPaddingH,
                  vertical: topBarPaddingV,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
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

                    ExpressiveButton(
                      text: true,
                      onPressed: _skipTutorial,
                      style: TextButton.styleFrom(
                        foregroundColor: colorScheme.onSurfaceVariant,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                      ),
                      child: Text(
                        l10n.setupSkip,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),

              Expanded(
                child: PageView(
                  controller: _pageController,
                  onPageChanged: (page) => setState(() => _currentPage = page),
                  children: [
                    _TutorialPage(
                      index: 0,
                      currentIndex: _currentPage,
                      icon: Icons.waving_hand_rounded,
                      title: l10n.tutorialWelcomeTitle,
                      description: l10n.tutorialWelcomeDesc,
                      content: _buildFeatureList(context, [
                        (
                          Icons.travel_explore_rounded,
                          l10n.tutorialWelcomeTip1,
                        ),
                        (Icons.high_quality_rounded, l10n.tutorialWelcomeTip2),
                        (Icons.auto_awesome_rounded, l10n.tutorialWelcomeTip3),
                      ]),
                    ),
                    _TutorialPage(
                      index: 1,
                      currentIndex: _currentPage,
                      icon: Icons.search_rounded,
                      title: l10n.tutorialSearchTitle,
                      description: l10n.tutorialSearchDesc,
                      content: const _InteractiveSearchExample(),
                    ),
                    _TutorialPage(
                      index: 2,
                      currentIndex: _currentPage,
                      icon: Icons.download_rounded,
                      title: l10n.tutorialDownloadTitle,
                      description: l10n.tutorialDownloadDesc,
                      content: const _InteractiveDownloadExample(),
                    ),
                    _TutorialPage(
                      index: 3,
                      currentIndex: _currentPage,
                      icon: Icons.library_music_rounded,
                      title: l10n.tutorialLibraryTitle,
                      description: l10n.tutorialLibraryDesc,
                      content: _buildFeatureList(context, [
                        (Icons.downloading_rounded, l10n.tutorialLibraryTip1),
                        (Icons.play_circle_fill, l10n.tutorialLibraryTip2),
                        (Icons.grid_view_rounded, l10n.tutorialLibraryTip3),
                      ]),
                    ),
                    _TutorialPage(
                      index: 4,
                      currentIndex: _currentPage,
                      icon: Icons.extension_rounded,
                      title: l10n.tutorialExtensionsTitle,
                      description: l10n.tutorialExtensionsDesc,
                      content: _buildFeatureList(context, [
                        (Icons.extension_rounded, l10n.tutorialExtensionsTip1),
                        (
                          Icons.add_circle_outline_rounded,
                          l10n.tutorialExtensionsTip2,
                        ),
                        (Icons.sync_rounded, l10n.tutorialExtensionsTip3),
                      ]),
                    ),
                    _TutorialPage(
                      index: 5,
                      currentIndex: _currentPage,
                      icon: Icons.settings_rounded,
                      title: l10n.tutorialSettingsTitle,
                      description: l10n.tutorialSettingsDesc,
                      content: Column(
                        children: [
                          _buildFeatureList(context, [
                            (
                              Icons.folder_open_rounded,
                              l10n.tutorialSettingsTip1,
                            ),
                            (Icons.tune_rounded, l10n.tutorialSettingsTip2),
                            (Icons.palette_rounded, l10n.tutorialSettingsTip3),
                          ]),
                          const SizedBox(height: 24),
                          _AnimatedReadyCard(text: l10n.tutorialReadyMessage),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(_totalPages, (index) {
                        final isActive = _currentPage == index;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOutBack,
                          margin: EdgeInsets.symmetric(horizontal: 4 * scale),
                          height: pageIndicatorHeight,
                          width: isActive
                              ? activeIndicatorWidth
                              : pageIndicatorWidth,
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
                    SizedBox(height: bottomGap),
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 400),
                        child: SizedBox(
                          width: double.infinity,
                          height: actionButtonHeight,
                          child: ExpressiveButton(
                            onPressed: _nextPage,
                            style: FilledButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(28),
                              ),
                            ),
                            child: Text(
                              isLastPage
                                  ? l10n.setupGetStarted
                                  : l10n.setupNext,
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
    if (!isDesktopPlatform) return scaffold;
    // Enter moves on, as the default button of a desktop window would.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): _nextPage,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _nextPage,
      },
      child: Focus(autofocus: true, child: scaffold),
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

  Widget _buildFeatureList(
    BuildContext context,
    List<(IconData, String)> features,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      children: features.asMap().entries.map((entry) {
        final index = entry.key;
        final feature = entry.value;
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: Duration(milliseconds: 600 + (index * 200)),
          curve: Curves.easeOutQuart,
          builder: (context, value, child) {
            return Transform.translate(
              offset: Offset(0, 20 * (1 - value)),
              child: Opacity(
                opacity: value,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          feature.$1,
                          size: 24,
                          color: colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: Text(
                          feature.$2,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                color: colorScheme.onSurface,
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      }).toList(),
    );
  }
}

class _AnimatedReadyCard extends StatelessWidget {
  final String text;
  const _AnimatedReadyCard({required this.text});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Row(
        children: [
          Icon(
            Icons.lightbulb_rounded,
            color: colorScheme.onPrimaryContainer,
            size: 28,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InteractiveSearchExample extends StatefulWidget {
  const _InteractiveSearchExample();

  @override
  State<_InteractiveSearchExample> createState() =>
      _InteractiveSearchExampleState();
}

class _InteractiveSearchExampleState extends State<_InteractiveSearchExample> {
  final TextEditingController _controller = TextEditingController();
  bool _showResult = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppSearchField(
            controller: _controller,
            hintText: context.l10n.tutorialSearchHint,
            clearTooltip: context.l10n.dialogClear,
            onClear: () => setState(() => _showResult = false),
            onChanged: (value) {
              setState(() {
                _showResult = value.isNotEmpty;
              });
            },
          ),

          AnimatedSize(
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutBack,
            child: _showResult
                // The result is a plain row inside the demo frame, not a
                // second card.
                ? Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        children: [
                          Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              Icons.music_note_rounded,
                              color: colorScheme.onPrimaryContainer,
                              size: 28,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: double.infinity,
                                  height: 14,
                                  decoration: BoxDecoration(
                                    color: colorScheme.onSurface.withValues(
                                      alpha: 0.1,
                                    ),
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Container(
                                  width: 100,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: colorScheme.onSurfaceVariant
                                        .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Icon(
                            Icons.download_rounded,
                            color: colorScheme.primary,
                          ),
                        ],
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _InteractiveDownloadExample extends StatefulWidget {
  const _InteractiveDownloadExample();

  @override
  State<_InteractiveDownloadExample> createState() =>
      _InteractiveDownloadExampleState();
}

class _InteractiveDownloadExampleState
    extends State<_InteractiveDownloadExample> {
  bool _isDownloading = false;
  double _progress = 0.0;
  bool _isCompleted = false;

  void _startDownload() async {
    if (_isDownloading || _isCompleted) return;

    setState(() {
      _isDownloading = true;
      _progress = 0.0;
    });

    for (int i = 0; i <= 100; i += 5) {
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      setState(() => _progress = i / 100);
    }

    setState(() {
      _isDownloading = false;
      _isCompleted = true;
    });

    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) {
      setState(() {
        _isCompleted = false;
        _progress = 0.0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = constraints.maxWidth;
        final coverSize = (cardWidth * 0.18).clamp(56.0, 80.0);
        final buttonPadding = (coverSize * 0.18).clamp(10.0, 14.0);
        final buttonIconSize = (coverSize * 0.4).clamp(22.0, 30.0);

        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: coverSize,
                height: coverSize,
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(
                  Icons.album_rounded,
                  size: coverSize * 0.5,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: (cardWidth * 0.35).clamp(100.0, 160.0),
                      height: 14,
                      decoration: BoxDecoration(
                        color: colorScheme.onSurface,
                        borderRadius: BorderRadius.circular(7),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_isDownloading)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: AppProgressIndicator.linear(
                          value: _progress,
                          minHeight: 12,
                          trackColor: colorScheme.surfaceContainerHighest,
                          color: colorScheme.primary,
                        ),
                      )
                    else
                      Container(
                        width: (cardWidth * 0.22).clamp(70.0, 100.0),
                        height: 12,
                        decoration: BoxDecoration(
                          color: colorScheme.onSurfaceVariant,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Semantics(
                button: true,
                label: _isCompleted
                    ? context.l10n.tutorialDownloadCompletedSemantics
                    : _isDownloading
                    ? context.l10n.tutorialDownloadInProgressSemantics
                    : context.l10n.tutorialStartDownloadSemantics,
                child: TvTapTarget(
                  onTap: _startDownload,
                  // The visual can shrink on narrow screens; the hit box
                  // keeps the minimum touch target.
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minWidth: context.tokens.minTouchTarget,
                      minHeight: context.tokens.minTouchTarget,
                    ),
                    child: Center(
                      widthFactor: 1,
                      heightFactor: 1,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        padding: EdgeInsets.all(buttonPadding),
                        decoration: BoxDecoration(
                          color: _isCompleted
                              ? colorScheme.tertiary
                              : colorScheme.primary,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color:
                                  (_isCompleted
                                          ? colorScheme.tertiary
                                          : colorScheme.primary)
                                      .withValues(alpha: 0.3),
                              blurRadius: 12,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: _isDownloading
                            ? AppLoadingIndicator(
                                size: buttonIconSize,
                                color: colorScheme.onPrimary,
                              )
                            : ExcludeSemantics(
                                child: Icon(
                                  _isCompleted
                                      ? Icons.check_rounded
                                      : Icons.download_rounded,
                                  color: _isCompleted
                                      ? colorScheme.onTertiary
                                      : colorScheme.onPrimary,
                                  size: buttonIconSize,
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TutorialPage extends StatelessWidget {
  final int index;
  final int currentIndex;
  final IconData icon;
  final String title;
  final String description;
  final Widget content;
  const _TutorialPage({
    required this.index,
    required this.currentIndex,
    required this.icon,
    required this.title,
    required this.description,
    required this.content,
  });

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
                        icon,
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
                        title,
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
                        description,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          height: 1.5,
                          fontSize: 16 * (1 + ((textScale - 1) * 0.1)),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    SizedBox(height: contentGap),
                    content,
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
