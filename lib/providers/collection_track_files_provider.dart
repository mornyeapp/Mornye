import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/local_track_redownload_service.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/utils/file_access.dart';

/// Keeps one file lookup for an unchanged, ordered collection selection.
@immutable
class CollectionTrackFilesRequest {
  CollectionTrackFilesRequest(Iterable<Track> tracks)
    : tracks = List.unmodifiable(tracks);

  final List<Track> tracks;

  @override
  bool operator ==(Object other) =>
      other is CollectionTrackFilesRequest && listEquals(tracks, other.tracks);

  @override
  int get hashCode => Object.hashAll(tracks);
}

final collectionTrackFilesProvider = FutureProvider.autoDispose
    .family<List<PlayableMedia>, CollectionTrackFilesRequest>(
      (ref, request) => resolveCollectionTrackFiles(
        ref.watch(playbackProvider.notifier),
        request.tracks,
      ),
    );

/// The playable files of [tracks] that have a download or a local copy, in
/// order; tracks without one, and cue sheet entries, are left out.
Future<List<PlayableMedia>> resolveCollectionTrackFiles(
  PlaybackController playback,
  List<Track> tracks,
) async {
  final paths = await playback.resolveTrackFilePaths(tracks);
  return [
    for (var index = 0; index < tracks.length; index++)
      if (paths[index] case final path?)
        if (path.isNotEmpty && !isCueVirtualPath(path))
          playableFromTrack(tracks[index], path),
  ];
}

/// Uses scanned metadata so FLAC files behind opaque SAF URIs stay excluded.
final collectionTrackFlacCandidatesProvider = FutureProvider.autoDispose
    .family<List<LocalLibraryItem>, CollectionTrackFilesRequest>((
      ref,
      request,
    ) async {
      if (!ref.watch(settingsProvider.select((s) => s.localLibraryEnabled))) {
        return const [];
      }
      ref.watch(localLibraryIndexRevisionProvider);
      final items = await ref
          .read(localLibraryProvider.notifier)
          .findExistingBatchAsync([
            for (final track in request.tracks)
              LocalLibraryBatchLookupRequest(
                id: track.source?.toLowerCase() == 'local' ? track.id : null,
                isrc: track.isrc,
                trackName: track.name,
                artistName: track.artistName,
              ),
          ]);
      final seen = <String>{};
      return [
        for (final item in items)
          if (item != null &&
              LocalTrackRedownloadService.isFlacUpgradeEligible(item) &&
              seen.add(item.filePath))
            item,
      ];
    });
