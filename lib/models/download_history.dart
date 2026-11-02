import 'package:mornye/utils/string_utils.dart';

/// Another transfer published the same origin while this one was fetching.
class OfflineCopyAlreadySaved implements Exception {
  const OfflineCopyAlreadySaved();
}

class DownloadHistoryItem {
  final String id;
  final String trackName;
  final String artistName;
  final String albumName;
  final String? albumArtist;
  final String? coverUrl;
  final String filePath;

  /// Stable network source of an independently saved offline copy.
  final String? originFilePath;

  /// Whether the latest Library scan still contains the original file.
  final bool originAvailable;
  final String? storageMode;
  final String? downloadTreeUri;
  final String? safRelativeDir;
  final String? safFileName;
  final bool safRepaired;
  final String service;
  final DateTime downloadedAt;
  final String? isrc;
  final String? spotifyId;
  final int? trackNumber;
  final int? totalTracks;
  final int? discNumber;
  final int? totalDiscs;
  final int? duration;
  final String? releaseDate;
  final String? quality;
  final int? bitDepth;
  final int? sampleRate;
  final int? bitrate;
  final String? format;
  final String? genre;
  final String? composer;
  final String? label;
  final String? copyright;
  final bool explicit;
  final bool hasLyrics;
  final int lyricsMetadataScanVersion;
  final bool hasReplayGain;

  /// 0 until the finished file's tags were read; only then is a false
  /// [hasReplayGain] a confirmed absence.
  final int replayGainMetadataScanVersion;

  /// File copies retain their scanned Library identity for playlists/likes.
  /// The legacy spotifyId column also stores foreign ids from other sources.
  bool get _offlineLibraryFile =>
      originFilePath != null &&
      const {'Network offline', 'Mornye Link'}.contains(service);
  String get collectionTrackId => _offlineLibraryFile ? spotifyId ?? id : id;
  String get collectionTrackSource => _offlineLibraryFile ? 'local' : service;

  const DownloadHistoryItem({
    required this.id,
    required this.trackName,
    required this.artistName,
    required this.albumName,
    this.albumArtist,
    this.coverUrl,
    required this.filePath,
    this.originFilePath,
    this.originAvailable = false,
    this.storageMode,
    this.downloadTreeUri,
    this.safRelativeDir,
    this.safFileName,
    this.safRepaired = false,
    required this.service,
    required this.downloadedAt,
    this.isrc,
    this.spotifyId,
    this.trackNumber,
    this.totalTracks,
    this.discNumber,
    this.totalDiscs,
    this.duration,
    this.releaseDate,
    this.quality,
    this.bitDepth,
    this.sampleRate,
    this.bitrate,
    this.format,
    this.genre,
    this.composer,
    this.label,
    this.copyright,
    this.explicit = false,
    this.hasLyrics = false,
    this.lyricsMetadataScanVersion = 0,
    this.hasReplayGain = false,
    this.replayGainMetadataScanVersion = 0,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'trackName': trackName,
    'artistName': artistName,
    'albumName': albumName,
    'albumArtist': albumArtist,
    'coverUrl': coverUrl,
    'filePath': filePath,
    'originFilePath': originFilePath,
    'storageMode': storageMode,
    'downloadTreeUri': downloadTreeUri,
    'safRelativeDir': safRelativeDir,
    'safFileName': safFileName,
    'safRepaired': safRepaired,
    'service': service,
    'downloadedAt': downloadedAt.toUtc().toIso8601String(),
    'isrc': isrc,
    'spotifyId': spotifyId,
    'trackNumber': trackNumber,
    'totalTracks': totalTracks,
    'discNumber': discNumber,
    'totalDiscs': totalDiscs,
    'duration': duration,
    'releaseDate': releaseDate,
    'quality': quality,
    'bitDepth': bitDepth,
    'sampleRate': sampleRate,
    'bitrate': bitrate,
    'format': format,
    'genre': genre,
    'composer': composer,
    'label': label,
    'copyright': copyright,
    'explicit': explicit,
    'hasLyrics': hasLyrics,
    'lyricsMetadataScanVersion': lyricsMetadataScanVersion,
    'hasReplayGain': hasReplayGain,
    'replayGainMetadataScanVersion': replayGainMetadataScanVersion,
  };

  factory DownloadHistoryItem.fromJson(Map<String, dynamic> json) =>
      DownloadHistoryItem(
        id: json['id'] as String,
        trackName: json['trackName'] as String,
        artistName: json['artistName'] as String,
        albumName: json['albumName'] as String,
        albumArtist: normalizeOptionalString(json['albumArtist'] as String?),
        coverUrl: normalizeCoverReference(json['coverUrl']?.toString()),
        filePath: json['filePath'] as String,
        originFilePath: json['originFilePath'] as String?,
        originAvailable:
            json['originAvailable'] == true || json['originAvailable'] == 1,
        storageMode: json['storageMode'] as String?,
        downloadTreeUri: json['downloadTreeUri'] as String?,
        safRelativeDir: json['safRelativeDir'] as String?,
        safFileName: json['safFileName'] as String?,
        safRepaired: json['safRepaired'] == true,
        service: json['service'] as String,
        downloadedAt: DateTime.parse(json['downloadedAt'] as String).toLocal(),
        isrc: json['isrc'] as String?,
        spotifyId: json['spotifyId'] as String?,
        trackNumber: json['trackNumber'] as int?,
        totalTracks: json['totalTracks'] as int?,
        discNumber: json['discNumber'] as int?,
        totalDiscs: json['totalDiscs'] as int?,
        duration: json['duration'] as int?,
        releaseDate: json['releaseDate'] as String?,
        quality: json['quality'] as String?,
        bitDepth: json['bitDepth'] as int?,
        sampleRate: json['sampleRate'] as int?,
        bitrate: (json['bitrate'] as num?)?.toInt(),
        format: json['format'] as String?,
        genre: json['genre'] as String?,
        composer: json['composer'] as String?,
        label: json['label'] as String?,
        copyright: json['copyright'] as String?,
        explicit: parseExplicitFlag(json['explicit']) == true,
        hasLyrics: json['hasLyrics'] == true || json['hasLyrics'] == 1,
        lyricsMetadataScanVersion:
            (json['lyricsMetadataScanVersion'] as num?)?.toInt() ?? 0,
        hasReplayGain:
            json['hasReplayGain'] == true || json['hasReplayGain'] == 1,
        replayGainMetadataScanVersion:
            (json['replayGainMetadataScanVersion'] as num?)?.toInt() ?? 0,
      );

  DownloadHistoryItem copyWith({
    String? trackName,
    String? artistName,
    String? albumName,
    String? albumArtist,
    String? coverUrl,
    String? filePath,
    String? originFilePath,
    bool? originAvailable,
    String? storageMode,
    String? downloadTreeUri,
    String? safRelativeDir,
    String? safFileName,
    bool? safRepaired,
    String? isrc,
    String? spotifyId,
    int? trackNumber,
    int? totalTracks,
    int? discNumber,
    int? totalDiscs,
    int? duration,
    String? releaseDate,
    String? quality,
    int? bitDepth,
    int? sampleRate,
    int? bitrate,
    String? format,
    String? genre,
    String? composer,
    String? label,
    String? copyright,
    bool? explicit,
    bool? hasLyrics,
    int? lyricsMetadataScanVersion,
    bool? hasReplayGain,
    int? replayGainMetadataScanVersion,
  }) {
    return DownloadHistoryItem(
      id: id,
      trackName: trackName ?? this.trackName,
      artistName: artistName ?? this.artistName,
      albumName: albumName ?? this.albumName,
      albumArtist: albumArtist ?? this.albumArtist,
      coverUrl: normalizeCoverReference(coverUrl ?? this.coverUrl),
      filePath: filePath ?? this.filePath,
      originFilePath: originFilePath ?? this.originFilePath,
      originAvailable: originAvailable ?? this.originAvailable,
      storageMode: storageMode ?? this.storageMode,
      downloadTreeUri: downloadTreeUri ?? this.downloadTreeUri,
      safRelativeDir: safRelativeDir ?? this.safRelativeDir,
      safFileName: safFileName ?? this.safFileName,
      safRepaired: safRepaired ?? this.safRepaired,
      service: service,
      downloadedAt: downloadedAt,
      isrc: isrc ?? this.isrc,
      spotifyId: spotifyId ?? this.spotifyId,
      trackNumber: trackNumber ?? this.trackNumber,
      totalTracks: totalTracks ?? this.totalTracks,
      discNumber: discNumber ?? this.discNumber,
      totalDiscs: totalDiscs ?? this.totalDiscs,
      duration: duration ?? this.duration,
      releaseDate: releaseDate ?? this.releaseDate,
      quality: quality ?? this.quality,
      bitDepth: bitDepth ?? this.bitDepth,
      sampleRate: sampleRate ?? this.sampleRate,
      bitrate: bitrate ?? this.bitrate,
      format: format ?? this.format,
      genre: genre ?? this.genre,
      composer: composer ?? this.composer,
      label: label ?? this.label,
      copyright: copyright ?? this.copyright,
      explicit: explicit ?? this.explicit,
      hasLyrics: hasLyrics ?? this.hasLyrics,
      lyricsMetadataScanVersion:
          lyricsMetadataScanVersion ?? this.lyricsMetadataScanVersion,
      hasReplayGain: hasReplayGain ?? this.hasReplayGain,
      replayGainMetadataScanVersion:
          replayGainMetadataScanVersion ?? this.replayGainMetadataScanVersion,
    );
  }
}

Map<String, DownloadHistoryItem> _indexRecentHistoryItems(
  Iterable<DownloadHistoryItem> items,
  String? Function(DownloadHistoryItem item) keyOf,
) {
  final index = <String, DownloadHistoryItem>{};
  for (final item in items) {
    final key = keyOf(item);
    if (key != null && key.isNotEmpty) {
      index.putIfAbsent(key, () => item);
    }
  }
  return index;
}

Map<String, DownloadHistoryItem> _indexWithNewest(
  Map<String, DownloadHistoryItem> index,
  String? key,
  DownloadHistoryItem item,
) => key == null || key.isEmpty ? index : ({...index, key: item});

class DownloadHistoryState {
  final List<DownloadHistoryItem> items;
  final int totalCount;
  final int loadedIndexVersion;
  final List<DownloadHistoryItem> _lookupItems;
  final Map<String, DownloadHistoryItem> _bySpotifyId;
  final Map<String, DownloadHistoryItem> _byIsrc;
  final Map<String, DownloadHistoryItem> _byTrackArtistKey;

  DownloadHistoryState({
    this.items = const [],
    this.totalCount = 0,
    this.loadedIndexVersion = 0,
    List<DownloadHistoryItem>? lookupItems,
  }) : _lookupItems = List.unmodifiable(lookupItems ?? items),
       _bySpotifyId = _indexRecentHistoryItems(
         lookupItems ?? items,
         (item) => item.spotifyId,
       ),
       _byIsrc = _indexRecentHistoryItems(
         lookupItems ?? items,
         (item) => item.isrc,
       ),
       _byTrackArtistKey = _indexRecentHistoryItems(
         lookupItems ?? items,
         (item) => trackArtistKey(item.trackName, item.artistName),
       );

  DownloadHistoryState._withExistingLookup({
    required DownloadHistoryState source,
    required this.items,
    required this.totalCount,
    required this.loadedIndexVersion,
  }) : _lookupItems = source._lookupItems,
       _bySpotifyId = source._bySpotifyId,
       _byIsrc = source._byIsrc,
       _byTrackArtistKey = source._byTrackArtistKey;

  DownloadHistoryState._withPrependedLookup({
    required DownloadHistoryState source,
    required DownloadHistoryItem item,
    required this.items,
    required this.totalCount,
  }) : loadedIndexVersion = source.loadedIndexVersion,
       _lookupItems = List.unmodifiable([item, ...source._lookupItems]),
       _bySpotifyId = _indexWithNewest(
         source._bySpotifyId,
         item.spotifyId,
         item,
       ),
       _byIsrc = _indexWithNewest(source._byIsrc, item.isrc, item),
       _byTrackArtistKey = _indexWithNewest(
         source._byTrackArtistKey,
         trackArtistKey(item.trackName, item.artistName),
         item,
       );

  /// The key [findByTrackArtistKey] reads; '' for an empty track name.
  static String trackArtistKey(String trackName, String artistName) {
    final normalizedTrack = trackName.trim().toLowerCase();
    if (normalizedTrack.isEmpty) return '';
    final normalizedArtist = artistName.trim().toLowerCase();
    return '$normalizedTrack|$normalizedArtist';
  }

  bool isDownloaded(String spotifyId) => _bySpotifyId.containsKey(spotifyId);

  DownloadHistoryItem? getBySpotifyId(String spotifyId) =>
      _bySpotifyId[spotifyId];

  DownloadHistoryItem? getByIsrc(String isrc) => _byIsrc[isrc];

  DownloadHistoryItem? findByTrackAndArtist(
    String trackName,
    String artistName,
  ) => findByTrackArtistKey(trackArtistKey(trackName, artistName));

  DownloadHistoryItem? findByTrackArtistKey(String key) =>
      key.isEmpty ? null : _byTrackArtistKey[key];

  List<DownloadHistoryItem> get lookupItems => _lookupItems;

  DownloadHistoryState copyWith({
    List<DownloadHistoryItem>? items,
    int? totalCount,
    int? loadedIndexVersion,
    List<DownloadHistoryItem>? lookupItems,
  }) {
    if (lookupItems == null || identical(lookupItems, _lookupItems)) {
      return DownloadHistoryState._withExistingLookup(
        source: this,
        items: items ?? this.items,
        totalCount: totalCount ?? this.totalCount,
        loadedIndexVersion: loadedIndexVersion ?? this.loadedIndexVersion,
      );
    }
    return DownloadHistoryState(
      items: items ?? this.items,
      totalCount: totalCount ?? this.totalCount,
      loadedIndexVersion: loadedIndexVersion ?? this.loadedIndexVersion,
      lookupItems: lookupItems,
    );
  }

  /// Same lookups as `copyWith(lookupItems: [item, ...lookupItems])`: the
  /// first occurrence wins each key, so [item] only overwrites its own keys.
  DownloadHistoryState copyWithPrependedLookup(
    DownloadHistoryItem item, {
    required List<DownloadHistoryItem> items,
    required int totalCount,
  }) => DownloadHistoryState._withPrependedLookup(
    source: this,
    item: item,
    items: items,
    totalCount: totalCount,
  );
}
