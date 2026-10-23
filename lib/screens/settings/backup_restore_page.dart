import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart' show ShareParams, SharePlus, XFile;
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/user_profile_provider.dart';
import 'package:mornye/services/backup_service.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_sliver_header.dart';

class BackupRestorePage extends ConsumerStatefulWidget {
  const BackupRestorePage({super.key});

  @override
  ConsumerState<BackupRestorePage> createState() => _BackupRestorePageState();
}

class _BackupRestorePageState extends ConsumerState<BackupRestorePage> {
  static final _log = AppLogger('BackupRestorePage');

  bool _isExporting = false;
  bool _isImporting = false;
  bool _includeSecrets = false;
  bool _includeSettings = true;
  bool _includeHistory = true;
  bool _includeCollections = true;
  bool _includeExtensions = true;

  bool get _isBusy => _isExporting || _isImporting;
  bool get _hasSelection =>
      _includeSettings ||
      _includeHistory ||
      _includeCollections ||
      _includeExtensions;

  Future<void> _createBackup() async {
    if (_isBusy || !_hasSelection) return;
    setState(() => _isExporting = true);
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final settings = _includeSettings
          ? ref.read(settingsProvider).toJson()
          : null;
      String? collectionsJson;
      var covers = <String, Map<String, String>>{};
      if (_includeCollections) {
        final notifier = ref.read(libraryCollectionsProvider.notifier);
        collectionsJson = await notifier.exportCollectionsJson();
        covers = await notifier.exportPlaylistCoverFiles();
      }
      final extensions = _includeExtensions
          ? await ref
                .read(extensionProvider.notifier)
                .exportBackup(includeSecrets: _includeSecrets)
          : <String, dynamic>{};

      final file = await BackupService.writeBackupArchive(
        settings: settings,
        profile: _includeSettings
            ? await ref.read(userProfileProvider.future)
            : null,
        includeHistory: _includeHistory,
        loadHistoryPage: (limit, offset) =>
            HistoryDatabase.instance.getAll(limit: limit, offset: offset),
        collections: const {},
        collectionsJson: collectionsJson,
        playlistCoverFiles: covers,
        extensions: extensions,
      );

      messenger.showSnackBar(SnackBar(content: Text(l10n.backupCreated)));

      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: l10n.backupTitle),
      );
    } catch (e, stack) {
      _log.e('Failed to create backup: $e', e, stack);
      messenger.showSnackBar(SnackBar(content: Text(l10n.backupCreateFailed)));
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _restoreBackup() async {
    if (_isBusy) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);

    BackupBundle? bundle;
    try {
      // Android resolves custom extensions to MIME types. It recognizes JSON
      // but not SFLB, so mixing them hides our own backups. Validate contents
      // with BackupService after selection instead of filtering by extension.
      final picked = await FilePicker.pickFile(type: FileType.any);
      if (picked == null) return;
      final path = picked.path;
      bundle = path != null
          ? await BackupService.parseFile(path)
          : BackupService.parse(utf8.decode(await picked.readAsBytes()));
    } catch (e) {
      _log.e('Failed to read backup file: $e');
      messenger.showSnackBar(SnackBar(content: Text(l10n.backupInvalidFile)));
      return;
    }

    if (bundle == null) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.backupInvalidFile)));
      return;
    }

    if (!mounted) {
      await bundle.cleanup();
      return;
    }
    final confirmed = await _confirmRestore(bundle);
    if (!confirmed || !mounted) {
      await bundle.cleanup();
      return;
    }

    setState(() => _isImporting = true);
    try {
      if (bundle.profile != null) {
        await ref
            .read(userProfileProvider.notifier)
            .restoreFromBackup(bundle.profile!);
      }
      if (bundle.hasSettings) {
        await ref
            .read(settingsProvider.notifier)
            .restoreFromBackup(bundle.settings!);
      }
      if (bundle.hasHistory) {
        await ref
            .read(downloadHistoryProvider.notifier)
            .restoreFromBackupOperation(
              () => BackupService.restoreHistory(bundle!),
            );
      }
      if (bundle.hasCollections) {
        await ref
            .read(libraryCollectionsProvider.notifier)
            .restoreFromBackup(
              bundle.collections,
              coverImages: bundle.playlistCovers,
            );
      }

      ExtensionRestoreResult? extResult;
      if (bundle.hasExtensions) {
        extResult = await ref
            .read(extensionProvider.notifier)
            .restoreFromBackup(bundle.extensions);
      }

      final message = StringBuffer(l10n.backupRestored)
        ..write('\n')
        ..write(l10n.backupRestoreRestartHint);
      if (extResult != null && extResult.failed > 0) {
        message
          ..write('\n')
          ..write(l10n.backupExtensionsRestoreFailed(extResult.failed));
      }

      messenger.showSnackBar(
        SnackBar(
          content: Text(message.toString()),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (e, stack) {
      _log.e('Failed to restore backup: $e', e, stack);
      messenger.showSnackBar(SnackBar(content: Text(l10n.backupRestoreFailed)));
    } finally {
      await bundle.cleanup();
      if (mounted) setState(() => _isImporting = false);
    }
  }

  Future<bool> _confirmRestore(BackupBundle bundle) {
    final l10n = context.l10n;
    return showAppConfirmDialog(
      context,
      title: l10n.backupRestoreConfirmTitle,
      confirmLabel: l10n.backupRestoreConfirmButton,
      cancelIsDefault: true,
      destructive: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.backupSelectedRestoreMessage),
          const SizedBox(height: 16),
          Builder(
            builder: (dialogContext) => Text(
              l10n.backupContentsTitle,
              style: Theme.of(
                dialogContext,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 6),
          if (bundle.hasSettings)
            _ContentRow(
              icon: Icons.settings_outlined,
              label: l10n.backupContentsSettings,
            ),
          if (bundle.profile != null)
            _ContentRow(icon: Icons.person_outline, label: l10n.profileTitle),
          if (bundle.hasHistory)
            _ContentRow(
              icon: Icons.history,
              label: l10n.backupContentsHistory(bundle.historyCount),
            ),
          if (bundle.hasCollections)
            _ContentRow(
              icon: Icons.favorite_outline,
              label: l10n.backupContentsLiked(bundle.likedCount),
            ),
          if (bundle.hasCollections)
            _ContentRow(
              icon: Icons.bookmark_outline,
              label: l10n.backupContentsWishlist(bundle.wishlistCount),
            ),
          if (bundle.hasCollections)
            _ContentRow(
              icon: Icons.queue_music_outlined,
              label: l10n.backupContentsPlaylists(bundle.playlistCount),
            ),
          if (bundle.favoriteArtistCount > 0)
            _ContentRow(
              icon: Icons.person_outline,
              label: l10n.backupContentsArtists(bundle.favoriteArtistCount),
            ),
          if (bundle.extensionCount > 0)
            _ContentRow(
              icon: Icons.extension_outlined,
              label: l10n.backupContentsExtensions(bundle.extensionCount),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: l10n.backupTitle),
          ...settingsSectionSlivers(
            title: l10n.backupExportSectionTitle,
            children: [
              SettingsItem(
                icon: Icons.settings_outlined,
                title: l10n.backupSettingsOnly,
                onTap: _isBusy
                    ? null
                    : () => setState(() {
                        _includeSettings = true;
                        _includeHistory = false;
                        _includeCollections = false;
                        _includeExtensions = false;
                        _includeSecrets = false;
                      }),
              ),
              SettingsSwitchItem(
                icon: Icons.settings_outlined,
                title: l10n.backupContentsSettings,
                subtitle: l10n.backupIncludesProfile,
                value: _includeSettings,
                onChanged: _isBusy
                    ? null
                    : (value) => setState(() => _includeSettings = value),
              ),
              SettingsSwitchItem(
                icon: Icons.history,
                title: l10n.backupSelectHistory,
                value: _includeHistory,
                onChanged: _isBusy
                    ? null
                    : (value) => setState(() => _includeHistory = value),
              ),
              SettingsSwitchItem(
                icon: Icons.library_music_outlined,
                title: l10n.backupSelectCollections,
                subtitle: l10n.backupSelectCollectionsDescription,
                value: _includeCollections,
                onChanged: _isBusy
                    ? null
                    : (value) => setState(() => _includeCollections = value),
              ),
              SettingsSwitchItem(
                icon: Icons.extension_outlined,
                title: l10n.backupSelectExtensions,
                value: _includeExtensions,
                onChanged: _isBusy
                    ? null
                    : (value) => setState(() {
                        _includeExtensions = value;
                        if (!value) _includeSecrets = false;
                      }),
              ),
              SettingsSwitchItem(
                icon: Icons.vpn_key_outlined,
                title: l10n.backupIncludeSecrets,
                subtitle: l10n.backupIncludeSecretsDescription,
                value: _includeSecrets,
                onChanged: _isBusy || !_includeExtensions
                    ? null
                    : (value) => setState(() => _includeSecrets = value),
              ),
              SettingsItem(
                icon: Icons.ios_share,
                title: l10n.backupExportButton,
                subtitle: _hasSelection
                    ? l10n.backupSelectedExportDescription
                    : l10n.backupSelectAtLeastOne,
                onTap: _isBusy || !_hasSelection ? null : _createBackup,
                trailing: _isExporting
                    ? const AppLoadingIndicator(size: 20, strokeWidth: 2)
                    : null,
                showDivider: false,
              ),
            ],
          ),
          ...settingsSectionSlivers(
            title: l10n.backupImportSectionTitle,
            children: [
              SettingsItem(
                icon: Icons.settings_backup_restore,
                title: l10n.backupImportButton,
                subtitle: l10n.backupImportSectionDescription,
                onTap: _isBusy ? null : _restoreBackup,
                trailing: _isImporting
                    ? const AppLoadingIndicator(size: 20, strokeWidth: 2)
                    : null,
                showDivider: false,
              ),
            ],
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

class _ContentRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _ContentRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          AppIcon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
