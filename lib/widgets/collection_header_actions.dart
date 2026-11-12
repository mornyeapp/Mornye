import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/expressive_button_group.dart';

/// Love all, download all and add to playlist buttons of a track collection
/// header, laid out for desktop, Mornye or Material. All three are disabled
/// while [tracks] is empty.
class CollectionHeaderActions extends StatelessWidget {
  const CollectionHeaderActions({
    super.key,
    required this.tracks,
    required this.onLoveAll,
    this.onPlayOnline,
    required this.downloadIcon,
    required this.onDownloadAll,
    required this.addToPlaylistIcon,
    required this.onAddToPlaylist,
    this.tonalDownload = false,
  });

  final List<Track> tracks;
  final VoidCallback onLoveAll;
  final VoidCallback? onPlayOnline;

  /// The Material download glyph; Mornye uses its filled arrow.
  final IconData downloadIcon;
  final VoidCallback onDownloadAll;
  final bool tonalDownload;
  final IconData addToPlaylistIcon;
  final VoidCallback onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    final enabled = tracks.isNotEmpty;
    final mornye = context.isMornye;
    final love = Consumer(
      builder: (context, ref, _) {
        ref.watch(libraryCollectionsProvider.select((state) => state.loved));
        final collectionsState = ref.read(libraryCollectionsProvider);
        final allLoved =
            enabled && tracks.every((t) => collectionsState.isLoved(t));
        return HeaderCircleButton(
          icon: allLoved ? Icons.favorite : Icons.favorite_border,
          tonal: true,
          iconColor: allLoved ? Theme.of(context).colorScheme.error : null,
          tooltip: allLoved
              ? context.l10n.trackOptionRemoveFromLoved
              : context.l10n.tooltipLoveAll,
          onPressed: enabled ? onLoveAll : null,
        );
      },
    );
    final play = onPlayOnline == null
        ? null
        : HeaderCircleButton(
            icon: Icons.play_circle_fill_rounded,
            tonal: true,
            tooltip: 'Play album / playlist online',
            onPressed: enabled ? onPlayOnline : null,
          );
    final download = HeaderFilledButton(
      icon: mornye ? CupertinoIcons.arrow_down_circle_fill : downloadIcon,
      tonal: tonalDownload,
      label: mornye
          ? context.l10n.dialogDownload
          : context.l10n.downloadAllCount(tracks.length),
      onPressed: enabled ? onDownloadAll : null,
    );
    final addToPlaylist = HeaderCircleButton(
      icon: addToPlaylistIcon,
      tonal: true,
      tooltip: context.l10n.tooltipAddToPlaylist,
      onPressed: enabled ? onAddToPlaylist : null,
    );
    if (isDesktopPlatform) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 10,
        children: [love, if (play != null) play, download, addToPlaylist],
      );
    }
    if (mornye) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          love,
          const SizedBox(width: 8),
          if (play != null) ...[play, const SizedBox(width: 8)],
          Flexible(child: SizedBox(width: 144, child: download)),
          const SizedBox(width: 8),
          addToPlaylist,
        ],
      );
    }
    return ExpressiveButtonGroup(
      flexible: play == null ? const {1} : const {2},
      children: [love, if (play != null) play, download, addToPlaylist],
    );
  }
}
