import 'dart:io';

import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/string_utils.dart';

final RegExp _lrcDisplayTimestampPattern = RegExp(
  r'^\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\]',
);
final RegExp _lrcDisplayMetadataPattern = RegExp(
  r'^\[[a-zA-Z][a-zA-Z0-9_-]*:.*\]$',
);
final RegExp _lrcDisplayInlineTimestampPattern = RegExp(
  r'<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>',
);
final RegExp _lrcDisplaySpeakerPrefixPattern = RegExp(
  r'^v[1-9]\d*:\s*',
  caseSensitive: false,
);
final RegExp _lrcDisplayBackgroundLinePattern = RegExp(
  r'^\[bg:(.*)\]$',
  caseSensitive: false,
);
final RegExp _lrcDisplayWhitespacePattern = RegExp(r'\s+');
const _instrumentalMarker = '[instrumental:true]';

bool isInstrumentalLyricsMarker(String lyrics) {
  final trimmed = lyrics.trim();
  return trimmed.length == _instrumentalMarker.length &&
      trimmed.toLowerCase() == _instrumentalMarker;
}

String _cleanLyricsDisplayLine(String line) {
  var cleaned = line.trim();
  if (_lrcDisplayMetadataPattern.hasMatch(cleaned) &&
      !_lrcDisplayBackgroundLinePattern.hasMatch(cleaned)) {
    return '';
  }
  final backgroundMatch = _lrcDisplayBackgroundLinePattern.firstMatch(cleaned);
  if (backgroundMatch != null) {
    cleaned = backgroundMatch.group(1)?.trim() ?? '';
  }
  while (_lrcDisplayTimestampPattern.hasMatch(cleaned)) {
    cleaned = cleaned.replaceFirst(_lrcDisplayTimestampPattern, '').trim();
  }
  cleaned = cleaned.replaceAll(_lrcDisplayInlineTimestampPattern, '').trim();
  cleaned = cleaned.replaceFirst(_lrcDisplaySpeakerPrefixPattern, '');
  return cleaned.replaceAll(_lrcDisplayWhitespacePattern, ' ').trim();
}

/// Converts embedded or fetched LRC into text suitable for the metadata UI.
/// Header-only payloads intentionally produce an empty string.
String cleanLyricsForDisplay(String lyrics) {
  final cleanLines = <String>[];

  for (final line in lyrics.split('\n')) {
    final cleaned = _cleanLyricsDisplayLine(line);
    if (cleaned.isNotEmpty) {
      cleanLines.add(cleaned);
    }
  }

  return cleanLines.join('\n');
}

bool hasUsableLyricsContent(String lyrics) {
  if (isInstrumentalLyricsMarker(lyrics)) return true;
  // Scan lazily: checking existence does not need a line list or the full
  // display text. Share normalization so metadata and rendered lyrics agree.
  var start = 0;
  while (start < lyrics.length) {
    final newline = lyrics.indexOf('\n', start);
    final end = newline < 0 ? lyrics.length : newline;
    if (_cleanLyricsDisplayLine(lyrics.substring(start, end)).isNotEmpty) {
      return true;
    }
    if (newline < 0) break;
    start = newline + 1;
  }
  return false;
}

/// Extracts lyrics from a description, comment, or unstructured metadata text.
String extractLyricsFromDescription(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return '';

  // 1. If it contains LRC timestamps, extract timestamped lines
  final timestampMatches = RegExp(
    r'\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\].+',
  ).allMatches(trimmed);
  if (timestampMatches.length >= 2) {
    return timestampMatches.map((m) => m.group(0)!).join('\n');
  }

  // 2. Look for explicit lyrics header: Lyrics:, Testo:, Letra:, Paroles:
  final headerMatch = RegExp(
    r'(?:^|\n)\s*(?:[-=*#~\[\(]*\s*)?(?:lyrics|testo|letra|paroles|song\s*lyrics|testo\s*della\s*canzone)\s*(?:[-=*#~\]\)]*)\s*:\s*\n?',
    caseSensitive: false,
  ).firstMatch(trimmed);

  if (headerMatch != null) {
    final afterHeader = trimmed.substring(headerMatch.end).trim();
    if (afterHeader.isNotEmpty) {
      // Cut off any trailing promotional sections if present
      final promoCutoff = RegExp(
        r'\n\s*(?:[-=*#~]*\s*)?(?:follow|links?|subscribe|connect|copyright|socials?|merch|stream|listen|credits?)\b[^\n]*[:\n]',
        caseSensitive: false,
      ).firstMatch(afterHeader);
      final candidate =
          (promoCutoff != null
                  ? afterHeader.substring(0, promoCutoff.start)
                  : afterHeader)
              .trim();
      if (hasUsableLyricsContent(candidate)) {
        return candidate;
      }
    }
  }

  // 3. If multiple lines exist and at least 3 lines look like lyrics (not URLs or promo headers)
  final lines = trimmed.split('\n');
  final lyricLines = <String>[];
  var inLyrics = false;
  for (final rawLine in lines) {
    final line = rawLine.trim();
    if (line.isEmpty) {
      if (inLyrics) lyricLines.add('');
      continue;
    }
    // Skip common URL or promo lines
    if (line.startsWith('http://') ||
        line.startsWith('https://') ||
        line.startsWith('www.')) {
      continue;
    }
    if (RegExp(
      r'^(?:follow|subscribe|connect|stream|buy|prod\.|produced by|mixed by|mastered by|directed by)\b',
      caseSensitive: false,
    ).hasMatch(line)) {
      continue;
    }

    lyricLines.add(line);
    inLyrics = true;
  }

  final cleaned = lyricLines.join('\n').trim();
  if (lyricLines.where((l) => l.trim().isNotEmpty).length >= 3 &&
      hasUsableLyricsContent(cleaned)) {
    return cleaned;
  }

  return '';
}

bool hasEmbeddedLyricsMetadata(Map<String, String> metadata) {
  final lyrics = (metadata['LYRICS'] ?? '').trim();
  if (hasUsableLyricsContent(lyrics)) return true;

  final unsyncedLyrics = (metadata['UNSYNCEDLYRICS'] ?? '').trim();
  if (hasUsableLyricsContent(unsyncedLyrics)) return true;

  return false;
}

String _sidecarLrcPath(String path) {
  final slash = path.lastIndexOf(Platform.pathSeparator);
  final dot = path.lastIndexOf('.');
  if (dot > slash) {
    return '${path.substring(0, dot)}.lrc';
  }
  return '$path.lrc';
}

/// Writes a ".lrc" sidecar next to a re-enriched audio file when the backend
/// result requests it (`write_external_lrc`), honoring the user's lyrics mode.
///
/// This handles the filesystem case only. SAF (`content://`) files are written
/// centrally by the Kotlin `reEnrichFile` handler, which still holds the
/// original document URI, so callers should skip those here (they are detected
/// and ignored). A requested write must succeed before re-enrich reports
/// completion; failures propagate to the single-track or batch result.
Future<bool> writeReEnrichSidecarLrc({
  required String audioFilePath,
  required Map<String, dynamic> reEnrichResult,
}) async {
  if (reEnrichResult['write_external_lrc'] != true) return false;

  if (isContentUri(audioFilePath)) return false;

  final lrc = (reEnrichResult['lyrics'] as String?)?.trim() ?? '';
  if (lrc.isEmpty) throw StateError('The updated LRC lyrics are empty');

  final lrcPath = _sidecarLrcPath(audioFilePath);
  await File(lrcPath).writeAsString(lrc);
  return true;
}

/// Writes a SAF ".lrc" sidecar after a FFmpeg re-enrich write-back succeeds.
///
/// Native FLAC re-enrich handles SAF sidecars in Kotlin after the direct
/// write-back. This helper is for the FFmpeg path, where Dart owns the final
/// `writeTempToSaf` success/failure decision.
Future<bool> writeReEnrichSafSidecarLrc({
  required String safUri,
  required Map<String, dynamic> reEnrichResult,
}) async {
  if (reEnrichResult['write_external_lrc'] != true) return false;
  if (!isContentUri(safUri)) throw ArgumentError.value(safUri, 'safUri');

  final lrc = (reEnrichResult['lyrics'] as String?)?.trim() ?? '';
  if (lrc.isEmpty) throw StateError('The updated LRC lyrics are empty');

  if (!await PlatformBridge.writeSafSidecarLrc(safUri, lrc)) {
    throw StateError(
      'Metadata was saved, but the LRC lyrics file could not be updated',
    );
  }
  return true;
}

Future<void> ensureLyricsMetadataForConversion({
  required Map<String, String> metadata,
  required String sourcePath,
  required bool shouldEmbedLyrics,
  required String trackName,
  required String artistName,
  String spotifyId = '',
  int durationMs = 0,
}) async {
  if (!shouldEmbedLyrics || hasEmbeddedLyricsMetadata(metadata)) {
    return;
  }

  String? lyrics;

  // Prefer sidecar .lrc when available to avoid network calls.
  if (!isContentUri(sourcePath)) {
    try {
      final lrcPath = _sidecarLrcPath(sourcePath);
      final lrcFile = File(lrcPath);
      if (await lrcFile.exists()) {
        final content = (await lrcFile.readAsString()).trim();
        if (content.isNotEmpty) {
          lyrics = content;
        }
      }
    } catch (_) {}
  }

  if (lyrics == null || lyrics.isEmpty) {
    try {
      final fetched = await PlatformBridge.getLyricsLRC(
        spotifyId,
        trackName,
        artistName,
        durationMs: durationMs,
      );
      final normalized = fetched.trim();
      if (normalized.isNotEmpty &&
          normalized.toLowerCase() != '[instrumental:true]') {
        lyrics = normalized;
      }
    } catch (_) {}
  }

  if (lyrics == null || lyrics.isEmpty) {
    return;
  }

  metadata['LYRICS'] = lyrics;
  metadata['UNSYNCEDLYRICS'] = lyrics;
}

void mergePlatformMetadataForTagEmbed({
  required Map<String, String> target,
  required Map<String, dynamic> source,
}) {
  void put(String key, dynamic value) {
    final normalized = value?.toString().trim();
    if (normalized == null || normalized.isEmpty) return;
    target[key] = normalized;
  }

  put('TITLE', source['title']);
  put('ARTIST', source['artist']);
  put('ALBUM', source['album']);
  put('ALBUMARTIST', source['album_artist']);
  put('DATE', source['date']);
  put('ISRC', source['isrc']);
  put('GENRE', source['genre']);
  put('ORGANIZATION', source['label']);
  put('COPYRIGHT', source['copyright']);
  put('COMPOSER', source['composer']);
  put('COMMENT', source['comment']);
  put('LYRICS', source['lyrics']);
  put('UNSYNCEDLYRICS', source['lyrics']);

  final explicit = parseExplicitFlag(source['explicit']);
  if (explicit == true) {
    target['ITUNESADVISORY'] = '1';
  } else if (explicit == false) {
    target.remove('ITUNESADVISORY');
  }

  final trackNumber = source['track_number'];
  final totalTracks = source['total_tracks'];
  if (trackNumber != null && trackNumber.toString() != '0') {
    put(
      'TRACKNUMBER',
      totalTracks != null &&
              totalTracks.toString().isNotEmpty &&
              totalTracks.toString() != '0'
          ? '${trackNumber.toString()}/${totalTracks.toString()}'
          : trackNumber,
    );
  }

  final discNumber = source['disc_number'];
  final totalDiscs = source['total_discs'];
  if (discNumber != null && discNumber.toString() != '0') {
    put(
      'DISCNUMBER',
      totalDiscs != null &&
              totalDiscs.toString().isNotEmpty &&
              totalDiscs.toString() != '0'
          ? '${discNumber.toString()}/${totalDiscs.toString()}'
          : discNumber,
    );
  }
}
