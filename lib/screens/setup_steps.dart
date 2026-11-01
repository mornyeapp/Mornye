part of 'setup_screen.dart';

extension _SetupScreenSteps on _SetupScreenState {
  /// Expressive FABs keep their icon leading and show loading in its place.
  Widget _buildExpressiveFab(ColorScheme colorScheme) {
    final isLastStep = _currentStep >= _totalSteps - 1;
    return MaterialExpressiveScope(
      child: isLastStep
          ? M3EExtendedFab(
              label: context.l10n.setupGetStarted,
              icon: _isLoading
                  ? AppLoadingIndicator(size: 24, color: colorScheme.onPrimary)
                  : const AppIcon(Icons.check),
              color: M3EFabColor.primaryFilled,
              onPressed: _isLoading ? null : _completeSetup,
            )
          : M3EExtendedFab(
              label: context.l10n.setupNext,
              icon: const AppIcon(Icons.arrow_forward),
              onPressed: !_isLoading && _isStepCompleted(_currentStep)
                  ? _nextPage
                  : null,
            ),
    );
  }

  Widget _buildWelcomeStep(ColorScheme colorScheme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final shortestSide = MediaQuery.sizeOf(context).shortestSide;
        final textScale = MediaQuery.textScalerOf(
          context,
        ).scale(1.0).clamp(1.0, 1.4);
        final logoSize = (shortestSide * 0.24).clamp(80.0, 104.0);
        final titleGap = (shortestSide * 0.06).clamp(16.0, 32.0);
        final subtitleGap = (shortestSide * 0.04).clamp(8.0, 16.0);
        const totalPadding = 48.0 + _headerHeight;
        final minContentHeight = constraints.maxHeight > totalPadding
            ? constraints.maxHeight - totalPadding
            : 0.0;

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 24 + _headerHeight),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: minContentHeight,
                maxWidth: 560,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset(
                    'assets/images/logo-transparent.png',
                    width: logoSize,
                    height: logoSize,
                    color: colorScheme.primary,
                    fit: BoxFit.contain,
                  ),
                  SizedBox(height: titleGap),
                  Text(
                    context.l10n.appName,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                      fontSize:
                          (Theme.of(context).textTheme.displaySmall?.fontSize ??
                              36) *
                          (1 + ((textScale - 1) * 0.18)),
                    ),
                  ),
                  SizedBox(height: subtitleGap),
                  Text(
                    context.l10n.setupDownloadInFlac,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _onLanguageSelected(String locale) {
    _setState(() => _selectedLocale = locale);
    ref.read(settingsProvider.notifier).setLocale(locale);
  }

  Widget _buildLanguageStep(ColorScheme colorScheme) {
    final languages = supportedLanguageChoices;

    return LayoutBuilder(
      builder: (context, constraints) {
        final shortestSide = MediaQuery.sizeOf(context).shortestSide;
        final iconPadding = (shortestSide * 0.06).clamp(16.0, 24.0);
        final iconSize = (shortestSide * 0.12).clamp(32.0, 48.0);
        final titleGap = (shortestSide * 0.06).clamp(16.0, 32.0);
        final descriptionGap = (shortestSide * 0.04).clamp(8.0, 16.0);
        final actionGap = (shortestSide * 0.09).clamp(20.0, 48.0);
        // Desktop already centers setup in a narrow column, so the inset
        // follows this step's width rather than the window's.
        final inset = wideInsetForWidth(
          constraints.maxWidth,
          contentMaxWidth: 560,
        );

        return Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(24 + inset, 24, 24 + inset, 0),
              child: Column(
                children: [
                  Container(
                    padding: EdgeInsets.all(iconPadding),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.translate,
                      size: iconSize,
                      color: colorScheme.primary,
                    ),
                  ),
                  SizedBox(height: titleGap),
                  Text(
                    context.l10n.setupLanguageTitle,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: descriptionGap),
                  Text(
                    context.l10n.setupLanguageDescription,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: actionGap),
                ],
              ),
            ),
            Expanded(
              child: ScrollEdgeFade(
                child: Scrollbar(
                  controller: _languageScrollController,
                  thumbVisibility: true,
                  child: _buildLanguageList(languages, colorScheme, inset),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLanguageList(
    List<(String, String, IconData)> languages,
    ColorScheme colorScheme,
    double inset,
  ) {
    return ListView.builder(
      controller: _languageScrollController,
      padding: EdgeInsets.fromLTRB(24 + inset, 0, 24 + inset, 80),
      itemCount: languages.length,
      itemBuilder: (context, index) {
        final lang = languages[index];
        final code = lang.$1;
        final name = lang.$2;
        final isSelected = _selectedLocale == code;

        // Expressive rows morph into a pill as they become selected.
        final shapeMotion = AppMotion.spatial(
          context,
          const AppMotionSpec(Duration.zero, Curves.linear),
        );
        final fillMotion = AppMotion.effects(
          context,
          const AppMotionSpec(Duration.zero, Curves.linear),
        );
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: isSelected ? 1 : 0),
            duration: fillMotion.duration,
            curve: fillMotion.curve,
            builder: (context, fill, child) => TweenAnimationBuilder<double>(
              tween: Tween(
                end: isSelected && materialExpressiveEnabled(context) ? 28 : 16,
              ),
              duration: shapeMotion.duration,
              curve: shapeMotion.curve,
              builder: (context, radius, child) => Material(
                color: Color.lerp(
                  colorScheme.primaryContainer.withValues(alpha: 0),
                  colorScheme.primaryContainer,
                  fill.clamp(0.0, 1.0),
                ),
                borderRadius: BorderRadius.circular(radius.clamp(0.0, 32.0)),
                clipBehavior: Clip.antiAlias,
                child: child,
              ),
              child: child,
            ),
            child: InkWell(
              onTap: () => _onLanguageSelected(code),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Icon(
                      lang.$3,
                      color: isSelected
                          ? colorScheme.onPrimaryContainer
                          : colorScheme.onSurfaceVariant,
                      size: 22,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        code == 'system'
                            ? context.l10n.setupLanguageSystemDefault
                            : name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: isSelected
                              ? colorScheme.onPrimaryContainer
                              : colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (isSelected)
                      Icon(
                        Icons.check_circle,
                        color: colorScheme.onPrimaryContainer,
                        size: 22,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStorageStep(ColorScheme colorScheme) {
    return _StepLayout(
      title: context.l10n.setupStorageRequired,
      description: context.l10n.setupStorageDescription,
      icon: Icons.folder,
      child: _storagePermissionGranted
          ? _SuccessCard(
              text: context.l10n.setupStorageGranted,
              colorScheme: colorScheme,
            )
          : ExpressiveButton(
              tonal: true,
              onPressed: _requestStoragePermission,
              icon: const Icon(Icons.folder_open),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
              ),
              child: Text(context.l10n.setupGrantPermission),
            ),
    );
  }

  Widget _buildNotificationStep(ColorScheme colorScheme) {
    return _StepLayout(
      title: context.l10n.setupNotificationEnable,
      description: context.l10n.setupNotificationBackgroundDescription,
      icon: Icons.notifications,
      child: _notificationPermissionGranted || _notificationPermissionSkipped
          ? _SuccessCard(
              text: context.l10n.setupNotificationGranted,
              colorScheme: colorScheme,
            )
          : Column(
              children: [
                ExpressiveButton(
                  tonal: true,
                  onPressed: _requestNotificationPermission,
                  icon: const Icon(Icons.notifications_active),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 16,
                    ),
                  ),
                  child: Text(context.l10n.setupEnableNotifications),
                ),
                ExpressiveButton(
                  text: true,
                  onPressed: () async {
                    _setState(() => _notificationPermissionSkipped = true);
                    await _saveProgress();
                  },
                  child: Text(context.l10n.setupSkipForNow),
                ),
              ],
            ),
    );
  }

  Widget _buildNearbyStep(ColorScheme colorScheme) {
    return _StepLayout(
      title: context.l10n.setupNearbyEnable,
      description: context.l10n.setupNearbyDescription,
      icon: Icons.devices,
      // No Skip: Android 17 blocks Link and network storage without it.
      // A refusal still enables Next, so nobody is stuck here.
      child: _nearbyGranted
          ? _SuccessCard(
              text: context.l10n.setupNearbyGranted,
              colorScheme: colorScheme,
            )
          : ExpressiveButton(
              tonal: true,
              onPressed: _requestNearbyDevices,
              icon: const Icon(Icons.wifi_find),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
              ),
              child: Text(context.l10n.setupNearbyEnable),
            ),
    );
  }

  Widget _buildDirectoryStep(ColorScheme colorScheme) {
    return _StepLayout(
      title: context.l10n.setupFolderChoose,
      description: _platform == TargetPlatform.android
          ? context.l10n.storageDownloadFolderHint
          : context.l10n.setupFolderDescription,
      icon: Icons.create_new_folder,
      child: Column(
        children: [
          if (_selectedDirectory != null)
            AppContentCard(
              color: colorScheme.secondaryContainer,
              mornyeSurface: false,
              child: ListTile(
                leading: Icon(
                  Icons.folder,
                  color: colorScheme.onSecondaryContainer,
                ),
                title: Text(
                  _selectedDirectory!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: AppIconButton(
                  tooltip: context.l10n.setupChangeFolderTooltip,
                  icon: const Icon(Icons.edit),
                  onPressed: _selectDirectory,
                ),
              ),
            )
          else
            ExpressiveButton(
              tonal: true,
              onPressed: _selectDirectory,
              icon: const Icon(Icons.create_new_folder),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
              ),
              child: Text(context.l10n.setupSelectFolder),
            ),
          const ExtensionStorageSetting(),
        ],
      ),
    );
  }
}

class _StepLayout extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;
  final Widget child;

  const _StepLayout({
    required this.title,
    required this.description,
    required this.icon,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final shortestSide = MediaQuery.sizeOf(context).shortestSide;
        final iconPadding = (shortestSide * 0.06).clamp(16.0, 24.0);
        final iconSize = (shortestSide * 0.12).clamp(32.0, 48.0);
        final titleGap = (shortestSide * 0.06).clamp(16.0, 32.0);
        final descriptionGap = (shortestSide * 0.04).clamp(8.0, 16.0);
        final actionGap = (shortestSide * 0.09).clamp(20.0, 48.0);
        // Extra bottom padding offsets the 80dp header above the PageView so
        // the content sits at the optical center of the full screen.
        const totalPadding = 48.0 + _headerHeight;
        final minContentHeight = constraints.maxHeight > totalPadding
            ? constraints.maxHeight - totalPadding
            : 0.0;

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 24 + _headerHeight),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: minContentHeight,
                maxWidth: 560,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: EdgeInsets.all(iconPadding),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      icon,
                      size: iconSize,
                      color: colorScheme.primary,
                    ),
                  ),
                  SizedBox(height: titleGap),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: descriptionGap),
                  Text(
                    description,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: actionGap),
                  child,
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SuccessCard extends StatelessWidget {
  final String text;
  final ColorScheme colorScheme;

  const _SuccessCard({required this.text, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle, color: colorScheme.onPrimaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: colorScheme.onPrimaryContainer,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
