import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/audio_quality_badges.dart';

/// File metadata can arrive after playback starts without rebuilding the layout.
class PlayerMetadataTitle extends StatelessWidget {
  const PlayerMetadataTitle({
    super.key,
    required this.mediaItem,
    required this.metadata,
    this.style,
    this.textAlign,
    this.maxLines,
  });

  final MediaItem mediaItem;
  final PlayerMetadataController metadata;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: metadata,
    builder: (context, _) {
      final source = mediaItem.extras?['source']?.toString();
      final loaded = source == metadata.source ? metadata.metadata : null;
      return ExplicitTrackTitle(
        title: mediaItem.title,
        explicit:
            parseExplicitFlag(loaded?['explicit']) ??
            parseExplicitFlag(mediaItem.extras?['explicit']) ??
            false,
        style: style,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
      );
    },
  );
}
