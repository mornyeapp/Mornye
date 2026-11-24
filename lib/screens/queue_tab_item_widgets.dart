part of 'queue_tab.dart';

extension _QueueTabItemWidgets on _QueueTabState {
  Widget _buildSelectionBottomBar(
    BuildContext context,
    ColorScheme colorScheme,
    List<UnifiedLibraryItem> unifiedItems,
    double bottomPadding,
  ) {
    final selectedCount = _selectedIds.length;
    final allSelected =
        selectedCount == unifiedItems.length && unifiedItems.isNotEmpty;
    final selectedItems = _selectedItemsFromAll(unifiedItems);
    final localOnlySelection =
        selectedItems.isNotEmpty &&
        selectedItems.every((item) => item.localItem != null);
    final flacEligibleCount = localOnlySelection
        ? selectedItems
              .where(
                (item) => LocalTrackRedownloadService.isFlacUpgradeEligible(
                  item.localItem!,
                ),
              )
              .length
        : 0;

    return LibraryTrackSelectionBar(
      playbackActions: LibrarySelectionPlaybackActions(
        items: selectedItems,
        onClose: _exitSelectionMode,
      ),
      selectedCount: selectedCount,
      allSelected: allSelected,
      onClose: _exitSelectionMode,
      onToggleSelectAll: () {
        if (allSelected) {
          _exitSelectionMode();
        } else {
          _selectAll(unifiedItems);
        }
      },
      bottomPadding: bottomPadding,
      flacEligibleCount: flacEligibleCount,
      onQueueFlac: () => _queueSelectedLocalAsFlac(unifiedItems),
      onReEnrich: () => _reEnrichSelectedFromQueue(unifiedItems),
      onConvert: () => _showBatchConvertSheet(context, unifiedItems),
      onReplayGain: ({required remove}) =>
          _runBatchReplayGain(unifiedItems, remove: remove),
      onDelete: () => _deleteSelected(unifiedItems),
    );
  }

  Widget _buildQueueItem(
    BuildContext context,
    DownloadItem item,
    ColorScheme colorScheme,
  ) {
    final isCompleted = item.status == DownloadStatus.completed;
    final isActive =
        item.status == DownloadStatus.queued ||
        item.status == DownloadStatus.downloading ||
        item.status == DownloadStatus.finalizing;

    return SmoothedProgressScope(
      value: item.progress,
      animate: _shouldAnimateDownloadProgress(context, item),
      child: SwipeDeleteDismissible(
        dismissKey: ValueKey('dismiss_${item.id}'),
        confirmDismiss: isActive
            ? (_) async {
                return await showAppDialog<bool>(
                      context: context,
                      builder: (ctx) => AppAlertDialog(
                        title: Text(context.l10n.cancelDownloadTitle),
                        content: Text(
                          context.l10n.cancelDownloadContent(item.track.name),
                        ),
                        actions: [
                          AppDialogAction(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            child: Text(context.l10n.cancelDownloadKeep),
                          ),
                          AppDialogAction(
                            isDestructive: true,
                            onPressed: () => Navigator.of(ctx).pop(true),
                            child: Text(context.l10n.dialogCancel),
                          ),
                        ],
                      ),
                    ) ??
                    false;
              }
            : null,
        onDismissed: (_) {
          ref.read(downloadQueueProvider.notifier).dismissItem(item.id);
        },
        child: TrackCard(
          onTap: isCompleted
              ? songRowTap(
                  ref,
                  openDetails: () => _navigateToMetadataScreen(item),
                  play: () => _playCompletedDownload(item),
                )
              : item.status == DownloadStatus.failed ||
                    item.status == DownloadStatus.skipped
              ? () => _showDownloadErrorDialog(context, item)
              : null,
          onLongPress: () => _showDownloadItemMenu(context, item),
          onContextMenu: (position) =>
              _showDownloadItemMenu(context, item, position: position),
          background: item.status == DownloadStatus.downloading
              ? SmoothedProgressBuilder(
                  builder: (context, progress, child) => Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FractionallySizedBox(
                      widthFactor: progress,
                      child: child,
                    ),
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: AlignmentDirectional.centerStart,
                        end: AlignmentDirectional.centerEnd,
                        colors: [
                          colorScheme.primary.withValues(alpha: 0.16),
                          colorScheme.primary.withValues(alpha: 0.04),
                        ],
                      ),
                    ),
                  ),
                )
              : null,
          leading: isCompleted
              ? Hero(
                  tag: 'cover_${item.id}',
                  transitionOnUserGestures: heroFollowsBackSwipe(context),
                  child: _buildCoverArt(item, colorScheme),
                )
              : _buildCoverArt(item, colorScheme),
          title: item.track.name,
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ClickableArtistName(
                artistName: item.track.artistName,
                artistId: item.track.artistId,
                coverUrl: item.track.coverUrl,
                extensionId: item.track.source,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              if (item.status == DownloadStatus.downloading) ...[
                const SizedBox(height: 5),
                Row(
                  children: [
                    AppIcon(
                      Icons.download_rounded,
                      size: 12,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: SmoothedProgressBuilder(
                        builder: (context, progress, child) => Text(
                          _formatDownloadStatusLine(
                            context,
                            item,
                            visualProgress: progress,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (item.status == DownloadStatus.finalizing &&
                  item.preparationStage == 'network_upload') ...[
                const SizedBox(height: 4),
                Text(
                  '${context.l10n.networkUploading}${item.bytesTotal > 0 ? ' • ${(100 * item.bytesReceived / item.bytesTotal).round()}%' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: colorScheme.primary),
                ),
              ],
              if (item.status == DownloadStatus.failed) ...[
                const SizedBox(height: 4),
                _buildDownloadFailureMessage(context, item, colorScheme),
              ],
            ],
          ),
          trailing: DownloadStateSwitcher(
            state: item.status,
            child: _buildActionButtons(context, item, colorScheme),
          ),
        ),
      ),
    );
  }

  bool _requiresFolderReselection(DownloadItem item) =>
      item.status == DownloadStatus.failed &&
      item.networkDownloadFolder.isEmpty &&
      !isExtensionSandboxPathError(item.error) &&
      (item.errorType == DownloadErrorType.permission ||
          item.error == safPermissionLostErrorMessage ||
          item.error == downloadFolderAccessLostErrorMessage);

  /// Preserve folder recovery errors before the model's generic type mapping.
  /// Legacy permission failures also need the picker instead of another retry.
  String _downloadErrorForDisplay(DownloadItem item) {
    final raw = item.error;
    if (raw == safPermissionLostErrorMessage ||
        raw == downloadFolderAccessLostErrorMessage) {
      return raw!;
    }
    if (_requiresFolderReselection(item)) {
      return downloadFolderAccessLostErrorMessage;
    }
    return item.errorMessage;
  }

  /// Download error messages are stored as fixed English sentinels on the
  /// item (so code can match on them); translate the known ones for display.
  String _localizedDownloadError(BuildContext context, String raw) {
    if (raw == safPermissionLostErrorMessage) {
      return context.l10n.downloadErrorSafPermissionLost;
    }
    if (raw == downloadFolderAccessLostErrorMessage) {
      return context.l10n.downloadErrorFolderAccessLost;
    }
    return context.friendlyError(
      raw,
      fallback: context.l10n.updateDownloadFailed,
    );
  }

  Widget _buildDownloadFailureMessage(
    BuildContext context,
    DownloadItem item,
    ColorScheme colorScheme,
  ) {
    if (item.errorType != DownloadErrorType.rateLimit) {
      return Text(
        _localizedDownloadError(context, _downloadErrorForDisplay(item)),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: colorScheme.error),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: AppIcon(
            Icons.hourglass_top_rounded,
            size: 14,
            color: colorScheme.tertiary,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.l10n.queueRateLimitTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.tertiary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                context.l10n.queueRateLimitMessage,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.tertiary.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCoverArt(DownloadItem item, ColorScheme colorScheme) {
    final coverSize = _queueCoverSize();
    final radius = BorderRadius.circular(8);

    final cover = item.track.coverUrl != null
        ? CachedCoverImage(
            imageUrl: item.track.coverUrl!,
            width: coverSize,
            height: coverSize,
            borderRadius: radius,
          )
        : Container(
            width: coverSize,
            height: coverSize,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: radius,
            ),
            child: AppIcon(
              Icons.music_note,
              color: colorScheme.onSurfaceVariant,
            ),
          );

    final isDownloading =
        item.status == DownloadStatus.downloading ||
        item.status == DownloadStatus.finalizing;
    if (!isDownloading) return cover;

    final progress = item.progress.clamp(0.0, 1.0);
    final indeterminate =
        item.status == DownloadStatus.finalizing || progress <= 0;

    return SizedBox(
      width: coverSize,
      height: coverSize,
      child: Stack(
        fit: StackFit.expand,
        children: [
          cover,
          ClipRRect(
            borderRadius: radius,
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
          ),
          if (indeterminate)
            Center(
              child: SizedBox(
                width: coverSize * 0.6,
                height: coverSize * 0.6,
                child: AppProgressIndicator.circular(
                  strokeWidth: 3,
                  color: Colors.white,
                  trackColor: Colors.white.withValues(alpha: 0.25),
                ),
              ),
            )
          else
            SmoothedProgressBuilder(
              builder: (context, visualProgress, child) => Stack(
                fit: StackFit.expand,
                children: [
                  Center(
                    child: SizedBox(
                      width: coverSize * 0.6,
                      height: coverSize * 0.6,
                      child: AppProgressIndicator.circular(
                        value: visualProgress,
                        strokeWidth: 3,
                        color: Colors.white,
                        trackColor: Colors.white.withValues(alpha: 0.25),
                      ),
                    ),
                  ),
                  Center(
                    child: Text(
                      '${(visualProgress * 100).round()}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// A download's actions: a menu at [position] on desktop, a sheet
  /// elsewhere. Only a queued download is reordered or cancelled here.
  Future<void> _showDownloadItemMenu(
    BuildContext context,
    DownloadItem item, {
    Offset? position,
  }) {
    final notifier = ref.read(downloadQueueProvider.notifier);
    final track = item.track;
    final root = Navigator.of(context, rootNavigator: true).context;
    final isQueued = item.status == DownloadStatus.queued;
    if (position != null && isDesktopPlatform) {
      return showContextMenu(
        context,
        position: position,
        groups: [
          if (isQueued)
            [
              ContextMenuAction(
                icon: Icons.skip_next,
                label: context.l10n.queueDownloadNext,
                onSelected: () => notifier.downloadNext(item.id),
              ),
              ContextMenuAction(
                icon: Icons.arrow_upward,
                label: context.l10n.queueMoveUp,
                onSelected: () => notifier.moveQueuedItem(item.id, -1),
              ),
              ContextMenuAction(
                icon: Icons.arrow_downward,
                label: context.l10n.queueMoveDown,
                onSelected: () => notifier.moveQueuedItem(item.id, 1),
              ),
            ],
          [
            ContextMenuAction(
              icon: Icons.album_outlined,
              label: context.l10n.homeGoToAlbum,
              onSelected: () => navigateToTrackAlbum(root, track),
            ),
            ContextMenuAction(
              icon: Icons.copy_all_rounded,
              label: context.l10n.trackOptionCopyTrackAndArtist,
              onSelected: () => copyTrackText(root, trackAndArtistText(track)),
            ),
          ],
          if (isQueued)
            [
              ContextMenuAction(
                icon: Icons.close,
                label: context.l10n.dialogCancel,
                destructive: true,
                onSelected: () => notifier.cancelItem(item.id),
              ),
            ],
        ],
      );
    }
    return showAppBottomSheet<void>(
      context: context,
      title: item.track.name,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: ctx.tokens.gapLg),
        child: SettingsGroup(
          children: [
            if (isQueued) ...[
              SettingsItem(
                icon: Icons.skip_next,
                showIconInMornye: true,
                title: context.l10n.queueDownloadNext,
                onTap: () {
                  Navigator.of(ctx).pop();
                  notifier.downloadNext(item.id);
                },
              ),
              SettingsItem(
                icon: Icons.arrow_upward,
                showIconInMornye: true,
                title: context.l10n.queueMoveUp,
                onTap: () {
                  Navigator.of(ctx).pop();
                  notifier.moveQueuedItem(item.id, -1);
                },
              ),
              SettingsItem(
                icon: Icons.arrow_downward,
                showIconInMornye: true,
                title: context.l10n.queueMoveDown,
                onTap: () {
                  Navigator.of(ctx).pop();
                  notifier.moveQueuedItem(item.id, 1);
                },
              ),
            ],
            SettingsItem(
              icon: Icons.album_outlined,
              showIconInMornye: true,
              title: context.l10n.homeGoToAlbum,
              onTap: () {
                Navigator.of(ctx).pop();
                navigateToTrackAlbum(root, track);
              },
            ),
            SettingsItem(
              icon: Icons.copy_all_rounded,
              showIconInMornye: true,
              title: context.l10n.trackOptionCopyTrackAndArtist,
              showDivider: false,
              onTap: () {
                Navigator.of(ctx).pop();
                copyTrackText(root, trackAndArtistText(track));
              },
            ),
          ],
        ),
      ),
    );
  }

  void _openCompletedDownload(DownloadItem item) => _openFile(
    item.filePath!,
    title: item.track.name,
    artist: item.track.artistName,
    album: item.track.albumName,
    coverUrl: item.track.coverUrl ?? '',
  );

  /// A tap on a completed download that does what its play button does; a
  /// download whose file is missing has none and opens its details.
  void _playCompletedDownload(DownloadItem item) {
    final path = item.filePath;
    if (path == null || !_fileExistsListenable(path).value) {
      _navigateToMetadataScreen(item);
      return;
    }
    _LibraryPlaybackButton.run(ref, (
      id: '',
      path: _cleanFilePath(path),
    ), () => _openCompletedDownload(item));
  }

  Widget _buildActionButtons(
    BuildContext context,
    DownloadItem item,
    ColorScheme colorScheme,
  ) {
    switch (item.status) {
      case DownloadStatus.queued:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIconButton(
              onPressed: () => ref
                  .read(downloadQueueProvider.notifier)
                  .downloadNext(item.id),
              icon: Icon(
                Icons.skip_next,
                color: colorScheme.onPrimaryContainer,
              ),
              tooltip: context.l10n.queueDownloadNext,
              style: IconButton.styleFrom(
                backgroundColor: colorScheme.primaryContainer,
              ),
            ),
            const SizedBox(width: 4),
            AppIconButton(
              onPressed: () =>
                  ref.read(downloadQueueProvider.notifier).cancelItem(item.id),
              icon: Icon(Icons.close, color: colorScheme.onErrorContainer),
              tooltip: context.l10n.dialogCancel,
              style: IconButton.styleFrom(
                backgroundColor: colorScheme.errorContainer,
              ),
            ),
          ],
        );
      case DownloadStatus.downloading:
        return AppIconButton(
          onPressed: () =>
              ref.read(downloadQueueProvider.notifier).cancelItem(item.id),
          icon: Icon(Icons.stop, color: colorScheme.onErrorContainer),
          tooltip: context.l10n.actionStop,
          style: IconButton.styleFrom(
            backgroundColor: colorScheme.errorContainer,
          ),
        );
      case DownloadStatus.finalizing:
        return Semantics(
          label: context.l10n.queueFinalizingDownload,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AppProgressIndicator.circular(
                  strokeWidth: 3,
                  color: colorScheme.tertiary,
                ),
                ExcludeSemantics(
                  child: AppIcon(
                    Icons.edit_note,
                    color: colorScheme.tertiary,
                    size: 16,
                  ),
                ),
              ],
            ),
          ),
        );
      case DownloadStatus.completed:
        return ValueListenableBuilder<bool>(
          valueListenable: _fileExistsListenable(item.filePath),
          builder: (context, fileExists, child) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (fileExists)
                  SongRowButton(
                    playButton: _LibraryPlaybackButton(
                      playbackKey: (
                        id: '',
                        path: _cleanFilePath(item.filePath!),
                      ),
                      playTooltip: context.l10n.a11yPlayTrackByArtist(
                        item.track.name,
                        item.track.artistName,
                      ),
                      onPlay: () => _openCompletedDownload(item),
                    ),
                    onOpenDetails: () => _navigateToMetadataScreen(item),
                  )
                else
                  Semantics(
                    label: context.l10n.queueDownloadedFileMissing,
                    child: ExcludeSemantics(
                      child: AppIcon(
                        Icons.error_outline,
                        color: colorScheme.error,
                        size: 20,
                      ),
                    ),
                  ),
                const SizedBox(width: 4),
                Semantics(
                  label: context.l10n.queueDownloadCompleted,
                  child: ExcludeSemantics(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: AppIcon(
                        Icons.check,
                        color: colorScheme.onPrimaryContainer,
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      case DownloadStatus.failed:
      case DownloadStatus.skipped:
        final requiresFolderReselection = _requiresFolderReselection(item);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIconButton(
              onPressed: requiresFolderReselection
                  ? () => _showDownloadErrorDialog(context, item)
                  : () => ref
                        .read(downloadQueueProvider.notifier)
                        .retryItem(item.id),
              icon: Icon(
                requiresFolderReselection ? Icons.folder_open : Icons.refresh,
                color: colorScheme.onPrimaryContainer,
              ),
              tooltip: requiresFolderReselection
                  ? context.l10n.downloadFolderReselect
                  : context.l10n.dialogRetry,
              style: IconButton.styleFrom(
                backgroundColor: colorScheme.primaryContainer,
              ),
            ),
            const SizedBox(width: 4),
            AppIconButton(
              onPressed: () =>
                  ref.read(downloadQueueProvider.notifier).removeItem(item.id),
              icon: Icon(
                Icons.close,
                color: item.status == DownloadStatus.failed
                    ? colorScheme.onErrorContainer
                    : colorScheme.onSurfaceVariant,
              ),
              tooltip: context.l10n.dialogRemove,
              style: item.status == DownloadStatus.failed
                  ? IconButton.styleFrom(
                      backgroundColor: colorScheme.errorContainer,
                    )
                  : null,
            ),
          ],
        );
    }
  }

  Widget _buildFilterButton(BuildContext context) {
    return GestureDetector(
      onLongPress: _activeFilterCount > 0 ? _resetFilters : null,
      child: ExpressiveButton(
        text: true,
        onPressed: () => _showFilterSheet(context),
        icon: Badge(
          isLabelVisible: _activeFilterCount > 0,
          label: Text('$_activeFilterCount'),
          child: const AppIcon(Icons.filter_list, size: 18),
        ),
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        child: Text(context.l10n.libraryFilterTitle),
      ),
    );
  }

  /// When [size] is provided, renders at fixed dimensions (list mode).
  /// When [size] is null, fills the parent container (grid mode).
  Widget _buildUnifiedCoverImage(
    UnifiedLibraryItem item,
    ColorScheme colorScheme, [
    double? size,
  ]) {
    final isDownloaded = item.source == LibraryItemSource.downloaded;
    // Grid badges line up with the card's other corner overlays.
    final badgeInset = size == null ? 4.0 : 0.0;

    // Scanned SAF tracks also recover artwork after a transient provider error.
    if (isDownloaded || item.filePath.startsWith('content://')) {
      return OfflineAvailabilityCover(
        item: item,
        inset: badgeInset,
        child: ValueListenableBuilder<int>(
          valueListenable: _embeddedCoverListenable(item.filePath),
          builder: (context, _, child) => _buildUnifiedCoverImageInner(
            item,
            colorScheme,
            isDownloaded,
            size,
          ),
        ),
      );
    }

    return OfflineAvailabilityCover(
      item: item,
      inset: badgeInset,
      child: _buildUnifiedCoverImageInner(
        item,
        colorScheme,
        isDownloaded,
        size,
      ),
    );
  }

  Widget _buildUnifiedCoverImageInner(
    UnifiedLibraryItem item,
    ColorScheme colorScheme,
    bool isDownloaded, [
    double? size,
  ]) {
    final cacheSize = size != null ? (size * 2).toInt() : 200;
    final iconSize = size != null ? size * 0.4 : 32.0;

    Widget buildPlaceholder({
      bool isLocal = false,
      bool recoverDocument = true,
    }) {
      if (recoverDocument && item.filePath.startsWith('content://')) {
        final recovered = _resolveDownloadedEmbeddedCoverPath(item.filePath);
        if (recovered != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(recovered),
              width: size,
              height: size,
              fit: BoxFit.cover,
              cacheWidth: cacheSize,
              errorBuilder: (_, _, _) =>
                  buildPlaceholder(isLocal: isLocal, recoverDocument: false),
            ),
          );
        }
      }
      final bgColor = (isDownloaded && !isLocal)
          ? colorScheme.surfaceContainerHighest
          : colorScheme.secondaryContainer;
      final fgColor = (isDownloaded && !isLocal)
          ? colorScheme.onSurfaceVariant
          : colorScheme.onSecondaryContainer;
      return Container(
        width: size,
        height: size,
        decoration: size != null
            ? BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(8),
              )
            : null,
        color: size != null ? null : bgColor,
        child: Center(
          child: AppIcon(Icons.music_note, color: fgColor, size: iconSize),
        ),
      );
    }

    Widget fadeInFileImage(Widget child, int? frame, bool wasSync) {
      if (wasSync) return child;
      final Widget backdrop;
      if (isDownloaded && item.coverUrl != null) {
        backdrop = CachedCoverImage(
          imageUrl: item.coverUrl!,
          width: size,
          height: size,
          memCacheWidth: cacheSize,
          placeholder: (context, url) =>
              buildPlaceholder(recoverDocument: false),
          errorWidget: (context, url, error) => buildPlaceholder(),
        );
      } else {
        backdrop = buildPlaceholder(
          isLocal: !isDownloaded,
          recoverDocument: false,
        );
      }
      final animated = _LocalCoverFade(
        loaded: frame != null,
        backdrop: backdrop,
        child: child,
      );
      if (size == null) return animated;
      return SizedBox(width: size, height: size, child: animated);
    }

    if (isDownloaded) {
      final embeddedCoverPath = _resolveDownloadedEmbeddedCoverPath(
        item.filePath,
      );
      if (embeddedCoverPath != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(embeddedCoverPath),
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: cacheSize,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
                fadeInFileImage(child, frame, wasSynchronouslyLoaded),
            errorBuilder: (context, error, stackTrace) => item.coverUrl != null
                ? CachedCoverImage(
                    imageUrl: item.coverUrl!,
                    width: size,
                    height: size,
                    memCacheWidth: cacheSize,
                    placeholder: (context, url) => buildPlaceholder(),
                    errorWidget: (context, url, error) => buildPlaceholder(),
                  )
                : buildPlaceholder(),
          ),
        );
      }
    }

    if (item.coverUrl != null) {
      return CachedCoverImage(
        imageUrl: item.coverUrl!,
        width: size,
        height: size,
        memCacheWidth: cacheSize,
        borderRadius: BorderRadius.circular(8),
        placeholder: (context, url) => buildPlaceholder(),
        errorWidget: (context, url, error) => buildPlaceholder(),
      );
    }

    if (item.localCoverPath != null && item.localCoverPath!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(item.localCoverPath!),
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: cacheSize,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
              fadeInFileImage(child, frame, wasSynchronouslyLoaded),
          errorBuilder: (context, error, stackTrace) =>
              buildPlaceholder(isLocal: true),
        ),
      );
    }

    if (size != null) {
      return buildPlaceholder();
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: buildPlaceholder(),
    );
  }

  /// A tap on a library song outside selection mode: opens its metadata, or
  /// the bare file when the song has no history or library record.
  VoidCallback _libraryItemOpenAction(
    UnifiedLibraryItem item, {
    required List<DownloadHistoryItem> downloadedNavigationItems,
    required int? downloadedNavigationIndex,
    required List<LocalLibraryItem> localNavigationItems,
    required int? localNavigationIndex,
  }) {
    if (item.source == LibraryItemSource.downloaded) {
      return () => _navigateToHistoryMetadataScreen(
        item.historyItem!,
        navigationItems: downloadedNavigationItems,
        navigationIndex: downloadedNavigationIndex,
      );
    }
    if (item.localItem != null) {
      return () => _navigateToLocalMetadataScreen(
        item.localItem!,
        navigationItems: localNavigationItems,
        navigationIndex: localNavigationIndex,
      );
    }
    return () => _openFile(
      item.filePath,
      title: item.trackName,
      artist: item.artistName,
      album: item.albumName,
      coverUrl: item.coverUrl ?? item.localCoverPath ?? '',
    );
  }

  /// A desktop click on a library song runs [open], what a tap does on a
  /// phone; modifier clicks select.
  void _desktopLibraryItemClick(
    UnifiedLibraryItem item,
    List<UnifiedLibraryItem> libraryItems,
    VoidCallback open,
  ) {
    handleDesktopRowClick(
      item.id,
      select: (kind) => _applyDesktopClick(item.id, kind, [
        for (final song in libraryItems) song.id,
      ]),
      activate: open,
    );
  }

  /// The desktop Songs table, after the [leadCount] active downloads. Songs
  /// load in pages already sorted, so the header sorts through the Library
  /// sort modes.
  Widget _buildLibrarySongTable(
    BuildContext context, {
    required String filterMode,
    required List<UnifiedLibraryItem> items,
    required int leadCount,
    required Widget Function(int index) leadBuilder,
    required VoidCallback Function(UnifiedLibraryItem item) openAction,
  }) {
    final table = _librarySongTableRows(
      filterMode,
      items,
      Theme.of(context).colorScheme,
      openAction,
    );
    final byId = table.byId;
    final sort = switch (_sortMode) {
      'a-z' => (column: TrackTableColumn.title, ascending: true),
      'z-a' => (column: TrackTableColumn.title, ascending: false),
      'artist-asc' => (column: TrackTableColumn.artist, ascending: true),
      'artist-desc' => (column: TrackTableColumn.artist, ascending: false),
      'album-asc' => (column: TrackTableColumn.album, ascending: true),
      'album-desc' => (column: TrackTableColumn.album, ascending: false),
      _ => null,
    };
    final inset = EdgeInsets.symmetric(horizontal: wideListInset(context));
    return SliverMainAxisGroup(
      slivers: [
        if (leadCount > 0)
          SliverPadding(
            padding: inset,
            sliver: SliverList.builder(
              itemCount: leadCount,
              itemBuilder: (context, index) => leadBuilder(index),
            ),
          ),
        SliverPadding(
          padding: inset,
          sliver: SliverTrackTable(
            rows: table.rows,
            uniformRowHeight: true,
            columns: const [
              TrackTableColumn.title,
              TrackTableColumn.artist,
              TrackTableColumn.album,
              TrackTableColumn.quality,
              TrackTableColumn.duration,
            ],
            selectedIds: _selectedIds,
            onSelect: _applyDesktopClick,
            // A click does what a tap does on a phone: by the Library song
            // tap setting, plays as the row's button does or opens the
            // details.
            onActivate: (id) {
              final item = byId[id];
              if (item == null) return;
              songRowTap(
                ref,
                path: item.filePath,
                openDetails: openAction(item),
                play: () => _LibraryPlaybackButton.run(
                  ref,
                  _libraryPlaybackKey(item),
                  () => _playLibraryItem(item, items),
                ),
              )();
            },
            onContextMenu: (id, position) {
              final item = byId[id];
              if (item == null) return;
              _showLibraryItemMenu(
                context,
                item,
                items,
                position,
                onOpenDetails: openAction(item),
              );
            },
            sort: sort,
            sortableColumns: const {
              TrackTableColumn.title,
              TrackTableColumn.artist,
              TrackTableColumn.album,
            },
            onSort: (next) {
              final mode = switch (next) {
                null => 'latest',
                (column: TrackTableColumn.title, ascending: true) => 'a-z',
                (column: TrackTableColumn.title, ascending: false) => 'z-a',
                (column: TrackTableColumn.artist, ascending: true) =>
                  'artist-asc',
                (column: TrackTableColumn.artist, ascending: false) =>
                  'artist-desc',
                (column: TrackTableColumn.album, ascending: true) =>
                  'album-asc',
                (column: TrackTableColumn.album, ascending: false) =>
                  'album-desc',
                _ => _sortMode,
              };
              _setSortMode(mode);
            },
          ),
        ),
      ],
    );
  }

  /// The Songs table rows for [items], kept while the songs, the quality
  /// label mode and [colorScheme] stay the same. A new list, such as one
  /// with another page loaded, reuses the rows of the songs it keeps.
  _LibrarySongTableRows _librarySongTableRows(
    String filterMode,
    List<UnifiedLibraryItem> items,
    ColorScheme colorScheme,
    VoidCallback Function(UnifiedLibraryItem item) openAction,
  ) {
    final qualityMode = _libraryQualityLabelMode;
    final cached = _songTableByMode[filterMode];
    final reusable =
        cached != null &&
        cached.qualityMode == qualityMode &&
        cached.colorScheme == colorScheme;
    if (reusable && identical(cached.items, items)) {
      return cached..openAction = openAction;
    }
    final previous = reusable ? cached.rowByItem : null;
    final rows = <TrackTableRow>[];
    final rowByItem = Map<UnifiedLibraryItem, TrackTableRow>.identity();
    final byId = <String, UnifiedLibraryItem>{};
    for (final item in items) {
      final row =
          previous?[item] ??
          TrackTableRow(
            id: item.id,
            title: item.trackName,
            artist: item.artistName,
            album: item.albumName,
            quality: item.qualityForMode(qualityMode),
            duration: switch (item.historyItem?.duration ??
                item.localItem?.duration) {
              final seconds? when seconds > 0 => Duration(seconds: seconds),
              _ => null,
            },
            leading: _buildUnifiedCoverImage(item, colorScheme, 32),
            titleTrailing: Builder(
              builder: (context) => SongRowButton(
                playButton: _LibraryPlaybackButton(
                  playbackKey: _libraryPlaybackKey(item),
                  playTooltip: context.l10n.a11yPlayTrackByArtist(
                    item.trackName,
                    item.artistName,
                  ),
                  // Cached rows must use the current page and sort order.
                  onPlay: () => _playLibraryItem(
                    item,
                    _songTableByMode[filterMode]?.items ?? items,
                  ),
                  inline: true,
                ),
                onOpenDetails: () =>
                    (_songTableByMode[filterMode]?.openAction ?? openAction)(
                      item,
                    )(),
                path: item.filePath,
              ),
            ),
            playback: mediaItemPlaybackUiProvider(_libraryPlaybackKey(item)),
          );
      rows.add(row);
      rowByItem[item] = row;
      byId[item.id] = item;
    }
    return _songTableByMode[filterMode] = _LibrarySongTableRows(
      items: items,
      qualityMode: qualityMode,
      colorScheme: colorScheme,
      rows: rows,
      rowByItem: rowByItem,
      byId: byId,
      openAction: openAction,
    );
  }

  Widget _buildUnifiedLibraryItem(
    BuildContext context,
    UnifiedLibraryItem item,
    ColorScheme colorScheme, {
    required List<DownloadHistoryItem> downloadedNavigationItems,
    required int? downloadedNavigationIndex,
    required List<LocalLibraryItem> localNavigationItems,
    required int? localNavigationIndex,
    required List<UnifiedLibraryItem> libraryItems,
    // Null where the playlist drag around the song takes the long press.
    required VoidCallback? onLongPress,
  }) {
    final fileExistsListenable = _fileExistsListenable(item.filePath);
    final isSelected = _selectedIds.contains(item.id);
    final date = item.addedAt;
    final dateStr =
        '${shortMonthNames[date.month - 1]} ${date.day}, ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

    final isDownloaded = item.source == LibraryItemSource.downloaded;
    final quality = item.qualityForMode(_libraryQualityLabelMode);
    final sourceLabel = isDownloaded
        ? context.l10n.librarySourceDownloaded
        : context.l10n.librarySourceLocal;
    // The label text tells the sources apart; rows keep one neutral role.
    final sourceColor = colorScheme.surfaceContainerHighest;
    final sourceTextColor = colorScheme.onSurfaceVariant;

    final open = _libraryItemOpenAction(
      item,
      downloadedNavigationItems: downloadedNavigationItems,
      downloadedNavigationIndex: downloadedNavigationIndex,
      localNavigationItems: localNavigationItems,
      localNavigationIndex: localNavigationIndex,
    );

    final playbackKey = _libraryPlaybackKey(item);
    final leading = Hero(
      tag: 'cover_lib_${item.id}',
      transitionOnUserGestures: heroFollowsBackSwipe(context),
      child: _buildUnifiedCoverImage(
        item,
        colorScheme,
        context.tokens.coverList,
      ),
    );
    // The text reads the row's supporting colour, which follows the fill of
    // the current track; the badges keep their own surfaces.
    final subtitle = Builder(
      builder: (context) {
        final textColor = DefaultTextStyle.of(context).style.color;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // The history service is where the audio was downloaded from;
            // artist lookups use the user's search provider instead.
            ClickableArtistName(
              artistName: item.artistName,
              coverUrl: item.coverUrl,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: textColor),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Container(
                  padding: context.tokens.badgePadding,
                  decoration: BoxDecoration(
                    color: sourceColor,
                    borderRadius: context.tokens.borderRadiusBadge,
                  ),
                  child: Text(
                    sourceLabel,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: sourceTextColor,
                      fontSize: context.tokens.badgeFontSize,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    dateStr,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: textColor),
                  ),
                ),
                if (quality != null && quality.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  _buildLibraryQualityBadge(
                    context,
                    colorScheme,
                    quality,
                    listStyle: true,
                  ),
                ],
                if (offlineAvailabilityLabel(context, item)
                    case final status?) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ],
              ],
            ),
          ],
        );
      },
    );
    void play() => _playLibraryItem(item, libraryItems);
    // A song whose file is missing has no play action and keeps opening.
    final tap = songRowTap(
      ref,
      path: item.filePath,
      openDetails: open,
      play: () => fileExistsListenable.value
          ? _LibraryPlaybackButton.run(ref, playbackKey, play)
          : open(),
    );
    final trailing = ValueListenableBuilder<bool>(
      valueListenable: fileExistsListenable,
      builder: (context, fileExists, child) {
        if (fileExists) {
          return SongRowButton(
            playButton: _LibraryPlaybackButton(
              playbackKey: playbackKey,
              playTooltip: context.l10n.a11yPlayTrackByArtist(
                item.trackName,
                item.artistName,
              ),
              onPlay: play,
            ),
            onOpenDetails: open,
            path: item.filePath,
          );
        }
        return Tooltip(
          message: context.l10n.queueDownloadedFileMissing,
          child: AppIcon(
            Icons.error_outline,
            color: colorScheme.error,
            size: 20,
          ),
        );
      },
    );
    Widget card({
      bool current = false,
      bool playing = false,
      QueueSwipeActions? swipe,
    }) => TrackCard(
      isSelectionMode: _isSelectionMode,
      isSelected: isSelected,
      isCurrent: current,
      isPlaying: playing,
      leadingArtwork: true,
      onTap: isDesktopPlatform
          ? () => _desktopLibraryItemClick(item, libraryItems, tap)
          : _isSelectionMode
          ? () => _toggleSelection(item.id)
          : tap,
      onContextMenu: (position) => _showLibraryItemMenu(
        context,
        item,
        libraryItems,
        position,
        onOpenDetails: open,
      ),
      onLongPress: onLongPress,
      leading: leading,
      title: item.trackName,
      subtitle: subtitle,
      trailing: trailing,
      queueSwipe: swipe,
    );

    return Semantics(
      label: context.l10n.a11yTrackByArtist(item.trackName, item.artistName),
      selected: isSelected,
      // Rows follow their own file, so a track change rebuilds only the rows
      // involved, and queueSwipe subscribes on this leaf Consumer's ref.
      child: Consumer(
        builder: (context, ref, _) {
          final playback = ref.watch(mediaItemPlaybackUiProvider(playbackKey));
          return card(
            current: playback.isCurrent,
            playing: playback.isPlaying,
            swipe: libraryItemQueueSwipe(ref, item),
          );
        },
      ),
    );
  }

  Widget _buildUnifiedGridItem(
    BuildContext context,
    UnifiedLibraryItem item,
    ColorScheme colorScheme, {
    required List<DownloadHistoryItem> downloadedNavigationItems,
    required int? downloadedNavigationIndex,
    required List<LocalLibraryItem> localNavigationItems,
    required int? localNavigationIndex,
    required List<UnifiedLibraryItem> libraryItems,
    // Null where the playlist drag around the song takes the long press.
    required VoidCallback? onLongPress,
  }) {
    final fileExistsListenable = _fileExistsListenable(item.filePath);
    final isSelected = _selectedIds.contains(item.id);
    final isDownloaded = item.source == LibraryItemSource.downloaded;
    final quality = item.qualityForMode(_libraryQualityLabelMode);

    final open = _libraryItemOpenAction(
      item,
      downloadedNavigationItems: downloadedNavigationItems,
      downloadedNavigationIndex: downloadedNavigationIndex,
      localNavigationItems: localNavigationItems,
      localNavigationIndex: localNavigationIndex,
    );
    final playbackKey = _libraryPlaybackKey(item);
    void play() => _playLibraryItem(item, libraryItems);
    // A song whose file is missing has no play action and keeps opening.
    final tap = songRowTap(
      ref,
      path: item.filePath,
      openDetails: open,
      play: () => fileExistsListenable.value
          ? _LibraryPlaybackButton.run(ref, playbackKey, play)
          : open(),
    );

    return TrackGridCard(
      isSelected: _isSelectionMode && isSelected,
      semanticLabel: context.l10n.a11yTrackByArtist(
        item.trackName,
        item.artistName,
      ),
      onTap: isDesktopPlatform
          ? () => _desktopLibraryItemClick(item, libraryItems, tap)
          : _isSelectionMode
          ? () => _toggleSelection(item.id)
          : tap,
      onContextMenu: (position) => _showLibraryItemMenu(
        context,
        item,
        libraryItems,
        position,
        onOpenDetails: open,
      ),
      onLongPress: onLongPress,
      cover: Hero(
        tag: 'cover_lib_${item.id}',
        transitionOnUserGestures: heroFollowsBackSwipe(context),
        child: _buildUnifiedCoverImage(item, colorScheme),
      ),
      overlays: [
        if (!_isSelectionMode)
          PositionedDirectional(
            end: 4,
            top: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              // The glyph tells the sources apart; the badge stays neutral.
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: context.tokens.borderRadiusBadge,
              ),
              child: AppIcon(
                isDownloaded ? Icons.download_done : Icons.folder,
                size: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (quality != null && quality.isNotEmpty)
          PositionedDirectional(
            start: 4,
            end: _isSelectionMode ? 4 : 28,
            top: 4,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: _buildLibraryQualityBadge(context, colorScheme, quality),
            ),
          ),
        // A desktop click selects, so the play button stays during selection.
        if (!_isSelectionMode || isDesktopPlatform)
          PositionedDirectional(
            end: 4,
            bottom: 4,
            child: ValueListenableBuilder<bool>(
              valueListenable: fileExistsListenable,
              builder: (context, fileExists, child) {
                if (fileExists) {
                  return SongRowButton(
                    playButton: _LibraryPlaybackButton(
                      playbackKey: playbackKey,
                      playTooltip: context.l10n.a11yPlayTrackByArtist(
                        item.trackName,
                        item.artistName,
                      ),
                      onPlay: play,
                      grid: true,
                    ),
                    onOpenDetails: open,
                    size: SongRowButtonSize.grid,
                    path: item.filePath,
                  );
                }
                return Tooltip(
                  message: context.l10n.queueDownloadedFileMissing,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: colorScheme.errorContainer,
                      shape: BoxShape.circle,
                    ),
                    child: AppIcon(
                      Icons.error_outline,
                      color: colorScheme.error,
                      size: 14,
                    ),
                  ),
                );
              },
            ),
          ),
        if (_isSelectionMode)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: isSelected
                    ? colorScheme.primary.withValues(alpha: 0.3)
                    : Colors.transparent,
                borderRadius: context.tokens.borderRadiusThumb,
              ),
            ),
          ),
        if (_isSelectionMode)
          PositionedDirectional(
            end: 4,
            top: 4,
            child: AnimatedSelectionCheckbox(
              selected: isSelected,
              colorScheme: colorScheme,
              size: 24,
              unselectedColor: colorScheme.surface,
            ),
          ),
      ],
      title: item.trackName,
      // Not the history service: see the list row above.
      subtitle: ClickableArtistName(
        artistName: item.artistName,
        coverUrl: item.coverUrl,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _LibraryPlaybackButton extends ConsumerWidget {
  const _LibraryPlaybackButton({
    required this.playbackKey,
    required this.playTooltip,
    required this.onPlay,
    this.grid = false,
    this.inline = false,
  });

  final PlaybackRowKey playbackKey;
  final String playTooltip;
  final VoidCallback onPlay;
  final bool grid;
  final bool inline;

  /// What the button does for [playback]: nothing while its song loads,
  /// pause or resume for the current song, and [onPlay] for any other.
  static VoidCallback? action(
    WidgetRef ref,
    MediaPlaybackUi playback,
    VoidCallback onPlay,
  ) => playback.isLoading
      ? null
      : () {
          if (playback.isCurrent) {
            ref
                .read(musicPlayerControllerProvider)
                .togglePlayPause(playback.isPlaying);
          } else {
            onPlay();
          }
        };

  /// Runs [action] for the song's playback state at the time of the call, as
  /// a row tap that does what the button does.
  static void run(
    WidgetRef ref,
    PlaybackRowKey playbackKey,
    VoidCallback onPlay,
  ) => action(
    ref,
    ref.read(mediaItemPlaybackUiProvider(playbackKey)),
    onPlay,
  )?.call();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(mediaItemPlaybackUiProvider(playbackKey));
    final icon = playback.isPlaying ? Icons.pause : Icons.play_arrow;
    final tooltip = playback.isPlaying ? context.l10n.actionPause : playTooltip;
    final onPressed = action(ref, playback, onPlay);

    if (grid) {
      return TrackGridPlayButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: icon,
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    if (inline) {
      return AppIconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        iconSize: 24,
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tightFor(
          width: context.tokens.minTouchTarget,
          height: context.tokens.minTouchTarget,
        ),
        icon: playback.isLoading
            ? AppLoadingIndicator(
                size: 18,
                strokeWidth: 2,
                color: colorScheme.primary,
              )
            : Icon(
                playback.isPlaying
                    ? Icons.pause_circle_filled_rounded
                    : playback.isCurrent
                    ? Icons.play_circle_fill_rounded
                    : Icons.play_circle_outline_rounded,
                color: playback.isCurrent
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
      );
    }

    // Material draws a filled tonal icon button: a solid role pair rather
    // than a faded primary container.
    final material = !context.isMornye;
    return AppIconButton(
      onPressed: onPressed,
      icon: Icon(
        icon,
        color: material
            ? colorScheme.onSecondaryContainer
            : colorScheme.primary,
      ),
      tooltip: tooltip,
      style: IconButton.styleFrom(
        minimumSize: Size.square(context.tokens.minTouchTarget),
        backgroundColor: material
            ? colorScheme.secondaryContainer
            : colorScheme.primaryContainer,
      ),
    );
  }
}

/// The desktop Songs table rows of one song list, with the inputs they were
/// built from.
class _LibrarySongTableRows {
  _LibrarySongTableRows({
    required this.items,
    required this.qualityMode,
    required this.colorScheme,
    required this.rows,
    required this.rowByItem,
    required this.byId,
    required this.openAction,
  });

  final List<UnifiedLibraryItem> items;
  final String qualityMode;
  final ColorScheme colorScheme;
  final List<TrackTableRow> rows;
  final Map<UnifiedLibraryItem, TrackTableRow> rowByItem;
  final Map<String, UnifiedLibraryItem> byId;

  /// Opens a song's details with the latest build's navigation lists, for
  /// the details buttons of rows kept from an earlier build.
  VoidCallback Function(UnifiedLibraryItem item) openAction;
}

/// Fades a decoded local cover in over [backdrop], then drops the backdrop
/// and the stack, so a settled row paints the cover alone.
class _LocalCoverFade extends StatefulWidget {
  const _LocalCoverFade({
    required this.loaded,
    required this.backdrop,
    required this.child,
  });

  final bool loaded;
  final Widget backdrop;
  final Widget child;

  @override
  State<_LocalCoverFade> createState() => _LocalCoverFadeState();
}

class _LocalCoverFadeState extends State<_LocalCoverFade> {
  final GlobalKey _childKey = GlobalKey();
  late bool _settled = widget.loaded;

  @override
  void didUpdateWidget(_LocalCoverFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.loaded) {
      _settled = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyedChild = KeyedSubtree(key: _childKey, child: widget.child);
    if (widget.loaded &&
        (_settled ||
            MediaQuery.disableAnimationsOf(context) ||
            Scrollable.recommendDeferredLoadingForContext(context))) {
      _settled = true;
      return keyedChild;
    }
    final motion = AppMotion.effectsFast(
      context,
      const AppMotionSpec(Duration(milliseconds: 180), Curves.easeOutCubic),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.backdrop,
        AnimatedOpacity(
          opacity: widget.loaded ? 1.0 : 0.0,
          duration: motion.duration,
          curve: motion.curve,
          onEnd: () {
            if (mounted && widget.loaded && !_settled) {
              setState(() => _settled = true);
            }
          },
          child: keyedChild,
        ),
      ],
    );
  }
}
