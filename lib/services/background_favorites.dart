import 'dart:convert';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_media_identity.dart';

/// Loved songs for the media controls while the app shell is closed, such as
/// when a car starts playback. It reads and writes the same Loved collection
/// with the same Library identity as the shell, which takes over once open.
class BackgroundFavorites {
  BackgroundFavorites({
    required this.library,
    required this.history,
    required this.collections,
    this.covers,
  });

  final LibraryDatabase library;
  final HistoryDatabase history;
  final LibraryCollectionsDatabase collections;

  /// The player's cover store, which chose the covers media items show.
  final CoverStore? covers;

  Future<Track> _track(MediaItem item) async => collectionTrackForMedia(
    item,
    await libraryItemForMedia(
      id: item.id,
      source: item.extras?['source']?.toString() ?? '',
      title: item.title,
      artist: item.artist ?? '',
      historyByPath: (path) async {
        final row = await history.findByFilePath(path);
        return row == null ? null : DownloadHistoryItem.fromJson(row);
      },
      library: library,
    ),
    covers: covers,
  );

  Future<bool> isLoved(MediaItem item) async =>
      collections.containsLovedTrack(trackCollectionKey(await _track(item)));

  /// Loves [item], or stops loving it, and returns whether it is now loved.
  Future<bool> toggle(MediaItem item) async {
    final track = await _track(item);
    final key = trackCollectionKey(track);
    if (await collections.containsLovedTrack(key)) {
      await collections.deleteLovedEntry(key);
      return false;
    }
    await collections.upsertLovedEntry(
      trackKey: key,
      trackJson: jsonEncode(track.toJson()),
      addedAt: DateTime.now().toIso8601String(),
    );
    return true;
  }
}
