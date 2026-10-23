part of 'extensions_page.dart';

class _ExtensionItem extends StatelessWidget {
  final Extension extension;
  final ExtensionHealthStatus? healthStatus;
  final bool showDivider;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;

  const _ExtensionItem({
    required this.extension,
    this.healthStatus,
    required this.showDivider,
    required this.onTap,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasError = extension.status == 'error';
    final serviceHealthStatus = extension.hasServiceHealth
        ? healthStatus?.status
        : null;
    final serviceHealthColor = serviceHealthStatus == null
        ? null
        : extensionHealthColor(context, serviceHealthStatus);

    return ExtensionRow(
      showDivider: showDivider,
      onTap: onTap,
      avatar: context.isMornye
          ? null
          : ExtensionAvatar(
              filePath: extension.iconPath,
              fallbackIcon: hasError ? Icons.error_outline : Icons.extension,
              background: hasError
                  ? colorScheme.errorContainer
                  : colorScheme.primaryContainer,
              foreground: hasError
                  ? colorScheme.error
                  : colorScheme.onPrimaryContainer,
            ),
      title: Text(extension.displayName),
      subtitle: Text.rich(
        hasError
            ? TextSpan(
                text: context.friendlyError(
                  extension.errorMessage,
                  fallback: context.l10n.extensionsErrorLoading,
                ),
              )
            : TextSpan(
                text: 'v${extension.version}',
                children: [
                  if (serviceHealthStatus != null) ...[
                    const TextSpan(text: ' · '),
                    TextSpan(
                      text: _extensionHealthLabel(context, serviceHealthStatus),
                      style: TextStyle(color: serviceHealthColor),
                    ),
                  ],
                ],
              ),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: hasError ? colorScheme.error : colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: AppSwitch(
        value: extension.enabled,
        semanticLabel: extension.displayName,
        onChanged: hasError ? null : onToggle,
      ),
    );
  }
}

String _extensionHealthLabel(BuildContext context, String status) {
  switch (status) {
    case 'online':
      return context.l10n.extensionHealthOnline;
    case 'degraded':
      return context.l10n.extensionHealthDegraded;
    case 'offline':
      return context.l10n.extensionHealthOffline;
    default:
      return context.l10n.extensionHealthUnknown;
  }
}

enum _PriorityLink { download, fallback, metadata }

class _ExtensionPriorityLink extends ConsumerWidget {
  const _ExtensionPriorityLink(this.kind);

  final _PriorityLink kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final metadata = kind == _PriorityLink.metadata;
    final enabled = ref
        .watch(extensionProvider)
        .extensions
        .any(
          (e) =>
              e.enabled &&
              (metadata ? e.hasMetadataProvider : e.hasDownloadProvider),
        );
    final (icon, title, subtitle, page) = switch (kind) {
      _PriorityLink.download => (
        Icons.download,
        l10n.extensionsDownloadPriority,
        l10n.extensionsDownloadPrioritySubtitle,
        const ProviderPriorityPage(),
      ),
      _PriorityLink.fallback => (
        Icons.alt_route,
        l10n.extensionsFallbackTitle,
        l10n.extensionsFallbackSubtitle,
        const DownloadFallbackExtensionsPage(),
      ),
      _PriorityLink.metadata => (
        Icons.search,
        l10n.extensionsMetadataPriority,
        l10n.extensionsMetadataPrioritySubtitle,
        const MetadataProviderPriorityPage(),
      ),
    };

    // The standard row keeps these links in line with the other settings
    // rows of the group in both styles.
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: SettingsItem(
        icon: icon,
        title: title,
        subtitle: enabled
            ? subtitle
            : metadata
            ? l10n.extensionsNoMetadataProvider
            : l10n.extensionsNoDownloadProvider,
        onTap: enabled
            ? () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => page),
              )
            : null,
      ),
    );
  }
}

class _SearchProviderSelector extends ConsumerWidget {
  const _SearchProviderSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final extState = ref.watch(extensionProvider);

    final searchProviders = extState.extensions
        .where((e) => e.enabled && e.hasCustomSearch)
        .toList();

    final hasAnyProvider = searchProviders.isNotEmpty;

    final resolvedProviderId =
        (settings.searchProvider != null && settings.searchProvider!.isNotEmpty)
        ? settings.searchProvider!
        : searchProviders.firstOrNull?.id;
    String currentProviderName = context.l10n.optionsPrimaryProviderSubtitle;
    if (resolvedProviderId != null && resolvedProviderId.isNotEmpty) {
      final ext = searchProviders
          .where((e) => e.id == resolvedProviderId)
          .firstOrNull;
      currentProviderName = ext?.displayName ?? resolvedProviderId;
    }

    return Opacity(
      opacity: hasAnyProvider ? 1 : 0.5,
      child: SettingsItem(
        icon: Icons.manage_search,
        title: context.l10n.extensionsSearchProvider,
        subtitle: hasAnyProvider
            ? currentProviderName
            : context.l10n.extensionsNoCustomSearch,
        onTap: hasAnyProvider
            ? () => _showSearchProviderPicker(
                context,
                ref,
                settings,
                searchProviders,
              )
            : null,
      ),
    );
  }

  void _showSearchProviderPicker(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    List<Extension> searchProviders,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.extensionsSearchProvider,
      subtitle: context.l10n.extensionsSearchProviderDescription,
      builder: (ctx, controller) => SingleChildScrollView(
        controller: controller,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...searchProviders.map(
              (ext) => AppSheetOption(
                leading: AppIcon(Icons.extension, color: colorScheme.secondary),
                title: Text(ext.displayName),
                subtitle: Text(
                  ext.searchBehavior?.placeholder ??
                      ctx.l10n.extensionsCustomSearch,
                ),
                selected: settings.searchProvider == ext.id,
                trailing: settings.searchProvider == ext.id
                    ? AppIcon(Icons.check_circle, color: colorScheme.primary)
                    : AppIcon(
                        Icons.circle_outlined,
                        color: colorScheme.outline,
                      ),
                onTap: () {
                  ref.read(settingsProvider.notifier).setSearchProvider(ext.id);
                  Navigator.pop(ctx);
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _HomeFeedProviderSelector extends ConsumerWidget {
  const _HomeFeedProviderSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final extState = ref.watch(extensionProvider);

    final homeFeedProviders = extState.extensions
        .where((e) => e.enabled && e.hasHomeFeed)
        .toList();

    final hasAnyProvider = homeFeedProviders.isNotEmpty;
    final homeFeedDisabled =
        settings.homeFeedProvider == AppSettings.homeFeedProviderOff;

    String currentProviderName = context.l10n.extensionsHomeFeedAuto;
    if (homeFeedDisabled) {
      currentProviderName = context.l10n.extensionsHomeFeedOff;
    } else if (settings.homeFeedProvider != null &&
        settings.homeFeedProvider!.isNotEmpty) {
      final ext = homeFeedProviders
          .where((e) => e.id == settings.homeFeedProvider)
          .firstOrNull;
      currentProviderName = ext?.displayName ?? settings.homeFeedProvider!;
    }

    return SettingsItem(
      icon: Icons.explore_outlined,
      title: context.l10n.extensionsHomeFeedProvider,
      subtitle: !hasAnyProvider && !homeFeedDisabled
          ? context.l10n.extensionsNoHomeFeedExtensions
          : currentProviderName,
      showDivider: false,
      onTap: () => _showHomeFeedProviderPicker(
        context,
        ref,
        settings,
        homeFeedProviders,
      ),
    );
  }

  void _showHomeFeedProviderPicker(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    List<Extension> homeFeedProviders,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.extensionsHomeFeedProvider,
      subtitle: context.l10n.extensionsHomeFeedDescription,
      builder: (ctx, controller) => SingleChildScrollView(
        controller: controller,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppSheetOption(
              leading: AppIcon(Icons.auto_awesome, color: colorScheme.primary),
              title: Text(ctx.l10n.extensionsHomeFeedAuto),
              subtitle: Text(ctx.l10n.extensionsHomeFeedAutoSubtitle),
              trailing:
                  (settings.homeFeedProvider == null ||
                      settings.homeFeedProvider!.isEmpty)
                  ? AppIcon(Icons.check_circle, color: colorScheme.primary)
                  : AppIcon(Icons.circle_outlined, color: colorScheme.outline),
              onTap: () {
                ref.read(settingsProvider.notifier).setHomeFeedProvider(null);
                ref.read(exploreProvider.notifier).refresh();
                Navigator.pop(ctx);
              },
            ),
            AppSheetOption(
              leading: AppIcon(Icons.block, color: colorScheme.error),
              title: Text(ctx.l10n.extensionsHomeFeedOff),
              subtitle: Text(ctx.l10n.extensionsHomeFeedOffSubtitle),
              selected:
                  settings.homeFeedProvider == AppSettings.homeFeedProviderOff,
              trailing:
                  settings.homeFeedProvider == AppSettings.homeFeedProviderOff
                  ? AppIcon(Icons.check_circle, color: colorScheme.primary)
                  : AppIcon(Icons.circle_outlined, color: colorScheme.outline),
              onTap: () {
                ref
                    .read(settingsProvider.notifier)
                    .setHomeFeedProvider(AppSettings.homeFeedProviderOff);
                ref.read(exploreProvider.notifier).clear();
                Navigator.pop(ctx);
              },
            ),
            if (homeFeedProviders.isEmpty)
              AppSheetOption(
                enabled: false,
                leading: AppIcon(
                  Icons.extension_off,
                  color: colorScheme.outline,
                ),
                title: Text(ctx.l10n.extensionsNoHomeFeedExtensions),
              ),
            ...homeFeedProviders.map(
              (ext) => AppSheetOption(
                leading: AppIcon(Icons.extension, color: colorScheme.secondary),
                title: Text(ext.displayName),
                subtitle: Text(ctx.l10n.extensionsHomeFeedUse(ext.displayName)),
                selected: settings.homeFeedProvider == ext.id,
                trailing: settings.homeFeedProvider == ext.id
                    ? AppIcon(Icons.check_circle, color: colorScheme.primary)
                    : AppIcon(
                        Icons.circle_outlined,
                        color: colorScheme.outline,
                      ),
                onTap: () {
                  ref
                      .read(settingsProvider.notifier)
                      .setHomeFeedProvider(ext.id);
                  ref.read(exploreProvider.notifier).refresh();
                  Navigator.pop(ctx);
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
