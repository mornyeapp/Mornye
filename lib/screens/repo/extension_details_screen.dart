import 'package:material_ui/material_ui.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/repo_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/widgets/extension_repo_card.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/error_card.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/extension_icon_image.dart';

class ExtensionDetailsScreen extends ConsumerStatefulWidget {
  final RepoExtension extension;

  const ExtensionDetailsScreen({super.key, required this.extension});

  @override
  ConsumerState<ExtensionDetailsScreen> createState() =>
      _ExtensionDetailsScreenState();
}

class _ExtensionDetailsScreenState
    extends ConsumerState<ExtensionDetailsScreen> {
  /// The repository picked to install from, while not installed.
  String? _installSource;

  @override
  Widget build(BuildContext context) {
    final storeState = ref.watch(repoProvider);

    final id = widget.extension.id.toLowerCase();
    final merged =
        storeState.extensions
            .where((e) => e.id.toLowerCase() == id)
            .firstOrNull ??
        widget.extension;
    final chosen = !merged.isInstalled && _installSource != null
        ? merged.sourceEntry(_installSource!)
        : null;
    final liveExtension = chosen?.copyWith(sources: merged.sources) ?? merged;
    final canChangeSource =
        merged.sources.length > 1 ||
        (merged.sourceMissing && merged.sources.isNotEmpty);
    final showRepository =
        storeState.hasMultipleRepositories || merged.sourceMissing;

    final isDownloading = storeState.downloadingId == liveExtension.id;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          _buildAppBar(context, liveExtension, colorScheme),
          _buildInfoCard(context, liveExtension, colorScheme, isDownloading),
          if (merged.sourceMissing)
            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.fromLTRB(16, 0, 16, 16) +
                    EdgeInsets.symmetric(horizontal: wideListInset(context)),
                child: ErrorCard(
                  key: const ValueKey('store-source-missing'),
                  error: canChangeSource
                      ? context.l10n.storeSourceMissing
                      : context.l10n.storeSourceMissingNoOther,
                  colorScheme: colorScheme,
                ),
              ),
            ),
          _buildSectionHeader(
            context,
            context.l10n.aboutTitle,
            Icons.info_outline,
            colorScheme,
          ),
          _buildDescription(context, liveExtension, colorScheme),

          if (liveExtension.tags.isNotEmpty) ...[
            _buildSectionHeader(
              context,
              context.l10n.extensionDetailsTags,
              Icons.tag,
              colorScheme,
            ),
            _buildTags(context, liveExtension, colorScheme),
          ],

          _buildSectionHeader(
            context,
            context.l10n.extensionDetailsInformation,
            Icons.table_chart_outlined,
            colorScheme,
          ),
          _buildMetadataTable(
            context,
            liveExtension,
            colorScheme,
            showRepository: showRepository,
            onChangeRepository: canChangeSource
                ? () => _changeRepository(liveExtension)
                : null,
          ),

          _buildSectionHeader(
            context,
            context.l10n.extensionCapabilities,
            Icons.extension_outlined,
            colorScheme,
          ),
          _buildCapabilities(context, liveExtension, colorScheme),

          SliverToBoxAdapter(
            child: SizedBox(height: 32 + context.navBarBottomInset),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar(
    BuildContext context,
    RepoExtension ext,
    ColorScheme colorScheme,
  ) {
    final edgeInset = detailHeaderEdgeInset(context);
    return SliverAppBar(
      expandedHeight: 200,
      pinned: true,
      stretch: true,
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      flexibleSpace: FlexibleSpaceBar(
        background: Center(
          child: Padding(
            padding: const EdgeInsets.only(top: kToolbarHeight),
            child: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                color: colorScheme.surfaceContainerHighest,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: ext.iconUrl != null && ext.iconUrl!.isNotEmpty
                    ? Image(
                        image: ExtensionIconImage(
                          NetworkImage(ext.iconUrl!),
                          extent: (100 * MediaQuery.devicePixelRatioOf(context))
                              .ceil(),
                        ),
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) =>
                            _buildFallbackIcon(ext, colorScheme, 50),
                      )
                    : _buildFallbackIcon(ext, colorScheme, 50),
              ),
            ),
          ),
        ),
      ),
      leadingWidth: kToolbarHeight + edgeInset,
      leading: Padding(
        padding: EdgeInsetsDirectional.only(start: edgeInset),
        child: AppIconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          icon: Icon(context.isMornye ? CupertinoIcons.back : Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
    );
  }

  Widget _buildFallbackIcon(
    RepoExtension ext,
    ColorScheme colorScheme,
    double size,
  ) {
    return Container(
      color: colorScheme.surfaceContainerHighest,
      child: Icon(
        context.isMornye
            ? mornyeIconFor(_getCategoryIcon(ext.category))
            : _getCategoryIcon(ext.category),
        size: size,
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildInfoCard(
    BuildContext context,
    RepoExtension ext,
    ColorScheme colorScheme,
    bool isDownloading,
  ) {
    return SliverToBoxAdapter(
      child: Padding(
        padding:
            const EdgeInsets.all(16) +
            EdgeInsets.symmetric(horizontal: wideListInset(context)),
        child: ExtensionRepoCard(
          color: colorScheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            ext.displayName,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.onSurface,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    // Only the installed state is emphasized.
                    _Badge(
                      label: 'v${ext.version}',
                      color: colorScheme.surfaceContainerHighest,
                      textColor: colorScheme.onSurfaceVariant,
                    ),
                    _Badge(
                      label: _getCategoryName(context, ext.category),
                      color: colorScheme.surfaceContainerHighest,
                      textColor: colorScheme.onSurfaceVariant,
                    ),
                    if (ext.isInstalled)
                      _Badge(
                        label: context.l10n.storeInstalled,
                        color: colorScheme.primaryContainer,
                        textColor: colorScheme.onPrimaryContainer,
                        icon: Icons.check,
                      ),
                  ],
                ),

                const SizedBox(height: 24),

                if (isDownloading)
                  Center(child: AppLoadingIndicator(color: colorScheme.primary))
                else ...[
                  if (ext.hasUpdate)
                    ExpressiveButton(
                      onPressed: () => _updateExtension(ext),
                      icon: Icon(
                        context.isMornye
                            ? CupertinoIcons.arrow_clockwise
                            : Icons.update,
                      ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: Text(
                        '${context.l10n.storeUpdate} v${ext.version}',
                      ),
                    )
                  else if (ext.isInstalled)
                    Row(
                      children: [
                        Expanded(
                          child: ExpressiveButton(
                            outlined: true,
                            onPressed: null,
                            icon: Icon(
                              context.isMornye
                                  ? CupertinoIcons.check_mark
                                  : Icons.check,
                            ),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 52),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            child: Text(context.l10n.storeInstalled),
                          ),
                        ),
                        const SizedBox(width: 12),
                        AppIconButton.filled(
                          onPressed: () => _uninstallExtension(ext),
                          icon: Icon(
                            context.isMornye
                                ? CupertinoIcons.trash
                                : Icons.delete_outline,
                          ),
                          style: IconButton.styleFrom(
                            backgroundColor: colorScheme.errorContainer,
                            foregroundColor: colorScheme.onErrorContainer,
                            minimumSize: const Size(52, 52),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          tooltip: context.l10n.extensionsUninstall,
                        ),
                      ],
                    )
                  else
                    ExpressiveButton(
                      onPressed: () => _installExtension(ext),
                      icon: Icon(
                        context.isMornye
                            ? CupertinoIcons.arrow_down_circle
                            : Icons.download,
                      ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: Text(context.l10n.storeInstall),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
    BuildContext context,
    String title,
    IconData icon,
    ColorScheme colorScheme,
  ) {
    return SliverToBoxAdapter(
      child: Padding(
        padding:
            const EdgeInsets.fromLTRB(20, 8, 20, 8) +
            EdgeInsets.symmetric(horizontal: wideListInset(context)),
        child: Row(
          children: [
            Icon(
              context.adaptiveIcon(icon),
              size: 20,
              color: colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDescription(
    BuildContext context,
    RepoExtension ext,
    ColorScheme colorScheme,
  ) {
    return SliverToBoxAdapter(
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 24, vertical: 8) +
            EdgeInsets.symmetric(horizontal: wideListInset(context)),
        child: Text(
          ext.description,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            height: 1.5,
            color: colorScheme.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _buildTags(
    BuildContext context,
    RepoExtension ext,
    ColorScheme colorScheme,
  ) {
    return SliverToBoxAdapter(
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 24, vertical: 8) +
            EdgeInsets.symmetric(horizontal: wideListInset(context)),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: ext.tags
              .map(
                (tag) => context.isMornye
                    ? ExtensionRepoCard(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: Text(
                            tag,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      )
                    : Chip(
                        label: Text(tag),
                        backgroundColor: colorScheme.surfaceContainer,
                        labelStyle: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: colorScheme.onSurfaceVariant),
                        side: BorderSide.none,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
              )
              .toList(),
        ),
      ),
    );
  }

  Widget _buildMetadataTable(
    BuildContext context,
    RepoExtension ext,
    ColorScheme colorScheme, {
    required bool showRepository,
    VoidCallback? onChangeRepository,
  }) {
    return SliverPadding(
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 8) +
          EdgeInsets.symmetric(horizontal: wideListInset(context)),
      sliver: SliverToBoxAdapter(
        child: ExtensionRepoCard(
          color: colorScheme.surfaceContainer,
          radius: 16,
          child: Column(
            children: [
              _MetadataRow(
                label: context.l10n.extensionUpdated,
                value: ext.updatedAt.isNotEmpty
                    ? _formatDate(context, ext.updatedAt)
                    : '-',
                colorScheme: colorScheme,
              ),
              _MetadataRow(
                label: context.l10n.extensionId,
                value: ext.id,
                colorScheme: colorScheme,
              ),
              _MetadataRow(
                label: context.l10n.extensionMinAppVersion,
                value: ext.minAppVersion ?? context.l10n.storeAnyVersion,
                colorScheme: colorScheme,
                isLast: !showRepository,
              ),
              if (showRepository)
                _MetadataRow(
                  key: const ValueKey('store-extension-repository'),
                  label: context.l10n.storeExtensionRepository,
                  value: ext.registryName.isEmpty
                      ? ext.registryUrl
                      : ext.registryName,
                  colorScheme: colorScheme,
                  isLast: true,
                  onTap: onChangeRepository,
                  tapLabel: context.l10n.storeChangeRepoTooltip,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCapabilities(
    BuildContext context,
    RepoExtension ext,
    ColorScheme colorScheme,
  ) {
    final isMetadataProvider =
        ext.category == 'metadata' || ext.category == 'integration';
    final isDownloadProvider = ext.category == 'download';
    final isLyricsProvider = ext.category == 'lyrics';
    final isUtility = ext.category == 'utility';

    return SliverPadding(
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 8) +
          EdgeInsets.symmetric(horizontal: wideListInset(context)),
      sliver: SliverToBoxAdapter(
        child: ExtensionRepoCard(
          color: colorScheme.surfaceContainer,
          radius: 16,
          child: Column(
            children: [
              _CapabilityRow(
                icon: Icons.search,
                label: context.l10n.extensionMetadataProvider,
                enabled: isMetadataProvider,
                colorScheme: colorScheme,
              ),
              _CapabilityRow(
                icon: Icons.download,
                label: context.l10n.extensionDownloadProvider,
                enabled: isDownloadProvider,
                colorScheme: colorScheme,
              ),
              _CapabilityRow(
                icon: Icons.lyrics,
                label: context.l10n.extensionLyricsProvider,
                enabled: isLyricsProvider,
                colorScheme: colorScheme,
              ),
              _CapabilityRow(
                icon: Icons.build,
                label: context.l10n.extensionUtilityFunctions,
                enabled: isUtility,
                colorScheme: colorScheme,
                isLast: true,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(BuildContext context, String dateStr) {
    try {
      final date = DateTime.parse(dateStr);
      final now = DateTime.now();
      final diff = now.difference(date);

      if (diff.inDays == 0) {
        return context.l10n.dateToday;
      } else if (diff.inDays == 1) {
        return context.l10n.dateYesterday;
      } else if (diff.inDays < 7) {
        return context.l10n.dateDaysAgo(diff.inDays);
      } else if (diff.inDays < 30) {
        return context.l10n.dateWeeksAgo((diff.inDays / 7).floor());
      } else if (diff.inDays < 365) {
        return context.l10n.dateMonthsAgo((diff.inDays / 30).floor());
      } else {
        return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      }
    } catch (_) {
      return dateStr.split('T').first;
    }
  }

  IconData _getCategoryIcon(String category) {
    switch (category) {
      case 'metadata':
        return Icons.label_outline;
      case 'download':
        return Icons.download_outlined;
      case 'utility':
        return Icons.build_outlined;
      case 'lyrics':
        return Icons.lyrics_outlined;
      case 'integration':
        return Icons.link;
      default:
        return Icons.extension;
    }
  }

  String _getCategoryName(BuildContext context, String category) {
    switch (category) {
      case 'metadata':
        return context.l10n.storeCategoryMetadata;
      case 'download':
        return context.l10n.storeCategoryDownload;
      case 'utility':
        return context.l10n.storeCategoryUtility;
      case 'lyrics':
        return context.l10n.storeCategoryLyrics;
      case 'integration':
        return context.l10n.storeCategoryIntegration;
      default:
        return category;
    }
  }

  /// Picks another repository that lists the extension: an installed one
  /// moves its pin (nothing is reinstalled), one not installed installs
  /// from the picked repository.
  Future<void> _changeRepository(RepoExtension ext) async {
    await showAppChoiceSheet<String>(
      context: context,
      title: context.l10n.storeChangeRepoTooltip,
      subtitle: ext.displayName,
      selected: ext.registryUrl,
      choices: [
        for (final source in ext.sources)
          AppChoice(
            source.registryUrl,
            Icons.link,
            source.registryName.isEmpty
                ? source.registryUrl
                : source.registryName,
            subtitle: 'v${source.version}',
          ),
      ],
      onSelected: (url) async {
        if (url == ext.registryUrl) return;
        if (!ext.isInstalled) {
          setState(() => _installSource = url);
          return;
        }
        final l10n = context.l10n;
        await ref
            .read(repoProvider.notifier)
            .changeExtensionSource(ext.id, url);
        final name = ext.sourceEntry(url)?.registryName ?? url;
        if (mounted) {
          showAppSnackBar(
            context,
            content: Text(l10n.storeRepositoryChanged(ext.displayName, name)),
            behavior: SnackBarBehavior.floating,
          );
        }
      },
    );
  }

  Future<void> _installExtension(RepoExtension ext) async {
    final success = await ref
        .read(repoProvider.notifier)
        .installExtensionToDefaultPaths(
          ext.id,
          registryUrl: ext.registryUrl.isEmpty ? null : ext.registryUrl,
        );

    if (mounted) {
      showAppSnackBar(
        context,
        content: Text(
          success
              ? context.l10n.snackbarExtensionInstalled(ext.displayName)
              : context.l10n.snackbarFailedToInstall,
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
              ? context.l10n.snackbarExtensionUpdated(ext.displayName)
              : context.l10n.snackbarFailedToUpdate,
        ),
        behavior: SnackBarBehavior.floating,
      );
    }
  }

  Future<void> _uninstallExtension(RepoExtension ext) async {
    final confirm = await showAppConfirmDialog(
      context,
      title: context.l10n.dialogUninstallExtension,
      message: context.l10n.dialogUninstallExtensionMessage(ext.displayName),
      confirmLabel: context.l10n.dialogUninstall,
      destructive: true,
      filled: false,
      cancelIsDefault: true,
      errorConfirm: true,
    );

    if (confirm) {
      await ref.read(extensionProvider.notifier).removeExtension(ext.id);
      await ref.read(repoProvider.notifier).refresh();
      if (mounted) {
        Navigator.pop(context);
      }
    }
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;
  final IconData? icon;

  const _Badge({
    required this.label,
    required this.color,
    required this.textColor,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: textColor),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetadataRow extends StatelessWidget {
  final String label;
  final String value;
  final ColorScheme colorScheme;
  final bool isLast;

  /// Makes the row a button (with a chevron) announced as [tapLabel].
  final VoidCallback? onTap;
  final String? tapLabel;

  const _MetadataRow({
    super.key,
    required this.label,
    required this.value,
    required this.colorScheme,
    this.isLast = false,
    this.onTap,
    this.tapLabel,
  });

  @override
  Widget build(BuildContext context) {
    Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 14),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w500,
                fontSize: 14,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(
              context.isMornye ? CupertinoIcons.forward : Icons.chevron_right,
              size: 20,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ],
      ),
    );
    if (onTap != null) {
      row = Semantics(
        button: true,
        hint: tapLabel,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: context.tokens.minTouchTarget,
            ),
            child: row,
          ),
        ),
      );
    }
    return Column(
      children: [
        row,
        // Material groups rows by the card alone; dividers are Mornye's.
        if (!isLast && context.isMornye)
          Divider(
            height: 1,
            thickness: 1,
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
            indent: 16,
            endIndent: 16,
          ),
      ],
    );
  }
}

class _CapabilityRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final ColorScheme colorScheme;
  final bool isLast;

  const _CapabilityRow({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.colorScheme,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                context.adaptiveIcon(icon),
                size: 20,
                color: enabled ? colorScheme.primary : colorScheme.outline,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(color: colorScheme.onSurface, fontSize: 14),
                ),
              ),
              Icon(
                context.isMornye
                    ? (enabled
                          ? CupertinoIcons.check_mark_circled
                          : CupertinoIcons.clear_circled)
                    : (enabled ? Icons.check_circle : Icons.cancel_outlined),
                size: 20,
                color: enabled ? colorScheme.primary : colorScheme.outline,
              ),
            ],
          ),
        ),
        if (!isLast && context.isMornye)
          Divider(
            height: 1,
            thickness: 1,
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
            indent: 16,
            endIndent: 16,
          ),
      ],
    );
  }
}
