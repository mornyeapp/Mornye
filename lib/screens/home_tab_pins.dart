part of 'home_tab.dart';

IconData _homePinIcon(HomePinKind kind) => switch (kind) {
  HomePinKind.album => Icons.album_outlined,
  HomePinKind.playlist => Icons.queue_music_rounded,
  HomePinKind.loved => Icons.favorite_border,
  HomePinKind.artist => Icons.person_outline,
  HomePinKind.genre => Icons.sell_outlined,
  HomePinKind.folder => Icons.folder_outlined,
};

/// [pin] as Home shows it now: a playlist under its current name and cover,
/// Loved in the current language.
HomePin _homePinShown(BuildContext context, WidgetRef ref, HomePin pin) {
  switch (pin.kind) {
    case HomePinKind.loved:
      return HomePin(
        kind: pin.kind,
        id: pin.id,
        title: context.l10n.collectionLoved,
      );
    case HomePinKind.playlist:
      final playlist = ref.watch(
        libraryCollectionsProvider.select(
          (s) => s.playlists.where((p) => p.id == pin.id).firstOrNull,
        ),
      );
      if (playlist == null) return pin;
      final custom = playlist.coverImagePath;
      return HomePin.playlist(
        id: pin.id,
        name: playlist.name,
        cover: custom != null && custom.isNotEmpty
            ? custom
            : playlist.tracks
                      .map((entry) => entry.track.coverUrl)
                      .where((url) => url != null && url.isNotEmpty)
                      .firstOrNull ??
                  playlist.previewCover ??
                  pin.cover,
      );
    case HomePinKind.album ||
        HomePinKind.artist ||
        HomePinKind.genre ||
        HomePinKind.folder:
      return pin;
  }
}

/// The kind of [pin], under its name on the Mornye shelf.
String _homePinSubtitle(AppLocalizations l10n, HomePin pin) =>
    switch (pin.kind) {
      HomePinKind.album => pin.subtitle,
      HomePinKind.playlist || HomePinKind.loved => l10n.collectionPlaylist,
      HomePinKind.artist => l10n.trackArtist,
      HomePinKind.genre => l10n.trackGenre,
      HomePinKind.folder => l10n.homePinFolder,
    };

/// The artwork of [pin] filling a square of [size], or [fallback] when it
/// has none.
Widget _homePinArtwork(
  BuildContext context,
  HomePin pin,
  double size, {
  required Widget fallback,
}) {
  final colorScheme = Theme.of(context).colorScheme;
  final cacheWidth = (size * MediaQuery.devicePixelRatioOf(context)).round();
  final iconSize = math.min(size * 0.4, 32.0);
  if (pin.source == 'downloaded') {
    return _DownloadedOrRemoteCover(
      downloadedFilePath: pin.coverFile,
      imageUrl: pin.cover,
      width: size,
      height: size,
      borderRadius: BorderRadius.zero,
      fallbackIcon: _homePinIcon(pin.kind),
      fallbackIconSize: iconSize,
      colorScheme: colorScheme,
    );
  }
  if (pin.source == 'local') {
    return LocalLibraryArtworkBuilder(
      coverPath: pin.cover,
      filePath: pin.coverFile,
      builder: (context, cover) => cover == null
          ? fallback
          : PlayerArtwork(
              artUri: cover,
              colorScheme: colorScheme,
              cacheWidth: cacheWidth,
              iconSize: iconSize,
            ),
    );
  }
  final cover = pin.cover;
  if (cover == null) return fallback;
  return PlayerArtwork(
    artUri: cover,
    colorScheme: colorScheme,
    cacheWidth: cacheWidth,
    iconSize: iconSize,
    songFile: pin.coverFile,
  );
}

/// Opens the pinned album, playlist, artist, genre or folder as the Library
/// does. A target that is gone says so and offers to unpin.
Future<void> _openHomePin(
  BuildContext context,
  WidgetRef ref,
  HomePin pin,
) async {
  final l10n = context.l10n;
  final pins = ref.read(homePinsProvider.notifier);
  final exists = await ref.read(homePinTargetExistsProvider)(pin);
  if (!context.mounted) return;
  if (!exists) {
    showAppSnackBar(
      context,
      content: Text(l10n.homePinMissing),
      action: SnackBarAction(
        label: l10n.homePinUnpin,
        onPressed: () => pins.remove(pin.key),
      ),
    );
    return;
  }
  final Widget screen;
  switch (pin.kind) {
    case HomePinKind.album when pin.source == 'local':
      screen = LocalAlbumScreen(
        albumName: pin.title,
        artistName: pin.subtitle,
        coverPath: pin.cover,
        loadTracks: () async => [
          for (final row
              in await LibraryDatabase.instance.getQueueLocalAlbumTracksByKey(
                pin.id,
              ))
            LocalLibraryItem.fromJson(row),
        ],
      );
    case HomePinKind.album:
      screen = DownloadedAlbumScreen(
        albumName: pin.title,
        artistName: pin.subtitle,
        coverUrl: pin.cover,
      );
    case HomePinKind.playlist:
      screen = LibraryTracksFolderScreen(
        mode: LibraryTracksFolderMode.playlist,
        playlistId: pin.id,
      );
    case HomePinKind.loved:
      screen = const LibraryTracksFolderScreen(
        mode: LibraryTracksFolderMode.loved,
      );
    case HomePinKind.artist:
      screen = LibraryArtistScreen(artist: pin.title);
    case HomePinKind.genre:
      // The genre's own entry counts its songs while they load.
      final genres = await ref
          .read(libraryGenresProvider.future)
          .catchError((Object _) => const <LibraryBrowseEntry>[]);
      if (!context.mounted) return;
      screen = LibraryMixScreen.genre(
        genre:
            genres.where((genre) => genre.key == pin.id).firstOrNull ??
            LibraryBrowseEntry(
              source: pin.source ?? '',
              key: pin.id,
              name: pin.title,
              artist: '',
              cover: pin.cover,
              samplePath: pin.coverFile ?? '',
              trackCount: 0,
            ),
      );
    case HomePinKind.folder:
      screen = LibraryDirectoryScreen(folderKey: pin.id);
  }
  await pushPage<void>(context, (_) => screen);
}

/// A pin's menu on Home: Move to front and Unpin, then [more] in a group
/// of its own.
void _showHomePinMenu(
  BuildContext context,
  WidgetRef ref,
  HomePin pin,
  Offset position, {
  List<ContextMenuAction> more = const [],
}) {
  final l10n = context.l10n;
  // Read up front: unpinning removes the tile that opened the menu.
  final pins = ref.read(homePinsProvider.notifier);
  final first = ref.read(homePinsProvider).firstOrNull == pin;
  showContextMenu(
    context,
    position: position,
    groups: [
      [
        ContextMenuAction(
          icon: Icons.vertical_align_top,
          label: l10n.homePinMoveToFront,
          onSelected: first ? null : () => pins.moveToFront(pin.key),
        ),
        ContextMenuAction(
          icon: Icons.push_pin,
          label: l10n.homePinUnpin,
          onSelected: () => pins.remove(pin.key),
        ),
      ],
      if (more.isNotEmpty) more,
    ],
  );
}

/// A pin among the Material Home's shortcuts: the same tile, with the
/// pin's cover where a shortcut has its icon.
class _HomePinShortcutTile extends ConsumerWidget {
  const _HomePinShortcutTile({
    required this.pin,
    required this.layout,
    this.more,
  });

  final HomePin pin;
  final _HomeShortcutsLayout layout;

  /// Menu rows beyond the pin's own, read when the menu opens.
  final List<ContextMenuAction> Function()? more;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final shown = _homePinShown(context, ref, pin);
    final badge = _HomeIconBadge(
      icon: _homePinIcon(pin.kind),
      color: colorScheme.secondaryContainer,
      onColor: colorScheme.onSecondaryContainer,
    );
    final artwork = SizedBox.square(
      dimension: 40,
      child: _homePinArtwork(context, shown, 40, fallback: badge),
    );
    return _HomeShortcutTile(
      label: shown.title,
      icon: _homePinIcon(pin.kind),
      leading: shown.cover == null && shown.coverFile == null
          ? badge
          : pin.kind == HomePinKind.artist
          ? ClipOval(child: artwork)
          : ClipRRect(borderRadius: BorderRadius.circular(10), child: artwork),
      container: colorScheme.surfaceContainerHigh,
      onContainer: colorScheme.onSurface,
      badge: colorScheme.secondaryContainer,
      onBadge: colorScheme.onSecondaryContainer,
      onTap: () => _openHomePin(context, ref, pin),
      onMenu: (position) => _showHomePinMenu(
        context,
        ref,
        pin,
        position,
        more: more?.call() ?? const [],
      ),
      layout: layout,
      position: (index: 0, count: 1),
    );
  }
}

/// A pin on the Mornye shelf: its cover, name and kind.
class _HomePinShelfTile extends ConsumerWidget {
  const _HomePinShelfTile({required this.pin, required this.size});

  final HomePin pin;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final shown = _homePinShown(context, ref, pin);
    final subtitle = _homePinSubtitle(context.l10n, shown);
    final artwork = _homePinArtwork(
      context,
      shown,
      size,
      fallback: ColoredBox(
        color: colorScheme.surfaceContainerHighest,
        child: Center(
          child: AppIcon.adaptive(
            _homePinIcon(pin.kind),
            size: math.min(size * 0.3, 48),
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
    void showMenu(Offset position) =>
        _showHomePinMenu(context, ref, pin, position);
    return DesktopContextMenuRegion(
      onContextMenu: showMenu,
      child: _HomeShelfTile(
        size: size,
        title: shown.title,
        subtitle: subtitle,
        semanticLabel: subtitle.isEmpty
            ? shown.title
            : '${shown.title}, $subtitle',
        cover: pin.kind == HomePinKind.artist
            ? ClipOval(child: artwork)
            : artwork,
        onTap: () => _openHomePin(context, ref, pin),
        onLongPress: () {
          final origin = contextMenuOriginOf(context);
          if (origin != null) showMenu(origin);
        },
      ),
    );
  }
}

/// What the person pinned: a shelf on Mornye, and on the Material desktop,
/// where Shortcuts keep their fixed row, rows of shortcut tiles.
class _HomePinsSection extends ConsumerWidget {
  const _HomePinsSection({required this.inset});

  final double inset;

  static bool hasContent(WidgetRef ref) =>
      ref.watch(homePinsProvider.select((pins) => pins.isNotEmpty));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pins = ref.watch(homePinsProvider);
    if (!context.isMornye) {
      return _HomeSection(
        title: context.l10n.homePinned,
        inset: inset,
        child: Column(
          children: [
            for (
              var row = 0;
              row < pins.length;
              row += HomeShortcut.slotCount
            ) ...[
              if (row > 0) const SizedBox(height: 8),
              // A label that wraps keeps its neighbors the same height.
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (
                      var slot = 0;
                      slot < HomeShortcut.slotCount;
                      slot++
                    ) ...[
                      if (slot > 0) const SizedBox(width: 8),
                      Expanded(
                        child: row + slot < pins.length
                            ? _HomePinShortcutTile(
                                pin: pins[row + slot],
                                layout: _HomeShortcutsLayout.row,
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      );
    }
    final shelfInset = inset + 8;
    return _HomeSection(
      title: context.l10n.homePinned,
      inset: inset,
      shelf: true,
      child: _HomeShelfSize(
        inset: shelfInset,
        builder: (context, coverSize) => _HomeShelf(
          inset: shelfInset,
          coverSize: coverSize,
          itemCount: pins.length,
          itemBuilder: (context, index) =>
              _HomePinShelfTile(pin: pins[index], size: coverSize),
        ),
      ),
    );
  }
}
