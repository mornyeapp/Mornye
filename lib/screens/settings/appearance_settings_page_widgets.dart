part of 'appearance_settings_page.dart';

class _ThemePreviewCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (context.isMornye) {
      return ExcludeSemantics(
        child: IgnorePointer(
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.navLibrary,
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    AppIcon(
                      Icons.library_music_outlined,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 16),
                    Text(
                      context.l10n.appName,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                MornyeTabBar(
                  destinations: [
                    NavigationDestination(
                      icon: const AppIcon(Icons.home_outlined),
                      label: context.l10n.navHome,
                    ),
                    NavigationDestination(
                      icon: const AppIcon(Icons.library_music_outlined),
                      label: context.l10n.navLibrary,
                    ),
                    NavigationDestination(
                      icon: const AppIcon(Icons.settings_outlined),
                      label: context.l10n.navSettings,
                    ),
                  ],
                  selectedIndex: 1,
                  onSelected: (_) {},
                  blurEnabled: false,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cardWidth = constraints.maxWidth;
          final previewHeight = (cardWidth * 0.56).clamp(170.0, 220.0);
          final innerWidth = (cardWidth - 48).clamp(220.0, 320.0);
          final innerHeight = (previewHeight * 0.70).clamp(120.0, 160.0);
          final innerPadding = (innerHeight * 0.11).clamp(12.0, 18.0);
          final artworkSize = (innerHeight - (innerPadding * 2)).clamp(
            80.0,
            120.0,
          );

          return Container(
            height: previewHeight,
            width: double.infinity,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(28),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Positioned(
                  top: -(previewHeight * 0.25),
                  right: -(previewHeight * 0.25),
                  child: Container(
                    width: previewHeight,
                    height: previewHeight,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colorScheme.primaryContainer.withValues(
                        alpha: 0.5,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: -(previewHeight * 0.15),
                  left: -(previewHeight * 0.15),
                  child: Container(
                    width: previewHeight * 0.75,
                    height: previewHeight * 0.75,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colorScheme.tertiaryContainer.withValues(
                        alpha: 0.5,
                      ),
                    ),
                  ),
                ),
                Center(
                  child: Container(
                    width: innerWidth,
                    height: innerHeight,
                    padding: EdgeInsets.all(innerPadding),
                    decoration: BoxDecoration(
                      color: colorScheme.surface,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 12,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: artworkSize,
                          height: artworkSize,
                          decoration: BoxDecoration(
                            color: colorScheme.primary,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: AppIcon(
                            Icons.music_note,
                            color: colorScheme.onPrimary,
                            size: artworkSize * 0.44,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: double.infinity,
                                height: 14,
                                decoration: BoxDecoration(
                                  color: colorScheme.onSurface,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                width: 80,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: colorScheme.primary,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              const SizedBox(height: 24),
                              Row(
                                children: [
                                  AppIcon(
                                    Icons.skip_previous,
                                    size: 24,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 12),
                                  AppIcon(
                                    Icons.play_circle_fill,
                                    size: 32,
                                    color: colorScheme.primary,
                                  ),
                                  const SizedBox(width: 12),
                                  AppIcon(
                                    Icons.skip_next,
                                    size: 24,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                PositionedDirectional(
                  bottom: 12,
                  end: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      isDark
                          ? context.l10n.appearanceThemeDark
                          : context.l10n.appearanceThemeLight,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _MornyeGlassClaritySlider extends ConsumerWidget {
  const _MornyeGlassClaritySlider();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clarity = ref.watch(
      themeProvider.select((settings) => settings.mornyeGlassClarity),
    );
    final notifier = ref.read(themeProvider.notifier);
    final theme = Theme.of(context);
    final l10n = context.l10n;
    // Match the renderer's policy without changing the stored clarity value.
    final contrastBlocked = ref.watch(
      mornyeGlassContrastBlockedProvider(MediaQuery.highContrastOf(context)),
    );
    final adjustable = !contrastBlocked && ref.watch(mornyeBlurEnabledProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.appearanceGlassClarity, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            l10n.appearanceGlassClaritySubtitle,
            style: theme.textTheme.bodySmall,
          ),
          if (!adjustable) ...[
            const SizedBox(height: 8),
            Text(
              contrastBlocked
                  ? l10n.appearanceGlassClarityHighContrast(
                      l10n.appearanceForceBlur,
                    )
                  : l10n.appearanceGlassClarityBlurOff(
                      l10n.appearanceForceBlur,
                    ),
              key: const ValueKey('mornye-glass-clarity-unavailable'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 16),
          ExcludeSemantics(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      for (final color in [
                        theme.colorScheme.primary,
                        const Color(0xff277f94),
                        const Color(0xffc69756),
                      ])
                        // Preview light glass over a light backdrop, as in the
                        // app. Dense sample colors make white glass look gray.
                        theme.brightness == Brightness.light
                            ? Color.lerp(Colors.white, color, 0.4)!
                            : color,
                    ],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: MornyeGlassPanel(
                    radius: 22,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      child: Row(
                        children: [
                          const AppIcon(Icons.music_note_rounded),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Mornye',
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                          const AppIcon(Icons.play_arrow_rounded),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Semantics(
            label: l10n.appearanceGlassClarity,
            child: Slider(
              key: const ValueKey('mornye-glass-clarity'),
              value: clarity,
              divisions: 20,
              label: '${(clarity * 100).round()}%',
              onChanged: adjustable
                  ? (value) =>
                        notifier.setMornyeGlassClarity(value, persist: false)
                  : null,
              onChangeEnd: adjustable ? notifier.setMornyeGlassClarity : null,
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                l10n.appearanceGlassTinted,
                style: theme.textTheme.bodySmall,
              ),
              Text(l10n.appearanceGlassClear, style: theme.textTheme.bodySmall),
            ],
          ),
          if (adjustable && clarity >= 0.9) ...[
            const SizedBox(height: 8),
            Text(
              l10n.appearanceGlassClearPerformance,
              key: const ValueKey('mornye-glass-clear-performance'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MornyeAccentPicker extends StatelessWidget {
  const _MornyeAccentPicker({required this.selected, required this.onChanged});

  final MornyeAccent selected;
  final ValueChanged<MornyeAccent> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final labels = {
      MornyeAccent.red: l10n.appearanceAccentRed,
      MornyeAccent.orange: l10n.appearanceAccentOrange,
      MornyeAccent.green: l10n.appearanceAccentGreen,
      MornyeAccent.teal: l10n.appearanceAccentTeal,
      MornyeAccent.blue: l10n.appearanceAccentBlue,
      MornyeAccent.purple: l10n.appearanceAccentPurple,
      MornyeAccent.pink: l10n.appearanceAccentPink,
    };
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final accent in MornyeAccent.values)
            Builder(
              builder: (context) {
                final color = MornyeTheme.accentColor(
                  accent,
                  Theme.of(context).brightness,
                );
                final foreground =
                    ThemeData.estimateBrightnessForColor(color) ==
                        Brightness.dark
                    ? Colors.white
                    : Colors.black;
                return Semantics(
                  selected: selected == accent,
                  child: IconButton(
                    tooltip: labels[accent],
                    onPressed: () => onChanged(accent),
                    style: IconButton.styleFrom(
                      backgroundColor: color,
                      foregroundColor: foreground,
                      minimumSize: const Size.square(48),
                    ),
                    icon: selected == accent
                        ? const AppIcon(Icons.check)
                        : const SizedBox.square(dimension: 24),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _ColorPalettePicker extends StatelessWidget {
  final int currentColor;
  final ValueChanged<Color> onColorSelected;
  const _ColorPalettePicker({
    required this.currentColor,
    required this.onColorSelected,
  });

  static const _colors = [
    Color(0xFF1DB954),
    Color(0xFF6750A4),
    Color(0xFF0061A4),
    Color(0xFF006E1C),
    Color(0xFFBA1A1A),
    Color(0xFF984061),
    Color(0xFF7D5260),
    Color(0xFF006874),
  ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: _colors.map((color) {
          final isSelected = color.toARGB32() == currentColor;
          final colorHex = color
              .toARGB32()
              .toRadixString(16)
              .padLeft(8, '0')
              .toUpperCase();
          return Padding(
            padding: const EdgeInsetsDirectional.only(end: 12),
            child: Semantics(
              button: true,
              selected: isSelected,
              label: context.l10n.appearanceSelectAccentColor(colorHex),
              child: GestureDetector(
                onTap: () => onColorSelected(color),
                child: _ColorPaletteItem(color: color, isSelected: isSelected),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _ColorPaletteItem extends StatelessWidget {
  final Color color;
  final bool isSelected;

  const _ColorPaletteItem({required this.color, required this.isSelected});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: color,
      brightness: Theme.of(context).brightness,
    );
    final size = 64.0;

    return Stack(
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(20)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Expanded(child: Container(color: scheme.primaryContainer)),
                    Expanded(child: Container(color: scheme.tertiaryContainer)),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: Container(color: scheme.secondaryContainer),
                    ),
                    Expanded(child: Container(color: scheme.surfaceContainer)),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (isSelected)
          Positioned.fill(
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: AppIcon(Icons.check, size: 16, color: scheme.primary),
              ),
            ),
          ),
      ],
    );
  }
}

class _ThemeModeSelector extends StatelessWidget {
  final ThemeMode currentMode;
  final ValueChanged<ThemeMode> onChanged;
  const _ThemeModeSelector({
    required this.currentMode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (context.isMornye) {
      final labels = {
        ThemeMode.system: context.l10n.appearanceThemeSystem,
        ThemeMode.light: context.l10n.appearanceThemeLight,
        ThemeMode.dark: context.l10n.appearanceThemeDark,
      };
      return Padding(
        padding: const EdgeInsets.all(12),
        child: MornyeSegmentedControl(
          labels: labels.values.toList(),
          selectedIndex: labels.keys.toList().indexOf(currentMode),
          onChanged: (index) => onChanged(labels.keys.elementAt(index)),
          samplesBackdrop: false,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: SettingsSegmentedChoice<ThemeMode>(
        selected: currentMode,
        onChanged: onChanged,
        options: [
          SettingsSegmentOption(
            value: ThemeMode.system,
            icon: Icons.brightness_auto,
            label: context.l10n.appearanceThemeSystem,
          ),
          SettingsSegmentOption(
            value: ThemeMode.light,
            icon: Icons.light_mode,
            label: context.l10n.appearanceThemeLight,
          ),
          SettingsSegmentOption(
            value: ThemeMode.dark,
            icon: Icons.dark_mode,
            label: context.l10n.appearanceThemeDark,
          ),
        ],
      ),
    );
  }
}

class _HistoryViewSelector extends StatelessWidget {
  final String currentMode;
  final ValueChanged<String> onChanged;
  const _HistoryViewSelector({
    required this.currentMode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final content = Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 8, bottom: 8),
            child: Text(
              context.l10n.appearanceHistoryView,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          SettingsSegmentedChoice<String>(
            selected: currentMode,
            onChanged: onChanged,
            semanticLabel: context.l10n.appearanceHistoryView,
            options: [
              SettingsSegmentOption(
                value: 'list',
                icon: Icons.view_list,
                label: context.l10n.appearanceHistoryViewList,
              ),
              SettingsSegmentOption(
                value: 'grid',
                icon: Icons.grid_view,
                label: context.l10n.appearanceHistoryViewGrid,
              ),
            ],
          ),
        ],
      ),
    );
    return SettingsSearchTarget(
      label: context.l10n.appearanceHistoryView,
      child: content,
    );
  }
}

class _LanguageSelector extends StatelessWidget {
  final String currentLocale;
  final ValueChanged<String> onChanged;
  const _LanguageSelector({
    required this.currentLocale,
    required this.onChanged,
  });

  String _getLanguageName(String code) {
    for (final lang in appLanguageChoices) {
      if (lang.$1 == code) return lang.$2;
    }
    return code;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final content = ListTile(
      leading: context.isMornye
          ? null
          : AppIcon(Icons.language, color: colorScheme.onSurfaceVariant),
      title: Text(context.l10n.appearanceLanguage),
      subtitle: Text(_getLanguageName(currentLocale)),
      trailing: AppIcon(
        Icons.chevron_right,
        color: colorScheme.onSurfaceVariant,
      ),
      onTap: () => _showLanguagePicker(context),
    );
    return SettingsSearchTarget(
      label: context.l10n.appearanceLanguage,
      child: content,
    );
  }

  void _showLanguagePicker(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.appearanceLanguage,
      builder: (context, controller) => ListView.builder(
        controller: controller,
        shrinkWrap: true,
        itemCount: supportedLanguageChoices.length,
        itemBuilder: (context, index) {
          final lang = supportedLanguageChoices[index];
          final isSelected = currentLocale == lang.$1;
          return AppSheetOption(
            leading: AppIcon(
              lang.$3,
              color: isSelected
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant,
            ),
            title: Text(
              lang.$2,
              style: TextStyle(
                color: isSelected ? colorScheme.primary : colorScheme.onSurface,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            selected: isSelected,
            trailing: isSelected
                ? AppIcon(Icons.check, color: colorScheme.primary)
                : null,
            onTap: () {
              onChanged(lang.$1);
              Navigator.pop(context);
            },
          );
        },
      ),
    );
  }
}
