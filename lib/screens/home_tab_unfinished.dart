part of 'home_tab.dart';

/// Loose ends of the collection: songs to fetch, albums with gaps,
/// recognized songs not kept and downloads that failed. Each row shows only
/// while it has something.
class _HomeUnfinishedSection extends ConsumerWidget {
  const _HomeUnfinishedSection({required this.inset});

  final double inset;

  static bool hasContent(WidgetRef ref) =>
      ref.watch(homeUnfinishedProvider.select((s) => !s.isEmpty));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final unfinished = ref.watch(homeUnfinishedProvider);
    final queueRuns = ref.watch(
      downloadQueueProvider.select((s) => s.isProcessing),
    );
    void open(Widget page) => pushPage<void>(context, (_) => page);
    final rows = unfinished.rows;
    final items = [
      for (final (index, row) in rows.indexed)
        if (unfinished.countOf(row) case final count)
          switch (row) {
            HomeUnfinishedRow.wishlist => SettingsItem(
              icon: Icons.add_circle_outline,
              showIconInMornye: true,
              title: l10n.homeUnfinishedWishlist(count),
              showDivider: index < rows.length - 1,
              onTap: () => open(
                const LibraryTracksFolderScreen(
                  mode: LibraryTracksFolderMode.wishlist,
                ),
              ),
            ),
            HomeUnfinishedRow.incompleteAlbums => SettingsItem(
              icon: Icons.rule,
              showIconInMornye: true,
              title: l10n.homeUnfinishedAlbums(count),
              showDivider: index < rows.length - 1,
              onTap: () => open(const _HomeIncompleteAlbumsPage()),
            ),
            HomeUnfinishedRow.recognized => SettingsItem(
              icon: Icons.mic,
              showIconInMornye: true,
              title: l10n.homeUnfinishedRecognized(count),
              showDivider: index < rows.length - 1,
              onTap: () => _openRecognition(context),
            ),
            HomeUnfinishedRow.failedDownloads => SettingsItem(
              icon: Icons.error_outline,
              showIconInMornye: true,
              title: l10n.homeUnfinishedFailed(count),
              showDivider: index < rows.length - 1,
              // As in the queue header: no retry while the queue runs.
              trailing: queueRuns
                  ? null
                  : AppIconButton(
                      key: const ValueKey('home-unfinished-retry'),
                      onPressed: () => ref
                          .read(downloadQueueProvider.notifier)
                          .retryAllFailed(),
                      icon: const AppIcon.adaptive(Icons.replay_rounded),
                      tooltip: l10n.queueRetryAllFailed(count),
                    ),
              onTap: () => open(
                const Scaffold(body: QueueTab(librarySection: 'downloads')),
              ),
            ),
          },
    ];
    return _HomeSection(
      title: l10n.homeUnfinishedTitle,
      inset: inset,
      // A list row stays readable width on a wide desktop pane.
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: _homeDesktopColumnsMinWidth,
          ),
          child: SettingsGroup(
            margin: EdgeInsets.zero,
            connected: true,
            children: items,
          ),
        ),
      ),
    );
  }

  /// The history lists the songs; a result's Search returns its query.
  Future<void> _openRecognition(BuildContext context) async {
    final query = await pushPage<String>(
      context,
      (_) => const MusicRecognitionScreen(listenOnOpen: false),
    );
    if (query != null && query.trim().isNotEmpty) {
      ShellNavigationService.requestSearch();
    }
  }
}

const LibraryBrowseRequest _homeIncompleteAlbumsRequest = (
  artists: false,
  artist: null,
  search: '',
  sort: 'a-z',
  limit: 40,
  completeness: incompleteAlbumFilter,
);

/// The Library's incomplete albums, as its Incomplete albums filter finds
/// them, with how many of their songs are kept.
class _HomeIncompleteAlbumsPage extends ConsumerWidget {
  const _HomeIncompleteAlbumsPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final inset = 16 + wideListInset(context);
    final albums = ref.watch(
      libraryBrowseProvider(_homeIncompleteAlbumsRequest),
    );
    final entries = albums.value?.entries ?? const <LibraryBrowseEntry>[];
    return MornyeSettingsTheme(
      child: Scaffold(
        body: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.metrics.extentAfter < 500 &&
                (albums.value?.hasMore ?? false)) {
              unawaited(
                ref
                    .read(
                      libraryBrowseProvider(
                        _homeIncompleteAlbumsRequest,
                      ).notifier,
                    )
                    .loadMore(),
              );
            }
            return false;
          },
          child: CustomScrollView(
            slivers: [
              AppSliverHeader.page(title: l10n.libraryFilterIncompleteAlbums),
              const SliverToBoxAdapter(child: SizedBox(height: 8)),
              SliverSettingsGroup(
                margin: EdgeInsets.symmetric(horizontal: inset),
                itemCount: entries.length,
                itemBuilder: (context, index) =>
                    _HomeIncompleteAlbumRow(album: entries[index]),
              ),
              const NavBarSliverSpacer(),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeIncompleteAlbumRow extends StatelessWidget {
  const _HomeIncompleteAlbumRow({required this.album});

  final LibraryBrowseEntry album;

  static const _coverSize = 48.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colorScheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(context.tokens.radiusThumb);
    final completeness = album.completeness;
    final expected = completeness?.expected;
    final present = completeness?.present ?? album.trackCount;
    final progress = expected == null
        ? l10n.homeUnfinishedAlbumSomeMissing(present)
        : l10n.homeUnfinishedAlbumProgress(present, expected);
    final cacheWidth = (_coverSize * MediaQuery.devicePixelRatioOf(context))
        .round();
    return ListTile(
      leading: ClipRRect(
        borderRadius: radius,
        child: SizedBox.square(
          dimension: _coverSize,
          child: album.source == 'local'
              ? LocalLibraryArtworkBuilder(
                  coverPath: album.cover,
                  filePath: album.samplePath,
                  builder: (context, cover) => PlayerArtwork(
                    artUri: cover,
                    colorScheme: colorScheme,
                    cacheWidth: cacheWidth,
                    iconSize: 20,
                  ),
                )
              : _DownloadedOrRemoteCover(
                  downloadedFilePath: album.samplePath,
                  imageUrl: album.cover,
                  width: _coverSize,
                  height: _coverSize,
                  borderRadius: BorderRadius.zero,
                  fallbackIcon: Icons.album_outlined,
                  fallbackIconSize: 20,
                  colorScheme: colorScheme,
                ),
        ),
      ),
      title: Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        album.artist.isEmpty ? progress : '${album.artist} · $progress',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => _openHomeLibraryAlbum(context, album),
    );
  }
}
