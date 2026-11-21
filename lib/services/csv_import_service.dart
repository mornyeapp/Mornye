import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/constants/music_services.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/extension_link_resolver.dart';
import 'package:mornye/services/m3u_playlist_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/service_track_link.dart';

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

  /// Null when no file was picked; empty when the file has no usable rows.
  /// [beforeEnrich] runs once rows were found, before any lookup.
  static Future<List<Track>?> pickAndParseCsv({
    void Function(int current, int total)? onProgress,
    Future<void> Function()? beforeEnrich,
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
          await beforeEnrich?.call();
          return await enrichTracksMetadata(tracks, onProgress: onProgress);
        }
        return tracks;
      }
    } catch (e) {
      _log.e('Error picking/parsing playlist file: $e');
      rethrow;
    }
    return null;
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
    Future<List<Track>?> Function(String url)? resolveLink,
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
    final linkLookup = resolveLink ?? ExtensionLinkResolver.resolveTracks;
    final covers = <String, Future<String?>>{};
    final results = List<List<Track>>.filled(tracks.length, const []);
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
        results[index] = await _enrichRow(
          track,
          providerLookup,
          linkLookup,
          covers,
        );
        completed++;
        onProgress?.call(completed, tracks.length);
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
    final enriched = [for (final row in results) ...row];
    _log.i(
      'Enrichment complete: ${enriched.length} tracks from ${tracks.length} rows',
    );
    return enriched;
  }

  /// A row's tracks: what its link names (all tracks of an album or a
  /// playlist), else the row itself matched by ISRC or text.
  static Future<List<Track>> _enrichRow(
    Track row,
    Future<List<Map<String, dynamic>>> Function(String query, int limit) lookup,
    Future<List<Track>?> Function(String url) resolveLink,
    Map<String, Future<String?>> covers,
  ) async {
    final link = _rowLink(row.id);
    if (link == null) return [await _enrichTrack(row, lookup)];
    try {
      var tracks = await resolveLink(link);
      if (tracks != null && tracks.isNotEmpty) {
        final isrc = row.isrc?.trim() ?? '';
        if (tracks.length == 1 &&
            isrc.isNotEmpty &&
            (tracks.single.isrc?.trim() ?? '').isEmpty) {
          tracks = [tracks.single.copyWith(isrc: isrc)];
        }
        // A playlist would cost one search per song, so it keeps its covers.
        final albums = {for (final track in tracks) track.albumId?.trim()};
        final oneCover =
            tracks.length == 1 ||
            (albums.length == 1 && (albums.single ?? '').isNotEmpty);
        if (!oneCover) return tracks;
        return [
          for (final track in tracks)
            await _withPriorityCover(track, lookup, covers),
        ];
      }
      _log.d('No extension resolved $link, matching the row text');
    } catch (e) {
      _log.w('Link lookup failed for $link: $e');
    }
    // A web URL is no track id a download provider understands.
    final fallback = _isWebUrl(row.id) ? row.copyWith(id: '') : row;
    return [await _enrichTrack(fallback, lookup)];
  }

  /// [track] with the cover of the first metadata provider, in the user's
  /// priority order, that has its exact ISRC, unless that is its own source.
  static Future<Track> _withPriorityCover(
    Track track,
    Future<List<Map<String, dynamic>>> Function(String query, int limit) lookup,
    Map<String, Future<String?>> covers,
  ) async {
    final isrc = track.isrc?.trim().toUpperCase() ?? '';
    final source = track.source?.trim().toLowerCase() ?? '';
    if (isrc.isEmpty || source.isEmpty) return track;
    // The tracks of one album share a cover, so one lookup serves them all.
    final albumId = track.albumId?.trim() ?? '';
    final key = albumId.isEmpty ? 'isrc:$isrc' : 'album:$source:$albumId';
    final cover = await (covers[key] ??= _priorityCover(isrc, source, lookup));
    return cover == null ? track : track.copyWith(coverUrl: cover);
  }

  static Future<String?> _priorityCover(
    String isrc,
    String source,
    Future<List<Map<String, dynamic>>> Function(String query, int limit) lookup,
  ) async {
    try {
      // Providers answer in priority order with one result per ISRC, so the
      // first result belongs to the highest provider that knows the ISRC.
      for (final candidate in await lookup(isrc, 1)) {
        final match = Track.fromBackendMap(candidate);
        final cover = match.coverUrl ?? '';
        if (match.isrc?.trim().toUpperCase() != isrc || cover.isEmpty) continue;
        final provider = match.source?.trim().toLowerCase() ?? '';
        return provider.isEmpty || provider == source ? null : cover;
      }
    } catch (e) {
      _log.w('Cover lookup by ISRC failed for $isrc: $e');
    }
    return null;
  }

  static final _legacyTrackId = RegExp(
    r'^(?:spotify:track:)?([A-Za-z0-9]{22})$',
  );

  /// The link a row's id names: a web URL, or a track id of the fixed legacy
  /// id columns in its link form.
  static String? _rowLink(String id) {
    final value = id.trim();
    if (_isWebUrl(value)) return value;
    final legacyId = _legacyTrackId.firstMatch(value)?.group(1);
    return legacyId == null
        ? null
        : ServiceTrackLink(MusicServices.spotify, legacyId).webUrl;
  }

  static bool _isWebUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
        (uri.isScheme('http') || uri.isScheme('https')) &&
        uri.host.isNotEmpty;
  }

  static const _placeholders = {
    'Unknown Track',
    'Unknown Artist',
    'Unknown Album',
  };

  /// [value] without the parsers' text for a missing column.
  static String _known(String value) {
    final text = value.trim();
    return _placeholders.contains(text) ? '' : text;
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

    final name = _known(track.name);
    if (selected == null && name.isNotEmpty) {
      final artist = _known(track.artistName);
      try {
        final candidates = await lookup(
          artist.isEmpty ? name : '$artist $name',
          5,
        );
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
    // The source fills in a download by its own track id: both travel together.
    final source = candidate.source?.trim() ?? '';
    final sourceId = source.isNotEmpty && candidate.id.isNotEmpty;
    return track.copyWith(
      id: sourceId ? candidate.id : null,
      source: sourceId ? source : null,
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
      headerVideoUrl: candidate.headerVideoUrl,
      previewUrl: candidate.previewUrl,
      isrc: candidate.isrc,
      duration: candidate.duration > 0 ? candidate.duration : track.duration,
      trackNumber: candidate.trackNumber,
      discNumber: candidate.discNumber,
      totalDiscs: candidate.totalDiscs,
      totalTracks: candidate.totalTracks,
      releaseDate: candidate.releaseDate,
      albumType: candidate.albumType,
      genre: candidate.genre,
      label: candidate.label,
      copyright: candidate.copyright,
      composer: candidate.composer,
      comment: candidate.comment,
      audioQuality: candidate.audioQuality,
      audioModes: candidate.audioModes,
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
    final targetName = _normalizeMatchText(_known(track.name));
    final targetArtist = _known(track.artistName);
    final hasArtist = _normalizeMatchText(targetArtist).isNotEmpty;
    Map<String, dynamic>? best;
    var bestScore = 0;
    for (final candidate in candidates) {
      final candidateIsrc =
          candidate['isrc']?.toString().trim().toUpperCase() ?? '';
      final isrcMatch = targetIsrc.isNotEmpty && candidateIsrc == targetIsrc;
      if (requireExactIsrc && !isrcMatch) continue;
      final nameScore = _nameScore(
        targetName,
        _normalizeMatchText(candidate['name']?.toString() ?? ''),
      );
      final artistScore = _artistScore(
        targetArtist,
        (candidate['artists'] ?? candidate['artist'])?.toString() ?? '',
      );
      // Text alone must agree on the title and on the row's artist, if any.
      final textMatch = nameScore > 0 && (!hasArtist || artistScore > 0);
      if (!isrcMatch && !textMatch) continue;
      final score = (isrcMatch ? 100 : 0) + nameScore + artistScore;
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    return best;
  }

  /// 30 for the same title, 15 when one holds the other as specific words.
  static int _nameScore(String target, String candidate) {
    if (target.isEmpty || candidate.isEmpty) return 0;
    if (target == candidate) return 30;
    return _containsWords(target, candidate) ? 15 : 0;
  }

  /// 20 for the same credit, 10 when the credits share an artist.
  static int _artistScore(String target, String candidate) {
    final targetKey = _normalizeMatchText(target);
    final candidateKey = _normalizeMatchText(candidate);
    if (targetKey.isEmpty || candidateKey.isEmpty) return 0;
    if (targetKey == candidateKey) return 20;
    final credits = _artistCredits(candidate).toSet();
    return _artistCredits(target).any(credits.contains) ||
            _containsWords(targetKey, candidateKey)
        ? 10
        : 0;
  }

  static final _creditSeparator = RegExp(
    r'[,;&/]|\s+(?:feat\.?|ft\.?|featuring|x)\s+',
    caseSensitive: false,
  );

  static Iterable<String> _artistCredits(String artists) => artists
      .split(_creditSeparator)
      .map(_normalizeMatchText)
      .where((credit) => credit.isNotEmpty && !_genericText.contains(credit));

  /// Whether the shorter text sits in the longer one as whole words and is
  /// specific enough to tell songs or artists apart.
  static bool _containsWords(String a, String b) {
    final (shorter, longer) = a.length <= b.length ? (a, b) : (b, a);
    if (shorter.replaceAll(' ', '').length < 4 ||
        _genericText.contains(shorter)) {
      return false;
    }
    return ' $longer '.contains(' $shorter ');
  }

  static const _genericText = {
    'unknown',
    'unknown track',
    'unknown artist',
    'unknown album',
    'untitled',
    'track',
    'song',
    'title',
    'artist',
    'artists',
    'various artists',
    'test',
    'none',
    'null',
  };

  static final _featuring = RegExp(
    r'[(\[]\s*(?:feat|ft|featuring)\b[^)\]]*[)\]]|\s(?:feat|ft|featuring)\b.*$',
    caseSensitive: false,
  );
  static final _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
  static const _accented = 'àáâãäåçèéêëìíîïñòóôõöøùúûüýÿ';
  static const _unaccented = 'aaaaaaceeeeiiiinoooooouuuuyy';

  /// Lowercase words without a featured-artist part, accents or punctuation.
  static String _normalizeMatchText(String value) {
    final lower = value.replaceAll(_featuring, ' ').toLowerCase();
    final folded = String.fromCharCodes(
      lower.codeUnits.map((unit) {
        final index = _accented.indexOf(String.fromCharCode(unit));
        return index < 0 ? unit : _unaccented.codeUnitAt(index);
      }),
    );
    return folded.replaceAll(_nonWord, ' ').trim();
  }

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
      // A link travels in the id; enrichment resolves it before matching text.
      final url = getVal(['url', 'link', 'track url', 'track link']);
      if (url != null && url.isNotEmpty) spotifyId = url;

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
