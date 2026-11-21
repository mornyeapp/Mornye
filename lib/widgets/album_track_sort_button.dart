import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/album_track_sort_provider.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/scaled_drag_proxy.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Picks how a Library album orders its songs, for the header. [songs] are
/// the album's titles as the page shows them.
class AlbumTrackSortButton extends ConsumerWidget {
  const AlbumTrackSortButton({
    super.key,
    required this.albumKey,
    required this.songs,
  });

  final AlbumTrackSortKey albumKey;
  final List<String> songs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final choices = ref.read(albumTrackChoicesProvider.notifier);
    final sort = ref.watch(
      albumTrackChoicesProvider.select(
        (all) => albumTrackChoiceIn(all, albumKey).sort,
      ),
    );
    void pick(AlbumTrackSort next) => choices.setSort(albumKey, next);
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
            ContextMenuAction(
              icon: Icons.format_list_numbered,
              label: l10n.albumSortAlbumOrder,
              checked: sort == AlbumTrackSort.album,
              onSelected: () => pick(AlbumTrackSort.album),
            ),
            ContextMenuAction(
              icon: Icons.trending_up,
              label: l10n.albumSortMostPlayed,
              checked: sort == AlbumTrackSort.mostPlayed,
              onSelected: () => pick(AlbumTrackSort.mostPlayed),
            ),
            ContextMenuAction(
              icon: Icons.swap_vert,
              label: l10n.albumSortCustom,
              checked: sort == AlbumTrackSort.custom,
              onSelected: () => _editCustomOrder(context),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _editCustomOrder(BuildContext context) {
    final navigator = Navigator.of(context, rootNavigator: true);
    return showAppScrollableBottomSheet<void>(
      context: navigator.context,
      title: context.l10n.albumSortCustom,
      builder: (sheetContext, controller) => _CustomOrderList(
        albumKey: albumKey,
        songs: songs,
        controller: controller,
      ),
    );
  }
}

/// The album's songs with drag handles. Every drop applies at once, so the
/// sheet has nothing to save.
class _CustomOrderList extends ConsumerStatefulWidget {
  const _CustomOrderList({
    required this.albumKey,
    required this.songs,
    required this.controller,
  });

  final AlbumTrackSortKey albumKey;
  final List<String> songs;
  final ScrollController controller;

  @override
  ConsumerState<_CustomOrderList> createState() => _CustomOrderListState();
}

class _CustomOrderListState extends ConsumerState<_CustomOrderList> {
  // Numbered, since an album can repeat a title.
  late final _songs = widget.songs.indexed.toList();

  void _apply() => ref.read(albumTrackChoicesProvider.notifier).setCustom(
    widget.albumKey,
    [for (final (_, song) in _songs) song],
  );

  void _move(int from, int to) {
    setState(() {
      _songs.insert(to, _songs.removeAt(from));
    });
    _apply();
  }

  @override
  void initState() {
    super.initState();
    // Opening the sheet selects the order it shows.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _apply();
    });
  }

  @override
  Widget build(BuildContext context) => ReorderableListView.builder(
    scrollController: widget.controller,
    buildDefaultDragHandles: false,
    padding: const EdgeInsets.only(bottom: 16),
    itemCount: _songs.length,
    onReorderItem: _move,
    // The list's own lift, inside the proxy that follows a scaled page.
    proxyDecorator: (child, index, animation) => ScaledDragProxy(
      animation: animation,
      child: AnimatedBuilder(
        animation: animation,
        child: child,
        builder: (context, child) => Material(
          elevation: 6 * Curves.easeInOut.transform(animation.value),
          child: child,
        ),
      ),
    ),
    itemBuilder: (context, index) => ConnectedGroupRow(
      key: ValueKey('album-order-${_songs[index].$1}'),
      index: index,
      count: _songs.length,
      child: ListTile(
        title: Text(
          _songs[index].$2,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: ReorderableDragStartListener(
          index: index,
          child: const SizedBox.square(
            dimension: 44,
            child: AppIcon(Icons.drag_handle),
          ),
        ),
      ),
    ),
  );
}
