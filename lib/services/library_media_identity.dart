import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/library_database.dart';

/// The download or Library record of the file a media item plays: by its
/// source path, then by its media id, then by title and artist with the same
/// path. Null when the file has no record.
Future<UnifiedLibraryItem?> libraryItemForMedia({
  required String id,
  required String source,
  required String title,
  required String artist,
  required Future<DownloadHistoryItem?> Function(String path) historyByPath,
  required LibraryDatabase library,
}) async {
  if (source.isNotEmpty) {
    final history = await historyByPath(source);
    if (history != null) return UnifiedLibraryItem.fromDownloadHistory(history);
  }
  final row = await library.getById(id);
  if (row != null) {
    return UnifiedLibraryItem.fromLocalLibrary(LocalLibraryItem.fromJson(row));
  }
  if (source.isNotEmpty) {
    final matches = await library.findByTrackAndArtist(title, artist);
    for (final row in matches) {
      final local = LocalLibraryItem.fromJson(row);
      if (local.filePath == source) {
        return UnifiedLibraryItem.fromLocalLibrary(local);
      }
    }
  }
  return null;
}

/// The collection track that loves [item]: its Library record's identity
/// when it has one ([match]), otherwise the media item's own fields, with
/// no cover when the item shows one that does not outlast this run.
///
/// A network song keeps the network cover it shows, or shows once fetched,
/// as its reference (`extras['artworkRef']`), which [covers] fetches again
/// after a trim, rather than the stored file.
Track collectionTrackForMedia(
  MediaItem item,
  UnifiedLibraryItem? match, {
  CoverStore? covers,
}) =>
    match?.toTrack() ??
    Track(
      id: item.id,
      name: item.title,
      artistName: item.artist ?? '',
      albumName: item.album ?? '',
      coverUrl: _collectionCover(item, covers ?? CoverStore.instance),
      duration: item.duration?.inSeconds ?? 0,
      source: 'local',
    );

String? _collectionCover(MediaItem item, CoverStore covers) {
  final reference = item.extras?['artworkRef']?.toString();
  final shown = item.artUri;
  if (CoverStore.refetches(reference)) {
    // Unless the item shows another cover, such as the one from its tags.
    final stored = covers.indexedFile(reference);
    if (shown == null || (stored != null && shown == Uri.file(stored))) {
      return reference;
    }
  }
  return durableCoverReference(shown?.toString());
}
