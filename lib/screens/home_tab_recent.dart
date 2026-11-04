part of 'home_tab.dart';

extension _HomeTabRecentUI on _HomeTabState {
  /// The Mornye desktop Search page lays recents out as a horizontal card shelf.
  bool get _recentAccessAsCards =>
      context.isMornye &&
      isDesktopPlatform &&
      widget.mode == HomeTabMode.search;

  Widget _buildRecentAccess(_RecentAccessView view, ColorScheme colorScheme) {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: _buildRecentAccessHeader(view, colorScheme)),
        if (view.uniqueItems.isNotEmpty && _recentAccessAsCards)
          SliverToBoxAdapter(
            child: _buildRecentAccessCardRow(view, colorScheme),
          )
        else if (view.uniqueItems.isNotEmpty)
          SliverPadding(
            padding:
                const EdgeInsets.fromLTRB(16, 0, 16, 8) +
                EdgeInsets.symmetric(horizontal: homeContentInset(context)),
            sliver: SliverList.builder(
              itemCount: view.uniqueItems.length,
              itemBuilder: (context, index) {
                final item = view.uniqueItems[index];
                return KeyedSubtree(
                  key: ValueKey('${item.type.name}:${item.id}'),
                  child: _buildRecentAccessItem(
                    item,
                    colorScheme,
                    view.downloadFilePathByRecentKey,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildRecentAccessHeader(
    _RecentAccessView view,
    ColorScheme colorScheme,
  ) {
    final uniqueItems = view.uniqueItems;
    final hasHiddenDownloads = view.hasHiddenDownloads;

    return Padding(
      padding:
          EdgeInsets.fromLTRB(16, 8, 16, uniqueItems.isEmpty ? 8 : 0) +
          EdgeInsets.symmetric(horizontal: homeContentInset(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Semantics(
                header: true,
                child: _recentAccessAsCards
                    ? Text(
                        context.l10n.searchRecentlySearched,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      )
                    : Text(
                        context.l10n.homeRecent,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
              if (uniqueItems.isNotEmpty)
                ExpressiveButton(
                  text: true,
                  onPressed: () async {
                    // Clearing history is not undoable, so ask first.
                    final confirmed = await showAppDialog<bool>(
                      context: context,
                      builder: (dialogContext) => AppAlertDialog(
                        title: Text(dialogContext.l10n.dialogClearAll),
                        content: Text(dialogContext.l10n.recentClearAllMessage),
                        actions: [
                          AppDialogAction(
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(false),
                            child: Text(dialogContext.l10n.dialogCancel),
                          ),
                          AppDialogAction(
                            filled: true,
                            isDestructive: true,
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(true),
                            child: Text(dialogContext.l10n.dialogClearAll),
                          ),
                        ],
                      ),
                    );
                    if (confirmed != true) return;
                    await ref
                        .read(recentAccessProvider.notifier)
                        .clearHistory();
                  },
                  child: Text(
                    context.l10n.dialogClearAll,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (uniqueItems.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: SizedBox(
                width: double.infinity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(
                      hasHiddenDownloads ? Icons.visibility_off : Icons.history,
                      size: 48,
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      context.l10n.recentEmpty,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (hasHiddenDownloads) ...[
                      const SizedBox(height: 16),
                      ExpressiveButton(
                        outlined: true,
                        onPressed: () {
                          ref
                              .read(recentAccessProvider.notifier)
                              .clearHiddenDownloads();
                        },
                        icon: const Icon(Icons.visibility, size: 18),
                        child: Text(context.l10n.recentShowAllDownloads),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  (IconData, String) _recentAccessType(
    RecentAccessItem item,
  ) => switch (item.type) {
    RecentAccessType.artist => (Icons.person, context.l10n.recentTypeArtist),
    RecentAccessType.album => (Icons.album, context.l10n.recentTypeAlbum),
    RecentAccessType.track => (Icons.music_note, context.l10n.recentTypeSong),
    RecentAccessType.playlist => (
      Icons.playlist_play,
      context.l10n.recentTypePlaylist,
    ),
  };

  String _recentAccessSubtitle(RecentAccessItem item, String typeLabel) {
    // A downloaded entry is always a song.
    final label = item.providerId == 'download'
        ? context.l10n.recentTypeSong
        : typeLabel;
    final subtitle = item.subtitle;
    return subtitle != null ? '$label • $subtitle' : label;
  }

  void _removeRecentAccessItem(RecentAccessItem item) {
    final notifier = ref.read(recentAccessProvider.notifier);
    if (item.providerId == 'download') {
      notifier.hideDownloadFromRecents(item.id);
    } else {
      notifier.removeItem(item);
    }
  }

  Widget _buildRecentAccessCover(
    RecentAccessItem item,
    ColorScheme colorScheme,
    Map<String, String> downloadFilePathByRecentKey, {
    required IconData fallbackIcon,
    required double radius,
  }) {
    final size = context.tokens.coverList;
    return DownloadableCover(
      coverUrl: item.imageUrl,
      baseName: item.subtitle == null
          ? item.name
          : '${item.subtitle} - ${item.name}',
      child: _DownloadedOrRemoteCover(
        downloadedFilePath: item.providerId == 'download'
            ? downloadFilePathByRecentKey['${item.type.name}:${item.id}']
            : null,
        imageUrl: item.imageUrl,
        width: size,
        height: size,
        borderRadius: BorderRadius.circular(
          item.type == RecentAccessType.artist ? size / 2 : radius,
        ),
        fallbackIcon: fallbackIcon,
        colorScheme: colorScheme,
      ),
    );
  }

  Widget _buildRecentAccessCardRow(
    _RecentAccessView view,
    ColorScheme colorScheme,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    final textTheme = Theme.of(context).textTheme;
    // Two lines of text or the cover, whichever is taller, inside the
    // card's padding; grows with the text size instead of clipping.
    final textHeight =
        scaler.scale(textTheme.bodyLarge?.fontSize ?? 17) * 1.3 +
        scaler.scale(textTheme.bodySmall?.fontSize ?? 13) * 1.3 +
        2;
    final cardHeight =
        math.max(context.tokens.coverList, textHeight) + 2 * _recentCardPadding;
    final inset = 16 + homeContentInset(context);
    return SizedBox(
      height: cardHeight + 20,
      child: DesktopScrollArrows(
        builder: (context, controller) => ListView.separated(
          key: const ValueKey('recent-access-cards'),
          controller: controller,
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.fromLTRB(inset, 4, inset, 16),
          itemCount: view.uniqueItems.length,
          separatorBuilder: (_, _) => const SizedBox(width: 16),
          itemBuilder: (context, index) {
            final item = view.uniqueItems[index];
            return KeyedSubtree(
              key: ValueKey('${item.type.name}:${item.id}'),
              child: _buildRecentAccessCard(
                item,
                colorScheme,
                view.downloadFilePathByRecentKey,
              ),
            );
          },
        ),
      ),
    );
  }

  static const double _recentCardPadding = 12;

  Widget _buildRecentAccessCard(
    RecentAccessItem item,
    ColorScheme colorScheme,
    Map<String, String> downloadFilePathByRecentKey,
  ) {
    final (typeIcon, typeLabel) = _recentAccessType(item);
    final textTheme = Theme.of(context).textTheme;
    final tokens = context.tokens;

    void showMenu(BuildContext anchorContext) {
      final box = anchorContext.findRenderObject();
      showMornyeContextMenu<void>(
        context: anchorContext,
        anchor: box is RenderBox && box.hasSize
            ? box.localToGlobal(Offset.zero) & box.size
            : null,
        builder: (menuContext) => MornyeContextMenu(
          groups: [
            [
              MornyeMenuAction(
                icon: mornyeIconFor(Icons.delete_outline),
                label: menuContext.l10n.dialogRemove,
                destructive: true,
                onPressed: () {
                  Navigator.pop(menuContext);
                  _removeRecentAccessItem(item);
                },
              ),
            ],
          ],
        ),
      );
    }

    // A plain grouped fill: recents are content, not floating controls.
    return SizedBox(
      width: 320,
      child: Material(
        color: MornyeTheme.controlFill(context),
        borderRadius: BorderRadius.circular(tokens.radiusCard),
        clipBehavior: Clip.antiAlias,
        child: Builder(
          builder: (cardContext) => InkWell(
            onTap: () => _navigateToRecentItem(item),
            onSecondaryTap: () => showMenu(cardContext),
            onLongPress: () => showMenu(cardContext),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                _recentCardPadding,
                _recentCardPadding,
                4,
                _recentCardPadding,
              ),
              child: Row(
                children: [
                  _buildRecentAccessCover(
                    item,
                    colorScheme,
                    downloadFilePathByRecentKey,
                    fallbackIcon: typeIcon,
                    radius: tokens.radiusThumb,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _recentAccessSubtitle(item, typeLabel),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Builder(
                    builder: (buttonContext) => AppIconButton(
                      tooltip: MaterialLocalizations.of(
                        buttonContext,
                      ).moreButtonTooltip,
                      icon: Icon(
                        Icons.more_horiz,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      onPressed: () => showMenu(buttonContext),
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

  Widget _buildRecentAccessItem(
    RecentAccessItem item,
    ColorScheme colorScheme,
    Map<String, String> downloadFilePathByRecentKey,
  ) {
    final (typeIcon, typeLabel) = _recentAccessType(item);
    final isDownloaded = item.providerId == 'download';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        onTap: () => _navigateToRecentItem(item),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            children: [
              _buildRecentAccessCover(
                item,
                colorScheme,
                downloadFilePathByRecentKey,
                fallbackIcon: typeIcon,
                radius: 4,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _recentAccessSubtitle(item, typeLabel),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isDownloaded
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              AppIconButton(
                tooltip: context.l10n.actionDismiss,
                icon: Icon(
                  Icons.close,
                  size: 20,
                  color: colorScheme.onSurfaceVariant,
                ),
                onPressed: () => _removeRecentAccessItem(item),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _isEnabledMetadataExtension(String? providerId) {
    final normalized = providerId?.trim();
    if (normalized == null || normalized.isEmpty) return false;

    return ref
        .read(extensionProvider)
        .extensions
        .any(
          (ext) =>
              ext.enabled && ext.hasMetadataProvider && ext.id == normalized,
        );
  }

  Future<void> _navigateToRecentItem(RecentAccessItem item) async {
    _searchFocusNode.unfocus();

    switch (item.type) {
      case RecentAccessType.artist:
        if (_isEnabledMetadataExtension(item.providerId)) {
          pushPage<void>(
            context,
            (context) => ExtensionArtistScreen(
              extensionId: item.providerId!,
              artistId: item.id,
              artistName: item.name,
              coverUrl: item.imageUrl,
            ),
          );
        } else {
          pushPage<void>(
            context,
            (context) => ArtistScreen(
              artistId: item.id,
              artistName: item.name,
              coverUrl: item.imageUrl,
            ),
          );
        }
        return;
      case RecentAccessType.album:
        if (item.providerId == 'download') {
          pushPage<void>(
            context,
            (context) => DownloadedAlbumScreen(
              albumName: item.name,
              artistName: item.subtitle ?? '',
              coverUrl: item.imageUrl,
            ),
          );
        } else if (_isEnabledMetadataExtension(item.providerId)) {
          pushPage<void>(
            context,
            (context) => ExtensionAlbumScreen(
              extensionId: item.providerId!,
              albumId: item.id,
              albumName: item.name,
              coverUrl: item.imageUrl,
            ),
          );
        } else {
          pushPage<void>(
            context,
            (context) => AlbumScreen(
              albumId: item.id,
              albumName: item.name,
              coverUrl: item.imageUrl,
            ),
          );
        }
        return;
      case RecentAccessType.track:
        final historyItem = await ref
            .read(downloadHistoryProvider.notifier)
            .getBySpotifyIdAsync(item.id);
        if (!mounted) return;
        if (historyItem != null) {
          _navigateToMetadataScreen(historyItem);
        } else {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(item.name)));
        }
        return;
      case RecentAccessType.playlist:
        if (item.id.trim().isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.recentPlaylistInfo(item.name))),
          );
          return;
        }

        if (_isEnabledMetadataExtension(item.providerId)) {
          pushPage<void>(
            context,
            (context) => ExtensionPlaylistScreen(
              extensionId: item.providerId!,
              playlistId: item.id,
              playlistName: item.name,
              coverUrl: item.imageUrl,
            ),
          );
        } else {
          pushPage<void>(
            context,
            (context) => PlaylistScreen(
              playlistName: item.name,
              coverUrl: item.imageUrl,
              tracks: const [],
              playlistId: item.id,
              metadataProviderId: item.providerId,
            ),
          );
        }
        return;
    }
  }

  Future<void> _navigateToMetadataScreen(
    DownloadHistoryItem item, {
    List<DownloadHistoryItem>? navigationItems,
    int? navigationIndex,
  }) async {
    final navigator = Navigator.of(context);
    final embeddedCoverPath =
        await DownloadedEmbeddedCoverResolver.resolveOrExtract(
          item.filePath,
          onChanged: _onEmbeddedCoverChanged,
        );
    if (!mounted) return;
    final artworkSource = embeddedCoverPath ?? item.coverUrl;
    if (embeddedCoverPath == null) {
      precacheCoverImage(context, item.coverUrl);
    }
    final backdropReady = precacheMetadataBackdrop(context, artworkSource);
    final beforeModTime =
        await DownloadedEmbeddedCoverResolver.readFileModTimeMillis(
          item.filePath,
        );
    await backdropReady;
    if (!mounted) return;
    final result = await navigator.push(
      slidePageRoute<bool>(
        page: TrackMetadataScreen(
          item: item,
          historyNavigationItems: navigationItems,
          navigationIndex: navigationIndex,
        ),
      ),
    );
    await DownloadedEmbeddedCoverResolver.scheduleRefreshForPath(
      item.filePath,
      beforeModTime: beforeModTime,
      force: result == true,
      onChanged: _onEmbeddedCoverChanged,
    );
  }
}
