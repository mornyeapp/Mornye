import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons, CupertinoTextField;
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_text_field.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/repo_provider.dart';
import 'package:mornye/utils/extension_auth_launcher.dart';
import 'package:mornye/controllers/extension_action_forms.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/utils/extension_country_name.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/extension_health.dart';
import 'package:mornye/widgets/sliver_layout_info_builder.dart';

part 'extension_detail_page_widgets.dart';

class ExtensionDetailPage extends ConsumerStatefulWidget {
  final String extensionId;

  const ExtensionDetailPage({super.key, required this.extensionId});

  @override
  ConsumerState<ExtensionDetailPage> createState() =>
      _ExtensionDetailPageState();
}

class _ExtensionDetailPageState extends ConsumerState<ExtensionDetailPage> {
  Map<String, dynamic> _settings = {};
  bool _isLoadingSettings = true;
  bool _isRefreshingHealth = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshHealth();
    });
  }

  Future<void> _loadSettings() async {
    final settings = await ref
        .read(extensionProvider.notifier)
        .getExtensionSettings(widget.extensionId);
    setState(() {
      _settings = settings;
      _isLoadingSettings = false;
    });
  }

  Future<void> _refreshHealth({bool force = false}) async {
    final ext = ref
        .read(extensionProvider)
        .extensions
        .where((extension) => extension.id == widget.extensionId)
        .firstOrNull;
    if (ext == null || !ext.hasServiceHealth) return;

    setState(() => _isRefreshingHealth = true);
    try {
      await ref
          .read(extensionProvider.notifier)
          .checkExtensionHealth(widget.extensionId, force: force);
    } finally {
      if (mounted) {
        setState(() => _isRefreshingHealth = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final extState = ref.watch(extensionProvider);
    final extension = extState.extensions.firstWhere(
      (e) => e.id == widget.extensionId,
      orElse: () => const Extension(
        id: '',
        name: '',
        displayName: 'Unknown',
        version: '0.0.0',
        description: '',
        enabled: false,
        status: 'error',
      ),
    );

    final colorScheme = Theme.of(context).colorScheme;
    final hasError = extension.status == 'error';
    final healthStatus = extState.healthStatuses[extension.id];

    return PopScope(
      canPop: true,
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: extension.displayName),

            SliverLayoutInfoBuilder(
              select: (constraints) =>
                  settingsHorizontalInset(constraints.crossAxisExtent),
              builder: (context, inset) => SliverToBoxAdapter(
                child: Padding(
                  // Same column as the settings groups below on wide panes.
                  padding: EdgeInsets.symmetric(
                    horizontal: inset,
                    vertical: 16,
                  ),
                  child: _ExtensionOverviewSurface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                color: context.isMornye
                                    ? MornyeTheme.controlFill(context)
                                    : hasError
                                    ? colorScheme.errorContainer
                                    : colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child:
                                  extension.iconPath != null &&
                                      extension.iconPath!.isNotEmpty
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(16),
                                      child: Image.file(
                                        File(extension.iconPath!),
                                        width: 56,
                                        height: 56,
                                        fit: BoxFit.cover,
                                        errorBuilder:
                                            (
                                              context,
                                              error,
                                              stackTrace,
                                            ) => AppIcon(
                                              context.isMornye
                                                  ? (hasError
                                                        ? CupertinoIcons
                                                              .exclamationmark_circle
                                                        : CupertinoIcons
                                                              .square_grid_2x2)
                                                  : hasError
                                                  ? Icons.error_outline
                                                  : Icons.extension,
                                              size: 28,
                                              color: hasError
                                                  ? colorScheme.error
                                                  : colorScheme
                                                        .onPrimaryContainer,
                                            ),
                                      ),
                                    )
                                  : AppIcon(
                                      context.isMornye
                                          ? (hasError
                                                ? CupertinoIcons
                                                      .exclamationmark_circle
                                                : CupertinoIcons
                                                      .square_grid_2x2)
                                          : hasError
                                          ? Icons.error_outline
                                          : Icons.extension,
                                      size: 28,
                                      color: hasError
                                          ? colorScheme.error
                                          : colorScheme.onPrimaryContainer,
                                    ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    extension.displayName,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(fontWeight: FontWeight.bold),
                                  ),
                                  Text(
                                    'v${extension.version}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            AppSwitch(
                              value: extension.enabled,
                              semanticLabel: extension.displayName,
                              onChanged: hasError
                                  ? null
                                  : (enabled) => ref
                                        .read(extensionProvider.notifier)
                                        .setExtensionEnabled(
                                          widget.extensionId,
                                          enabled,
                                        ),
                            ),
                          ],
                        ),
                        if (extension.description.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Text(
                            extension.description,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                        const SizedBox(height: 16),
                        if (context.isMornye)
                          Divider(
                            color: MornyeTheme.metadataDividerColor(context),
                          ),
                        _InfoRow(
                          label: context.l10n.extensionId,
                          value: extension.id,
                        ),
                        if (!context.isMornye)
                          _InfoRow(
                            label: context.l10n.extensionsVersion(
                              extension.version,
                            ),
                            value: '',
                          ),
                        if (hasError && extension.errorMessage != null)
                          _InfoRow(
                            label: context.l10n.extensionError,
                            value: context.friendlyError(
                              extension.errorMessage,
                              fallback: context.l10n.extensionsErrorLoading,
                            ),
                            isError: true,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            if (extension.settings.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: SettingsSectionHeader(
                  title: context.l10n.extensionSettings,
                ),
              ),
              if (_isLoadingSettings)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: AppLoadingIndicator()),
                  ),
                )
              else
                SliverToBoxAdapter(
                  child: SettingsGroup(
                    glass: true,
                    connected: true,
                    children: extension.settings.asMap().entries.map((entry) {
                      final index = entry.key;
                      final setting = entry.value;
                      return _SettingItem(
                        key: ValueKey(setting.key),
                        countryOptions:
                            setting.key == extension.homeFeedRegionSetting?.key,
                        setting: setting,
                        value: _settings[setting.key] ?? setting.defaultValue,
                        showDivider: index < extension.settings.length - 1,
                        onChanged: (value) =>
                            _updateSetting(setting.key, value),
                        extensionId: widget.extensionId,
                        onActionPayload: _handleExtensionActionPayload,
                      );
                    }).toList(),
                  ),
                ),
            ],

            if (extension.hasServiceHealth) ...[
              SliverToBoxAdapter(
                child: SettingsSectionHeader(
                  title: context.l10n.extensionServiceStatus,
                ),
              ),
              SliverToBoxAdapter(
                child: SettingsGroup(
                  glass: true,
                  connected: true,
                  children: [
                    _HealthSummaryItem(
                      status: healthStatus,
                      isRefreshing: _isRefreshingHealth,
                      onRefresh: () => _refreshHealth(force: true),
                    ),
                    if (healthStatus != null)
                      ...healthStatus.checks.asMap().entries.map((entry) {
                        final index = entry.key;
                        final check = entry.value;
                        return _HealthCheckItem(
                          check: check,
                          showDivider: index < healthStatus.checks.length - 1,
                        );
                      }),
                  ],
                ),
              ),
            ],

            if (extension.hasURLHandler &&
                extension.urlHandler!.patterns.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: SettingsSectionHeader(
                  title: context.l10n.extensionUrlHandler,
                ),
              ),
              SliverToBoxAdapter(
                child: SettingsGroup(
                  glass: true,
                  children: [
                    _URLHandlerInfo(patterns: extension.urlHandler!.patterns),
                  ],
                ),
              ),
            ],

            if (extension.hasDownloadProvider &&
                extension.qualityOptions.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: SettingsSectionHeader(
                  title: context.l10n.extensionQualityOptions,
                ),
              ),
              SliverToBoxAdapter(
                child: SettingsGroup(
                  glass: true,
                  connected: true,
                  children: extension.qualityOptions.asMap().entries.map((
                    entry,
                  ) {
                    final index = entry.key;
                    final quality = entry.value;
                    return _QualityOptionItem(
                      quality: quality,
                      showDivider: index < extension.qualityOptions.length - 1,
                    );
                  }).toList(),
                ),
              ),
            ],

            if (extension.hasPostProcessing &&
                extension.postProcessing!.hooks.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: SettingsSectionHeader(
                  title: context.l10n.extensionPostProcessingHooks,
                ),
              ),
              SliverToBoxAdapter(
                child: SettingsGroup(
                  glass: true,
                  connected: true,
                  children: extension.postProcessing!.hooks.asMap().entries.map(
                    (entry) {
                      final index = entry.key;
                      final hook = entry.value;
                      return _PostProcessingHookItem(
                        hook: hook,
                        showDivider:
                            index < extension.postProcessing!.hooks.length - 1,
                      );
                    },
                  ).toList(),
                ),
              ),
            ],

            if (extension.permissions.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: SettingsSectionHeader(
                  title: context.l10n.extensionPermissions,
                ),
              ),
              SliverToBoxAdapter(
                child: SettingsGroup(
                  glass: true,
                  connected: true,
                  children: extension.permissions.asMap().entries.map((entry) {
                    final index = entry.key;
                    final permission = entry.value;
                    return _PermissionItem(
                      permission: permission,
                      showDivider: index < extension.permissions.length - 1,
                    );
                  }).toList(),
                ),
              ),
            ],

            SliverToBoxAdapter(
              child: SettingsSectionHeader(
                title: context.l10n.extensionCapabilities,
              ),
            ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                glass: true,
                connected: true,
                children: [
                  _CapabilityItem(
                    icon: Icons.search,
                    title: context.l10n.extensionMetadataProvider,
                    enabled: extension.hasMetadataProvider,
                  ),
                  _CapabilityItem(
                    icon: Icons.download,
                    title: context.l10n.extensionDownloadProvider,
                    enabled: extension.hasDownloadProvider,
                  ),
                  _CapabilityItem(
                    icon: Icons.lyrics,
                    title: context.l10n.extensionLyricsProvider,
                    enabled: extension.hasLyricsProvider,
                  ),
                  _CapabilityItem(
                    icon: Icons.manage_search,
                    title: context.l10n.extensionsSearchProvider,
                    enabled: extension.hasCustomSearch,
                    subtitle: extension.searchBehavior?.placeholder,
                  ),
                  _CapabilityItem(
                    icon: Icons.compare_arrows,
                    title: context.l10n.extensionCustomTrackMatching,
                    enabled: extension.hasCustomMatching,
                    subtitle: extension.trackMatching?.strategy != null
                        ? context.l10n.extensionStrategy(
                            extension.trackMatching!.strategy!,
                          )
                        : null,
                  ),
                  _CapabilityItem(
                    icon: Icons.auto_fix_high,
                    title: context.l10n.extensionPostProcessing,
                    enabled: extension.hasPostProcessing,
                    subtitle: extension.postProcessing?.hooks.isNotEmpty == true
                        ? context.l10n.extensionHooksAvailable(
                            extension.postProcessing!.hooks.length,
                          )
                        : null,
                  ),
                  _CapabilityItem(
                    icon: Icons.link,
                    title: context.l10n.extensionUrlHandler,
                    enabled: extension.hasURLHandler,
                    subtitle: extension.urlHandler?.patterns.isNotEmpty == true
                        ? context.l10n.extensionPatternsCount(
                            extension.urlHandler!.patterns.length,
                          )
                        : null,
                  ),
                  _CapabilityItem(
                    icon: Icons.monitor_heart_outlined,
                    title: context.l10n.extensionServiceHealth,
                    enabled: extension.hasServiceHealth,
                    subtitle: extension.hasServiceHealth
                        ? context.l10n.extensionHealthChecksConfigured(
                            extension.serviceHealth.length,
                          )
                        : null,
                    showDivider: false,
                  ),
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: AppDialogAction(
                  onPressed: () => _confirmRemove(context),
                  isDestructive: true,
                  outlined: true,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colorScheme.error,
                    side: BorderSide(color: colorScheme.error),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AppIcon(
                        context.isMornye
                            ? CupertinoIcons.trash
                            : Icons.delete_outline,
                      ),
                      const SizedBox(width: 8),
                      Flexible(child: Text(context.l10n.extensionRemoveButton)),
                    ],
                  ),
                ),
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }

  Future<void> _updateSetting(String key, dynamic value) async {
    setState(() {
      _settings[key] = value;
    });
    await ref
        .read(extensionProvider.notifier)
        .setExtensionSettings(widget.extensionId, _settings);
  }

  /// Extensions may return `setting_updates` from button actions (e.g. OAuth URL field).
  Future<void> _handleExtensionActionPayload(
    Map<String, dynamic> payload,
  ) async {
    final raw = payload['setting_updates'];
    if (raw is! Map) return;
    final partial = <String, dynamic>{};
    for (final entry in raw.entries) {
      partial[entry.key.toString()] = entry.value;
    }
    if (partial.isEmpty) return;
    final merged = Map<String, dynamic>.from(_settings);
    merged.addAll(partial);
    await ref
        .read(extensionProvider.notifier)
        .setExtensionSettings(widget.extensionId, merged);
    if (mounted) {
      setState(() => _settings = merged);
    }
  }

  Future<void> _confirmRemove(BuildContext context) async {
    final colorScheme = Theme.of(context).colorScheme;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppAlertDialog(
        title: Text(context.l10n.dialogRemoveExtension),
        content: Text(context.l10n.dialogRemoveExtensionMessage),
        actions: [
          AppDialogAction(
            isDefault: true,
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.dialogCancel),
          ),
          AppDialogAction(
            filled: true,
            isDestructive: true,
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: colorScheme.error),
            child: Text(context.l10n.dialogRemove),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final success = await ref
          .read(extensionProvider.notifier)
          .removeExtension(widget.extensionId);
      if (success && mounted) {
        ref.read(repoProvider.notifier).refresh();
        Navigator.pop(this.context);
      }
    }
  }
}
