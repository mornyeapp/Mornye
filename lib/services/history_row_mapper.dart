import 'package:mornye/services/history_database.dart';
import 'package:mornye/utils/audio_format_utils.dart';

/// Maps history JSON to storage rows and back without opening a database.
abstract final class HistoryRowMapper {
  static String normalizeSpotifyId(String? value) {
    return (value ?? '').trim().toLowerCase();
  }

  static Map<String, dynamic> normalizedColumns({
    required String? spotifyId,
    required String? isrc,
    required String? trackName,
    required String? artistName,
    required String? albumName,
    required String? albumArtist,
  }) {
    final normalizedTrack = HistoryDatabase.normalizeLookupText(trackName);
    final normalizedArtist = HistoryDatabase.normalizeLookupText(artistName);
    final normalizedAlbum = HistoryDatabase.normalizeLookupText(albumName);
    final normalizedAlbumArtist = HistoryDatabase.normalizeLookupText(
      (albumArtist ?? '').trim().isEmpty ? artistName : albumArtist,
    );
    return {
      'spotify_id_norm': normalizeSpotifyId(spotifyId),
      'isrc_norm': HistoryDatabase.normalizeIsrc(isrc),
      'match_key': HistoryDatabase.matchKeyFor(trackName, artistName),
      'album_key': '$normalizedAlbum|$normalizedAlbumArtist',
      'search_text': [
        normalizedTrack,
        normalizedArtist,
        normalizedAlbum,
        normalizedAlbumArtist,
      ].where((value) => value.isNotEmpty).join(' '),
    };
  }

  static Map<String, dynamic> queueSortColumns({
    required String? trackName,
    required String? artistName,
    required String? albumName,
    required String? albumArtist,
    required String? genre,
    required String? releaseDate,
    required Object? downloadedAt,
  }) {
    final parsedDownloadedAt = downloadedAt is DateTime
        ? downloadedAt
        : DateTime.tryParse(downloadedAt?.toString() ?? '');
    return {
      'sort_track': HistoryDatabase.normalizeLookupText(trackName),
      'sort_artist': HistoryDatabase.normalizeLookupText(artistName),
      'sort_album': HistoryDatabase.normalizeLookupText(albumName),
      'sort_album_artist': HistoryDatabase.normalizeLookupText(
        (albumArtist ?? '').trim().isEmpty ? artistName : albumArtist,
      ),
      'sort_genre': HistoryDatabase.normalizeLookupText(genre),
      'sort_release': releaseDate?.trim() ?? '',
      'sort_added': parsedDownloadedAt?.millisecondsSinceEpoch ?? 0,
    };
  }

  static Map<String, dynamic> jsonToDbRow(Map<String, dynamic> json) {
    final downloadedAt = json['downloadedAt'];
    final parsedDownloadedAt = downloadedAt is DateTime
        ? downloadedAt
        : DateTime.tryParse(downloadedAt?.toString() ?? '');
    final row = {
      'id': json['id'],
      'track_name': json['trackName'],
      'artist_name': json['artistName'],
      'album_name': json['albumName'],
      'album_artist': json['albumArtist'],
      'cover_url': json['coverUrl'],
      'file_path': json['filePath'],
      'origin_file_path': json['originFilePath'],
      'storage_mode': json['storageMode'],
      'download_tree_uri': json['downloadTreeUri'],
      'saf_relative_dir': json['safRelativeDir'],
      'saf_file_name': json['safFileName'],
      'saf_repaired': json['safRepaired'] == true ? 1 : 0,
      'service': json['service'],
      'downloaded_at':
          parsedDownloadedAt?.toUtc().toIso8601String() ??
          downloadedAt?.toString(),
      'isrc': json['isrc'],
      'spotify_id': json['spotifyId'],
      'track_number': json['trackNumber'],
      'total_tracks': json['totalTracks'],
      'disc_number': json['discNumber'],
      'total_discs': json['totalDiscs'],
      'duration': json['duration'],
      'release_date': json['releaseDate'],
      'quality': json['quality'],
      'bit_depth': json['bitDepth'],
      'sample_rate': json['sampleRate'],
      'bitrate': json['bitrate'],
      'format': json['format'],
      'genre': json['genre'],
      'composer': json['composer'],
      'label': json['label'],
      'copyright': json['copyright'],
      'explicit': json['explicit'] == true ? 1 : 0,
      'has_lyrics': json['hasLyrics'] == true ? 1 : 0,
      'lyrics_metadata_scan_version':
          (json['lyricsMetadataScanVersion'] as num?)?.toInt() ??
          (json.containsKey('hasLyrics') ? 1 : 0),
      'has_replaygain': metadataHasReplayGain(json) ? 1 : 0,
      'replaygain_metadata_scan_version':
          (json['replayGainMetadataScanVersion'] as num?)?.toInt() ?? 0,
    };
    row.addAll(
      queueSortColumns(
        trackName: json['trackName'] as String?,
        artistName: json['artistName'] as String?,
        albumName: json['albumName'] as String?,
        albumArtist: json['albumArtist'] as String?,
        genre: json['genre'] as String?,
        releaseDate: json['releaseDate'] as String?,
        downloadedAt: parsedDownloadedAt,
      ),
    );
    row.addAll(
      normalizedColumns(
        spotifyId: json['spotifyId'] as String?,
        isrc: json['isrc'] as String?,
        trackName: json['trackName'] as String?,
        artistName: json['artistName'] as String?,
        albumName: json['albumName'] as String?,
        albumArtist: json['albumArtist'] as String?,
      ),
    );
    return row;
  }

  /// [filePath] is the already-normalized value for `row['file_path']`, since
  /// iOS container rebasing depends on HistoryDatabase state.
  static Map<String, dynamic> dbRowToJson(
    Map<String, dynamic> row,
    String filePath,
  ) {
    return {
      'id': row['id'],
      'trackName': row['track_name'],
      'artistName': row['artist_name'],
      'albumName': row['album_name'],
      'albumArtist': row['album_artist'],
      'coverUrl': row['cover_url'],
      'filePath': filePath,
      'originFilePath': row['origin_file_path'],
      if (row.containsKey('origin_available'))
        'originAvailable': row['origin_available'] == 1,
      'storageMode': row['storage_mode'],
      'downloadTreeUri': row['download_tree_uri'],
      'safRelativeDir': row['saf_relative_dir'],
      'safFileName': row['saf_file_name'],
      'safRepaired': row['saf_repaired'] == 1 || row['saf_repaired'] == true,
      'service': row['service'],
      'downloadedAt': row['downloaded_at'],
      'isrc': row['isrc'],
      'spotifyId': row['spotify_id'],
      'trackNumber': row['track_number'],
      'totalTracks': row['total_tracks'],
      'discNumber': row['disc_number'],
      'totalDiscs': row['total_discs'],
      'duration': row['duration'],
      'releaseDate': row['release_date'],
      'quality': row['quality'],
      'bitDepth': row['bit_depth'],
      'sampleRate': row['sample_rate'],
      'bitrate': row['bitrate'],
      'format': row['format'],
      'genre': row['genre'],
      'composer': row['composer'],
      'label': row['label'],
      'copyright': row['copyright'],
      'explicit': row['explicit'] == 1 || row['explicit'] == true,
      'hasLyrics': row['has_lyrics'] == 1 || row['has_lyrics'] == true,
      'lyricsMetadataScanVersion': row['lyrics_metadata_scan_version'] ?? 0,
      'hasReplayGain':
          row['has_replaygain'] == 1 || row['has_replaygain'] == true,
      'replayGainMetadataScanVersion':
          row['replaygain_metadata_scan_version'] ?? 0,
    };
  }
}
