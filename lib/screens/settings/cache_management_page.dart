import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/audio_analysis_cache.dart';
import 'package:mornye/services/cache_maintenance_service.dart';
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/services/motion_artwork_store.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/services/explore_cache_store.dart';
import 'package:mornye/services/library_cleanup.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/app_sliver_header.dart';

class CacheManagementPage extends ConsumerStatefulWidget {
  const CacheManagementPage({super.key});

  @override
  ConsumerState<CacheManagementPage> createState() =>
      _CacheManagementPageState();
}

class _CacheManagementPageState extends ConsumerState<CacheManagementPage> {
  _CacheOverview? _overview;
  bool _isLoading = true;
  String? _busyAction;

  @override
  void initState() {
    super.initState();
    _refreshOverview();
  }

  bool get _isBusy => _busyAction != null;

  Future<void> _refreshOverview() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final overview = await _buildOverview();
      if (!mounted) return;
      setState(() {
        _overview = overview;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.snackbarError(context.friendlyError(e))),
        ),
      );
    }
  }

  Future<_CacheOverview> _buildOverview() async {
    final appCacheDirFuture = getApplicationCacheDirectory();
    final tempDirFuture = getTemporaryDirectory();
    final appSupportDirFuture = getApplicationSupportDirectory();
    final coverStatsFuture = CoverCacheManager.getStats();
    final motionStatsFuture = MotionArtworkStore.defaultDirectory().then(
      CacheMaintenanceService.scanDirectory,
    );
    final prefsFuture = SharedPreferences.getInstance();
    final trackCacheEntriesFuture = _getTrackCacheSizeSafe();

    final appCacheDir = await appCacheDirFuture;
    final tempDir = await tempDirFuture;
    final appCachePath = p.normalize(appCacheDir.path);
    final tempPath = p.normalize(tempDir.path);
    final tempIsSameAsAppCache = appCachePath == tempPath;

    final appCacheStatsFuture = CacheMaintenanceService.scanDirectory(
      Directory(appCachePath),
    );
    final tempStatsFuture = tempIsSameAsAppCache
        ? Future<DirectoryStats?>.value(null)
        : CacheMaintenanceService.scanDirectory(Directory(tempPath));

    final appSupportDir = await appSupportDirFuture;
    final libraryCoverStatsFuture = CacheMaintenanceService.scanDirectory(
      Directory('${appSupportDir.path}/library_covers'),
    );
    final audioAnalysisStatsFuture = CacheMaintenanceService.scanDirectory(
      AudioAnalysisDiskCache.directoryIn(appSupportDir.path),
    );

    final prefs = await prefsFuture;
    final exploreBytes = (await ExploreCacheStore(prefs).read()).sizeBytes;
    final hasExploreCache = exploreBytes > 0;

    final appCacheStats = await appCacheStatsFuture;
    final tempStats = await tempStatsFuture;
    final coverStats = await coverStatsFuture;
    final libraryCoverStats = await libraryCoverStatsFuture;
    final audioAnalysisStats = await audioAnalysisStatsFuture;
    final trackCacheEntries = await trackCacheEntriesFuture;

    return _CacheOverview(
      appCacheStats: appCacheStats,
      tempStats: tempStats,
      tempIsSameAsAppCache: tempIsSameAsAppCache,
      coverStats: coverStats,
      motionStats: await motionStatsFuture,
      libraryCoverStats: libraryCoverStats,
      audioAnalysisStats: audioAnalysisStats,
      exploreCacheBytes: exploreBytes,
      hasExploreCache: hasExploreCache,
      trackCacheEntries: trackCacheEntries,
    );
  }

  Future<int> _getTrackCacheSizeSafe() async {
    try {
      return await PlatformBridge.getTrackCacheSize();
    } catch (_) {
      return 0;
    }
  }

  Future<void> _clearAppCache() async {
    await DownloadedEmbeddedCoverResolver.clearPersistentCache();
    final cacheDir = await getApplicationCacheDirectory();
    await CacheMaintenanceService.clearDirectoryContents(cacheDir.path);
  }

  Future<void> _clearTempCache() async {
    final tempDir = await getTemporaryDirectory();
    await CacheMaintenanceService.clearDirectoryContents(tempDir.path);
  }

  Future<void> _clearCoverCache() async {
    await CoverCacheManager.clearCache();
  }

  Future<void> _clearMotionArtwork() async {
    await ref.read(motionArtworkStoreProvider).clear();
    if (mounted) ref.invalidate(playerMotionArtworkProvider);
  }

  Future<void> _clearLibraryCoverCache() async {
    final appSupportDir = await getApplicationSupportDirectory();
    final libraryCoverDir = Directory('${appSupportDir.path}/library_covers');
    await clearLibraryCoverFiles(
      libraryCoverDir,
      await LibraryDatabase.instance.database,
    );
  }

  Future<void> _clearAudioAnalysisCache() async {
    final appSupportDir = await getApplicationSupportDirectory();
    final analysisDir = AudioAnalysisDiskCache.directoryIn(appSupportDir.path);
    await CacheMaintenanceService.clearDirectoryContents(analysisDir.path);
  }

  Future<void> _clearExploreCache() async {
    final prefs = await SharedPreferences.getInstance();
    await ExploreCacheStore(prefs).clear();
  }

  Future<void> _clearTrackCache() async {
    await PlatformBridge.clearTrackCache();
  }

  Future<void> _clearAllCaches() async {
    final currentOverview = _overview;
    await _clearAppCache();
    if (currentOverview != null && !currentOverview.tempIsSameAsAppCache) {
      await _clearTempCache();
    }
    await _clearCoverCache();
    await _clearLibraryCoverCache();
    await _clearAudioAnalysisCache();
    await _clearExploreCache();
    await _clearTrackCache();
  }

  Future<bool> _confirmClear(String title, String message) =>
      showAppConfirmDialog(
        context,
        title: title,
        message: message,
        confirmLabel: context.l10n.dialogClear,
        cancelIsDefault: true,
        destructive: true,
      );

  Future<void> _runAction(
    String actionKey,
    Future<void> Function() action, {
    String? successMessage,
  }) async {
    if (_isBusy || !mounted) return;
    setState(() => _busyAction = actionKey);

    try {
      await action();
      if (!mounted) return;
      if (successMessage != null && successMessage.isNotEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successMessage)));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.snackbarError(context.friendlyError(e))),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _busyAction = null);
        await _refreshOverview();
      }
    }
  }

  Future<void> _confirmAndRunAction({
    required String actionKey,
    required String targetLabel,
    required Future<void> Function() action,
  }) async {
    final confirmed = await _confirmClear(
      context.l10n.cacheClearConfirmTitle,
      context.l10n.cacheClearConfirmMessage(targetLabel),
    );
    if (!confirmed) return;

    if (!mounted) return;
    await _runAction(
      actionKey,
      action,
      successMessage: context.l10n.cacheClearSuccess(targetLabel),
    );
  }

  Future<void> _cleanupUnusedData() async {
    await _runAction('cleanup_unused', () async {
      final orphanedDownloads = await ref
          .read(downloadHistoryProvider.notifier)
          .cleanupOrphanedDownloads();
      final iosBookmark = ref.read(settingsProvider).localLibraryBookmark;
      final missingLibraryEntries = await ref
          .read(localLibraryProvider.notifier)
          .cleanupMissingFiles(
            iosBookmark: iosBookmark.isNotEmpty ? iosBookmark : null,
          );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.cacheCleanupResult(
              orphanedDownloads,
              missingLibraryEntries,
            ),
          ),
        ),
      );
    });
  }

  String _sizeLabel(int fileCount, int totalSizeBytes) {
    if (fileCount == 0 || totalSizeBytes == 0) return context.l10n.cacheNoData;
    return context.l10n.cacheSizeWithFiles(
      formatBytes(totalSizeBytes),
      fileCount,
    );
  }

  /// A cache row whose clear button confirms with [title] as the target.
  Widget _clearRow(
    IconData icon,
    String title,
    String description,
    String sizeInfo,
    String actionKey,
    Future<void> Function() action, {
    bool showDivider = true,
  }) => SettingsItem(
    icon: icon,
    title: title,
    subtitle: '$description\n$sizeInfo',
    trailing: _buildClearTrailing(
      actionKey,
      () => _confirmAndRunAction(
        actionKey: actionKey,
        targetLabel: title,
        action: action,
      ),
    ),
    showDivider: showDivider,
  );

  Widget _buildClearTrailing(String actionKey, VoidCallback onPressed) {
    if (_busyAction == actionKey) {
      return const AppLoadingIndicator(size: 18, strokeWidth: 2);
    }

    return ExpressiveButton(
      text: true,
      onPressed: _isBusy ? null : onPressed,
      child: Text(context.l10n.dialogClear),
    );
  }

  Widget _overviewSurface({required Widget child}) {
    final scheme = Theme.of(context).colorScheme;
    final mornye = context.isMornye;
    final content = Padding(padding: const EdgeInsets.all(16), child: child);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: mornye
              ? scheme.surfaceContainer
              : scheme.primaryContainer.withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(mornye ? 28 : 18),
        ),
        child: content,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final mornye = context.isMornye;
    final overview = _overview;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(
            title: context.l10n.cacheTitle,
            actions: [
              AppIconButton(
                tooltip: context.l10n.cacheRefresh,
                onPressed: _isBusy ? null : _refreshOverview,
                icon: const AppIcon(Icons.refresh),
              ),
            ],
          ),

          if (_isLoading || overview == null)
            const SliverFillRemaining(
              child: Center(child: AppLoadingIndicator()),
            )
          else ...[
            SliverToBoxAdapter(
              child: _overviewSurface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.cacheSummaryTitle,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: mornye
                            ? colorScheme.onSurface
                            : colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      context.l10n.cacheEstimatedTotal(
                        formatBytes(overview.totalKnownDiskCacheBytes),
                      ),
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: mornye
                            ? colorScheme.onSurface
                            : colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.l10n.cacheSummarySubtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: mornye
                            ? colorScheme.onSurfaceVariant
                            : colorScheme.onPrimaryContainer.withValues(
                                alpha: 0.85,
                              ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        AppActionButton(
                          isDestructive: true,
                          style: FilledButton.styleFrom(
                            backgroundColor: colorScheme.secondaryContainer,
                            foregroundColor: colorScheme.onSecondaryContainer,
                          ),
                          onPressed: _isBusy
                              ? null
                              : () async {
                                  final l10n = context.l10n;
                                  final confirmed = await _confirmClear(
                                    l10n.cacheClearAllConfirmTitle,
                                    l10n.cacheClearAllConfirmMessage,
                                  );
                                  if (!confirmed) return;
                                  if (!mounted) return;
                                  await _runAction(
                                    'clear_all',
                                    _clearAllCaches,
                                    successMessage: l10n.cacheClearSuccess(
                                      l10n.cacheClearAll,
                                    ),
                                  );
                                },
                          icon: const AppIcon(Icons.delete_sweep_outlined),
                          label: Text(context.l10n.cacheClearAll),
                        ),
                        AppActionButton(
                          outlined: true,
                          glass: false,
                          onPressed: _isBusy ? null : _refreshOverview,
                          icon: const AppIcon(Icons.refresh),
                          label: Text(context.l10n.cacheRefreshStats),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            ...settingsSectionSlivers(
              title: context.l10n.cacheSectionStorage,
              children: [
                _clearRow(
                  Icons.folder_outlined,
                  context.l10n.cacheAppDirectory,
                  context.l10n.cacheAppDirectoryDesc,
                  _sizeLabel(
                    overview.appCacheStats.fileCount,
                    overview.appCacheStats.totalSizeBytes,
                  ),
                  'clear_app_cache',
                  _clearAppCache,
                ),
                if (!overview.tempIsSameAsAppCache &&
                    overview.tempStats != null)
                  _clearRow(
                    Icons.timer_outlined,
                    context.l10n.cacheTempDirectory,
                    context.l10n.cacheTempDirectoryDesc,
                    _sizeLabel(
                      overview.tempStats!.fileCount,
                      overview.tempStats!.totalSizeBytes,
                    ),
                    'clear_temp_cache',
                    _clearTempCache,
                  ),
                _clearRow(
                  Icons.image_outlined,
                  context.l10n.cacheCoverImage,
                  context.l10n.cacheCoverImageDesc,
                  _sizeLabel(
                    overview.coverStats.fileCount,
                    overview.coverStats.totalSizeBytes,
                  ),
                  'clear_cover_cache',
                  _clearCoverCache,
                ),
                _clearRow(
                  Icons.library_music_outlined,
                  context.l10n.cacheLibraryCover,
                  context.l10n.cacheLibraryCoverDesc,
                  _sizeLabel(
                    overview.libraryCoverStats.fileCount,
                    overview.libraryCoverStats.totalSizeBytes,
                  ),
                  'clear_library_cover_cache',
                  _clearLibraryCoverCache,
                ),
                _clearRow(
                  Icons.graphic_eq_outlined,
                  context.l10n.cacheAudioAnalysis,
                  context.l10n.cacheAudioAnalysisDesc,
                  _sizeLabel(
                    overview.audioAnalysisStats.fileCount,
                    overview.audioAnalysisStats.totalSizeBytes,
                  ),
                  'clear_audio_analysis_cache',
                  _clearAudioAnalysisCache,
                ),
                _clearRow(
                  Icons.video_library_outlined,
                  context.l10n.cacheMotionArtwork,
                  context.l10n.cacheMotionArtworkDesc,
                  overview.motionStats.totalSizeBytes > 0
                      ? formatBytes(overview.motionStats.totalSizeBytes)
                      : context.l10n.cacheNoData,
                  'clear_motion_artwork',
                  _clearMotionArtwork,
                ),
                _clearRow(
                  Icons.explore_outlined,
                  context.l10n.cacheExploreFeed,
                  context.l10n.cacheExploreFeedDesc,
                  overview.hasExploreCache
                      ? context.l10n.cacheSizeOnly(
                          formatBytes(overview.exploreCacheBytes),
                        )
                      : context.l10n.cacheNoData,
                  'clear_explore_cache',
                  _clearExploreCache,
                ),
                _clearRow(
                  Icons.memory_outlined,
                  context.l10n.cacheTrackLookup,
                  context.l10n.cacheTrackLookupDesc,
                  overview.trackCacheEntries > 0
                      ? context.l10n.cacheEntries(overview.trackCacheEntries)
                      : context.l10n.cacheNoData,
                  'clear_track_cache',
                  _clearTrackCache,
                  showDivider: false,
                ),
              ],
            ),

            ...settingsSectionSlivers(
              title: context.l10n.cacheSectionMaintenance,
              children: [
                SettingsItem(
                  icon: Icons.cleaning_services_outlined,
                  title: context.l10n.cacheCleanupUnused,
                  subtitle:
                      '${context.l10n.cacheCleanupUnusedDesc}\n${context.l10n.cacheCleanupUnusedSubtitle}',
                  trailing: _buildClearTrailing(
                    'cleanup_unused',
                    _cleanupUnusedData,
                  ),
                  showDivider: false,
                ),
              ],
            ),

            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ],
      ),
    );
  }
}

class _CacheOverview {
  final DirectoryStats appCacheStats;
  final DirectoryStats? tempStats;
  final bool tempIsSameAsAppCache;
  final CacheStats coverStats;
  final DirectoryStats motionStats;
  final DirectoryStats libraryCoverStats;
  final DirectoryStats audioAnalysisStats;
  final int exploreCacheBytes;
  final bool hasExploreCache;
  final int trackCacheEntries;

  const _CacheOverview({
    required this.appCacheStats,
    this.tempStats,
    required this.tempIsSameAsAppCache,
    required this.coverStats,
    required this.motionStats,
    required this.libraryCoverStats,
    required this.audioAnalysisStats,
    required this.exploreCacheBytes,
    required this.hasExploreCache,
    required this.trackCacheEntries,
  });

  int get totalKnownDiskCacheBytes {
    return appCacheStats.totalSizeBytes +
        (tempStats?.totalSizeBytes ?? 0) +
        coverStats.totalSizeBytes +
        libraryCoverStats.totalSizeBytes +
        exploreCacheBytes;
  }
}
