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
  if (!stored.contains(false)) return [for (final track in tracks) track.cover];
  final rows = await _libraryRows(tracks);
  return [
    for (var i = 0; i < tracks.length; i++)
      stored[i] ? tracks[i].cover : _nonEmptyCoverPath(rows[i]),
  ];
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

/// The first cover of a collection this device can load.
Future<String?> _firstCover(List<LocalLibraryCoverRequest> tracks) async {
  List<Map<String, dynamic>?>? rows;
  for (var i = 0; i < tracks.length; i++) {
    final stored = tracks[i].cover;
    if (stored != null && await _coverLoadsHere(stored)) return stored;
    // One lookup answers every song without a cover of its own.
    rows ??= await _libraryRows(tracks);
    final cover = _nonEmptyCoverPath(rows[i]);
    if (cover != null) return cover;
  }
  return null;
}

final localLibraryFirstCoverProvider = FutureProvider.autoDispose
    .family<String?, LocalLibraryCoverBatchRequest>((ref, request) {
      ref.watch(
        localLibraryProvider.select((state) => state.loadedIndexVersion),
      );
      return _firstCover(request.tracks);
    });

/// The cover of a playlist without an image of its own: `cover`, the stored
/// cover of its first song, when this device can load it, otherwise the
/// first cover its songs resolve to. `updatedAt` asks again after the
/// playlist changed. A failed lookup shows the placeholder, so it is not
/// retried.
final playlistCoverProvider = FutureProvider.autoDispose
    .family<String?, ({String id, String? cover, DateTime? updatedAt})>((
      ref,
      request,
    ) async {
      ref.watch(
        localLibraryProvider.select((state) => state.loadedIndexVersion),
      );
      final cover = request.cover;
      if (cover != null && await _coverLoadsHere(cover)) return cover;
      final tracks = await LibraryCollectionsDatabase.instance
          .loadPlaylistTracks(request.id);
      return _firstCover([
        for (final track in tracks) LocalLibraryCoverRequest.of(track),
      ]);
    }, retry: (_, _) => null);
