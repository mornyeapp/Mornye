import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/audio_format_utils.dart';

// v4 records ReplayGain availability; older rows rescan once.
const libraryAudioMetadataScanVersion = 4;
const libraryLyricsMetadataScanVersion = 3;

/// The path columns of one visible Library row.
typedef LibraryFilePathRow = ({String id, String sourceId, String filePath});

int libraryIncrementalSnapshotModTime({
  required int storedModTime,
  required int storedScanVersion,
}) {
  return storedScanVersion >= libraryAudioMetadataScanVersion
      ? storedModTime
      : -1;
}

class LocalLibraryItem {
  static const legacySourceId = 'legacy';

  final String id;
  final String sourceId;
  final String trackName;
  final String artistName;
  final String albumName;
  final String? albumArtist;
  final String filePath;
  final String? coverPath;
  final DateTime scannedAt;
  final int? fileModTime;
  final String? networkFileVersion;
  final String? isrc;
  final int? trackNumber;
  final int? totalTracks;
  final int? discNumber;
  final int? totalDiscs;
  final int? duration;
  final String? releaseDate;
  final int? bitDepth;
  final int? sampleRate;
  final int? bitrate; // average kbps for both lossless and lossy audio
  final String? genre;
  final String? composer;
  final String? label;
  final String? copyright;
  final bool explicit;
  final bool hasLyrics;
  final bool hasReplayGain;
  final String? format; // flac, alac, eac3, ac3, ac4, mp3, opus, m4a

  const LocalLibraryItem({
    required this.id,
    this.sourceId = legacySourceId,
    required this.trackName,
    required this.artistName,
    required this.albumName,
    this.albumArtist,
    required this.filePath,
    this.coverPath,
    required this.scannedAt,
    this.fileModTime,
    this.networkFileVersion,
    this.isrc,
    this.trackNumber,
    this.totalTracks,
    this.discNumber,
    this.totalDiscs,
    this.duration,
    this.releaseDate,
    this.bitDepth,
    this.sampleRate,
    this.bitrate,
    this.genre,
    this.composer,
    this.label,
    this.copyright,
    this.explicit = false,
    this.hasLyrics = false,
    this.hasReplayGain = false,
    this.format,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'sourceId': sourceId,
    'trackName': trackName,
    'artistName': artistName,
    'albumName': albumName,
    'albumArtist': albumArtist,
    'filePath': filePath,
    'coverPath': coverPath,
    'scannedAt': scannedAt.toIso8601String(),
    'fileModTime': fileModTime,
    'networkFileVersion': networkFileVersion,
    'isrc': isrc,
    'trackNumber': trackNumber,
    'totalTracks': totalTracks,
    'discNumber': discNumber,
    'totalDiscs': totalDiscs,
    'duration': duration,
    'releaseDate': releaseDate,
    'bitDepth': bitDepth,
    'sampleRate': sampleRate,
    'bitrate': bitrate,
    'genre': genre,
    'composer': composer,
    'label': label,
    'copyright': copyright,
    'explicit': explicit,
    'hasLyrics': hasLyrics,
    'hasReplayGain': hasReplayGain,
    'format': format,
  };

  factory LocalLibraryItem.fromJson(Map<String, dynamic> json) =>
      LocalLibraryItem(
        id: json['id'] as String,
        sourceId: json['sourceId'] as String? ?? legacySourceId,
        trackName: json['trackName'] as String,
        artistName: json['artistName'] as String,
        albumName: json['albumName'] as String,
        albumArtist: json['albumArtist'] as String?,
        filePath: json['filePath'] as String,
        coverPath: json['coverPath'] as String?,
        scannedAt: DateTime.parse(json['scannedAt'] as String),
        fileModTime: (json['fileModTime'] as num?)?.toInt(),
        networkFileVersion: json['networkFileVersion'] as String?,
        isrc: json['isrc'] as String?,
        trackNumber: (json['trackNumber'] as num?)?.toInt(),
        totalTracks: (json['totalTracks'] as num?)?.toInt(),
        discNumber: (json['discNumber'] as num?)?.toInt(),
        totalDiscs: (json['totalDiscs'] as num?)?.toInt(),
        duration: (json['duration'] as num?)?.toInt(),
        releaseDate: json['releaseDate'] as String?,
        bitDepth: (json['bitDepth'] as num?)?.toInt(),
        sampleRate: (json['sampleRate'] as num?)?.toInt(),
        bitrate: (json['bitrate'] as num?)?.toInt(),
        genre: json['genre'] as String?,
        composer: json['composer'] as String?,
        label: json['label'] as String?,
        copyright: json['copyright'] as String?,
        explicit: json['explicit'] == true || json['explicit'] == 1,
        hasLyrics: json['hasLyrics'] == true || json['hasLyrics'] == 1,
        // Scan results carry the raw replaygain_* tags; stored rows the flag.
        hasReplayGain: metadataHasReplayGain(json),
        format: json['format'] as String?,
      );

  LocalLibraryItem withAudioMetadata({
    int? duration,
    int? bitDepth,
    int? sampleRate,
    int? bitrate,
    bool? explicit,
    bool? hasLyrics,
    bool? hasReplayGain,
    String? format,
  }) {
    return LocalLibraryItem(
      id: id,
      sourceId: sourceId,
      trackName: trackName,
      artistName: artistName,
      albumName: albumName,
      albumArtist: albumArtist,
      filePath: filePath,
      coverPath: coverPath,
      scannedAt: scannedAt,
      fileModTime: fileModTime,
      networkFileVersion: networkFileVersion,
      isrc: isrc,
      trackNumber: trackNumber,
      totalTracks: totalTracks,
      discNumber: discNumber,
      totalDiscs: totalDiscs,
      duration: duration ?? this.duration,
      releaseDate: releaseDate,
      bitDepth: bitDepth ?? this.bitDepth,
      sampleRate: sampleRate ?? this.sampleRate,
      bitrate: bitrate ?? this.bitrate,
      genre: genre,
      composer: composer,
      label: label,
      copyright: copyright,
      explicit: explicit ?? this.explicit,
      hasLyrics: hasLyrics ?? this.hasLyrics,
      hasReplayGain: hasReplayGain ?? this.hasReplayGain,
      format: format ?? this.format,
    );
  }

  String get albumKey =>
      '${sqlite.normalizeLookupText(albumName)}|${sqlite.normalizeLookupText(albumArtist ?? artistName)}';
}

class LocalLibrarySource {
  final String id;
  final String path;
  final String displayName;
  final String? bookmark;
  final String? volumeId;
  final bool isRemovable;
  final bool enabled;
  final bool available;
  final int trackCount;
  final DateTime? lastScannedAt;
  final DateTime? lastSeenAt;
  final String? lastScanError;

  const LocalLibrarySource({
    required this.id,
    required this.path,
    required this.displayName,
    this.bookmark,
    this.volumeId,
    this.isRemovable = false,
    this.enabled = true,
    this.available = true,
    this.trackCount = 0,
    this.lastScannedAt,
    this.lastSeenAt,
    this.lastScanError,
  });

  bool get isIndexed => lastScannedAt != null || trackCount > 0;

  LocalLibrarySource copyWith({
    bool? enabled,
    bool? available,
    int? trackCount,
    DateTime? lastScannedAt,
    DateTime? lastSeenAt,
    String? lastScanError,
    bool clearLastScanError = false,
  }) {
    return LocalLibrarySource(
      id: id,
      path: path,
      displayName: displayName,
      bookmark: bookmark,
      volumeId: volumeId,
      isRemovable: isRemovable,
      enabled: enabled ?? this.enabled,
      available: available ?? this.available,
      trackCount: trackCount ?? this.trackCount,
      lastScannedAt: lastScannedAt ?? this.lastScannedAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      lastScanError: clearLastScanError
          ? null
          : lastScanError ?? this.lastScanError,
    );
  }
}

enum LocalLibrarySortMode { album, title, artist, latest, quality }

class LocalLibraryLookupIndex {
  final Set<String> isrcs;
  final Set<String> matchKeys;

  const LocalLibraryLookupIndex({
    this.isrcs = const <String>{},
    this.matchKeys = const <String>{},
  });
}

class LocalLibraryBatchLookupRequest {
  final String? id;
  final String? isrc;
  final String trackName;
  final String artistName;

  const LocalLibraryBatchLookupRequest({
    this.id,
    this.isrc,
    required this.trackName,
    required this.artistName,
  });
}

class IsrcDuplicateEntry {
  final String id;
  final String source; // 'downloaded' (history row) or 'local' (library row)
  final String trackName;
  final String artistName;
  final String filePath;
  final int? bitDepth;
  final int? sampleRate;
  final int? bitrate;
  final String? format;

  const IsrcDuplicateEntry({
    required this.id,
    required this.source,
    required this.trackName,
    required this.artistName,
    required this.filePath,
    this.bitDepth,
    this.sampleRate,
    this.bitrate,
    this.format,
  });
}

class IsrcDuplicateGroup {
  final String isrc;
  final List<IsrcDuplicateEntry> entries;

  const IsrcDuplicateGroup({required this.isrc, required this.entries});
}

class QueueLibraryDbQuery {
  final bool includeSingleTrackAlbums;
  final String? albumArtist;
  final int limit;
  final int offset;
  final String filterMode;
  final String? searchQuery;
  final String? source;
  final String? quality;
  final String? format;
  final String? metadata;
  final String sortMode;
  final bool includeLocal;
  final bool excludeNetwork;
  final QueueLibraryDbCursor? cursor;

  const QueueLibraryDbQuery({
    this.includeSingleTrackAlbums = false,
    this.albumArtist,
    this.limit = 100,
    this.offset = 0,
    this.filterMode = 'all',
    this.searchQuery,
    this.source,
    this.quality,
    this.format,
    this.metadata,
    this.sortMode = 'latest',
    this.includeLocal = true,
    this.excludeNetwork = false,
    this.cursor,
  });
}

/// Opaque seek cursor for queue Library pagination.
///
/// Values follow the active SQL order (including its unique tie-breaker), so
/// later pages can seek from the last row instead of making SQLite discard an
/// ever-growing OFFSET prefix.
class QueueLibraryDbCursor {
  final List<Object> values;

  const QueueLibraryDbCursor(this.values);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! QueueLibraryDbCursor ||
        other.values.length != values.length) {
      return false;
    }
    for (var i = 0; i < values.length; i++) {
      if (values[i] != other.values[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(values);
}

class QueueLibraryDbPage {
  final List<Map<String, dynamic>> rows;
  final QueueLibraryDbCursor? nextCursor;

  const QueueLibraryDbPage({required this.rows, required this.nextCursor});
}

class QueueLibraryCounts {
  final int allTrackCount;
  final int albumCount;
  final int singleTrackCount;

  const QueueLibraryCounts({
    required this.allTrackCount,
    required this.albumCount,
    required this.singleTrackCount,
  });
}
