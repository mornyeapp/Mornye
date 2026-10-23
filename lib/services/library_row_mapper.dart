import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/audio_format_utils.dart';

/// Maps scan/domain metadata to storage rows without opening a database.
abstract final class LibraryRowMapper {
  static const _columns = {
    'id': 'id',
    'trackName': 'track_name',
    'artistName': 'artist_name',
    'albumName': 'album_name',
    'albumArtist': 'album_artist',
    'filePath': 'file_path',
    'coverPath': 'cover_path',
    'scannedAt': 'scanned_at',
    'fileModTime': 'file_mod_time',
    'networkFileVersion': 'network_file_version',
    'isrc': 'isrc',
    'trackNumber': 'track_number',
    'totalTracks': 'total_tracks',
    'discNumber': 'disc_number',
    'totalDiscs': 'total_discs',
    'duration': 'duration',
    'releaseDate': 'release_date',
    'bitDepth': 'bit_depth',
    'sampleRate': 'sample_rate',
    'bitrate': 'bitrate',
    'genre': 'genre',
    'composer': 'composer',
    'label': 'label',
    'copyright': 'copyright',
    'format': 'format',
  };

  static bool _flag(Object? value) => value == true || value == 1;

  static Map<String, dynamic> encode(
    Map<String, dynamic> json, {
    String? sourceId,
  }) => {
    for (final column in _columns.entries) column.value: json[column.key],
    'source_id':
        sourceId ?? json['sourceId'] ?? LocalLibraryItem.legacySourceId,
    'explicit': _flag(json['explicit']) ? 1 : 0,
    'has_lyrics': _flag(json['hasLyrics']) ? 1 : 0,
    'has_replaygain': metadataHasReplayGain(json) ? 1 : 0,
    'audio_metadata_scan_version':
        (json['audioMetadataScanVersion'] as num?)?.toInt() ??
        (json['metadataFromFilename'] == true
            ? 0
            : libraryAudioMetadataScanVersion),
    ...normalized(
      trackName: json['trackName'] as String? ?? '',
      artistName: json['artistName'] as String? ?? '',
      albumName: json['albumName'] as String? ?? '',
      albumArtist: json['albumArtist'] as String?,
    ),
    ...queue(
      trackName: json['trackName'] as String?,
      artistName: json['artistName'] as String?,
      albumName: json['albumName'] as String?,
      albumArtist: json['albumArtist'] as String?,
      genre: json['genre'] as String?,
      releaseDate: json['releaseDate'] as String?,
      fileModTime: (json['fileModTime'] as num?)?.toInt(),
      scannedAt: json['scannedAt'] as String?,
    ),
  };

  static Map<String, dynamic> decode(Map<String, dynamic> row) => {
    for (final column in _columns.entries) column.key: row[column.value],
    'sourceId': row['source_id'] ?? LocalLibraryItem.legacySourceId,
    'explicit': _flag(row['explicit']),
    'hasLyrics': _flag(row['has_lyrics']),
    'hasReplayGain': _flag(row['has_replaygain']),
  };

  static Map<String, dynamic> normalized({
    required String trackName,
    required String artistName,
    required String albumName,
    required String? albumArtist,
  }) {
    final track = sqlite.normalizeLookupText(trackName);
    final artist = sqlite.normalizeLookupText(artistName);
    final album = sqlite.normalizeLookupText(albumName);
    final albumArtistValue = sqlite.normalizeLookupText(
      albumArtist ?? artistName,
    );
    return {
      'track_name_norm': track,
      'artist_name_norm': artist,
      'album_name_norm': album,
      'album_artist_norm': albumArtistValue,
      'match_key': '$track|$artist',
      'album_key': '$album|$albumArtistValue',
    };
  }

  static Map<String, dynamic> queue({
    required String? trackName,
    required String? artistName,
    required String? albumName,
    required String? albumArtist,
    required String? genre,
    required String? releaseDate,
    required int? fileModTime,
    required String? scannedAt,
  }) => {
    'search_text':
        [
              trackName,
              artistName,
              albumName,
              (albumArtist ?? '').trim().isEmpty ? artistName : albumArtist,
            ]
            .map(sqlite.normalizeLookupText)
            .where((value) => value.isNotEmpty)
            .join(' '),
    'sort_genre': sqlite.normalizeLookupText(genre),
    'sort_release': releaseDate?.trim() ?? '',
    'sort_added':
        fileModTime ??
        DateTime.tryParse(scannedAt ?? '')?.millisecondsSinceEpoch ??
        0,
  };
}
