import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/extension_row.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/download_fallback_extensions_page.dart';
import 'package:mornye/screens/settings/extension_detail_page.dart';
import 'package:mornye/screens/settings/metadata_provider_priority_page.dart';
import 'package:mornye/screens/settings/provider_priority_page.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/home_feed_region_setting.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/extension_health.dart';

part 'extensions_page_widgets.dart';

class ExtensionsPage extends ConsumerStatefulWidget {
  const ExtensionsPage({super.key});

  @override
  ConsumerState<ExtensionsPage> createState() => _ExtensionsPageState();
}

class _ExtensionsPageState extends ConsumerState<ExtensionsPage> {
  @override
  void initState() {
    super.initState();
    _initializeExtensions();
  }

  Future<void> _initializeExtensions() async {
    final extState = ref.read(extensionProvider);
    if (!extState.isInitialized) {
      try {
        await ref.read(extensionProvider.notifier).ensureInitialized();
      } catch (_) {
        // The provider exposes preparation failures in the existing error UI.
      }
    } else {
      ref.read(extensionProvider.notifier).refreshEnabledExtensionHealth();
    }
  }

  @override
  Widget build(BuildContext context) {
    final extState = ref.watch(extensionProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final installButton = AppActionButton(
      onPressed: _installExtension,
      icon: const AppIcon(Icons.add),
      label: Text(context.l10n.extensionsInstallButton),
      outlined: context.isMornye,
      glass: false,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );

    return PopScope(
      canPop: true,
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: context.l10n.extensionsTitle),

            if (extState.isLoading)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: AppLoadingIndicator()),
                ),
              ),

            if (extState.error != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        AppIcon(
                          Icons.error_outline,
                          color: colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            context.friendlyError(extState.error),
                            style: TextStyle(
                              color: colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            SliverToBoxAdapter(
              child: SettingsSectionHeader(
                title: context.l10n.extensionsProviderPrioritySection,
              ),
            ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                connected: true,
                children: [
                  _DownloadPriorityItem(),
                  _DownloadFallbackItem(),
                  _MetadataPriorityItem(),
                  _SearchProviderSelector(),
                  _HomeFeedProviderSelector(),
                  HomeFeedRegionSetting(),
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsSectionHeader(
                title: context.l10n.extensionsInstalledSection,
              ),
            ),

            if (extState.extensions.isEmpty && !extState.isLoading)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.3,
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      children: [
                        AppIcon(
                          Icons.extension_outlined,
                          size: 48,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          context.l10n.extensionsNoExtensions,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          context.l10n.extensionsNoExtensionsSubtitle,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            if (extState.extensions.isNotEmpty)
              SliverToBoxAdapter(
                child: SettingsGroup(
                  connected: true,
                  children: extState.extensions.asMap().entries.map((entry) {
                    final index = entry.key;
                    final ext = entry.value;
                    return _ExtensionItem(
                      extension: ext,
                      healthStatus: extState.healthStatuses[ext.id],
                      showDivider: index < extState.extensions.length - 1,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              ExtensionDetailPage(extensionId: ext.id),
                        ),
                      ),
                      onToggle: (enabled) => ref
                          .read(extensionProvider.notifier)
                          .setExtensionEnabled(ext.id, enabled),
                    );
                  }).toList(),
                ),
              ),

            SliverToBoxAdapter(
              child: SettingsSearchTarget(
                label: context.l10n.extensionsInstallButton,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Same edges as the extension group above.
                    final inset = settingsHorizontalInset(constraints.maxWidth);
                    return Padding(
                      padding: EdgeInsets.fromLTRB(inset, 16, inset, 16),
                      child: context.isMornye
                          ? MornyeGlassPanel.overlay(
                              radius: 28,
                              samplesBackdrop: false,
                              child: installButton,
                            )
                          : installButton,
                    );
                  },
                ),
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsInfoCard(
                glass: true,
                icon: Icons.info_outline,
                tone: SettingsInfoTone.warning,
                message: context.l10n.extensionsInfoTip,
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _installExtension() async {
    final selectedFiles = await FilePicker.pickFiles(type: FileType.any);
    if (selectedFiles.isEmpty) return;

    final hasInvalidFile = selectedFiles.any((file) {
      final lowerName = file.name.toLowerCase();
      return !lowerName.endsWith('.mornye-ext') &&
          !lowerName.endsWith('.spotiflac-ext') &&
          !lowerName.endsWith('.sflx');
    });
    if (hasInvalidFile) {
      if (mounted) {
        showAppSnackBar(
          context,
          content: Text(context.l10n.snackbarSelectExtFile),
        );
      }
      return;
    }

    Directory? materializedDir;
    try {
      final extensionPaths = <String>[];
      for (final selectedFile in selectedFiles) {
        final localPath = selectedFile.path;
        if (localPath != null && localPath.isNotEmpty) {
          extensionPaths.add(localPath);
          continue;
        }

        materializedDir ??= await Directory.systemTemp.createTemp(
          'mornye_extension_import_',
        );
        final safeName = p.basename(selectedFile.name);
        final materializedFile = File(
          p.join(materializedDir.path, '${extensionPaths.length}_$safeName'),
        );
        await materializedFile.writeAsBytes(
          await selectedFile.readAsBytes(),
          flush: true,
        );
        extensionPaths.add(materializedFile.path);
      }

      final installResult = await ref
          .read(extensionProvider.notifier)
          .installExtensions(extensionPaths);

      if (mounted) {
        final message = _getInstallResultMessage(installResult);
        ref.read(extensionProvider.notifier).clearError();

        showAppSnackBar(context, content: Text(message));
      }
    } finally {
      try {
        if (materializedDir != null && await materializedDir.exists()) {
          await materializedDir.delete(recursive: true);
        }
      } catch (_) {
        // The extension has already been copied into app storage.
      }
    }
  }

  String _getInstallResultMessage(ExtensionInstallBatchResult result) {
    if (result.attempted == 0) {
      return context.l10n.snackbarSelectExtFile;
    }

    if (!result.hasFailures) {
      if (result.installed == 1) {
        return context.l10n.extensionsInstalledSuccess;
      }
      return context.l10n.extensionsInstalledCount(result.installed);
    }

    if (result.anyInstalled) {
      return context.l10n.extensionsInstallPartialSuccess(
        result.installed,
        result.attempted,
      );
    }

    final firstError = result.failures.values.firstOrNull;
    return _getFriendlyErrorMessage(firstError);
  }

  String _getFriendlyErrorMessage(String? error) {
    return context.friendlyError(
      error,
      fallback: context.l10n.snackbarFailedToInstall,
    );
  }
}
