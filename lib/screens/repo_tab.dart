import 'package:flutter/material.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons, CupertinoTextField;
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_text_field.dart';
import 'package:mornye/widgets/app_refresh_indicator.dart';
import 'package:mornye/widgets/extension_row.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/widgets/app_search_field.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/repo_provider.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/screens/repo/extension_details_screen.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/extension_repo_card.dart';
import 'package:mornye/widgets/app_choice_chip.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';

class RepoTab extends ConsumerStatefulWidget {
  const RepoTab({super.key});

  @override
  ConsumerState<RepoTab> createState() => _RepoTabState();
}

class _RepoTabState extends ConsumerState<RepoTab> {
  final _searchController = TextEditingController();
  final _repoUrlController = TextEditingController();
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;

    final cacheDir = await getApplicationCacheDirectory();

    if (!mounted) return;

    await ref.read(repoProvider.notifier).initialize(cacheDir.path);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _repoUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final storeFilterState = ref.watch(
      repoProvider.select(
        (s) => (s.extensions, s.selectedCategory, s.searchQuery),
      ),
    );
    final extensions = storeFilterState.$1;
    final selectedCategory = storeFilterState.$2;
    final searchQuery = storeFilterState.$3;
    final isLoading = ref.watch(repoProvider.select((s) => s.isLoading));
    final error = ref.watch(repoProvider.select((s) => s.error));
    final downloadingId = ref.watch(
      repoProvider.select((s) => s.downloadingId),
    );
    final hasRegistryUrl = ref.watch(
      repoProvider.select((s) => s.hasRegistryUrl),
    );
    final registryUrl = ref.watch(repoProvider.select((s) => s.registryUrl));
    final filteredExtensions = RepoState(
      extensions: extensions,
      selectedCategory: selectedCategory,
      searchQuery: searchQuery,
    ).filteredExtensions;
    if (_searchController.text != searchQuery) {
      _searchController.value = TextEditingValue(
        text: searchQuery,
        selection: TextSelection.collapsed(offset: searchQuery.length),
      );
    }
    final colorScheme = Theme.of(context).colorScheme;
    // Controls share the centered column of the extension list on tablets.
    // Desktop fills the pane with a grid instead, with the same edges as the
    // other tabs.
    final edge = 16 + wideListInset(context);
    final desktopColumns = isDesktopPlatform
        ? _desktopGridColumns(MediaQuery.sizeOf(context).width - edge * 2)
        : 1;

    return Scaffold(
      body: AppRefreshIndicator(
        onRefresh: () =>
            ref.read(repoProvider.notifier).refresh(forceRefresh: true),
        child: CustomScrollView(
          slivers: [
            AppSliverHeader.tabRoot(
              alignToContent: true,
              title: context.l10n.storeTitle,
              actions: [
                if (hasRegistryUrl)
                  AppIconButton(
                    icon: Icon(
                      context.isMornye ? CupertinoIcons.link : Icons.link,
                    ),
                    tooltip: context.l10n.storeChangeRepoTooltip,
                    onPressed: () => _showChangeRepoDialog(registryUrl),
                  ),
              ],
            ),

            if (!hasRegistryUrl)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Builder(
                  builder: (context) =>
                      _buildSetupRepoState(context, colorScheme, error),
                ),
              )
            else ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(edge, 8, edge, 8),
                  // Full width like the Home and Library search fields.
                  child: AppSearchField(
                    controller: _searchController,
                    hintText: context.l10n.storeSearch,
                    clearTooltip: context.l10n.dialogClear,
                    samplesBackdrop: false,
                    onChanged: (value) =>
                        ref.read(repoProvider.notifier).setSearchQuery(value),
                    onClear: () =>
                        ref.read(repoProvider.notifier).setSearchQuery(''),
                  ),
                ),
              ),

              SliverToBoxAdapter(
                child: _CategoryChipRow(
                  edge: edge,
                  children: [
                    _CategoryChip(
                      label: context.l10n.storeFilterAll,
                      icon: Icons.apps,
                      isSelected: selectedCategory == null,
                      onTap: () =>
                          ref.read(repoProvider.notifier).setCategory(null),
                    ),
                    _CategoryChip(
                      label: context.l10n.storeFilterMetadata,
                      icon: Icons.label_outline,
                      isSelected: selectedCategory == RepoCategory.metadata,
                      onTap: () => ref
                          .read(repoProvider.notifier)
                          .setCategory(RepoCategory.metadata),
                    ),
                    _CategoryChip(
                      label: context.l10n.storeFilterDownload,
                      icon: Icons.download_outlined,
                      isSelected: selectedCategory == RepoCategory.download,
                      onTap: () => ref
                          .read(repoProvider.notifier)
                          .setCategory(RepoCategory.download),
                    ),
                    _CategoryChip(
                      label: context.l10n.storeFilterUtility,
                      icon: Icons.build_outlined,
                      isSelected: selectedCategory == RepoCategory.utility,
                      onTap: () => ref
                          .read(repoProvider.notifier)
                          .setCategory(RepoCategory.utility),
                    ),
                    _CategoryChip(
                      label: context.l10n.storeFilterLyrics,
                      icon: Icons.lyrics_outlined,
                      isSelected: selectedCategory == RepoCategory.lyrics,
                      onTap: () => ref
                          .read(repoProvider.notifier)
                          .setCategory(RepoCategory.lyrics),
                    ),
                    _CategoryChip(
                      label: context.l10n.storeFilterIntegration,
                      icon: Icons.link,
                      isSelected: selectedCategory == RepoCategory.integration,
                      onTap: () => ref
                          .read(repoProvider.notifier)
                          .setCategory(RepoCategory.integration),
                    ),
                  ],
                ),
              ),

              if (isLoading && extensions.isEmpty)
                SliverToBoxAdapter(child: _RepoListSkeleton(edge: edge))
              else if (error != null && extensions.isEmpty)
                SliverFillRemaining(child: _buildErrorState(error, colorScheme))
              else if (filteredExtensions.isEmpty)
                SliverFillRemaining(
                  child: _buildEmptyState(
                    hasFilters:
                        searchQuery.isNotEmpty || selectedCategory != null,
                    colorScheme: colorScheme,
                  ),
                )
              else ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(edge, 8, edge, 8),
                    child: Text(
                      context.l10n.storeExtensionsCount(
                        filteredExtensions.length,
                      ),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),

                if (desktopColumns > 1)
                  _desktopExtensionGrid(
                    filteredExtensions,
                    columns: desktopColumns,
                    edge: edge,
                    downloadingId: downloadingId,
                  )
                else if (context.isMornye)
                  SliverToBoxAdapter(
                    child: ExtensionRepoCard(
                      margin: EdgeInsets.symmetric(
                        horizontal: edge,
                        vertical: 4,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: filteredExtensions.asMap().entries.map((
                          entry,
                        ) {
                          final index = entry.key;
                          final ext = entry.value;
                          return _ExtensionItem(
                            extension: ext,
                            showDivider: index < filteredExtensions.length - 1,
                            isDownloading: downloadingId == ext.id,
                            onInstall: () => _installExtension(ext),
                            onUpdate: () => _updateExtension(ext),
                            onTap: () => _showExtensionDetails(ext),
                          );
                        }).toList(),
                      ),
                    ),
                  )
                else
                  SliverToBoxAdapter(
                    child: SettingsGroup(
                      connected: true,
                      children: filteredExtensions.asMap().entries.map((entry) {
                        final index = entry.key;
                        final ext = entry.value;
                        return _ExtensionItem(
                          extension: ext,
                          showDivider: index < filteredExtensions.length - 1,
                          isDownloading: downloadingId == ext.id,
                          onInstall: () => _installExtension(ext),
                          onUpdate: () => _updateExtension(ext),
                          onTap: () => _showExtensionDetails(ext),
                        );
                      }).toList(),
                    ),
                  ),

                const SliverToBoxAdapter(child: SizedBox(height: 16)),
              ],
            ],
            const NavBarSliverSpacer(),
          ],
        ),
      ),
    );
  }

  /// Columns of the desktop store grid for [width] of content: one per
  /// 360dp, up to four.
  static int _desktopGridColumns(double width) =>
      ((width + _desktopGridGap) / (360 + _desktopGridGap)).floor().clamp(1, 4);

  static const double _desktopGridGap = 12;

  /// Desktop extensions as a grid of tiles that fills the pane.
  Widget _desktopExtensionGrid(
    List<RepoExtension> extensions, {
    required int columns,
    required double edge,
    required String? downloadingId,
  }) {
    Widget tile(RepoExtension ext) {
      final item = _ExtensionItem(
        extension: ext,
        showDivider: false,
        isDownloading: downloadingId == ext.id,
        onInstall: () => _installExtension(ext),
        onUpdate: () => _updateExtension(ext),
        onTap: () => _showExtensionDetails(ext),
      );
      return context.isMornye
          ? ExtensionRepoCard(margin: EdgeInsets.zero, child: item)
          : SettingsGroup(
              connected: true,
              margin: EdgeInsets.zero,
              children: [item],
            );
    }

    final rows = (extensions.length / columns).ceil();
    return SliverPadding(
      key: const ValueKey('store-desktop-grid'),
      padding: EdgeInsets.fromLTRB(edge, 4, edge, 0),
      sliver: SliverList.builder(
        itemCount: rows,
        itemBuilder: (context, row) => Padding(
          padding: const EdgeInsets.only(bottom: _desktopGridGap),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var column = 0; column < columns; column++) ...[
                if (column > 0) const SizedBox(width: _desktopGridGap),
                Expanded(
                  child: row * columns + column < extensions.length
                      ? tile(extensions[row * columns + column])
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSetupRepoState(
    BuildContext context,
    ColorScheme colorScheme,
    String? error,
  ) {
    // Bottom padding keeps the content optically centered in the area
    // visible above the translucent nav bar.
    return Padding(
      padding: EdgeInsets.fromLTRB(32, 32, 32, 32 + context.navBarBottomInset),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.extension_outlined,
                size: 72,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 24),
              Text(
                context.l10n.storeAddRepoTitle,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              AppTextField(
                controller: _repoUrlController,
                outlined: true,
                label: context.l10n.storeRepoUrlLabel,
                hint: context.l10n.storeRepoUrlHint,
                leading: const Icon(Icons.link),
                decoration: InputDecoration(
                  hintText: context.l10n.storeRepoUrlHint,
                  labelText: context.l10n.storeRepoUrlLabel,
                  prefixIcon: const Icon(Icons.link),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide(color: colorScheme.outlineVariant),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide(color: colorScheme.outlineVariant),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide(
                      color: colorScheme.primary,
                      width: 2,
                    ),
                  ),
                  filled: true,
                  fillColor: colorScheme.surfaceContainerHighest,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
                // Reveal the submit button below the field when the keyboard
                // auto-scrolls to the focused input.
                scrollPadding: const EdgeInsets.only(bottom: 120),
                onSubmitted: (_) => _submitRepoUrl(),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 20,
                        color: colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          context.friendlyError(error),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ExpressiveButton(
                  onPressed: _submitRepoUrl,
                  icon: const Icon(Icons.add),
                  child: Text(context.l10n.storeAddRepoButton),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _submitRepoUrl() {
    final url = _repoUrlController.text.trim();
    if (url.isEmpty) return;
    ref.read(repoProvider.notifier).setRegistryUrl(url);
  }

  void _showChangeRepoDialog(String currentUrl) {
    final changeUrlController = TextEditingController(text: currentUrl);
    showAppDialog<void>(
      context: context,
      builder: (context) => AppAlertDialog(
        title: Text(context.l10n.storeRepoDialogTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.storeRepoDialogCurrent,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              currentUrl,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                fontSize: 11,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            if (context.isMornye)
              CupertinoTextField(
                controller: changeUrlController,
                placeholder: context.l10n.storeNewRepoUrlLabel,
                keyboardType: TextInputType.url,
                autocorrect: false,
                padding: const EdgeInsets.all(12),
              )
            else
              AppTextField(
                controller: changeUrlController,
                outlined: true,
                label: context.l10n.storeNewRepoUrlLabel,
                hint: context.l10n.storeRepoUrlHint,
                leading: const Icon(Icons.link),
                decoration: InputDecoration(
                  hintText: context.l10n.storeRepoUrlHint,
                  labelText: context.l10n.storeNewRepoUrlLabel,
                  prefixIcon: const Icon(Icons.link),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                  ),
                  filled: true,
                  fillColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
              ),
          ],
        ),
        actions: [
          AppDialogAction(
            isDestructive: true,
            onPressed: () {
              Navigator.of(context).pop();
              ref.read(repoProvider.notifier).removeRegistryUrl();
            },
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(context.l10n.dialogRemove),
          ),
          AppDialogAction(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.dialogCancel),
          ),
          AppDialogAction(
            filled: true,
            isDefault: true,
            onPressed: () {
              final newUrl = changeUrlController.text.trim();
              Navigator.of(context).pop();
              if (newUrl.isNotEmpty) {
                ref.read(repoProvider.notifier).setRegistryUrl(newUrl);
              }
            },
            child: Text(context.l10n.dialogSave),
          ),
        ],
      ),
    ).then((_) => changeUrlController.dispose());
  }

  Widget _buildErrorState(String error, ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 64, color: colorScheme.error),
            const SizedBox(height: 16),
            Text(
              context.l10n.storeLoadError,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              context.friendlyError(error),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ExpressiveButton(
              onPressed: () =>
                  ref.read(repoProvider.notifier).refresh(forceRefresh: true),
              icon: const Icon(Icons.refresh),
              child: Text(context.l10n.dialogRetry),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState({
    required bool hasFilters,
    required ColorScheme colorScheme,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hasFilters ? Icons.search_off : Icons.extension_off,
            size: 64,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            hasFilters
                ? context.l10n.storeEmptyNoResults
                : context.l10n.storeEmptyNoExtensions,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (hasFilters) ...[
            const SizedBox(height: 8),
            ExpressiveButton(
              text: true,
              onPressed: () {
                _searchController.clear();
                ref.read(repoProvider.notifier).clearSearch();
              },
              child: Text(context.l10n.storeClearFilters),
            ),
          ],
        ],
      ),
    );
  }

  void _showExtensionDetails(RepoExtension ext) {
    pushPage<void>(
      context,
      (context) => ExtensionDetailsScreen(extension: ext),
    );
  }

  Future<void> _installExtension(RepoExtension ext) async {
    final success = await ref
        .read(repoProvider.notifier)
        .installExtensionToDefaultPaths(ext.id);

    if (mounted) {
      showAppSnackBar(
        context,
        content: Text(
          success
              ? context.l10n.snackbarExtensionInstalledEnable(ext.displayName)
              : context.l10n.snackbarFailedToInstallNamed(ext.displayName),
        ),
        behavior: SnackBarBehavior.floating,
      );
    }
  }

  Future<void> _updateExtension(RepoExtension ext) async {
    final success = await ref
        .read(repoProvider.notifier)
        .updateExtensionToDefaultPaths(ext.id);

    if (mounted) {
      showAppSnackBar(
        context,
        content: Text(
          success
              ? context.l10n.snackbarExtensionUpdatedVersion(
                  ext.displayName,
                  ext.version,
                )
              : context.l10n.snackbarFailedToUpdateNamed(ext.displayName),
        ),
        behavior: SnackBarBehavior.floating,
      );
    }
  }
}

/// Category filters scroll sideways on phones. A mouse cannot swipe a clipped
/// row, so desktop windows wrap every category onto view.
class _CategoryChipRow extends StatelessWidget {
  const _CategoryChipRow({required this.edge, required this.children});

  final double edge;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final padding = EdgeInsets.symmetric(horizontal: edge, vertical: 8);
    if (isDesktopPlatform) {
      return Padding(
        padding: padding,
        child: Wrap(spacing: 8, runSpacing: 8, children: children),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: padding,
      child: Row(spacing: 8, children: children),
    );
  }
}

class _CategoryChip extends ConsumerWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _CategoryChip({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    if (context.isMornye) {
      return Semantics(
        button: true,
        selected: isSelected,
        label: label,
        onTap: onTap,
        excludeSemantics: true,
        // Scrolls with the list over the plain page: see ExtensionRepoCard.
        child: MornyeGlass.navigation(
          radius: 24,
          blurEnabled: ref.watch(mornyeBlurEnabledProvider),
          samplesBackdrop: false,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(24),
              child: Container(
                constraints: const BoxConstraints(minHeight: 44),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                color: isSelected
                    ? colorScheme.primary.withValues(alpha: 0.10)
                    : Colors.transparent,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      mornyeIconFor(icon),
                      size: 18,
                      color: isSelected
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      label,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: isSelected
                            ? colorScheme.primary
                            : colorScheme.onSurface,
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.w400,
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
    return AppChoiceChip(
      label: Text(label),
      icon: Icon(icon, size: 18),
      singleChoice: true,
      selected: isSelected,
      onSelected: (_) => onTap(),
    );
  }
}

/// The store list while the registry loads: real extension rows inside the
/// same grouped surface, with only their contents shimmering.
class _RepoListSkeleton extends StatelessWidget {
  const _RepoListSkeleton({required this.edge});

  /// Horizontal edge of the centered column, as the loaded list uses.
  final double edge;

  static const _count = 6;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // Placeholders keep their contrast on the Material group surface.
    final surface = context.isMornye ? null : settingsGroupColor(context);
    final buttonWidth = _storeButtonWidth(context);
    final rows = [
      for (var index = 0; index < _count; index++)
        ExtensionRow(
          showDivider: index < _count - 1,
          avatar: ShimmerLoading(
            surface: surface,
            child: const SkeletonBox(
              width: ExtensionAvatar.size,
              height: ExtensionAvatar.size,
              borderRadius: 12,
            ),
          ),
          title: ShimmerLoading(
            surface: surface,
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: SkeletonBox(
                      width: 110 + (index % 3) * 30,
                      height: 16,
                      borderRadius: 4,
                    ),
                  ),
                ),
                SizedBox(width: tokens.gapSm),
                const SkeletonBox(width: 44, height: 18, borderRadius: 6),
              ],
            ),
          ),
          subtitle: ShimmerLoading(
            surface: surface,
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: 4),
                SkeletonBox(
                  width: double.infinity,
                  height: 12,
                  borderRadius: 4,
                ),
                SizedBox(height: 6),
                FractionallySizedBox(
                  widthFactor: 0.6,
                  child: SkeletonBox(
                    width: double.infinity,
                    height: 12,
                    borderRadius: 4,
                  ),
                ),
              ],
            ),
          ),
          trailingWidth: buttonWidth,
          trailing: ShimmerLoading(
            surface: surface,
            child: SkeletonBox(
              width: 108,
              height: tokens.minTouchTarget,
              borderRadius: tokens.minTouchTarget / 2,
            ),
          ),
        ),
    ];
    if (context.isMornye) {
      return ExtensionRepoCard(
        margin: EdgeInsets.fromLTRB(edge, 12, edge, 4),
        child: Column(mainAxisSize: MainAxisSize.min, children: rows),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SettingsGroup(connected: true, children: rows),
    );
  }
}

/// The widest store button in the current language and text size: the
/// longest of the Install, Update and Installed labels, the last with its
/// check icon, plus the buttons' side padding. Store rows and their
/// skeleton share it, so every row puts its button in the same place.
double _storeButtonWidth(BuildContext context) {
  final l10n = context.l10n;
  final style = Theme.of(context).textTheme.labelLarge;
  final textScaler = MediaQuery.textScalerOf(context);
  final textDirection = Directionality.of(context);
  double labelWidth(String label) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: textDirection,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  final widest = [
    labelWidth(l10n.storeInstall),
    labelWidth(l10n.storeUpdate),
    // The check icon and its gap.
    labelWidth(l10n.storeInstalled) + 24,
  ].reduce((a, b) => a > b ? a : b);
  return widest + 32;
}

class _ExtensionItem extends StatelessWidget {
  final RepoExtension extension;
  final bool showDivider;
  final bool isDownloading;
  final VoidCallback onInstall;
  final VoidCallback onUpdate;
  final VoidCallback? onTap;

  const _ExtensionItem({
    required this.extension,
    required this.showDivider,
    required this.isDownloading,
    required this.onInstall,
    required this.onUpdate,
    this.onTap,
  });

  IconData _getCategoryIcon(String category) {
    switch (category) {
      case RepoCategory.metadata:
        return Icons.label_outline;
      case RepoCategory.download:
        return Icons.download_outlined;
      case RepoCategory.utility:
        return Icons.build_outlined;
      case RepoCategory.lyrics:
        return Icons.lyrics_outlined;
      case RepoCategory.integration:
        return Icons.link;
      default:
        return Icons.extension;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final tokens = context.tokens;

    return ExtensionRow(
      showDivider: showDivider,
      onTap: onTap,
      avatar: ExtensionAvatar(
        imageUrl: extension.iconUrl,
        fallbackIcon: context.isMornye
            ? mornyeIconFor(_getCategoryIcon(extension.category))
            : _getCategoryIcon(extension.category),
        background: extension.isInstalled
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerHighest,
        foreground: extension.isInstalled
            ? colorScheme.onPrimaryContainer
            : colorScheme.onSurfaceVariant,
      ),
      title: Row(
        children: [
          Expanded(child: Text(extension.displayName)),
          Container(
            padding: tokens.badgePadding,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: tokens.borderRadiusBadge,
            ),
            child: Text(
              'v${extension.version}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
      subtitle: extension.requiresNewerApp
          ? Container(
              padding: tokens.badgePadding,
              decoration: BoxDecoration(
                color: colorScheme.errorContainer,
                borderRadius: tokens.borderRadiusBadge,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 12,
                    color: colorScheme.onErrorContainer,
                  ),
                  SizedBox(width: tokens.gapXs),
                  Text(
                    context.l10n.storeRequiresVersion(
                      extension.minAppVersion ?? '',
                    ),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            )
          : Text(
              extension.description,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
      trailingWidth: _storeButtonWidth(context),
      trailing: isDownloading
          ? const AppLoadingIndicator(size: 24)
          : !context.isMornye
          ? ExpressiveButton(
              onPressed: extension.hasUpdate
                  ? onUpdate
                  : extension.isInstalled
                  ? null
                  : onInstall,
              outlined: extension.isInstalled && !extension.hasUpdate,
              tonal: extension.hasUpdate,
              icon: extension.isInstalled && !extension.hasUpdate
                  ? const Icon(Icons.check, size: 16)
                  : null,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              child: Text(
                extension.hasUpdate
                    ? context.l10n.storeUpdate
                    : extension.isInstalled
                    ? context.l10n.storeInstalled
                    : context.l10n.storeInstall,
              ),
            )
          : extension.hasUpdate
          ? FilledButton.tonal(
              onPressed: onUpdate,
              style: FilledButton.styleFrom(
                shape: context.isMornye ? const StadiumBorder() : null,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: Size(0, context.tokens.minTouchTarget),
              ),
              child: Text(context.l10n.storeUpdate),
            )
          : extension.isInstalled
          ? OutlinedButton(
              onPressed: null,
              style: OutlinedButton.styleFrom(
                shape: context.isMornye ? const StadiumBorder() : null,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: Size(0, context.tokens.minTouchTarget),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    context.isMornye ? CupertinoIcons.check_mark : Icons.check,
                    size: 16,
                    color: colorScheme.outline,
                  ),
                  SizedBox(width: tokens.gapXs),
                  Text(
                    context.l10n.storeInstalled,
                    style: TextStyle(color: colorScheme.outline),
                  ),
                ],
              ),
            )
          : FilledButton(
              onPressed: onInstall,
              style: FilledButton.styleFrom(
                shape: context.isMornye ? const StadiumBorder() : null,
                backgroundColor: context.isMornye
                    ? colorScheme.primary.withValues(alpha: 0.12)
                    : null,
                foregroundColor: context.isMornye ? colorScheme.primary : null,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: Size(0, context.tokens.minTouchTarget),
              ),
              child: Text(context.l10n.storeInstall),
            ),
    );
  }
}
