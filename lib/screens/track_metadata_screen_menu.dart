// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'track_metadata_screen.dart';

extension _TrackMetadataMenu on _TrackMetadataScreenState {
  /// The overflow menu's items in order. Every surface starts a new group
  /// where an item asks for a divider or is destructive.
  List<_MetadataOption> _menuOptions(
    BuildContext screenContext,
    WidgetRef ref,
    ColorScheme colorScheme,
    AppLocalizations l10n,
  ) {
    final canEditFile = _fileExists && !_isNetworkItem;
    final localItem = _localLibraryItem;
    final downloadItem = _downloadItem;
    final linkTransfers = linkTransfersAvailable(ref);
    final desktopSongs = localItem == null || !linkTransfers
        ? const <LinkOfflineSong>[]
        : linkDesktopSongsOf(ref, [localItem]);
    final linkClient = ref.read(linkPhoneClientProvider);
    final phoneSongs = !linkTransfers || !_fileExists
        ? const <UnifiedLibraryItem>[]
        : linkPhoneSongItemsOf([
            if (localItem != null)
              UnifiedLibraryItem.fromLocalLibrary(localItem)
            else if (downloadItem != null)
              UnifiedLibraryItem.fromDownloadHistory(downloadItem),
          ]);
    return <_MetadataOption>[
      if (_fileExists)
        _MetadataOption(
          icon: Icons.playlist_play,
          label: l10n.trackPlayNext,
          onTap: () => _enqueueThis(ref, playNext: true),
        ),
      if (_fileExists)
        _MetadataOption(
          icon: Icons.queue_music,
          label: l10n.trackAddToQueue,
          onTap: () => _enqueueThis(ref, playNext: false),
        ),
      if (desktopSongs.isNotEmpty)
        _MetadataOption(
          icon: Icons.phone_android,
          label: l10n.linkSaveToPhone,
          onTap: () => linkSaveSongsToPhone(screenContext, ref, desktopSongs),
        ),
      if (phoneSongs.isNotEmpty && linkClient != null)
        _MetadataOption(
          icon: Icons.computer,
          label: l10n.linkSendToDesktop(linkDesktopName(linkClient)),
          onTap: () => linkSendSongsToDesktop(screenContext, ref, phoneSongs),
        ),
      if (albumName.trim().isNotEmpty)
        _MetadataOption(
          icon: Icons.album_outlined,
          label: l10n.homeGoToAlbum,
          onTap: () => navigateToAlbum(
            screenContext,
            albumName: albumName,
            artistName: albumArtist ?? artistName,
            coverUrl: _coverUrl,
          ),
        ),
      _MetadataOption(
        icon: Icons.person_outline,
        label: l10n.mornyeGoToArtist,
        onTap: () =>
            navigateToArtistCredits(screenContext, artistNames: artistName),
      ),
      _MetadataOption(
        icon: Icons.copy_outlined,
        label: l10n.trackCopyFilePath,
        dividerAbove: _fileExists,
        onTap: () => _copyToClipboard(screenContext, cleanFilePath),
      ),
      if (canEditFile)
        _MetadataOption(
          icon: Icons.edit_outlined,
          label: l10n.trackEditMetadata,
          onTap: () => _showEditMetadataSheet(screenContext, ref, colorScheme),
        ),
      if (!_isNetworkItem && (_coverUrl != null || _fileExists))
        _MetadataOption(
          icon: Icons.image_outlined,
          label: l10n.trackSaveCoverArt,
          onTap: _saveCoverArt,
        ),
      if (!_isNetworkItem && (_fileExists || !_isLocalItem))
        _MetadataOption(
          icon: Icons.lyrics_outlined,
          label: l10n.trackSaveLyrics,
          onTap: _saveLyrics,
        ),
      if (canEditFile)
        _MetadataOption(
          icon: Icons.travel_explore,
          label: l10n.trackReEnrich,
          onTap: _reEnrichMetadata,
        ),
      if (canEditFile && _isConvertibleFormat)
        _MetadataOption(
          icon: Icons.swap_horiz,
          label: l10n.trackConvertFormat,
          onTap: () => _showConvertSheet(screenContext),
        ),
      if (canEditFile && !_isCueFile)
        _MetadataOption(
          icon: Icons.graphic_eq,
          label: l10n.trackReplayGain,
          onTap: () => _updateReplayGain(),
        ),
      if (canEditFile && !_isCueFile)
        _MetadataOption(
          icon: Icons.remove_circle_outline,
          label: l10n.trackRemoveReplayGain,
          onTap: () => _removeReplayGain(),
        ),
      if (canEditFile && _isCueFile)
        _MetadataOption(
          icon: Icons.call_split,
          label: l10n.cueSplitTitle,
          onTap: () => _showCueSplitSheet(screenContext),
        ),
      if (_spotifyId != null || (isrc?.isNotEmpty ?? false))
        _MetadataOption(
          icon: Icons.open_in_new,
          label: l10n.trackOpenOn,
          dividerAbove: true,
          onTap: () => OpenOnPlatformSheet.show(
            screenContext,
            spotifyId: _spotifyId ?? '',
            isrc: isrc ?? '',
          ),
        ),
      if (!_isNetworkItem)
        _MetadataOption(
          icon: Icons.share_outlined,
          label: l10n.trackMetadataShare,
          dividerAbove: _spotifyId == null && !(isrc?.isNotEmpty ?? false),
          onTap: () => _shareFile(screenContext),
        ),
      if (_canDeleteFile)
        _MetadataOption(
          icon: Icons.delete_outline,
          label: _isNetworkItem
              ? l10n.trackMetadataDelete
              : l10n.trackRemoveFromDevice,
          destructive: true,
          onTap: () => _confirmDelete(screenContext, ref, colorScheme),
        ),
    ];
  }

  void _showOptionsMenu(
    BuildContext screenContext,
    WidgetRef ref,
    ColorScheme colorScheme, {
    Rect? anchor,
  }) {
    if (isDesktopPlatform && !screenContext.isMornye) {
      _showDesktopOptionsMenu(screenContext, ref, colorScheme, anchor: anchor);
      return;
    }
    Widget buildMenu(BuildContext sheetContext) {
      final l10n = sheetContext.l10n;
      final options = _menuOptions(screenContext, ref, colorScheme, l10n);

      if (sheetContext.isMornye) {
        final groups = <List<MornyeMenuAction>>[];
        for (final option in options) {
          if (option.icon == Icons.share_outlined) {
            continue;
          }
          if (groups.isEmpty || option.dividerAbove || option.destructive) {
            groups.add([]);
          }
          groups.last.add(
            MornyeMenuAction(
              icon: mornyeIconFor(option.icon),
              label: option.label,
              destructive: option.destructive,
              onPressed: () =>
                  _closeOptionsMenuAndRun(sheetContext, option.onTap),
            ),
          );
        }
        return MornyeContextMenu(
          quickActions: [
            if (_fileExists) ...[
              MornyeMenuAction(
                icon: CupertinoIcons.play_fill,
                label: l10n.trackMetadataPlay,
                onPressed: () => _closeOptionsMenuAndRun(
                  sheetContext,
                  () => _openFile(screenContext, rawFilePath),
                ),
              ),
            ],
            if (!_isNetworkItem)
              MornyeMenuAction(
                icon: CupertinoIcons.share_solid,
                label: l10n.trackMetadataShare,
                onPressed: () => _closeOptionsMenuAndRun(
                  sheetContext,
                  () => _shareFile(screenContext),
                ),
              ),
          ],
          groups: groups,
        );
      }

      Widget buildContent({ScrollController? controller}) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          controller: controller,
          primary: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppSheetHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _buildOptionsHeaderCover(colorScheme),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            trackName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(sheetContext).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            artistName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(sheetContext).textTheme.bodyMedium
                                ?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                color: colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 8),
              Builder(
                builder: (context) {
                  final items = <Widget>[
                    for (int i = 0; i < options.length; i++) ...[
                      if (options[i].dividerAbove && i != 0)
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: colorScheme.outlineVariant.withValues(
                            alpha: 0.3,
                          ),
                        ),
                      _MetadataOptionTile(
                        option: options[i],
                        colorScheme: colorScheme,
                        onTap: () => _closeOptionsMenuAndRun(
                          sheetContext,
                          options[i].onTap,
                        ),
                      ),
                    ],
                  ];
                  return SettingsGroup(children: items);
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      );
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85,
        ),
        child: buildContent(),
      );
    }

    if (screenContext.isMornye) {
      showMornyeContextMenu<void>(
        context: screenContext,
        anchor: anchor,
        builder: buildMenu,
      );
      return;
    }
    showAppModalBottomSheet<void>(
      context: screenContext,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: buildMenu,
    );
  }

  /// Material desktop opens the items as a menu anchored under the More
  /// button, like the Library's right-click menus, instead of a phone sheet.
  void _showDesktopOptionsMenu(
    BuildContext screenContext,
    WidgetRef ref,
    ColorScheme colorScheme, {
    Rect? anchor,
  }) {
    final options = _menuOptions(
      screenContext,
      ref,
      colorScheme,
      screenContext.l10n,
    );
    final groups = <List<ContextMenuAction>>[];
    for (final option in options) {
      if (groups.isEmpty || option.dividerAbove || option.destructive) {
        groups.add([]);
      }
      groups.last.add(
        ContextMenuAction(
          icon: option.icon,
          label: option.label,
          destructive: option.destructive,
          onSelected: option.onTap,
        ),
      );
    }
    showContextMenu(
      screenContext,
      position:
          anchor?.bottomLeft ??
          contextMenuOriginOf(screenContext) ??
          MediaQuery.sizeOf(screenContext).center(Offset.zero),
      groups: groups,
    );
  }

  Widget _buildOptionsHeaderCover(ColorScheme colorScheme) {
    const size = 56.0;
    const cacheWidth = 112;

    Widget placeholder() => Container(
      width: size,
      height: size,
      color: colorScheme.surfaceContainerHighest,
      child: Icon(Icons.music_note, color: colorScheme.onSurfaceVariant),
    );

    if (_coverUrl != null) {
      return CachedCoverImage(
        imageUrl: _coverUrl!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        memCacheWidth: cacheWidth,
        memCacheHeight: cacheWidth,
        errorWidget: (_, _, _) => placeholder(),
      );
    }

    if (_localCoverPath != null && _localCoverPath!.isNotEmpty) {
      return Image.file(
        File(_localCoverPath!),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        errorBuilder: (_, _, _) => placeholder(),
      );
    }

    return placeholder();
  }
}
