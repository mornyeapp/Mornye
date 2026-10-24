import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_scan_failure.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/duplicate_review_sheet.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/ios_library_folder_sheet.dart';

part 'library_settings_page_widgets.dart';

class LibrarySettingsPage extends ConsumerStatefulWidget {
  const LibrarySettingsPage({super.key});

  @override
  ConsumerState<LibrarySettingsPage> createState() =>
      _LibrarySettingsPageState();
}

class _LibrarySettingsPageState extends ConsumerState<LibrarySettingsPage> {
  int _androidSdkVersion = 0;
  bool _hasStoragePermission = false;
  bool _isCleaningMissingFiles = false;

  String _getDisplayPath(String path) {
    if (!path.startsWith('content://')) return path;
    try {
      final uri = Uri.parse(path);
      final treePath = uri.pathSegments.last;
      final decoded = Uri.decodeComponent(treePath);
      if (decoded.startsWith('primary:')) {
        return '/storage/emulated/0/${decoded.substring('primary:'.length)}';
      }
      return decoded;
    } catch (_) {
      return path;
    }
  }

  @override
  void initState() {
    super.initState();
    _initDeviceInfo();
  }

  Future<void> _initDeviceInfo() async {
    if (Platform.isAndroid) {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      final sdkVersion = androidInfo.version.sdkInt;

      if (mounted) {
        setState(() {
          _androidSdkVersion = sdkVersion;
          _hasStoragePermission = sdkVersion >= 29 ? true : false;
        });
        if (sdkVersion < 29) {
          final hasPermission = await Permission.storage.isGranted;
          if (mounted) {
            setState(() => _hasStoragePermission = hasPermission);
          }
        }
      }
    } else if (Platform.isIOS) {
      setState(() => _hasStoragePermission = true);
    } else {
      setState(() => _hasStoragePermission = true);
    }
  }

  Future<bool> _requestStoragePermission() async {
    if (!Platform.isAndroid) return true;
    if (_androidSdkVersion >= 29) return true;

    final status = await Permission.storage.request();

    if (status.isGranted) {
      setState(() => _hasStoragePermission = true);
      return true;
    } else if (status.isPermanentlyDenied && mounted) {
      final shouldOpen = await showAppConfirmDialog(
        context,
        title: context.l10n.libraryStorageAccessRequired,
        message: context.l10n.libraryStorageAccessMessage,
        confirmLabel: context.l10n.setupOpenSettings,
        confirmIsDefault: true,
      );
      if (shouldOpen) await openAppSettings();
    }
    return false;
  }

  Future<void> _pickLibraryFolder() async {
    if (Platform.isAndroid && _androidSdkVersion >= 29) {
      // Use SAF tree picker - no MANAGE_EXTERNAL_STORAGE needed
      final result = await PlatformBridge.pickSafTree();
      if (result != null) {
        final treeUri = result['tree_uri'] as String? ?? '';
        if (treeUri.isNotEmpty) {
          final source = await ref
              .read(localLibraryProvider.notifier)
              .addSource(
                path: treeUri,
                displayName:
                    result['display_name'] as String? ??
                    _getDisplayPath(treeUri),
                volumeId: result['volume_id'] as String?,
                isRemovable: result['is_removable'] == true,
              );
          await ref
              .read(localLibraryProvider.notifier)
              .startSourceScan(source.id);
        }
      }
    } else {
      // Older Android needs storage permission; iOS chooses internal or Files.
      if (!_hasStoragePermission) {
        final granted = await _requestStoragePermission();
        if (!granted) return;
      }
      if (Platform.isIOS) {
        if (!mounted) return;
        IosPickedDirectory? picked;
        try {
          picked = await showIosLibraryFolderSheet(context);
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  context.l10n.snackbarFolderPickerFailed(
                    context.friendlyError(e),
                  ),
                ),
              ),
            );
          }
          return;
        }
        if (picked != null && mounted) {
          final library = ref.read(localLibraryProvider.notifier);
          final source = await library.addSource(
            path: picked.path,
            displayName: picked.bookmark.isEmpty
                ? context.l10n.setupAppDocumentsFolder
                : picked.path,
            bookmark: picked.bookmark,
          );
          await library.startSourceScan(source.id);
        }
        return;
      }
      String? result;
      try {
        result = await FilePicker.getDirectoryPath();
      } catch (e) {
        // Linux reaches the picker through the desktop portal, which a
        // session may not run.
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.l10n.snackbarFolderPickerFailed(
                  context.friendlyError(e),
                ),
              ),
            ),
          );
        }
        return;
      }
      if (result != null) {
        final source = await ref
            .read(localLibraryProvider.notifier)
            .addSource(path: result, displayName: result);
        await ref
            .read(localLibraryProvider.notifier)
            .startSourceScan(source.id);
      }
    }
  }

  Future<void> _startScan({bool forceFullScan = false}) async {
    final sources = ref.read(localLibraryProvider).sources;
    if (sources.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.libraryScanSelectFolderFirst)),
      );
      return;
    }
    await ref
        .read(localLibraryProvider.notifier)
        .scanAllSources(forceFullScan: forceFullScan);
  }

  Future<void> _cancelScan() async {
    await ref.read(localLibraryProvider.notifier).cancelScan();
  }

  Future<void> _pauseScan() async {
    await ref.read(localLibraryProvider.notifier).pauseScan();
  }

  Future<void> _resumeScan() async {
    await ref.read(localLibraryProvider.notifier).resumeScan();
  }

  Future<void> _clearLibrary() async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: context.l10n.libraryClearConfirmTitle,
      message: context.l10n.libraryClearConfirmMessage,
      confirmLabel: context.l10n.dialogClear,
      cancelIsDefault: true,
      destructive: true,
      errorConfirm: true,
    );

    if (confirmed) {
      await ref.read(localLibraryProvider.notifier).clearLibrary();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.libraryCleared)));
      }
    }
  }

  Future<void> _cleanupMissingFiles() async {
    if (_isCleaningMissingFiles || ref.read(localLibraryProvider).isScanning) {
      return;
    }
    final library = ref.read(localLibraryProvider.notifier);
    final downloads = ref.read(downloadHistoryProvider.notifier);
    setState(() => _isCleaningMissingFiles = true);
    try {
      final missingLibraryEntries = await library.cleanupMissingFiles();
      final orphanedDownloads = await downloads.cleanupOrphanedDownloads();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.libraryRemovedMissingFiles(
              missingLibraryEntries + orphanedDownloads,
            ),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.snackbarError(context.friendlyError(error)),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isCleaningMissingFiles = false);
    }
  }

  Future<void> _removeSource(LocalLibrarySource source) async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: context.l10n.libraryRemoveFolder,
      message: context.l10n.libraryRemoveFolderMessage,
      confirmLabel: context.l10n.dialogRemove,
      cancelIsDefault: true,
      destructive: true,
      errorConfirm: true,
    );
    if (!confirmed) return;
    await ref.read(localLibraryProvider.notifier).removeSource(source.id);
    final settings = ref.read(settingsProvider);
    if (settings.localLibraryPath == source.path) {
      ref
          .read(settingsProvider.notifier)
          .setLocalLibraryPathAndBookmark('', '');
    }
  }

  String _getAutoScanLabel(BuildContext context, String mode) {
    switch (mode) {
      case 'on_open':
        return context.l10n.libraryAutoScanOnOpen;
      case 'daily':
        return context.l10n.libraryAutoScanDaily;
      case 'weekly':
        return context.l10n.libraryAutoScanWeekly;
      default:
        return context.l10n.libraryAutoScanOff;
    }
  }

  void _showAutoScanPicker(BuildContext context, String current) =>
      showAppChoiceSheet(
        context: context,
        title: context.l10n.libraryAutoScan,
        subtitle: context.l10n.libraryAutoScanSubtitle,
        selected: current,
        choices: [
          AppChoice('off', Icons.block, context.l10n.libraryAutoScanOff),
          AppChoice(
            'on_open',
            Icons.open_in_new,
            context.l10n.libraryAutoScanOnOpen,
          ),
          AppChoice('daily', Icons.today, context.l10n.libraryAutoScanDaily),
          AppChoice(
            'weekly',
            Icons.date_range,
            context.l10n.libraryAutoScanWeekly,
          ),
        ],
        onSelected: (mode) =>
            ref.read(settingsProvider.notifier).setLocalLibraryAutoScan(mode),
      );

  String _getDefaultViewLabel(BuildContext context, String view) {
    switch (view) {
      case 'all':
        return context.l10n.searchSongs;
      case 'albums':
        return context.l10n.historyFilterAlbums;
      case 'singles':
        return context.l10n.historyFilterSingles;
      case 'artists':
        return context.l10n.searchArtists;
      case 'playlists':
        return context.l10n.searchPlaylists;
      case 'folders':
        return context.l10n.libraryFolders;
      default:
        return context.l10n.libraryDefaultViewLastUsed;
    }
  }

  void _showDefaultViewPicker(BuildContext context, String current) =>
      showAppChoiceSheet(
        context: context,
        title: context.l10n.libraryDefaultView,
        selected: current,
        choices: [
          for (final (value, icon) in const [
            ('last', Icons.history),
            ('all', Icons.music_note),
            ('albums', Icons.album),
            ('singles', Icons.audiotrack),
            ('artists', Icons.person),
            ('playlists', Icons.queue_music),
            ('folders', Icons.folder_outlined),
          ])
            AppChoice(value, icon, _getDefaultViewLabel(context, value)),
        ],
        onSelected: (view) =>
            ref.read(settingsProvider.notifier).setDefaultLibraryView(view),
      );

  String _getQualityLabelModeLabel(BuildContext context, String mode) {
    if (mode == AppSettings.libraryQualityLabelFileFormat) {
      return context.l10n.libraryQualityLabelFileFormat;
    }
    if (mode == AppSettings.libraryQualityLabelBitDepthOnly) {
      return context.l10n.audioAnalysisBitDepth;
    }
    if (mode == AppSettings.libraryQualityLabelBitDepth) {
      return '${context.l10n.audioAnalysisBitDepth} & '
          '${context.l10n.audioAnalysisSampleRate}';
    }
    if (mode == AppSettings.libraryQualityLabelBitDepthBitrate) {
      return '${context.l10n.audioAnalysisBitDepth} & '
          '${context.l10n.trackConvertBitrate}';
    }
    return context.l10n.trackConvertBitrate;
  }

  void _showQualityLabelModePicker(
    BuildContext context,
    String current,
  ) => showAppChoiceSheet(
    context: context,
    title: context.l10n.trackAudioQuality,
    selected: current,
    choices: [
      for (final (value, icon) in const [
        (AppSettings.libraryQualityLabelBitrate, Icons.speed_rounded),
        (AppSettings.libraryQualityLabelBitDepthOnly, Icons.tune_rounded),
        (AppSettings.libraryQualityLabelBitDepth, Icons.graphic_eq_rounded),
        (
          AppSettings.libraryQualityLabelBitDepthBitrate,
          Icons.multiline_chart_rounded,
        ),
        (AppSettings.libraryQualityLabelFileFormat, Icons.audio_file_rounded),
      ])
        AppChoice(value, icon, _getQualityLabelModeLabel(context, value)),
    ],
    onSelected: (mode) =>
        ref.read(settingsProvider.notifier).setLibraryQualityLabelMode(mode),
  );

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final librarySources = ref.watch(
      localLibraryProvider.select((state) => state.sources),
    );
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: context.l10n.libraryTitle),

          // Scan snapshots land ~2.5x/s; keep the per-snapshot rebuild scoped
          // to the widgets that actually display scan state instead of the
          // whole settings page.
          SliverToBoxAdapter(
            child: Consumer(
              builder: (context, ref, _) {
                final libraryState = ref.watch(localLibraryProvider);
                return _LibraryHeroCard(
                  itemCount: libraryState.totalCount,
                  excludedDownloadedCount: libraryState.excludedDownloadedCount,
                  isScanning: libraryState.isScanning,
                  scanIsFinalizing: libraryState.scanIsFinalizing,
                  scanIsPaused: libraryState.scanIsPaused,
                  scanProgress: libraryState.scanProgress,
                  scanCurrentFile: libraryState.scanCurrentFile,
                  scanTotalFiles: libraryState.scanTotalFiles,
                  scannedFiles: libraryState.scannedFiles,
                  lastScannedAt: libraryState.lastScannedAt,
                );
              },
            ),
          ),

          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsItem(
                  icon: Icons.grid_view_rounded,
                  title: context.l10n.libraryDefaultView,
                  subtitle: _getDefaultViewLabel(
                    context,
                    settings.defaultLibraryView,
                  ),
                  onTap: () => _showDefaultViewPicker(
                    context,
                    settings.defaultLibraryView,
                  ),
                ),
                SettingsItem(
                  icon: Icons.graphic_eq_rounded,
                  title: context.l10n.trackAudioQuality,
                  subtitle: _getQualityLabelModeLabel(
                    context,
                    settings.libraryQualityLabelMode,
                  ),
                  onTap: () => _showQualityLabelModePicker(
                    context,
                    settings.libraryQualityLabelMode,
                  ),
                  showDivider: false,
                ),
              ],
            ),
          ),

          SliverToBoxAdapter(
            child: SettingsSectionHeader(
              title: context.l10n.libraryScanSettings,
            ),
          ),
          SliverToBoxAdapter(
            child: Consumer(
              builder: (context, ref, _) {
                final status = ref.watch(
                  localLibraryProvider.select(
                    (state) =>
                        (loading: state.isLoading, failed: state.loadFailed),
                  ),
                );
                if (!status.loading && !status.failed) {
                  return const SizedBox.shrink();
                }
                return ListTile(
                  leading: status.loading
                      ? const AppLoadingIndicator(size: 24, strokeWidth: 2)
                      : AppIcon(Icons.error_outline, color: colorScheme.error),
                  title: Text(
                    status.loading
                        ? context.l10n.libraryLoading
                        : context.l10n.libraryLoadFailed,
                  ),
                  trailing: status.loading
                      ? null
                      : ExpressiveButton(
                          text: true,
                          onPressed: () => ref
                              .read(localLibraryProvider.notifier)
                              .reloadFromStorage(),
                          child: Text(context.l10n.dialogRetry),
                        ),
                );
              },
            ),
          ),
          SliverToBoxAdapter(
            child: SettingsGroup(
              connected: true,
              children: [
                SettingsSwitchItem(
                  icon: Icons.library_music_outlined,
                  title: context.l10n.libraryEnableLocalLibrary,
                  subtitle: settings.localLibraryEnabled
                      ? context.l10n.libraryEnableLocalLibrarySubtitle
                      : context.l10n.extensionsDisabled,
                  value: settings.localLibraryEnabled,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setLocalLibraryEnabled(value),
                ),
                for (final source in librarySources)
                  Consumer(
                    builder: (context, ref, _) {
                      final scan = ref.watch(
                        localLibraryProvider.select((state) {
                          final active = state.scanningSourceId == source.id;
                          return (
                            active: active,
                            finalizing: active && state.scanIsFinalizing,
                            paused: active && state.scanIsPaused,
                            scanned: active ? state.scannedFiles : 0,
                            total: active ? state.scanTotalFiles : 0,
                            progress: active ? state.scanProgress : 0.0,
                            failures: state.scanFailures[source.id],
                          );
                        }),
                      );
                      return _LibrarySourceSettingsItem(
                        source: source,
                        failures: scan.failures,
                        isScanning: scan.active,
                        isFinalizing: scan.finalizing,
                        isPaused: scan.paused,
                        scannedFiles: scan.scanned,
                        totalFiles: scan.total,
                        progress: scan.progress,
                        enabled: settings.localLibraryEnabled,
                        onEnabledChanged: (value) => ref
                            .read(localLibraryProvider.notifier)
                            .setSourceEnabled(source.id, value),
                        onScan: () => ref
                            .read(localLibraryProvider.notifier)
                            .startSourceScan(source.id),
                        onFullScan: () => ref
                            .read(localLibraryProvider.notifier)
                            .startSourceScan(source.id, forceFullScan: true),
                        onRemove: () => _removeSource(source),
                      );
                    },
                  ),
                Opacity(
                  opacity: settings.localLibraryEnabled ? 1.0 : 0.5,
                  child: SettingsItem(
                    icon: Icons.create_new_folder_outlined,
                    title: context.l10n.libraryAddFolder,
                    subtitle: librarySources.isEmpty
                        ? context.l10n.libraryFolderHint
                        : context.l10n.libraryAddFolderSubtitle,
                    onTap: settings.localLibraryEnabled
                        ? _pickLibraryFolder
                        : null,
                  ),
                ),
                SettingsSwitchItem(
                  icon: Icons.content_copy_outlined,
                  title: context.l10n.libraryShowDuplicateIndicator,
                  subtitle: settings.localLibraryShowDuplicates
                      ? context.l10n.libraryShowDuplicateIndicatorSubtitle
                      : context.l10n.extensionsDisabled,
                  value: settings.localLibraryShowDuplicates,
                  enabled: settings.localLibraryEnabled,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setLocalLibraryShowDuplicates(value),
                ),
                SettingsItem(
                  icon: Icons.difference_outlined,
                  title: context.l10n.libraryReviewDuplicates,
                  subtitle: context.l10n.libraryReviewDuplicatesSubtitle,
                  onTap: () => DuplicateReviewSheet.show(context),
                ),
                Opacity(
                  opacity: settings.localLibraryEnabled ? 1.0 : 0.5,
                  child: SettingsItem(
                    icon: Icons.autorenew_rounded,
                    title: context.l10n.libraryAutoScan,
                    subtitle: _getAutoScanLabel(
                      context,
                      settings.localLibraryAutoScan,
                    ),
                    onTap: settings.localLibraryEnabled
                        ? () => _showAutoScanPicker(
                            context,
                            settings.localLibraryAutoScan,
                          )
                        : null,
                    showDivider: false,
                  ),
                ),
              ],
            ),
          ),

          if (settings.localLibraryEnabled) ...[
            SliverToBoxAdapter(
              child: SettingsSectionHeader(title: context.l10n.libraryActions),
            ),
            if (ref.watch(
              localLibraryProvider.select((s) => s.scanWasCancelled),
            ))
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.tertiaryContainer.withValues(
                        alpha: 0.6,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        AppIcon(
                          Icons.warning_amber_outlined,
                          color: colorScheme.onTertiaryContainer,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                context.l10n.libraryScanCancelled,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: colorScheme.onTertiaryContainer,
                                    ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                context.l10n.libraryScanCancelledSubtitle,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: colorScheme.onTertiaryContainer
                                          .withValues(alpha: 0.8),
                                    ),
                              ),
                            ],
                          ),
                        ),
                        ExpressiveButton(
                          text: true,
                          onPressed: _startScan,
                          child: Text(context.l10n.dialogRetry),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: Consumer(
                builder: (context, ref, _) {
                  final libraryState = ref.watch(localLibraryProvider);
                  final hasDownloads = ref.watch(
                    downloadHistoryProvider.select(
                      (state) => state.totalCount > 0,
                    ),
                  );
                  final canCleanup =
                      !_isCleaningMissingFiles &&
                      !libraryState.isScanning &&
                      (libraryState.totalCount > 0 ||
                          hasDownloads ||
                          librarySources.isNotEmpty);
                  return SettingsGroup(
                    connected: true,
                    children: [
                      if (libraryState.isScanning)
                        _ScanProgressTile(
                          isFinalizing: libraryState.scanIsFinalizing,
                          isPaused: libraryState.scanIsPaused,
                          progress: libraryState.scanProgress,
                          currentFile: libraryState.scanCurrentFile,
                          scannedFiles: libraryState.scannedFiles,
                          totalFiles: libraryState.scanTotalFiles,
                          onPause: _pauseScan,
                          onResume: _resumeScan,
                          onCancel: _cancelScan,
                        )
                      else ...[
                        Opacity(
                          opacity: librarySources.isNotEmpty ? 1.0 : 0.5,
                          child: SettingsItem(
                            icon: Icons.refresh,
                            title: context.l10n.libraryScan,
                            subtitle: librarySources.isEmpty
                                ? context.l10n.libraryScanSelectFolderFirst
                                : context.l10n.libraryScanSubtitle,
                            onTap: librarySources.isNotEmpty
                                ? _startScan
                                : null,
                          ),
                        ),
                        Opacity(
                          opacity: librarySources.isNotEmpty ? 1.0 : 0.5,
                          child: SettingsItem(
                            icon: Icons.sync,
                            title: context.l10n.libraryForceFullScan,
                            subtitle: context.l10n.libraryForceFullScanSubtitle,
                            onTap: librarySources.isNotEmpty
                                ? () => _startScan(forceFullScan: true)
                                : null,
                          ),
                        ),
                      ],
                      Opacity(
                        opacity: canCleanup || _isCleaningMissingFiles
                            ? 1.0
                            : 0.5,
                        child: SettingsItem(
                          icon: Icons.cleaning_services_outlined,
                          title: context.l10n.libraryCleanupMissingFiles,
                          subtitle:
                              context.l10n.libraryCleanupMissingFilesSubtitle,
                          trailing: _isCleaningMissingFiles
                              ? const AppLoadingIndicator(
                                  size: 20,
                                  strokeWidth: 2,
                                )
                              : null,
                          onTap: canCleanup ? _cleanupMissingFiles : null,
                        ),
                      ),
                      Opacity(
                        opacity: libraryState.totalCount > 0 ? 1.0 : 0.5,
                        child: SettingsItem(
                          icon: Icons.delete_outline,
                          title: context.l10n.libraryClear,
                          subtitle: context.l10n.libraryClearSubtitle,
                          onTap: libraryState.totalCount > 0
                              ? _clearLibrary
                              : null,
                          showDivider: false,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],

          SliverToBoxAdapter(
            child: SettingsInfoCard(
              glass: true,
              icon: Icons.info_outline,
              title: context.l10n.libraryAbout,
              message: context.l10n.libraryAboutDescription,
              margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 32)),
          const NavBarSliverSpacer(),
        ],
      ),
    );
  }
}
