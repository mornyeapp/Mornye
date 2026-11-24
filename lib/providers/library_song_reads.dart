import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';

/// Whether the scanned Library is included, watching what changes the
/// Library's songs: downloads, the scanned Library and its switch.
bool watchLibrarySongs(Ref ref) {
  ref.watch(
    downloadHistoryProvider.select((state) => state.loadedIndexVersion),
  );
  final includeLocal = ref.watch(
    settingsProvider.select((s) => s.localLibraryEnabled),
  );
  if (includeLocal) {
    ref.watch(localLibraryProvider.select((state) => state.loadedIndexVersion));
  }
  return includeLocal;
}

/// Every song the Songs list's query finds with one filter, by title, read
/// in bounded pages.
Future<List<UnifiedLibraryItem>> readLibrarySongs({
  required bool includeLocal,
  List<String>? genreTags,
  String? creditedArtist,
}) async {
  const pageSize = 1000;
  final songs = <UnifiedLibraryItem>[];
  QueueLibraryDbCursor? cursor;
  for (var offset = 0; ; offset += pageSize) {
    final page = await LibraryDatabase.instance.getQueueTrackPageResult(
      QueueLibraryDbQuery(
        genreTags: genreTags,
        creditedArtist: creditedArtist,
        sortMode: 'a-z',
        includeLocal: includeLocal,
        limit: pageSize,
        offset: offset,
        cursor: cursor,
      ),
    );
    for (final row in page.rows) {
      final json = Map<String, dynamic>.from(row['item'] as Map);
      switch (row['source']) {
        case 'local':
          songs.add(
            UnifiedLibraryItem.fromLocalLibrary(
              LocalLibraryItem.fromJson(json),
            ),
          );
        case 'downloaded':
          songs.add(
            UnifiedLibraryItem.fromDownloadHistory(
              DownloadHistoryItem.fromJson(json),
            ),
          );
      }
    }
    if (page.rows.length < pageSize || page.nextCursor == null) break;
    cursor = page.nextCursor;
  }
  return songs;
}
