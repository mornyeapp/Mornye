import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';

/// Whether the scanned Library is included, watching what changes the
/// Library's songs: downloads, the scanned Library and its switch.
bool _watchLibrary(Ref ref) {
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

/// The genres of [rows] from [LibraryDatabase.getGenreSpellings], in their
/// order: each under its most common spelling, counting the songs of every
/// spelling, with the cover of the first spelling that has one.
List<LibraryBrowseEntry> libraryGenresFromRows(
  Iterable<Map<String, Object?>> rows,
) {
  final genres = <String, LibraryBrowseEntry>{};
  for (final row in rows) {
    final key = row['genre_key'] as String? ?? '';
    if (key.isEmpty) continue;
    final cover = row['cover_path'] as String? ?? row['cover_url'] as String?;
    final samplePath = row['sample_file_path'] as String? ?? '';
    final count = (row['track_count'] as num?)?.toInt() ?? 0;
    final known = genres[key];
    final takesCover = known?.cover == null && cover != null;
    genres[key] = LibraryBrowseEntry(
      source: '',
      key: key,
      name: known?.name ?? row['genre_name'] as String? ?? key,
      artist: '',
      cover: takesCover ? cover : known?.cover,
      samplePath: takesCover ? samplePath : known?.samplePath ?? samplePath,
      trackCount: (known?.trackCount ?? 0) + count,
    );
  }
  return genres.values.toList(growable: false);
}

/// The Library's genres by name, from one grouped query. Rebuilt when the
/// Library's songs change.
final libraryGenresProvider =
    FutureProvider.autoDispose<List<LibraryBrowseEntry>>((ref) async {
      final includeLocal = _watchLibrary(ref);
      return libraryGenresFromRows(
        await LibraryDatabase.instance.getGenreSpellings(
          includeLocal: includeLocal,
        ),
      );
    });

/// The songs of the genre with the given key, by title, read in bounded
/// pages of the Songs list's query.
final libraryGenreSongsProvider = FutureProvider.autoDispose
    .family<List<UnifiedLibraryItem>, String>((ref, genre) async {
      final includeLocal = _watchLibrary(ref);
      const pageSize = 1000;
      final songs = <UnifiedLibraryItem>[];
      QueueLibraryDbCursor? cursor;
      for (var offset = 0; ; offset += pageSize) {
        final page = await LibraryDatabase.instance.getQueueTrackPageResult(
          QueueLibraryDbQuery(
            genre: genre,
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
    });
