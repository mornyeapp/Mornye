part of 'local_library_provider.dart';

/// A song of a collection whose cover is looked up.
class LocalLibraryCoverRequest {
  /// The cover stored with the song. A file path can name a file of another
  /// device: older builds synced those over Link.
  final String? cover;
  final String? isrc;
  final String trackName;
  final String artistName;

  const LocalLibraryCoverRequest({
    this.cover,
    this.isrc,
    required this.trackName,
    required this.artistName,
  });

  /// [track] with its stored cover, apart from a `content://` cover, which
  /// the Library answers instead.
  factory LocalLibraryCoverRequest.of(Track track) {
    final cover = track.coverUrl?.trim();
    return LocalLibraryCoverRequest(
      cover: cover == null || cover.isEmpty || cover.startsWith('content://')
          ? null
          : cover,
      isrc: track.isrc?.trim(),
      trackName: track.name,
      artistName: track.artistName,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is LocalLibraryCoverRequest &&
        other.cover == cover &&
        other.isrc == isrc &&
        other.trackName == trackName &&
        other.artistName == artistName;
  }

  @override
  int get hashCode => Object.hash(cover, isrc, trackName, artistName);
}

class LocalLibraryCoverBatchRequest {
  final List<LocalLibraryCoverRequest> tracks;

  const LocalLibraryCoverBatchRequest(this.tracks);

  @override
  bool operator ==(Object other) {
    if (other is! LocalLibraryCoverBatchRequest) return false;
    if (other.tracks.length != tracks.length) return false;
    for (var i = 0; i < tracks.length; i++) {
      if (other.tracks[i] != tracks[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(tracks);
}

String? _nonEmptyCoverPath(Map<String, dynamic>? json) {
  final coverPath = json?['coverPath'] as String?;
  final trimmed = coverPath?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// Whether a stored cover needs no lookup: a web URL or a `network://`
/// reference loads on any device that holds it.
bool collectionCoverIsPortable(String? cover) =>
    cover != null &&
    (cover.startsWith('http://') ||
        cover.startsWith('https://') ||
        CoverStore.fetches(cover));

/// Whether this device can load the stored [cover].
Future<bool> _coverLoadsHere(String cover) async {
  if (collectionCoverIsPortable(cover)) return true;
  var path = cover;
  if (cover.startsWith('file://')) {
    try {
      path = Uri.parse(cover).toFilePath();
    } on FormatException {
      return false;
    } on UnsupportedError {
      return false;
    }
  }
  return p.isAbsolute(path) && await File(path).exists();
}

Future<List<Map<String, dynamic>?>> _libraryRows(
  List<LocalLibraryCoverRequest> tracks,
) => LibraryDatabase.instance.findExistingBatch([
  for (final track in tracks)
    LocalLibraryBatchLookupRequest(
      isrc: track.isrc,
      trackName: track.trackName,
      artistName: track.artistName,
    ),
]);

/// The cover each of [tracks] shows here: its stored cover when this device
/// can load it, otherwise the cover of the same song in the Library.
Future<List<String?>> _resolveCovers(
  List<LocalLibraryCoverRequest> tracks,
) async {
  final loads = <String, Future<bool>>{};
  final stored = await Future.wait([
    for (final track in tracks)
      if (track.cover case final cover?)
        loads.putIfAbsent(cover, () => _coverLoadsHere(cover))
      else
        Future.value(false),
  ]);
  final covers = [for (final track in tracks) track.cover];
  final missing = [
    for (var i = 0; i < tracks.length; i++)
      if (!stored[i]) i,
  ];
  if (missing.isEmpty) return covers;
  final rows = await _libraryRows([for (final i in missing) tracks[i]]);
  for (var j = 0; j < missing.length; j++) {
    covers[missing[j]] = _nonEmptyCoverPath(rows[j]);
  }
  return covers;
}

/// The cover one song of a collection shows on this device.
final localLibraryCoverProvider = FutureProvider.autoDispose
    .family<String?, LocalLibraryCoverRequest>((ref, request) async {
      ref.watch(
        localLibraryProvider.select((state) => state.loadedIndexVersion),
      );
      final cover = request.cover;
      if (cover != null && await _coverLoadsHere(cover)) return cover;
      return _nonEmptyCoverPath(
        await LibraryDatabase.instance.findExisting(
          isrc: request.isrc,
          trackName: request.trackName,
          artistName: request.artistName,
        ),
      );
    });

/// The covers a whole collection shows on this device, one for each song.
/// A failed lookup leaves the stored covers, so it is not retried.
final localLibraryCoversProvider = FutureProvider.autoDispose
    .family<List<String?>, LocalLibraryCoverBatchRequest>((ref, request) {
      ref.watch(
        localLibraryProvider.select((state) => state.loadedIndexVersion),
      );
      return _resolveCovers(request.tracks);
    }, retry: (_, _) => null);

/// Songs of the first page searched for a collection's first cover. Each
/// later page doubles, so a cover near the start reads a few songs and a long
/// collection without one still takes few lookups.
const _firstCoverPage = 16;

/// The first cover of [page] this device can load.
Future<String?> _firstCoverOfPage(List<LocalLibraryCoverRequest> page) async {
  List<Map<String, dynamic>?>? rows;
  var looked = 0;
  for (var i = 0; i < page.length; i++) {
    final stored = page[i].cover;
    if (stored != null && await _coverLoadsHere(stored)) return stored;
    // One lookup answers this song and every later one of the page.
    if (rows == null) {
      looked = i;
      rows = await _libraryRows(page.sublist(i));
    }
    final cover = _nonEmptyCoverPath(rows[i - looked]);
    if (cover != null) return cover;
  }
  return null;
}

/// The first cover of a collection this device can load, read page by page
/// until one answers.
Future<String?> _firstCover(
  Stream<List<LocalLibraryCoverRequest>> pages,
) async {
  await for (final page in pages) {
    final cover = await _firstCoverOfPage(page);
    if (cover != null) return cover;
  }
  return null;
}

Iterable<List<LocalLibraryCoverRequest>> _coverPages(
  List<LocalLibraryCoverRequest> tracks,
) sync* {
  for (
    var start = 0, size = _firstCoverPage;
    start < tracks.length;
    start += size, size *= 2
  ) {
    yield tracks.sublist(start, (start + size).clamp(0, tracks.length));
  }
}

final localLibraryFirstCoverProvider = FutureProvider.autoDispose
    .family<String?, LocalLibraryCoverBatchRequest>((ref, request) {
      ref.watch(
        localLibraryProvider.select((state) => state.loadedIndexVersion),
      );
      return _firstCover(Stream.fromIterable(_coverPages(request.tracks)));
    });

typedef _PlaylistCoverRequest = ({
  String id,
  String? cover,
  DateTime? updatedAt,
});

/// Playlist covers answered since the Library index last changed, so a tile
/// that scrolls back into view or the playlist picker asks no lookup again.
final _playlistCoversProvider = Provider<Map<_PlaylistCoverRequest, String?>>((
  ref,
) {
  ref.watch(localLibraryProvider.select((state) => state.loadedIndexVersion));
  return {};
});

const _playlistCoversKept = 256;

/// The cover of a playlist without an image of its own: `cover`, the stored
/// cover of its first song, when this device can load it, otherwise the
/// first cover its songs resolve to. `updatedAt` asks again after the
/// playlist changed. A failed lookup shows the placeholder, so it is not
/// retried.
final playlistCoverProvider = FutureProvider.autoDispose
    .family<String?, _PlaylistCoverRequest>((ref, request) async {
      final covers = ref.watch(_playlistCoversProvider);
      if (covers.containsKey(request)) return covers[request];
      final cover = await _playlistCover(request);
      covers[request] = cover;
      if (covers.length > _playlistCoversKept) {
        covers.remove(covers.keys.first);
      }
      return cover;
    }, retry: (_, _) => null);

Future<String?> _playlistCover(_PlaylistCoverRequest request) async {
  final cover = request.cover;
  if (cover != null && await _coverLoadsHere(cover)) return cover;
  return _firstCover(
    LibraryCollectionsDatabase.instance
        .playlistTrackPages(request.id, firstPage: _firstCoverPage)
        .map(
          (tracks) => [
            for (final track in tracks) LocalLibraryCoverRequest.of(track),
          ],
        ),
  );
}
