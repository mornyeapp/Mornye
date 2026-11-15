import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/isrc_utils.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/mornye_player_details_sheet.dart';
import 'package:mornye/widgets/settings_group.dart';

Future<void> showPlayerDetailsSheet(
  BuildContext context,
  ColorScheme colorScheme, {
  required PlayerMetadataController metadata,
  required MediaItem? mediaItem,
}) {
  final fallback = metadata.detailsSnapshot(mediaItem);
  final metadataFuture = metadata.readDetails(mediaItem);
  Widget details(ScrollController scrollController) =>
      FutureBuilder<Map<String, dynamic>>(
        future: metadataFuture,
        initialData: fallback,
        builder: (context, snapshot) => _MetadataList(
          meta: snapshot.data ?? fallback,
          colorScheme: colorScheme,
          scrollController: scrollController,
          mediaItem: mediaItem,
        ),
      );
  if (!context.isMornye) {
    // The shared sheet supplies the handle, shape and header on phones, and
    // opens as a desktop dialog.
    final item = mediaItem;
    final subtitle = [
      item?.title,
      item?.artist,
    ].whereType<String>().where((part) => part.trim().isNotEmpty).join(' · ');
    return showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.nowPlayingDetails,
      subtitle: subtitle.isEmpty ? null : subtitle,
      builder: (context, scrollController) => details(scrollController),
    );
  }
  // The Mornye details draw their own glass, handle and header.
  if (isDesktopPlatform) {
    return showAppSheetDialog<void>(
      context: context,
      isScrollControlled: true,
      mornyeGlass: false,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 1,
        minChildSize: 1,
        builder: (context, scrollController) => details(scrollController),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    sheetAnimationStyle: AppMotion.surfaceEntrance(context),
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.9,
      minChildSize: 0.4,
      builder: (context, scrollController) => details(scrollController),
    ),
  );
}

class _MetadataList extends StatelessWidget {
  final Map<String, dynamic> meta;
  final ColorScheme colorScheme;
  final ScrollController scrollController;
  final MediaItem? mediaItem;

  const _MetadataList({
    required this.meta,
    required this.colorScheme,
    required this.scrollController,
    this.mediaItem,
  });

  @override
  Widget build(BuildContext context) {
    String s(Object? v) => (v ?? '').toString();
    final l10n = context.l10n;
    final rows = <(String, String)>[
      (l10n.editMetadataFieldTitle, s(meta['title'])),
      (l10n.editMetadataFieldArtist, s(meta['artist'])),
      (l10n.editMetadataFieldAlbum, s(meta['album'])),
      (l10n.editMetadataFieldAlbumArtist, s(meta['album_artist'])),
      (l10n.editMetadataFieldGenre, s(meta['genre'])),
      (l10n.editMetadataFieldComposer, s(meta['composer'])),
      (l10n.editMetadataFieldDate, s(meta['date'])),
      (l10n.editMetadataFieldTrackNum, s(meta['track_number'])),
      (l10n.editMetadataFieldDiscNum, s(meta['disc_number'])),
      (l10n.editMetadataFieldIsrc, formatIsrcForDisplay(s(meta['isrc']))),
      (l10n.editMetadataFieldLabel, s(meta['label'])),
      (l10n.editMetadataFieldCopyright, s(meta['copyright'])),
      (l10n.libraryFilterFormat, s(meta['format']).toUpperCase()),
      (l10n.audioAnalysisCodec, s(meta['audio_codec'])),
      (
        l10n.audioAnalysisSampleRate,
        meta['sample_rate'] != null && (meta['sample_rate'] as num? ?? 0) > 0
            ? '${((meta['sample_rate'] as num) / 1000).toStringAsFixed(1)} kHz'
            : '',
      ),
      (
        l10n.audioAnalysisBitDepth,
        (meta['bit_depth'] as num? ?? 0) > 0 ? '${meta['bit_depth']}-bit' : '',
      ),
    ].where((r) => r.$2.trim().isNotEmpty && r.$2 != '0').toList();

    if (context.isMornye) {
      return MornyePlayerDetailsSheet(
        rows: rows,
        scrollController: scrollController,
        mediaItem: mediaItem,
      );
    }

    final textTheme = Theme.of(context).textTheme;
    final tokens = context.tokens;

    // The sheet header names the track, so the rows sit in one group below
    // it instead of a titled card.
    return ListView(
      controller: scrollController,
      padding: EdgeInsets.only(top: tokens.gapXs, bottom: tokens.gapXl),
      children: [
        if (rows.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.gapXl),
            child: Text(
              l10n.nowPlayingNoMetadata,
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          SettingsGroup(
            connected: true,
            children: [
              for (final (label, value) in rows)
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: tokens.rowPaddingH,
                    vertical: tokens.rowPaddingVCompact,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      SizedBox(
                        width: 100,
                        child: Text(
                          label,
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      SizedBox(width: tokens.gapSm),
                      Expanded(
                        child: Text(
                          value,
                          style: textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
