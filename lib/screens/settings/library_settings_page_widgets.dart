part of 'library_settings_page.dart';

class _LibrarySourceSettingsItem extends StatelessWidget {
  final LocalLibrarySource source;

  /// Files the last finished scan of [source] could not read.
  final LibraryScanFailures? failures;
  final bool isScanning;
  final bool isFinalizing;
  final bool isPaused;
  final int scannedFiles;
  final int totalFiles;
  final double progress;
  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback onScan;
  final VoidCallback onFullScan;
  final VoidCallback onRemove;

  const _LibrarySourceSettingsItem({
    required this.source,
    required this.failures,
    required this.isScanning,
    required this.isFinalizing,
    required this.isPaused,
    required this.scannedFiles,
    required this.totalFiles,
    required this.progress,
    required this.enabled,
    required this.onEnabledChanged,
    required this.onScan,
    required this.onFullScan,
    required this.onRemove,
  });

  String _title() {
    final normalized = source.displayName
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    final name = normalized.split('/').last.trim();
    return name.isEmpty ? source.displayName : name;
  }

  String _lastScanned(BuildContext context) {
    final value = source.lastScannedAt;
    if (value == null) return context.l10n.libraryLastScannedNever;
    final now = DateTime.now();
    final diff = now.difference(value);
    if (diff.inMinutes < 1) return context.l10n.timeJustNow;
    if (diff.inHours < 1) return context.l10n.timeMinutesAgo(diff.inMinutes);
    if (diff.inDays < 1) return context.l10n.timeHoursAgo(diff.inHours);
    if (diff.inDays < 7) return context.l10n.dateDaysAgo(diff.inDays);
    return '${value.day}/${value.month}/${value.year}';
  }

  Future<void> _showActions(BuildContext context) async {
    final canScan =
        enabled && source.enabled && source.available && !isScanning;
    final hasFailures = !isScanning && failures?.files.isNotEmpty == true;
    final action = await showAppBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      title: _title(),
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppSheetOption(
            enabled: canScan,
            leading: const AppIcon(Icons.refresh_rounded),
            title: Text(context.l10n.libraryScan),
            subtitle: Text(context.l10n.libraryScanSubtitle),
            onTap: canScan ? () => Navigator.pop(context, 'scan') : null,
          ),
          AppSheetOption(
            enabled: canScan,
            leading: const AppIcon(Icons.sync_rounded),
            title: Text(context.l10n.libraryForceFullScan),
            subtitle: Text(context.l10n.libraryForceFullScanSubtitle),
            onTap: canScan ? () => Navigator.pop(context, 'full_scan') : null,
          ),
          if (hasFailures)
            AppSheetOption(
              leading: const AppIcon(Icons.report_outlined),
              title: Text(context.l10n.libraryUnreadableFilesTitle),
              subtitle: Text(context.l10n.libraryUnreadableFilesAction),
              onTap: () => Navigator.pop(context, 'failures'),
            ),
          AppSheetOption(
            leading: AppIcon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              context.l10n.libraryRemoveFolder,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            onTap: () => Navigator.pop(context, 'remove'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'scan':
        onScan();
      case 'full_scan':
        onFullScan();
      case 'failures':
        await _showFailures(context, failures!);
      case 'remove':
        onRemove();
    }
  }

  Future<void> _showFailures(
    BuildContext context,
    LibraryScanFailures failures,
  ) {
    final files = failures.files;
    final unlisted = failures.count - files.length;
    return showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.libraryUnreadableFilesTitle,
      subtitle: context.l10n.libraryUnreadableFilesSubtitle,
      builder: (context, controller) => CustomScrollView(
        controller: controller,
        shrinkWrap: files.length <= 12,
        slivers: [
          SliverSettingsGroup(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: files.length,
            itemBuilder: (context, index) {
              final file = files[index];
              return SettingsItem(
                title: file.fileName,
                subtitle: [
                  if (file.folder.isNotEmpty) file.folder,
                  context.friendlyError(file.message),
                ].join('\n'),
                showDivider: index != files.length - 1,
              );
            },
          ),
          if (unlisted > 0)
            SliverPadding(
              padding: const EdgeInsetsDirectional.fromSTEB(32, 12, 32, 0),
              sliver: SliverToBoxAdapter(
                child: Text(
                  context.l10n.libraryUnreadableFilesMore(unlisted),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _title();
    final status = !source.enabled
        ? context.l10n.librarySourceDisabled
        : !source.available
        ? context.l10n.librarySourceOffline
        : isScanning
        ? isFinalizing
              ? context.l10n.libraryScanFinalizing
              : isPaused
              ? context.l10n.libraryScanPaused
              : totalFiles > 0
              ? context.l10n.librarySourceScanCount(
                  scannedFiles,
                  totalFiles,
                  progress.toStringAsFixed(0),
                )
              : context.l10n.libraryScanning
        : source.lastScanError?.trim().isNotEmpty == true
        ? context.l10n.notifLibraryScanFailed
        : context.l10n.librarySourceOnline;
    final pathLine = source.displayName == title ? null : source.displayName;
    final details = [
      status,
      context.l10n.libraryTracksUnit(source.trackCount),
      context.l10n.libraryLastScanned(_lastScanned(context)),
    ].join(' · ');

    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: SettingsItem(
        icon: source.path.startsWith('network://')
            ? Icons.dns_outlined
            : source.isRemovable
            ? Icons.usb_rounded
            : Icons.folder_outlined,
        title: title,
        titleTrailing: source.isRemovable
            ? Tooltip(
                message: context.l10n.libraryExternalStorage,
                child: const AppIcon(Icons.sd_storage_outlined, size: 16),
              )
            : null,
        subtitle: [
          ?pathLine,
          details,
          if (!isScanning && source.lastScanError?.trim().isNotEmpty == true)
            context.friendlyError(source.lastScanError!)
          else if (!isScanning && failures != null)
            context.l10n.libraryUnreadableFiles(failures!.count),
        ].join('\n'),
        onTap: () => _showActions(context),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isScanning)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: _AnimatedScanCount(
                  count: scannedFiles,
                  progress: progress,
                  determinate: totalFiles > 0 && !isFinalizing,
                ),
              ),
            AppSwitch(
              adaptive: true,
              semanticLabel: title,
              value: source.enabled,
              onChanged: enabled ? onEnabledChanged : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _AnimatedScanCount extends StatelessWidget {
  final int count;
  final double progress;
  final bool determinate;

  const _AnimatedScanCount({
    required this.count,
    required this.progress,
    required this.determinate,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 42,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 18,
            child: AppProgressIndicator.circular(
              value: determinate ? (progress / 100).clamp(0.0, 1.0) : null,
              strokeWidth: 2,
            ),
          ),
          const SizedBox(height: 2),
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: count.toDouble()),
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            builder: (context, value, _) => Text(
              value.round().toString(),
              maxLines: 1,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LibraryHeroCard extends StatelessWidget {
  final int itemCount;
  final int excludedDownloadedCount;
  final bool isScanning;
  final bool scanIsFinalizing;
  final bool scanIsPaused;
  final double scanProgress;
  final String? scanCurrentFile;
  final int scanTotalFiles;
  final int scannedFiles;
  final DateTime? lastScannedAt;

  const _LibraryHeroCard({
    required this.itemCount,
    required this.excludedDownloadedCount,
    required this.isScanning,
    required this.scanIsFinalizing,
    required this.scanIsPaused,
    required this.scanProgress,
    this.scanCurrentFile,
    required this.scanTotalFiles,
    required this.scannedFiles,
    this.lastScannedAt,
  });

  String _formatLastScanned(BuildContext context) {
    if (lastScannedAt == null) return context.l10n.libraryLastScannedNever;
    final now = DateTime.now();
    final diff = now.difference(lastScannedAt!);

    if (diff.inMinutes < 1) return context.l10n.timeJustNow;
    if (diff.inHours < 1) return context.l10n.timeMinutesAgo(diff.inMinutes);
    if (diff.inDays < 1) return context.l10n.timeHoursAgo(diff.inHours);
    if (diff.inDays < 7) return context.l10n.dateDaysAgo(diff.inDays);

    return '${lastScannedAt!.day}/${lastScannedAt!.month}/${lastScannedAt!.year}';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final showIndeterminateProgress =
        isScanning &&
        !scanIsPaused &&
        (scanIsFinalizing ||
            scanTotalFiles <= 0 ||
            (scannedFiles <= 0 && scanProgress <= 0));
    final displayCount = isScanning
        ? scannedFiles
        : itemCount + excludedDownloadedCount;

    return Container(
      margin: EdgeInsets.symmetric(
        horizontal: 16 + wideListInset(context),
        vertical: 8,
      ),
      constraints: const BoxConstraints(minHeight: 220),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          if (!isDark)
            BoxShadow(
              color: colorScheme.shadow.withValues(alpha: 0.05),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            right: -20,
            top: -20,
            child: AppIcon(
              Icons.library_music,
              size: 200,
              color: colorScheme.primary.withValues(alpha: 0.05),
            ),
          ),
          Positioned(
            left: -40,
            bottom: -40,
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colorScheme.secondaryContainer.withValues(alpha: 0.3),
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: AppIcon(
                        isScanning
                            ? scanIsPaused
                                  ? Icons.pause_rounded
                                  : Icons.sync
                            : Icons.music_note,
                        color: colorScheme.onPrimaryContainer,
                        size: 32,
                      ),
                    ),
                    const Spacer(),
                    if (isScanning)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 12,
                              height: 12,
                              child: scanIsPaused
                                  ? AppIcon(
                                      Icons.pause_rounded,
                                      size: 12,
                                      color: colorScheme.onPrimary,
                                    )
                                  : AppLoadingIndicator(
                                      size: 12,
                                      strokeWidth: 2,
                                      color: colorScheme.onPrimary,
                                    ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              scanIsPaused
                                  ? context.l10n.libraryScanPaused
                                  : context.l10n.libraryScanning,
                              style: TextStyle(
                                color: colorScheme.onPrimary,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    displayCount.toString(),
                    style: TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                      height: 1.0,
                      letterSpacing: -2,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isScanning
                      ? context.l10n.libraryFilesUnit(scannedFiles)
                      : context.l10n.libraryTracksUnit(displayCount),
                  style: TextStyle(
                    fontSize: 16,
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (!isScanning && excludedDownloadedCount > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    context.l10n.libraryDownloadsHistoryExcluded(
                      excludedDownloadedCount,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.8,
                      ),
                    ),
                  ),
                ],
                if (isScanning) ...[
                  const SizedBox(height: 16),
                  AppProgressIndicator.linear(
                    value: showIndeterminateProgress
                        ? null
                        : scanTotalFiles > 0
                        ? scanProgress / 100
                        : 0,
                    trackColor: colorScheme.surfaceContainerHighest,
                    color: colorScheme.primary,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    scanIsFinalizing
                        ? context.l10n.libraryScanFinalizing
                        : scanTotalFiles > 0
                        ? context.l10n.libraryScanProgress(
                            scanProgress.toStringAsFixed(0),
                            scanTotalFiles,
                          )
                        : scanIsPaused
                        ? context.l10n.libraryScanPaused
                        : context.l10n.libraryScanning,
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.8,
                      ),
                    ),
                  ),
                  if (!scanIsFinalizing &&
                      scanCurrentFile != null &&
                      scanCurrentFile!.trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      scanCurrentFile!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.7,
                        ),
                      ),
                    ),
                  ],
                ] else ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      AppIcon(
                        Icons.history,
                        size: 14,
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.7,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        context.l10n.libraryLastScanned(
                          _formatLastScanned(context),
                        ),
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.7,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanProgressTile extends StatelessWidget {
  final bool isFinalizing;
  final bool isPaused;
  final double progress;
  final String? currentFile;
  final int scannedFiles;
  final int totalFiles;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;

  const _ScanProgressTile({
    required this.isFinalizing,
    required this.isPaused,
    required this.progress,
    this.currentFile,
    required this.scannedFiles,
    required this.totalFiles,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // A paused bar stays still at its last position instead of animating.
    final showIndeterminateProgress =
        !isPaused &&
        (isFinalizing ||
            totalFiles <= 0 ||
            (scannedFiles <= 0 && progress <= 0));
    final progressValue = totalFiles > 0 ? progress / 100 : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(
                isPaused ? Icons.pause_circle_outline : Icons.scanner,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isPaused
                          ? context.l10n.libraryScanPaused
                          : context.l10n.libraryScanning,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      isFinalizing
                          ? context.l10n.libraryScanFinalizing
                          : totalFiles > 0
                          ? context.l10n.libraryScanProgress(
                              progress.toStringAsFixed(0),
                              totalFiles,
                            )
                          : context.l10n.libraryScanning,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (!isFinalizing)
                ExpressiveButton(
                  text: true,
                  onPressed: isPaused ? onResume : onPause,
                  child: Text(
                    isPaused
                        ? context.l10n.actionResume
                        : context.l10n.actionPause,
                  ),
                ),
              ExpressiveButton(
                text: true,
                onPressed: onCancel,
                child: Text(context.l10n.actionCancel),
              ),
            ],
          ),
          const SizedBox(height: 8),
          AppProgressIndicator.linear(
            value: showIndeterminateProgress ? null : progressValue,
            trackColor: colorScheme.surfaceContainerHighest,
            color: colorScheme.primary,
            borderRadius: BorderRadius.circular(4),
          ),
          if (!isFinalizing &&
              currentFile != null &&
              currentFile!.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              currentFile!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
