import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/library_song_reads.dart';
import 'package:mornye/services/sqlite_helpers.dart' show normalizeLookupText;
import 'package:mornye/utils/artist_utils.dart';

/// Whether [item] is a song of the artist [artistKey] (a name as the
/// database compares it): the album artist, or one of the names the song's
/// artist tag lists.
bool libraryItemCreditsArtist(UnifiedLibraryItem item, String artistKey) {
  final albumArtist =
      (item.historyItem?.albumArtist ?? item.localItem?.albumArtist ?? '')
          .trim();
  final owner = albumArtist.isEmpty ? item.artistName : albumArtist;
  if (normalizeLookupText(owner) == artistKey) return true;
  return splitArtistNames(
    item.artistName,
  ).any((name) => normalizeLookupText(name) == artistKey);
}

/// Every Library song of the artist with the given name, by title: the
/// songs of the artist's albums and the songs that credit the artist on
/// other albums.
final libraryArtistSongsProvider = FutureProvider.autoDispose
    .family<List<UnifiedLibraryItem>, String>((ref, artist) async {
      final includeLocal = watchLibrarySongs(ref);
      final key = normalizeLookupText(artist);
      if (key.isEmpty) return const [];
      final songs = await readLibrarySongs(
        includeLocal: includeLocal,
        creditedArtist: artist,
      );
      return [
        for (final song in songs)
          if (libraryItemCreditsArtist(song, key)) song,
      ];
    });
