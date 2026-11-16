import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/library_song_reads.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/sqlite_helpers.dart' show normalizeLookupText;
import 'package:mornye/utils/genre_tags.dart';

class _Genre {
  final spellings = <String, int>{};
  int trackCount = 0;
  String? cover;
  String? samplePath;
}

/// The genres of [rows] from [LibraryDatabase.getGenreSpellings], by key.
/// A tag that lists several genres ([splitGenreTag], with the user's genre
/// [separator]) counts its songs under each. Every genre takes its most
/// common spelling and the cover of the first tag that has one.
List<LibraryBrowseEntry> libraryGenresFromRows(
  Iterable<Map<String, Object?>> rows, {
  String separator = '',
}) {
  final genres = <String, _Genre>{};
  for (final row in rows) {
    final cover = row['cover_path'] as String? ?? row['cover_url'] as String?;
    final samplePath = row['sample_file_path'] as String? ?? '';
    final count = (row['track_count'] as num?)?.toInt() ?? 0;
    final names = splitGenreTag(
      row['genre_name'] as String?,
      separator: separator,
    );
    for (final name in names) {
      final genre = genres.putIfAbsent(normalizeLookupText(name), _Genre.new);
      genre.spellings.update(name, (n) => n + count, ifAbsent: () => count);
      genre.trackCount += count;
      if (genre.cover == null && cover != null) {
        genre.cover = cover;
        genre.samplePath = samplePath;
      }
      genre.samplePath ??= samplePath;
    }
  }
  String name(_Genre genre) => genre.spellings.entries.reduce((best, next) {
    final order = next.value.compareTo(best.value);
    return order > 0 || (order == 0 && next.key.compareTo(best.key) < 0)
        ? next
        : best;
  }).key;
  return [
    for (final key in genres.keys.toList()..sort())
      LibraryBrowseEntry(
        source: '',
        key: key,
        name: name(genres[key]!),
        artist: '',
        cover: genres[key]!.cover,
        samplePath: genres[key]!.samplePath ?? '',
        trackCount: genres[key]!.trackCount,
      ),
  ];
}

/// For each genre key of [libraryGenresFromRows], the genre tags of [rows]
/// that list it, as the database compares them.
Map<String, List<String>> libraryGenreTagsFromRows(
  Iterable<Map<String, Object?>> rows, {
  String separator = '',
}) {
  final tags = <String, Set<String>>{};
  for (final row in rows) {
    final tag = row['genre_key'] as String? ?? '';
    if (tag.isEmpty) continue;
    final names = splitGenreTag(
      row['genre_name'] as String?,
      separator: separator,
    );
    for (final name in names) {
      tags.putIfAbsent(normalizeLookupText(name), () => {}).add(tag);
    }
  }
  return {for (final entry in tags.entries) entry.key: entry.value.toList()};
}

/// Each spelling of each genre tag, from one grouped query. Rebuilt when
/// the Library's songs change.
final _libraryGenreRowsProvider =
    FutureProvider.autoDispose<List<Map<String, Object?>>>((ref) {
      final includeLocal = watchLibrarySongs(ref);
      return LibraryDatabase.instance.getGenreSpellings(
        includeLocal: includeLocal,
      );
    });

String _watchSeparator(Ref ref) =>
    ref.watch(settingsProvider.select((s) => s.metadataSeparators.genre));

/// The Library's genres by name.
final libraryGenresProvider =
    FutureProvider.autoDispose<List<LibraryBrowseEntry>>((ref) async {
      final separator = _watchSeparator(ref);
      return libraryGenresFromRows(
        await ref.watch(_libraryGenreRowsProvider.future),
        separator: separator,
      );
    });

/// The songs of the genre with the given key, by title, read in bounded
/// pages of the Songs list's query.
final libraryGenreSongsProvider = FutureProvider.autoDispose
    .family<List<UnifiedLibraryItem>, String>((ref, genre) async {
      final includeLocal = watchLibrarySongs(ref);
      final separator = _watchSeparator(ref);
      final tags = libraryGenreTagsFromRows(
        await ref.watch(_libraryGenreRowsProvider.future),
        separator: separator,
      )[genre];
      if (tags == null) return const [];
      return readLibrarySongs(includeLocal: includeLocal, genreTags: tags);
    });
