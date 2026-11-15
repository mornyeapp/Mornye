import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_playlist_search.dart';
import 'package:mornye/services/library_search.dart';

typedef LibrarySearchRequest = ({
  String query,
  LibrarySearchKind kind,
  int limit,
  int offset,
});

/// Resolve the selected record by its source and ID, without matching titles
/// that may also belong to another edition or remix.
final librarySearchTrackProvider = FutureProvider.autoDispose
    .family<UnifiedLibraryItem?, ({String source, String id})>((
      ref,
      key,
    ) async {
      if (key.source == 'local') {
        final row = await LibraryDatabase.instance.getById(key.id);
        return row == null
            ? null
            : UnifiedLibraryItem.fromLocalLibrary(
                LocalLibraryItem.fromJson(row),
              );
      }
      final row = await HistoryDatabase.instance.getById(key.id);
      return row == null
          ? null
          : UnifiedLibraryItem.fromDownloadHistory(
              DownloadHistoryItem.fromJson(row),
            );
    });

final librarySearchProvider = FutureProvider.autoDispose
    .family<List<LibrarySearchHit>, LibrarySearchRequest>((ref, request) async {
      final query = LibrarySearchQuery(request.query);
      if (query.terms.isEmpty) return const [];
      if (request.kind == LibrarySearchKind.playlists) {
        final playlists = ref.watch(
          libraryCollectionsProvider.select((state) => state.playlists),
        );
        return searchLibraryPlaylists(
          playlists: playlists,
          query: request.query,
          limit: request.limit,
          offset: request.offset,
        );
      }
      final includeLocal = ref.watch(
        settingsProvider.select((s) => s.localLibraryEnabled),
      );
      ref.watch(downloadHistoryProvider.select((s) => s.loadedIndexVersion));
      if (includeLocal) {
        ref.watch(localLibraryProvider.select((s) => s.loadedIndexVersion));
      }
      return LibraryDatabase.instance.searchLibrary(
        query: request.query,
        kind: request.kind,
        includeLocal: includeLocal,
        limit: request.limit,
        offset: request.offset,
      );
    });

/// The Library list a song played from a Library search continues into:
/// the list's mode, sort and filters, without the search text.
typedef LibrarySongListRequest = ({
  String filterMode,
  String sortMode,
  String? source,
  String? quality,
  String? format,
  String? metadata,
  bool includeLocal,
});

/// Every song of a Library list in its order, through the same queries
/// the list pages with. Read once when a search result plays, never while
/// the search is typed.
final librarySongListProvider = FutureProvider.autoDispose
    .family<List<UnifiedLibraryItem>, LibrarySongListRequest>((
      ref,
      request,
    ) async {
      const pageSize = 1000;
      final songs = <UnifiedLibraryItem>[];
      QueueLibraryDbCursor? cursor;
      for (var offset = 0; ; offset += pageSize) {
        final page = await LibraryDatabase.instance.getQueueTrackPageResult(
          QueueLibraryDbQuery(
            limit: pageSize,
            offset: offset,
            filterMode: request.filterMode,
            searchQuery: '',
            source: request.source,
            quality: request.quality,
            format: request.format,
            metadata: request.metadata,
            sortMode: request.sortMode,
            includeLocal: request.includeLocal,
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
        if (page.rows.length < pageSize) break;
        cursor = page.nextCursor;
      }
      return songs;
    });

/// [item] in [request]'s list: the list's songs and the entry that is
/// [item], matched by record and then by file. A song the list's filters
/// leave out is placed in the whole Songs list in the same sort. Null when
/// the Library has no place for it, or when an external player opens one
/// file and needs no list.
Future<({List<UnifiedLibraryItem> songs, UnifiedLibraryItem item})?>
placeInLibrarySongList(
  WidgetRef ref,
  UnifiedLibraryItem item,
  LibrarySongListRequest request,
) async {
  if (ref.read(settingsProvider).playerMode != 'internal') return null;
  final LibrarySongListRequest whole = (
    filterMode: 'all',
    sortMode: request.sortMode,
    source: null,
    quality: null,
    format: null,
    metadata: null,
    includeLocal: request.includeLocal,
  );
  for (final list in {request, whole}) {
    final songs = await ref.read(librarySongListProvider(list).future);
    final path = item.filePath.trim();
    final match =
        songs.where((song) => song.id == item.id).firstOrNull ??
        (path.isEmpty
            ? null
            : songs.where((song) => song.filePath.trim() == path).firstOrNull);
    if (match != null) return (songs: songs, item: match);
  }
  return null;
}
