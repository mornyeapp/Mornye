import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/collection_track_sort_provider.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';

/// Picks how a playlist, Liked Songs or the Wishlist lists its songs, for
/// the header. The choice is kept for the collection named [sortKey].
class CollectionTrackSortButton extends ConsumerWidget {
  const CollectionTrackSortButton({super.key, required this.sortKey});

  final String sortKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final current = ref.watch(
      collectionTrackSortsProvider.select(
        (sorts) => sorts[sortKey] ?? CollectionTrackSort.custom,
      ),
    );
    ContextMenuAction action(
      CollectionTrackSort sort,
      IconData icon,
      String label,
    ) => ContextMenuAction(
      icon: icon,
      label: label,
      checked: current == sort,
      onSelected: () => ref
          .read(collectionTrackSortsProvider.notifier)
          .setSort(sortKey, sort),
    );
    return HeaderCircleButton(
      icon: Icons.sort,
      tooltip: l10n.albumSortSongs,
      onPressed: () => showContextMenu(
        context,
        position:
            contextMenuPositionBelow(context) ??
            contextMenuOriginOf(context) ??
            Offset.zero,
        origin: contextMenuOriginOf(context),
        groups: [
          [
            action(
              CollectionTrackSort.custom,
              Icons.swap_vert,
              l10n.albumSortCustom,
            ),
          ],
          [
            action(
              CollectionTrackSort.title,
              Icons.sort_by_alpha,
              l10n.searchSortTitleAZ,
            ),
            action(
              CollectionTrackSort.artist,
              Icons.person_outline,
              l10n.searchSortArtistAZ,
            ),
            action(
              CollectionTrackSort.album,
              Icons.album_outlined,
              l10n.libraryFilterSortAlbumAsc,
            ),
            action(
              CollectionTrackSort.latest,
              Icons.schedule,
              l10n.libraryFilterSortLatest,
            ),
          ],
        ],
      ),
    );
  }
}
