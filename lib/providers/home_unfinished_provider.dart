import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/recognized_song.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_counts_provider.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_recognition_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/album_completeness.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/music_recognition_library.dart';

/// The rows of Home's "Finish your collection", in their order.
enum HomeUnfinishedRow {
  wishlist,
  incompleteAlbums,
  recognized,
  failedDownloads,
}

/// Loose ends of the collection, as counts.
@immutable
class HomeUnfinished {
  const HomeUnfinished({
    this.wishlist = 0,
    this.incompleteAlbums = 0,
    this.recognized = 0,
    this.failedDownloads = 0,
  });

  final int wishlist;
  final int incompleteAlbums;

  /// Recognized songs with no Library entry.
  final int recognized;
  final int failedDownloads;

  int countOf(HomeUnfinishedRow row) => switch (row) {
    HomeUnfinishedRow.wishlist => wishlist,
    HomeUnfinishedRow.incompleteAlbums => incompleteAlbums,
    HomeUnfinishedRow.recognized => recognized,
    HomeUnfinishedRow.failedDownloads => failedDownloads,
  };

  /// The rows with something to show.
  List<HomeUnfinishedRow> get rows => [
    for (final row in HomeUnfinishedRow.values)
      if (countOf(row) > 0) row,
  ];

  bool get isEmpty => rows.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is HomeUnfinished &&
      wishlist == other.wishlist &&
      incompleteAlbums == other.incompleteAlbums &&
      recognized == other.recognized &&
      failedDownloads == other.failedDownloads;

  @override
  int get hashCode =>
      Object.hash(wishlist, incompleteAlbums, recognized, failedDownloads);
}

/// The Library count under its Incomplete albums filter, shared with the
/// Library tab when that filter is on.
LibraryCountsRequest incompleteAlbumsCountRequest({
  required bool localLibraryEnabled,
}) => LibraryCountsRequest(
  searchQuery: '',
  filterSource: null,
  filterQuality: null,
  filterFormat: null,
  filterMetadata: incompleteAlbumFilter,
  localLibraryEnabled: localLibraryEnabled,
);

/// Assessing every album waits, as the mixes do, until startup settles.
final homeIncompleteAlbumCountProvider = FutureProvider.autoDispose<int>((
  ref,
) async {
  if (!ref.watch(libraryMixesStartupProvider)) return 0;
  final includeLocal = ref.watch(
    settingsProvider.select((s) => s.localLibraryEnabled),
  );
  final counts = await ref.watch(
    libraryCountsProvider(
      incompleteAlbumsCountRequest(localLibraryEnabled: includeLocal),
    ).future,
  );
  return counts.albumCount;
});

/// How many of [history] [library] has no entry for, matched as the
/// recognition screen matches a result.
Future<int> countRecognizedNotInLibrary(
  List<RecognizedSong> history,
  RecognitionLibrary library,
) async {
  var missing = 0;
  for (final song in history) {
    if (await findRecognizedSong(song, library) == null) missing++;
  }
  return missing;
}

/// Library lookups for recognized songs that read only the index: Home
/// counts at startup, so no file is checked.
final homeRecognitionLookupProvider = Provider<RecognitionLibrary>(
  _IndexedRecognitionLibrary.new,
);

class _IndexedRecognitionLibrary implements RecognitionLibrary {
  _IndexedRecognitionLibrary(this.ref);

  final Ref ref;

  bool get _includeLocal => ref.read(settingsProvider).localLibraryEnabled;

  @override
  Future<RecognitionLibraryMatch?> byIsrc(String isrc) async {
    final downloaded = await ref
        .read(downloadHistoryProvider.notifier)
        .getByIsrcAsync(isrc);
    if (downloaded != null) return _match(downloaded.filePath);
    if (!_includeLocal) return null;
    return _row(await LibraryDatabase.instance.getByIsrc(isrc));
  }

  @override
  Future<RecognitionLibraryMatch?> byTitleArtist(
    String title,
    String artist,
  ) async {
    final downloaded = await ref
        .read(downloadHistoryProvider.notifier)
        .findByTrackAndArtistAsync(title, artist);
    if (downloaded != null) return _match(downloaded.filePath);
    if (!_includeLocal) return null;
    return _row(
      await LibraryDatabase.instance.findFirstByTrackAndArtist(title, artist),
    );
  }

  static RecognitionLibraryMatch? _row(Map<String, dynamic>? row) =>
      row == null ? null : _match(row['filePath'] as String? ?? '');

  static RecognitionLibraryMatch _match(String path) =>
      RecognitionLibraryMatch(path: path, title: '', artist: '');
}

final homeRecognizedMissingProvider = FutureProvider.autoDispose<int>((
  ref,
) async {
  final history = ref.watch(recognitionHistoryProvider);
  if (history.isEmpty || !ref.watch(libraryMixesStartupProvider)) return 0;
  ref.watch(downloadHistoryProvider.select((s) => s.loadedIndexVersion));
  final includeLocal = ref.watch(
    settingsProvider.select((s) => s.localLibraryEnabled),
  );
  if (includeLocal) ref.watch(localLibraryIndexRevisionProvider);
  return countRecognizedNotInLibrary(
    history,
    ref.watch(homeRecognitionLookupProvider),
  );
});

/// Every row's count. A count still loading reads as nothing, so its row
/// appears once known instead of showing a placeholder.
final homeUnfinishedProvider = Provider.autoDispose<HomeUnfinished>(
  (ref) => HomeUnfinished(
    wishlist: ref.watch(
      libraryCollectionsProvider.select((s) => s.wishlist.length),
    ),
    incompleteAlbums: ref.watch(
      homeIncompleteAlbumCountProvider.select((s) => s.value ?? 0),
    ),
    recognized: ref.watch(
      homeRecognizedMissingProvider.select((s) => s.value ?? 0),
    ),
    failedDownloads: ref.watch(
      downloadQueueProvider.select((s) => s.failedCount),
    ),
  ),
);
