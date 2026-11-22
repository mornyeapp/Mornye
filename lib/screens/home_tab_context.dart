part of 'home_tab.dart';

/// What the Home situation sections read last, so a reload that finds the
/// same albums keeps the same list.
class _HomeContextMemo {
  List<LibraryBrowseEntry>? hiResAlbums;
}

final _homeContextMemoProvider = Provider<_HomeContextMemo>(
  (ref) => _HomeContextMemo(),
);

/// Albums that pass the Library's Hi-Res filter, picked anew each day as
/// the From your Library shelf picks its albums.
final homeHiResAlbumsProvider =
    FutureProvider.autoDispose<List<LibraryBrowseEntry>>((ref) async {
      final includeLocal = ref.watch(
        settingsProvider.select((s) => s.localLibraryEnabled),
      );
      ref.watch(downloadHistoryProvider.select((s) => s.loadedIndexVersion));
      if (includeLocal) ref.watch(localLibraryIndexRevisionProvider);
      final memo = ref.read(_homeContextMemoProvider);
      final counts = await ref.watch(
        libraryCountsProvider(
          homeHiResCountsRequest(includeLocal: includeLocal),
        ).future,
      );
      final day = listeningDay(DateTime.now());
      final page = await LibraryDatabase.instance.getQueueAlbumPageResult(
        homeHiResAlbumQuery(
          includeLocal: includeLocal,
          limit: _homeAlbumPool,
          offset: homeLibraryAlbumPoolOffset(counts.albumCount, day),
        ),
      );
      final albums = homeLibraryAlbumPicks(
        [
          for (final row in page.rows)
            LibraryBrowseEntry.fromRow(row, isArtist: false),
        ],
        day: day,
        limit: homeHiResShelfLimit,
      );
      final last = memo.hiResAlbums;
      if (last != null && _sameAlbums(last, albums)) return last;
      return memo.hiResAlbums = albums;
    });

/// The person's Hi-Res albums while a DAC or an exclusive hi-res output
/// plays; absent otherwise.
class _HomeHiResSection extends ConsumerWidget {
  const _HomeHiResSection({required this.inset});

  final double inset;

  /// The albums are read only while such an output plays.
  static bool hasContent(WidgetRef ref) =>
      ref.watch(homeHiResOutputProvider) &&
      ref.watch(
        homeHiResAlbumsProvider.select((s) => s.value?.isNotEmpty ?? false),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) => _HomeSection(
    title: context.l10n.homeHiResInYourLibrary,
    inset: inset,
    shelf: true,
    child: _HomeLibraryAlbumsShelf(
      albums:
          ref.watch(homeHiResAlbumsProvider.select((s) => s.value)) ?? const [],
      inset: context.isMornye ? inset + 8 : inset,
    ),
  );
}

/// One row naming the attached Link device, opening its Devices sheet;
/// absent while none is attached.
class _HomeLinkSection extends ConsumerWidget {
  const _HomeLinkSection({required this.inset});

  final double inset;

  static bool hasContent(WidgetRef ref) =>
      ref.watch(homeLinkDeviceProvider) != null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final device = ref.watch(homeLinkDeviceProvider);
    if (device == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: inset),
      child: SettingsGroup(
        margin: EdgeInsets.zero,
        children: [
          SettingsItem(
            key: const ValueKey('home-link-device'),
            icon: device.phone ? Icons.phone_android : Icons.computer,
            showIconInMornye: true,
            title: device.count > 1
                ? l10n.homeLinkConnectedDevices(device.count)
                : l10n.homeLinkConnectedTo(device.name),
            showDivider: false,
            onTap: () => _open(context, device),
          ),
        ],
      ),
    );
  }

  /// A phone host has no Devices sheet; its phones are on the Link page.
  void _open(BuildContext context, HomeLinkDevice device) {
    if (!device.hosting) {
      unawaited(showLinkDevicesSheet(context));
    } else if (isDesktopPlatform) {
      unawaited(showDesktopLinkDevicesSheet(context));
    } else {
      unawaited(pushPage<void>(context, (_) => const LinkSettingsPage()));
    }
  }
}
