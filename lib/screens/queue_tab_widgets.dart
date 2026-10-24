part of 'queue_tab.dart';

class _QueueItemSliverRow extends ConsumerWidget {
  final String itemId;
  final ColorScheme colorScheme;
  final Widget Function(BuildContext, DownloadItem, ColorScheme) itemBuilder;

  const _QueueItemSliverRow({
    super.key,
    required this.itemId,
    required this.colorScheme,
    required this.itemBuilder,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(
      downloadQueueLookupProvider.select((lookup) => lookup.byItemId[itemId]),
    );
    if (item == null) {
      return const SizedBox.shrink();
    }

    return RepaintBoundary(child: itemBuilder(context, item, colorScheme));
  }
}

enum _CollectionEntryType { wishlist, loved, favoriteArtists, playlist }

class _CollectionEntry {
  final _CollectionEntryType type;
  final int playlistIndex;

  const _CollectionEntry._(this.type, [this.playlistIndex = -1]);

  static const wishlist = _CollectionEntry._(_CollectionEntryType.wishlist);
  static const loved = _CollectionEntry._(_CollectionEntryType.loved);
  static const favoriteArtists = _CollectionEntry._(
    _CollectionEntryType.favoriteArtists,
  );
  static _CollectionEntry playlist(int index) =>
      _CollectionEntry._(_CollectionEntryType.playlist, index);
}

/// Library page switcher on Material: primary tabs, since the pages are
/// views of one collection rather than filters. Counts trail each label.
class _LibraryPageTabs extends StatefulWidget {
  const _LibraryPageTabs({
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
  });

  /// Label and item count per page; a null count is hidden.
  final List<(String, int?)> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  State<_LibraryPageTabs> createState() => _LibraryPageTabsState();
}

class _LibraryPageTabsState extends State<_LibraryPageTabs>
    with SingleTickerProviderStateMixin {
  late final TabController _controller = TabController(
    length: widget.tabs.length,
    initialIndex: widget.selectedIndex,
    vsync: this,
  );

  @override
  void didUpdateWidget(covariant _LibraryPageTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedIndex != _controller.index) {
      _controller.animateTo(widget.selectedIndex);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Inherits the tab's label color, so the count follows the selection.
    const countStyle = TextStyle(fontWeight: FontWeight.w400);
    return TabBar(
      controller: _controller,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      onTap: widget.onSelected,
      tabs: [
        for (final (label, count) in widget.tabs)
          Tab(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label),
                if (count != null) ...[
                  const SizedBox(width: 6),
                  Text('$count', style: countStyle),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
