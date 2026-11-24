import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/saf_siblings.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/lyric_supplement_tags.dart';
import 'package:mornye/utils/lyrics_draft.dart';
import 'package:mornye/utils/lyrics_parser.dart';

/// `.mlrc`, Mornye's lyrics file: saved next to a song, it keeps the song's
/// lyrics together with their translation and pronunciation, for synced LRC,
/// TTML and lyrics without timing alike, and leaves the song's own file as
/// it is.
///
/// Version 2 is UTF-8 LRC:
/// - The first line is `[x-mlrc:2]`.
/// - The lyrics follow as LRC, with word timing as enhanced LRC, a singer as
///   a `v1:` prefix and backing vocals as `[bg:...]` rows.
/// - A line's `[x-romanized-words:<key>:...]`, `[x-romanized:<key>:...]`,
///   `[x-translated-words:<key>:...]` and `[x-translated:<key>:...]` tags
///   follow it, in the readable form lyric_supplement_tags.dart describes.
///   The key is the line's time in milliseconds, so the file also reads as
///   ordinary LRC; in lyrics without timing it is the line's index, counted
///   from 0, and there is no word timing.
///
/// Version 1 wrote the same tags with base64 values; it is still read.
const mlrcExtension = 'mlrc';

/// `.lrc`, the plain lyrics file other players also read next to a song.
const lrcExtension = 'lrc';
const _mlrcHeader = '[x-mlrc:2]';
const _maxSidecarBytes = 8 * 1024 * 1024;

// The LRC ID tags the lyrics parsers drop.
final _tagRow = RegExp(
  r'^\[(ti|ar|al|by|offset|length|re|ve|tool|au|la|encoder|instrumental|x-[a-z0-9_-]+):.*\]$',
  caseSensitive: false,
);

String mlrcPathFor(String path) => sidecarPathFor(path, mlrcExtension);

String sidecarPathFor(String path, String extension) {
  final audioExtension = p.extension(path);
  final base = audioExtension.isEmpty
      ? path
      : path.substring(0, path.length - audioExtension.length);
  return '$base.$extension';
}

/// The `.mlrc` text for [shown], the song's lyrics as the player displays
/// them. Synced LRC [raw] lyrics are kept as written, with tags for what
/// [shown] adds; TTML and lyrics without timing are written from [shown].
/// [clearMissingTranslations] is passed on to [lyricsWithTranslations]:
/// a translation [shown] no longer carries is removed from the file too.
String buildMlrc({
  required String raw,
  required ParsedLyrics shown,
  bool clearMissingTranslations = false,
}) {
  final lrc = LyricsDraft.canEdit(raw) && raw.trim().isNotEmpty
      ? LyricsDraft.parse(raw)
      : null;
  final body = lrc != null && lrc.synced
      ? lyricsWithTranslations(
              raw,
              shown,
              clearMissingTranslations: clearMissingTranslations,
            ) ??
            lrc.toLrc()
      : _lrcOf(shown);
  return '$_mlrcHeader\n$body\n';
}

String _lrcOf(ParsedLyrics lyrics) {
  final lines = lyricsWithPlainLines(lyrics).lines;
  final out = <String>[];
  if (!lyrics.synced) {
    for (final (index, line) in lines.indexed) {
      out.add(line.text);
      for (final (kind, payload) in lyricLineSupplements(line)) {
        out.add(lyricSupplementRow(kind, index, payload));
      }
    }
    return out.join('\n');
  }
  for (final line in lines) {
    final content = _lineContent(line);
    if (line.isBackground) {
      // Backing vocals belong to the line before them.
      if (out.isNotEmpty) out.add('[bg:$content]');
      continue;
    }
    final voice = line.voice == null ? '' : 'v${line.voice!.index + 1}: ';
    out.add('[${formatLyricsTime(line.time)}]$voice$content');
    for (final (kind, payload) in lyricLineSupplements(line)) {
      out.add(lyricSupplementRow(kind, line.time.inMilliseconds, payload));
    }
  }
  return out.join('\n');
}

/// A line's text with its word timing as enhanced LRC, or its plain text
/// when the words do not spell it. TTML words may leave out the spaces
/// between them.
String _lineContent(LyricLine line) {
  if (line.words.isEmpty) return line.text;
  String squeezed(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final text = squeezed(line.text);
  final words = line.words.map((word) => word.text);
  final separator = squeezed(words.join()) == text
      ? ''
      : squeezed(words.join(' ')) == text
      ? ' '
      : null;
  if (separator == null) return line.text;
  final buffer = StringBuffer();
  for (final (index, word) in line.words.indexed) {
    if (index > 0) buffer.write(separator);
    buffer.write('<${formatLyricsTime(word.time)}>${word.text}');
  }
  final end = line.words.last.end;
  if (end != null) buffer.write('<${formatLyricsTime(end)}>');
  return buffer.toString().trimRight();
}

/// Lyrics read from `.mlrc` text, parsed by [parse] for synced lyrics.
/// Lyrics without timing key their tags by line, which only this reader
/// knows.
Future<ParsedLyrics> readMlrc(
  String raw,
  Future<ParsedLyrics> Function(String raw) parse,
) async {
  final parsed = await parse(raw);
  if (parsed.synced) return parsed;
  final rows = <String>[];
  final supplements = <int, Map<String, String>>{};
  for (final source in raw.split(RegExp(r'\r\n|\r|\n'))) {
    final row = source.trim();
    if (row.isEmpty) continue;
    final supplement = readLyricSupplementTag(row);
    if (supplement != null) {
      final (:kind, key: index, :text, words: _) = supplement;
      if (index != null && text != null && text.isNotEmpty) {
        (supplements[index] ??= {}).putIfAbsent(kind, () => text);
      }
      continue;
    }
    if (_tagRow.hasMatch(row)) continue;
    rows.add(row);
  }
  if (rows.isEmpty) return parsed;
  return ParsedLyrics(
    synced: false,
    wordSynced: false,
    lines: List.unmodifiable([
      for (final (index, text) in rows.indexed)
        LyricLine(
          time: Duration.zero,
          text: text,
          translation: supplements[index]?['translation'],
          romanization: supplements[index]?['romaji'],
        ),
    ]),
    plainText: rows.join('\n'),
    writers: parsed.writers,
    provider: parsed.provider,
  );
}

/// [lyrics] with the translations and pronunciations of [saved], the song's
/// `.mlrc` lyrics, on the lines with the same text. A saved one replaces the
/// song's own, since only Mornye writes it. Word timing applies only to a
/// line sung at the same time. Without lyrics of its own, the song shows
/// [saved].
ParsedLyrics mergeSavedLyrics(ParsedLyrics lyrics, ParsedLyrics? saved) {
  if (saved == null || saved.isEmpty) return lyrics;
  if (lyrics.isEmpty) return saved;
  final byText = <String, List<LyricLine>>{};
  for (final line in lyricsWithPlainLines(saved).lines) {
    final text = translatableLyricText(line.text);
    if (line.isBackground || text.isEmpty) continue;
    if (lyricLineSupplements(line).isEmpty) continue;
    (byText[text] ??= []).add(line);
  }
  if (byText.isEmpty) return lyrics;
  final base = lyricsWithPlainLines(lyrics);
  var changed = false;
  LyricLine merge(LyricLine line) {
    if (line.isBackground) return line;
    final candidates = byText[translatableLyricText(line.text)];
    if (candidates == null) return line;
    final timed = base.synced && saved.synced
        ? candidates
              .where(
                (candidate) =>
                    (candidate.time - line.time).inMilliseconds.abs() <= 10,
              )
              .firstOrNull
        : null;
    final match = timed ?? candidates.first;
    String? pick(String? saved, String? own) =>
        saved?.trim().isNotEmpty == true ? saved!.trim() : own;
    final translation = pick(match.translation, line.translation);
    final romanization = pick(match.romanization, line.romanization);
    // The parsers keep only timing that spells its saved text.
    List<LyricWord>? timing(List<LyricWord>? words) =>
        words != null && words.isNotEmpty ? words : null;
    final romanizationWords = timing(timed?.romanizationWords);
    final translationWords = timing(timed?.translationWords);
    if (translation == line.translation &&
        romanization == line.romanization &&
        romanizationWords == null &&
        translationWords == null) {
      return line;
    }
    changed = true;
    return line.withTranslation(
      translation,
      romanization: romanization,
      romanizationWords: romanizationWords,
      translationWords: translationWords,
    );
  }

  final lines = [for (final line in base.lines) merge(line)];
  if (!changed) return lyrics;
  return ParsedLyrics(
    synced: base.synced,
    wordSynced: base.wordSynced,
    lines: List.unmodifiable(lines),
    plainText: base.plainText,
    writers: base.writers,
    provider: base.provider,
  );
}

/// Reads and writes a song's `.mlrc` file, or its sidecar with another
/// [extension] such as `.lrc`: next to a local file, or in the folder of an
/// Android document. Network songs and CUE tracks, which share one audio
/// file, have none.
class LyricsSidecarStore {
  const LyricsSidecarStore({this.extension = mlrcExtension});

  /// The sidecar's file extension, without the dot.
  final String extension;

  String? _localPath(String source) {
    if (source.isEmpty ||
        source.startsWith('network://') ||
        isContentUri(source) ||
        isCueVirtualPath(source)) {
      return null;
    }
    final uri = Uri.tryParse(source);
    final path = uri?.scheme == 'file' ? uri!.toFilePath() : source;
    return p.posix.isAbsolute(path) || p.windows.isAbsolute(path) ? path : null;
  }

  bool _isDocument(String source) =>
      isContentUri(source) && !isCueVirtualPath(source) && !isDesktopPlatform;

  bool canWrite(String source) =>
      _localPath(source) != null || _isDocument(source);

  /// The sidecar text next to [source], or null when it has none.
  Future<String?> read(String source) async {
    final path = _localPath(source);
    if (path != null) {
      final file = File(sidecarPathFor(path, extension));
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size > _maxSidecarBytes) {
        return null;
      }
      return utf8.decode(await file.readAsBytes(), allowMalformed: true);
    }
    if (_isDocument(source)) {
      if (!SafSiblings.extensions.contains(extension)) {
        return PlatformBridge.readSafSidecar(source, extension);
      }
      final sidecar = await SafSiblings.instance.sidecar(source, extension);
      if (sidecar == null || sidecar.size > _maxSidecarBytes) return null;
      return PlatformBridge.readSafText(sidecar.uri, _maxSidecarBytes);
    }
    return null;
  }

  Future<void> write(String source, String content) async {
    final path = _localPath(source);
    if (path != null) {
      final target = File(sidecarPathFor(path, extension));
      final staged = File('${target.path}.partial');
      await staged.writeAsString(content, flush: true);
      try {
        await staged.rename(target.path);
      } catch (_) {
        await staged.delete().catchError((_) => staged);
        rethrow;
      }
      return;
    }
    if (_isDocument(source)) {
      final bool written;
      try {
        written = await PlatformBridge.writeSafSidecar(
          source,
          content,
          extension,
        );
      } finally {
        SafSiblings.instance.forget(source);
      }
      if (!written) {
        throw StateError('The .$extension file could not be written');
      }
      return;
    }
    throw UnsupportedError('This song cannot have a .$extension file');
  }
}
