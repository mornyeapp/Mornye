import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/models/track.dart';
import 'package:mornye/services/m3u_playlist_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';

List<Track> _parsePlaylistInBackground(Map<String, dynamic> request) {
  final content = utf8.decode(request['bytes'] as Uint8List);
  final seed = request['id_seed'] as int;
  return request['format'] == 'csv'
      ? CsvImportService._parseCsv(content, idSeed: seed)
      : M3uPlaylistService.parseM3u(content, idSeed: seed);
}

List<Track> _hydratePlaylistInBackground(List<dynamic> rows) => [
  for (final row in rows) Track.fromJson(Map<String, dynamic>.from(row as Map)),
];

class CsvImportService {
  static final _log = AppLogger('CsvImportService');
  static final RegExp _lineSplitPattern = RegExp(r'\r\n|\r|\n');

  static Future<List<Track>> pickAndParseCsv({
    void Function(int current, int total)? onProgress,
  }) async {
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['csv', 'm3u', 'm3u8'],
      );

      if (picked != null) {
        final bytes = await picked.readAsBytes();
        final extension = p.extension(picked.name).toLowerCase();
        final tracks = await parsePlaylistInBackground(
          bytes,
          format: (extension == '.m3u' || extension == '.m3u8') ? 'm3u' : 'csv',
        );

        if (tracks.isNotEmpty) {
          return await enrichTracksMetadata(tracks, onProgress: onProgress);
        }
        return tracks;
      }
    } catch (e) {
      _log.e('Error picking/parsing playlist file: $e');
    }
    return [];
  }

  /// Native parsing consumes bytes directly. Old native binaries and test
  /// hosts retain the same parser in an isolate, never the Flutter frame.
  static Future<List<Track>> parsePlaylistInBackground(
    Uint8List bytes, {
    required String format,
    int? idSeed,
  }) async {
    final seed = idSeed ?? DateTime.now().millisecondsSinceEpoch;
    List<dynamic> rows;
    try {
      final result = await PlatformBridge.runNativeDataJob({
        'operation': 'parse_playlist',
        'format': format,
        'id_seed': seed,
      }, bytes: bytes);
      rows = result['tracks'] as List;
    } on MissingPluginException {
      return compute(_parsePlaylistInBackground, {
        'bytes': bytes,
        'format': format,
        'id_seed': seed,
      });
    }
    return compute(_hydratePlaylistInBackground, rows);
  }

  @visibleForTesting
  static Future<List<Track>> enrichTracksMetadata(
    List<Track> tracks, {
    void Function(int current, int total)? onProgress,
    Future<List<Map<String, dynamic>>> Function(String query, int limit)?
    lookup,
    int concurrency = 3,
  }) async {
    if (tracks.isEmpty) return const [];
    final providerLookup =
        lookup ??
        (String query, int limit) =>
            PlatformBridge.searchTracksWithMetadataProviders(
              query,
              limit: limit,
              includeExtensions: true,
            );
    final results = List<Track?>.filled(tracks.length, null);
    var nextIndex = 0;
    var completed = 0;
    final workerCount = math.min(math.max(1, concurrency), tracks.length);

    _log.i(
      'Enriching ${tracks.length} imported tracks with configured metadata providers ($workerCount workers)',
    );

    Future<void> worker() async {
      while (true) {
        final index = nextIndex++;
        if (index >= tracks.length) return;
        final track = tracks[index];
        results[index] = await _enrichTrack(track, providerLookup);
        completed++;
        onProgress?.call(completed, tracks.length);
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
    final enriched = results.cast<Track>();
    _log.i('Enrichment complete: ${enriched.length} tracks');
    return enriched;
  }

  static Future<Track> _enrichTrack(
    Track track,
    Future<List<Map<String, dynamic>>> Function(String query, int limit) lookup,
  ) async {
    if (track.coverUrl != null && track.duration > 0) return track;

    Map<String, dynamic>? selected;
    final isrc = track.isrc?.trim().toUpperCase() ?? '';
    if (isrc.isNotEmpty) {
      try {
        final candidates = await lookup(isrc, 5);
        selected = _bestCandidate(track, candidates, requireExactIsrc: true);
      } catch (e) {
        _log.w('ISRC provider lookup failed for ${track.name}: $e');
      }
    }

    if (selected == null) {
      try {
        final candidates = await lookup('${track.artistName} ${track.name}', 5);
        selected = _bestCandidate(track, candidates);
      } catch (e) {
        _log.w('Metadata provider lookup failed for ${track.name}: $e');
      }
    }
    if (selected == null) return track;

    final candidate = Track.fromBackendMap(selected);
    _log.d(
      'Enriched ${track.name} via ${selected['provider_id'] ?? selected['source'] ?? 'metadata provider'}',
    );
    return track.copyWith(
      name: candidate.name.isEmpty ? track.name : candidate.name,
      artistName: candidate.artistName.isEmpty
          ? track.artistName
          : candidate.artistName,
      albumName: candidate.albumName.isEmpty
          ? track.albumName
          : candidate.albumName,
      albumArtist: candidate.albumArtist,
      artistId: candidate.artistId,
      albumId: candidate.albumId,
      coverUrl: candidate.coverUrl,
      isrc: candidate.isrc,
      duration: candidate.duration > 0 ? candidate.duration : track.duration,
      trackNumber: candidate.trackNumber,
      discNumber: candidate.discNumber,
      totalDiscs: candidate.totalDiscs,
      totalTracks: candidate.totalTracks,
      releaseDate: candidate.releaseDate,
      genre: candidate.genre,
      label: candidate.label,
      copyright: candidate.copyright,
      composer: candidate.composer,
      explicit: candidate.explicit,
      upc: candidate.upc,
    );
  }

  static Map<String, dynamic>? _bestCandidate(
    Track track,
    List<Map<String, dynamic>> candidates, {
    bool requireExactIsrc = false,
  }) {
    if (candidates.isEmpty) return null;
    final targetIsrc = track.isrc?.trim().toUpperCase() ?? '';
    final targetName = _normalizeMatchText(track.name);
    final targetArtist = _normalizeMatchText(track.artistName);
    Map<String, dynamic>? best;
    var bestScore = -1;
    for (final candidate in candidates) {
      final candidateIsrc =
          candidate['isrc']?.toString().trim().toUpperCase() ?? '';
      if (requireExactIsrc &&
          (targetIsrc.isEmpty || candidateIsrc != targetIsrc)) {
        continue;
      }
      var score = candidateIsrc.isNotEmpty && candidateIsrc == targetIsrc
          ? 100
          : 0;
      final name = _normalizeMatchText(candidate['name']?.toString() ?? '');
      final artist = _normalizeMatchText(
        (candidate['artists'] ?? candidate['artist'])?.toString() ?? '',
      );
      if (targetName.isNotEmpty && name == targetName) {
        score += 30;
      } else if (targetName.isNotEmpty &&
          name.isNotEmpty &&
          (name.contains(targetName) || targetName.contains(name))) {
        score += 15;
      }
      if (targetArtist.isNotEmpty && artist == targetArtist) {
        score += 20;
      } else if (targetArtist.isNotEmpty &&
          artist.isNotEmpty &&
          (artist.contains(targetArtist) || targetArtist.contains(artist))) {
        score += 10;
      }
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    return bestScore >= (requireExactIsrc ? 100 : 20) ? best : null;
  }

  static String _normalizeMatchText(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();

  static List<Track> _parseCsv(String content, {int? idSeed}) {
    final List<Track> tracks = [];
    final lines = content.split(_lineSplitPattern);
    if (lines.isEmpty) return tracks;

    int startIdx = 0;
    while (startIdx < lines.length && lines[startIdx].trim().isEmpty) {
      startIdx++;
    }
    if (startIdx >= lines.length) return tracks;

    final headers = _parseLine(lines[startIdx]);
    final colMap = <String, int>{};
    for (int i = 0; i < headers.length; i++) {
      String h = _cleanValue(headers[i]).toLowerCase();
      colMap[h] = i;
    }

    _log.d('CSV Headers: ${colMap.keys.toList()}');

    for (int i = startIdx + 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      final values = _parseLine(line);

      String? getVal(List<String> keys) {
        return _getValue(values, colMap, keys);
      }

      String? trackName = getVal(['track name', 'track', 'name', 'title']);
      String? artistName = getVal([
        'artist name(s)',
        'artist name',
        'artist',
        'artists',
      ]);
      String? albumName = getVal(['album name', 'album']);
      String? isrc = getVal(['isrc']);
      String? spotifyId = getVal([
        'track uri',
        'spotify - id',
        'spotify id',
        'spotify_id',
        'id',
        'uri',
      ]);

      if (spotifyId != null && spotifyId.startsWith('spotify:track:')) {
        spotifyId = spotifyId.replaceAll('spotify:track:', '');
      }

      if ((trackName != null && trackName.isNotEmpty && artistName != null) ||
          (spotifyId != null && spotifyId.isNotEmpty)) {
        tracks.add(
          Track(
            id:
                spotifyId ??
                'csv_${idSeed ?? DateTime.now().millisecondsSinceEpoch}_$i',
            name: trackName ?? 'Unknown Track',
            artistName: artistName ?? 'Unknown Artist',
            albumName: albumName ?? 'Unknown Album',
            isrc: isrc,
            duration: 0,
            coverUrl: null,
          ),
        );
      }
    }

    _log.i('Parsed ${tracks.length} tracks from CSV');
    return tracks;
  }

  static String? _getValue(
    List<String> values,
    Map<String, int> colMap,
    List<String> possibleKeys,
  ) {
    for (final key in possibleKeys) {
      if (colMap.containsKey(key)) {
        final index = colMap[key]!;
        if (index < values.length) {
          return _cleanValue(values[index]);
        }
      }
    }
    return null;
  }

  static String _cleanValue(String val) {
    val = val.trim();
    if (val.startsWith('"') && val.endsWith('"') && val.length >= 2) {
      val = val.substring(1, val.length - 1);
    }
    val = val.replaceAll('""', '"');
    return val;
  }

  static List<String> _parseLine(String line) {
    final List<String> result = [];
    bool inQuote = false;
    var buffer = StringBuffer();

    for (int i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == '"') {
        if (inQuote && i + 1 < line.length && line[i + 1] == '"') {
          buffer.write('"');
          i++;
        } else {
          inQuote = !inQuote;
        }
        continue;
      }
      if (char == ',' && !inQuote) {
        result.add(buffer.toString());
        buffer = StringBuffer();
        continue;
      }
      buffer.write(char);
    }
    result.add(buffer.toString());
    return result;
  }
}
