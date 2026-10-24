import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/link/features/link_track_resolver.dart';

/// [LinkLibraryLookup] over the download history and, when the Library is
/// on, the scanned Library rows.
class LinkDatabaseLookup implements LinkLibraryLookup {
  LinkDatabaseLookup({
    required DownloadHistoryNotifier Function() history,
    required this.library,
    required bool Function() includeLibrary,
  }) : _history = history,
       _includeLibrary = includeLibrary;

  final DownloadHistoryNotifier Function() _history;
  final LibraryDatabase library;
  final bool Function() _includeLibrary;

  DownloadHistoryNotifier get history => _history();

  /// Whether scanned Library rows count, read per query so a settings
  /// change applies at once.
  bool get includeLibrary => _includeLibrary();

  static LinkLocalTrack _fromHistory(DownloadHistoryItem item) =>
      LinkLocalTrack(playableFromHistory(item), isrc: item.isrc);

  static LinkLocalTrack _fromLibrary(Map<String, dynamic> row) {
    final item = LocalLibraryItem.fromJson(row);
    return LinkLocalTrack(playableFromLocal(item), isrc: item.isrc);
  }

  @override
  Future<LinkLocalTrack?> recordFor({
    required String id,
    required String source,
  }) async {
    if (source.isNotEmpty) {
      final item = await history.getByFilePathAsync(source);
      if (item != null) return _fromHistory(item);
    }
    if (!includeLibrary || id.isEmpty) return null;
    final row = await library.getById(id);
    return row == null ? null : _fromLibrary(row);
  }

  @override
  Future<List<LinkLocalTrack>> byIsrc(String isrc) async {
    final candidates = {isrc, HistoryDatabase.normalizeIsrc(isrc)}..remove('');
    final found = <LinkLocalTrack>[];
    for (final value in candidates) {
      final item = await history.getByIsrcAsync(value);
      if (item != null) {
        found.add(_fromHistory(item));
        break;
      }
    }
    if (includeLibrary) {
      for (final value in candidates) {
        final row = await library.getByIsrc(value);
        if (row != null) {
          found.add(_fromLibrary(row));
          break;
        }
      }
    }
    return found;
  }

  @override
  Future<List<LinkLocalTrack>> byMatchKey(String matchKey) async {
    // Both tables store `normalized title|normalized artist`, and normalizing
    // is idempotent, so the halves of the key look the same row up again.
    final split = matchKey.indexOf('|');
    if (split <= 0) return const [];
    final title = matchKey.substring(0, split);
    final artist = matchKey.substring(split + 1);
    final found = <LinkLocalTrack>[];
    final item = await history.findByTrackAndArtistAsync(title, artist);
    if (item != null) found.add(_fromHistory(item));
    if (includeLibrary) {
      for (final row in await library.findByTrackAndArtist(title, artist)) {
        found.add(_fromLibrary(row));
      }
    }
    return found;
  }
}
