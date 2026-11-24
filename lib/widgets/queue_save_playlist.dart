import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/library_media_identity.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';

/// Offers the whole queue, in its order, to a new or an existing playlist.
/// Songs match their Library rows, as when the player adds one song.
Future<void> saveQueueAsPlaylist(BuildContext context, WidgetRef ref) async {
  final queue = ref.read(playQueueProvider).value ?? const <MediaItem>[];
  if (queue.isEmpty) return;
  final root = Navigator.of(context, rootNavigator: true).context;
  // A song the Library lookup fails for still goes in, from its own tags.
  final tracks = await Future.wait<Track>([
    for (final item in queue)
      ref
          .read(playerCollectionTrackProvider(item).future)
          .catchError(
            (Object _) => collectionTrackForMedia(
              item,
              null,
              covers: ref
                  .read(musicPlayerRuntimeProvider)
                  .dependencies
                  .coverStore,
            ),
          ),
  ]);
  if (!root.mounted) return;
  await showAddTracksToPlaylistSheet(root, ref, tracks);
}
