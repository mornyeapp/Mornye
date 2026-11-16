part of 'download_settings_page.dart';

class _RegionPickerSheet extends StatefulWidget {
  const _RegionPickerSheet({
    required this.regions,
    required this.selected,
    required this.countryNameOf,
    required this.onSelected,
    required this.scrollController,
  });

  final List<String> regions;
  final String selected;
  final String Function(BuildContext context, String code) countryNameOf;
  final ValueChanged<String> onSelected;
  final ScrollController scrollController;

  @override
  State<_RegionPickerSheet> createState() => _RegionPickerSheetState();
}

class _RegionPickerSheetState extends State<_RegionPickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final query = _query.trim().toLowerCase();
    final matches = query.isEmpty
        ? widget.regions
        : widget.regions.where((code) {
            if (code.toLowerCase().contains(query)) return true;
            return widget
                .countryNameOf(context, code)
                .toLowerCase()
                .contains(query);
          }).toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: AppSearchField(
            controller: _searchController,
            onChanged: (value) => setState(() => _query = value),
            hintText: MaterialLocalizations.of(context).searchFieldLabel,
            clearTooltip: context.l10n.dialogClear,
            onClear: () => setState(() => _query = ''),
          ),
        ),
        Flexible(
          child: matches.isEmpty
              ? ListView(
                  controller: widget.scrollController,
                  shrinkWrap: true,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        context.l10n.searchEmptyResultSubtitle,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                )
              : ListView.builder(
                  controller: widget.scrollController,
                  shrinkWrap: true,
                  itemCount: matches.length,
                  itemBuilder: (context, index) {
                    final code = matches[index];
                    final isSelected = code == widget.selected;
                    final countryName = widget.countryNameOf(context, code);
                    return AppSheetOption.choice(
                      title: Text(countryName != code ? countryName : code),
                      subtitle: countryName != code ? Text(code) : null,
                      selected: isSelected,
                      onTap: () => widget.onSelected(code),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _QualityOption extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;
  final bool showDivider;

  const _QualityOption({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.isSelected,
    required this.onTap,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SettingsItem(
      icon: icon,
      title: title,
      subtitle: subtitle,
      selected: isSelected,
      trailing: isSelected
          ? AppIcon(Icons.check, color: colorScheme.primary)
          : null,
      onTap: onTap,
      showDivider: showDivider,
    );
  }
}

class _ServiceSelector extends ConsumerWidget {
  final String currentService;
  final ValueChanged<String> onChanged;
  const _ServiceSelector({
    required this.currentService,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final extState = ref.watch(extensionProvider);

    final extensionProviders = extState.extensions
        .where((e) => e.enabled && e.hasDownloadProvider)
        .toList();

    final effectiveService =
        extensionProviders.any((extension) => extension.id == currentService)
        ? currentService
        : '';

    return Padding(
      padding: const EdgeInsets.all(12),
      child: extensionProviders.isEmpty
          ? Row(
              children: [
                AppIcon(
                  Icons.info_outline,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    context.l10n.extensionsNoDownloadProvider,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                const spacing = 8.0;
                final columns = (constraints.maxWidth / 320).floor().clamp(
                  2,
                  4,
                );
                final chipWidth =
                    (constraints.maxWidth - spacing * (columns - 1)) / columns;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    for (final extension in extensionProviders)
                      SizedBox(
                        width: chipWidth,
                        child: SettingsChoiceChip(
                          layout: SettingsChipLayout.column,
                          icon: Icons.extension,
                          label: extension.displayName,
                          isSelected: effectiveService == extension.id,
                          onTap: () => onChanged(extension.id),
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }
}

class _MetadataSourceSelector extends ConsumerWidget {
  const _MetadataSourceSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider);
    final extState = ref.watch(extensionProvider);

    final rawSearchProvider = settings.searchProvider?.trim() ?? '';
    final primarySearchExtension = defaultSearchExtension(extState.extensions);
    final defaultProviderTarget =
        primarySearchExtension?.displayName ??
        context.l10n.extensionsNoCustomSearch;
    final defaultProviderLabel =
        '${context.l10n.extensionsHomeFeedAuto} ($defaultProviderTarget)';
    final searchProvider =
        extState.extensions.any(
          (e) => e.enabled && e.hasCustomSearch && e.id == rawSearchProvider,
        )
        ? rawSearchProvider
        : '';

    Extension? activeExtension;
    if (searchProvider.isNotEmpty) {
      activeExtension = extState.extensions
          .where((e) => e.id == searchProvider && e.enabled)
          .firstOrNull;
    }
    final hasNonDefaultProvider = activeExtension != null;

    String subtitle;
    if (activeExtension != null) {
      subtitle = context.l10n.optionsUsingExtension(
        activeExtension.displayName,
      );
    } else {
      subtitle = context.l10n.optionsPrimaryProviderSubtitle;
    }

    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.optionsPrimaryProvider,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: hasNonDefaultProvider
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          SettingsChoiceGrid(
            children: [
              SettingsChoiceChip(
                icon: Icons.auto_awesome,
                label: defaultProviderLabel,
                isSelected: searchProvider.isEmpty,
                onTap: () =>
                    ref.read(settingsProvider.notifier).setSearchProvider(''),
              ),
              for (final ext in extState.extensions.where(
                (e) => e.enabled && e.hasCustomSearch,
              ))
                SettingsChoiceChip(
                  icon: Icons.extension,
                  label: ext.displayName,
                  isSelected: searchProvider == ext.id,
                  onTap: () => ref
                      .read(settingsProvider.notifier)
                      .setSearchProvider(ext.id),
                ),
            ],
          ),
        ],
      ),
    );
    return SettingsSearchTarget(
      label: context.l10n.optionsPrimaryProvider,
      child: content,
    );
  }
}

class _DefaultSearchTabSelector extends ConsumerWidget {
  const _DefaultSearchTabSelector();

  String _labelForTab(BuildContext context, String tab) {
    return switch (tab) {
      'track' => context.l10n.searchTracks,
      'artist' => context.l10n.searchArtists,
      'album' => context.l10n.searchAlbums,
      'playlist' => context.l10n.searchPlaylists,
      _ => context.l10n.historyFilterAll,
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final current = settings.defaultSearchTab;

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.optionsDefaultSearchTab,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          Text(
            context.l10n.optionsDefaultSearchTabSubtitle,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          SettingsChoiceGrid(
            children: [
              for (final tab in const [
                'all',
                'track',
                'artist',
                'album',
                'playlist',
              ])
                SettingsChoiceChip(
                  icon: switch (tab) {
                    'track' => Icons.music_note,
                    'artist' => Icons.person,
                    'album' => Icons.album,
                    'playlist' => Icons.queue_music,
                    _ => Icons.grid_view,
                  },
                  label: _labelForTab(context, tab),
                  isSelected: current == tab,
                  onTap: () => ref
                      .read(settingsProvider.notifier)
                      .setDefaultSearchTab(tab),
                ),
            ],
          ),
        ],
      ),
    );
    return SettingsSearchTarget(
      label: context.l10n.optionsDefaultSearchTab,
      child: content,
    );
  }
}

/// Which TPDF Smart Dither adds: plain or high-pass, a two-way choice under
/// its title and the current choice's description.
class _SmartDitherTypeChoice extends StatelessWidget {
  const _SmartDitherTypeChoice({
    required this.highPass,
    required this.enabled,
    required this.onChanged,
  });

  final bool highPass;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final title = l10n.trackConvertDitherSmartType;
    final showIcon = !context.isMornye;
    final content = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.tokens.rowPaddingH,
        vertical: context.tokens.rowPaddingVCompact,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (showIcon) ...[
                AppIcon(
                  Icons.waves,
                  color: enabled
                      ? colorScheme.onSurfaceVariant
                      : colorScheme.outline,
                  size: 24,
                ),
                SizedBox(width: context.tokens.rowIconGap),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: textTheme.bodyLarge?.copyWith(
                        color: enabled ? null : colorScheme.outline,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      highPass
                          ? l10n.trackConvertDitherHighPassDescription
                          : l10n.trackConvertDitherPlainDescription,
                      style: textTheme.bodyMedium?.copyWith(
                        color: enabled
                            ? colorScheme.onSurfaceVariant
                            : colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SettingsSegmentedChoice<bool>(
            selected: highPass,
            enabled: enabled,
            onChanged: onChanged,
            semanticLabel: title,
            options: [
              SettingsSegmentOption(
                value: false,
                label: l10n.trackConvertDitherTriangular,
              ),
              SettingsSegmentOption(
                value: true,
                label: l10n.trackConvertDitherTriangularHp,
              ),
            ],
          ),
        ],
      ),
    );
    return SettingsSearchTarget(label: title, child: content);
  }
}
