import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:xml/xml.dart';

Uint8List _encodeLyricsInBackground(String raw) =>
    Uint8List.fromList(utf8.encode(raw));

ParsedLyrics _parseLyricsInBackground(String raw) => LyricsParser.parse(raw);

ParsedLyrics _hydrateParsedLyricsInBackground(Map<String, dynamic> result) {
  LyricWord word(Map<dynamic, dynamic> value) => LyricWord(
    time: Duration(milliseconds: value['timeMs'] as int),
    end: value['endMs'] == null
        ? null
        : Duration(milliseconds: value['endMs'] as int),
    text: value['text'] as String,
  );
  List<LyricWord> words(dynamic value) => (value as List)
      .map((entry) => word(entry as Map))
      .toList(growable: false);
  final lines = <LyricLine>[];
  for (final value in result['lines'] as List) {
    final row = value as Map;
    final voice = row['voice'] as Map?;
    lines.add(
      LyricLine(
        time: Duration(milliseconds: row['timeMs'] as int),
        end: row['endMs'] == null
            ? null
            : Duration(milliseconds: row['endMs'] as int),
        text: row['text'] as String,
        words: words(row['words']),
        romanization: row['romanization'] as String?,
        romanizationWords: words(row['romanizationWords']),
        translation: row['translation'] as String?,
        voice: voice == null
            ? null
            : LyricVoice(
                id: voice['id'] as String,
                index: voice['index'] as int,
                isGroup: voice['isGroup'] as bool,
              ),
        isBackground: row['isBackground'] as bool,
        vocalGroup: row['vocalGroup'] as int?,
      ),
    );
  }
  return ParsedLyrics(
    synced: result['synced'] as bool,
    wordSynced: result['wordSynced'] as bool,
    lines: lines,
    plainText: result['plainText'] as String,
    writers: result['writers'] as String?,
    provider: result['provider'] as String?,
  );
}

class LyricWord {
  final Duration time;
  final Duration? end;
  final String text;

  const LyricWord({required this.time, this.end, required this.text});
}

class LyricVoice {
  final String id;
  final int index;
  final bool isGroup;

  const LyricVoice({
    required this.id,
    required this.index,
    this.isGroup = false,
  });
}

class LyricLine {
  final Duration time;
  final Duration? end;
  final String text;
  final List<LyricWord> words;
  final String? romanization;
  final List<LyricWord> romanizationWords;
  final String? translation;
  final LyricVoice? voice;
  final bool isBackground;

  /// Links backing vocals to their lead even when another singer overlaps.
  final int? vocalGroup;

  const LyricLine({
    required this.time,
    this.end,
    required this.text,
    this.words = const [],
    this.romanization,
    this.romanizationWords = const [],
    this.translation,
    this.voice,
    this.isBackground = false,
    this.vocalGroup,
  });

  bool get hasWordTiming => words.isNotEmpty;

  /// This line showing [translation] instead of its own.
  LyricLine withTranslation(String? translation) => LyricLine(
    time: time,
    end: end,
    text: text,
    words: words,
    romanization: romanization,
    romanizationWords: romanizationWords,
    translation: translation,
    voice: voice,
    isBackground: isBackground,
    vocalGroup: vocalGroup,
  );
}

class ParsedLyrics {
  final bool synced;
  final bool wordSynced;
  final List<LyricLine> lines;
  final String plainText;
  final String? writers;
  final String? provider;

  const ParsedLyrics({
    required this.synced,
    required this.wordSynced,
    required this.lines,
    required this.plainText,
    this.writers,
    this.provider,
  });

  bool get isEmpty => lines.isEmpty && plainText.trim().isEmpty;

  static const ParsedLyrics empty = ParsedLyrics(
    synced: false,
    wordSynced: false,
    lines: [],
    plainText: '',
  );
}

class LyricsParser {
  LyricsParser._();

  // [mm:ss.xx] or [mm:ss.xxx] or [mm:ss]
  static final RegExp _lineTimeTag = RegExp(
    r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]',
  );

  // <mm:ss.xx> inline word timestamp (enhanced LRC).
  static final RegExp _wordTimeTag = RegExp(
    r'<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>',
  );
  static final RegExp _voicePrefix = RegExp(
    r'^(\s*(?:<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>\s*)*)(v[1-9]\d*):[ \t]*',
    caseSensitive: false,
  );
  static final RegExp _backgroundLine = RegExp(
    r'^\[bg:(.*)\]$',
    caseSensitive: false,
  );

  static (String, LyricVoice?) _vocalText(String content) {
    final match = _voicePrefix.firstMatch(content);
    if (match == null) return (content, null);
    final id = match.group(2)!.toLowerCase();
    final number = int.tryParse(id.substring(1));
    return (
      content.replaceRange(
        0,
        match.end,
        match.group(1)!.replaceAll(RegExp(r'\s+'), ''),
      ),
      LyricVoice(id: id, index: (number ?? 1) - 1, isGroup: id == 'v3'),
    );
  }

  // ID tags such as [ti:..], [ar:..], [offset:..].
  static final RegExp _idTag = RegExp(
    r'^\[(ti|ar|al|by|offset|length|re|ve|tool|au|la|encoder|instrumental|x-[a-z0-9_-]+):.*\]$',
    caseSensitive: false,
  );
  static final RegExp _supplementTag = RegExp(
    r'^\[x-(romaji-words|romaji|translation):(\d+):([^\]]*)\]$',
    caseSensitive: false,
  );
  static final RegExp _writerCredit = RegExp(
    r'^Written\s+by\s*:\s*(.+)$',
    caseSensitive: false,
  );

  static bool _hasUsableTiming(List<LyricLine> lines) {
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.text.trim().isEmpty ||
          (i == lines.length - 1 && _writerCredit.hasMatch(line.text.trim()))) {
        continue;
      }
      if (line.time > Duration.zero ||
          (line.end ?? Duration.zero) > Duration.zero ||
          line.words.any(
            (word) =>
                word.text.trim().isNotEmpty &&
                (word.time > Duration.zero ||
                    (word.end ?? Duration.zero) > Duration.zero),
          )) {
        return true;
      }
    }
    return false;
  }

  static ParsedLyrics parse(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return ParsedLyrics.empty;

    if (_looksLikeTtml(text)) {
      final ttml = _parseTtml(text);
      if (ttml != null && ttml.lines.isNotEmpty) {
        return _withCredits(text, ttml);
      }
    }

    return _withCredits(text, _parseLrcOrPlain(text));
  }

  /// Production parsing runs away from rendering. The synchronous parser
  /// remains the compatibility contract for old native builds and test hosts.
  static Future<ParsedLyrics> parseAsyncNative(String? raw) async {
    if (raw == null || raw.isEmpty) return ParsedLyrics.empty;
    Map<String, dynamic> result;
    try {
      final bytes = await compute(_encodeLyricsInBackground, raw);
      result = await PlatformBridge.runNativeDataJob({
        'operation': 'parse_lyrics',
      }, bytes: bytes);
    } on MissingPluginException {
      return compute(_parseLyricsInBackground, raw);
    } on PlatformException catch (error) {
      // Rust bounds its recursive XML tokenizer. The isolated compatibility
      // parser retains support for valid documents beyond that native limit.
      if (error.message?.contains('XML nesting exceeds') != true) rethrow;
      return compute(_parseLyricsInBackground, raw);
    }
    return compute(_hydrateParsedLyricsInBackground, result);
  }

  static ParsedLyrics _withCredits(String raw, ParsedLyrics lyrics) {
    String? tag(String name) => RegExp(
      '^\\[$name:([^\\]\\r\\n]*)\\]\\s*\$',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(raw)?.group(1)?.trim();
    var writers = tag('au');
    var provider = tag('x-provider');
    final credit = tag('by') ?? '';
    provider ??= RegExp(r'\bvia\s+([^\(]+)', caseSensitive: false)
        .firstMatch(credit)
        ?.group(1)
        ?.trim()
        .replaceFirst(RegExp(r'\s+API$', caseSensitive: false), '');
    provider ??= RegExp(
      r'\(source:\s*([^\)]+)\)',
      caseSensitive: false,
    ).firstMatch(credit)?.group(1)?.trim();
    provider = provider?.replaceFirst(
      RegExp(r'^extension:', caseSensitive: false),
      '',
    );
    if (_looksLikeTtml(raw)) {
      try {
        final doc = XmlDocument.parse(raw);
        final names = doc.descendants
            .whereType<XmlElement>()
            .where((node) => node.name.local == 'songwriter')
            .map((node) => node.innerText.trim())
            .where((name) => name.isNotEmpty)
            .toSet();
        if (names.isNotEmpty) writers = names.join(', ');
      } on XmlParserException {
        // Malformed optional credits must not prevent lyric playback.
      }
    }
    var lines = lyrics.lines;
    var plainText = lyrics.plainText;
    if (lines.isNotEmpty) {
      final trailer = _writerCredit.firstMatch(lines.last.text.trim());
      if (trailer != null) {
        writers ??= trailer.group(1)?.trim();
        lines = lines.sublist(0, lines.length - 1);
        plainText = lines.map((line) => line.text).join('\n');
      }
    } else {
      // Untimed provider results also keep the optional writer footer.
      final plainLines = plainText.split('\n');
      final trailer = _writerCredit.firstMatch(plainLines.last.trim());
      if (trailer != null) {
        writers ??= trailer.group(1)?.trim();
        plainText = plainLines.take(plainLines.length - 1).join('\n');
      }
    }
    return ParsedLyrics(
      synced: lyrics.synced,
      wordSynced: lyrics.wordSynced,
      lines: lyrics.synced ? lines : const [],
      plainText: plainText,
      writers: writers?.isNotEmpty == true ? writers : null,
      provider: provider?.isNotEmpty == true ? provider : null,
    );
  }

  static bool _looksLikeTtml(String text) {
    final head = text.trimLeft();
    return head.startsWith('<?xml') ||
        head.startsWith('<tt') ||
        head.contains('<tt ') ||
        head.contains('http://www.w3.org/ns/ttml');
  }

  static Duration? _toDuration(String? min, String? sec, String? frac) {
    if (min == null || sec == null) return null;
    final m = int.tryParse(min) ?? 0;
    final s = int.tryParse(sec) ?? 0;
    var ms = 0;
    if (frac != null && frac.isNotEmpty) {
      // Normalize to milliseconds regardless of 2 or 3 digit fractions.
      final padded = frac.padRight(3, '0').substring(0, 3);
      ms = int.tryParse(padded) ?? 0;
    }
    return Duration(minutes: m, seconds: s, milliseconds: ms);
  }

  static ParsedLyrics _parseLrcOrPlain(String text) {
    final rawLines = text.split(RegExp(r'\r\n|\r|\n'));
    final parsed = <LyricLine>[];
    final plainBuffer = <String>[];
    final romanization = <int, String>{};
    final romanizationWords = <int, List<LyricWord>>{};
    final translation = <int, String>{};
    var sawTimestamp = false;
    var sawWordTiming = false;
    var offsetMs = 0;

    for (final rawLine in rawLines) {
      var line = rawLine.trimRight();
      if (line.trim().isEmpty) continue;

      final background = _backgroundLine.firstMatch(line.trim());
      if (background != null) line = background.group(1)!.trim();

      final supplement = _supplementTag.firstMatch(line.trim());
      if (supplement != null) {
        final time = int.tryParse(supplement.group(2)!);
        try {
          final value = utf8.decode(base64.decode(supplement.group(3)!)).trim();
          if (time != null && value.isNotEmpty) {
            final kind = supplement.group(1)!.toLowerCase();
            if (kind == 'romaji-words') {
              final words = _parseRomanizationWords(value);
              if (words.isNotEmpty) {
                romanizationWords.putIfAbsent(time, () => words);
              }
            } else {
              final target = kind == 'romaji' ? romanization : translation;
              target.putIfAbsent(time, () => value);
            }
          }
        } on FormatException {
          // Optional corrupt metadata must not hide the original lyrics.
        }
        continue;
      }

      // Capture [offset:] for timing correction, drop other ID tags.
      final idMatch = _idTag.firstMatch(line.trim());
      if (idMatch != null) {
        final key = idMatch.group(1)!.toLowerCase();
        if (key == 'offset') {
          final value = line
              .substring(line.indexOf(':') + 1)
              .replaceAll(']', '')
              .trim();
          offsetMs = int.tryParse(value) ?? 0;
        }
        continue;
      }

      final timeMatches = _lineTimeTag.allMatches(line).toList();
      if (timeMatches.isEmpty) {
        final (content, voice) = _vocalText(line.trim());
        final clean = content.replaceAll(_wordTimeTag, '').trim();
        plainBuffer.add(clean);
        if (background != null && parsed.isNotEmpty && clean.isNotEmpty) {
          final words = _parseWords(content);
          final previous = parsed.last;
          parsed.add(
            LyricLine(
              time: words.firstOrNull?.time ?? previous.time,
              end: words.lastOrNull?.end ?? previous.end,
              text: clean,
              words: words,
              voice: voice ?? previous.voice,
              isBackground: true,
              vocalGroup: previous.vocalGroup,
            ),
          );
          sawWordTiming |= words.isNotEmpty;
        }
        continue;
      }

      sawTimestamp = true;

      final lastTag = timeMatches.last;
      final (content, voice) = _vocalText(line.substring(lastTag.end).trim());

      // Enhanced LRC word timestamps inside the content.
      final words = _parseWords(content);
      if (words.isNotEmpty) sawWordTiming = true;
      final cleanContent = content.replaceAll(_wordTimeTag, '').trim();
      plainBuffer.add(cleanContent);

      // A line can have multiple timestamps (repeated chorus).
      for (final tm in timeMatches) {
        final d = _toDuration(tm.group(1), tm.group(2), tm.group(3));
        if (d == null) continue;
        parsed.add(
          LyricLine(
            time: d,
            end: words.lastOrNull?.end,
            text: cleanContent,
            words: words,
            voice:
                voice ?? (background != null ? parsed.lastOrNull?.voice : null),
            isBackground: background != null,
            vocalGroup: background != null
                ? parsed.lastOrNull?.vocalGroup
                : parsed.length,
          ),
        );
      }
    }

    if (!sawTimestamp) {
      return ParsedLyrics(
        synced: false,
        wordSynced: false,
        lines: const [],
        plainText: plainBuffer.where((l) => l.isNotEmpty).join('\n'),
      );
    }

    // Providers can put [00:00.00] on every plain-text row. Check the source
    // before applying offsets, which must not manufacture usable timing.
    final synced = _hasUsableTiming(parsed);
    _sortLines(parsed);
    final alignedRomanization = _alignSupplements(parsed, romanization);
    final alignedRomanizationWords = _alignSupplements(
      parsed,
      romanizationWords,
    );
    final alignedTranslation = _alignSupplements(parsed, translation);

    final adjusted =
        offsetMs == 0 &&
            alignedRomanization.isEmpty &&
            alignedTranslation.isEmpty
        ? parsed
        : parsed.map((l) {
            final romanization = alignedRomanization[l.time.inMilliseconds];
            final words =
                alignedRomanizationWords[l.time.inMilliseconds] ??
                const <LyricWord>[];
            // Keep readable text when optional timings are incomplete or
            // belong to a different revision of the transliteration.
            final validWords =
                words.map((word) => word.text).join() == romanization
                ? words
                : const <LyricWord>[];
            return LyricLine(
              time: _shift(l.time, offsetMs),
              end: l.end == null ? null : _shift(l.end!, offsetMs),
              text: l.text,
              voice: l.voice,
              isBackground: l.isBackground,
              vocalGroup: l.vocalGroup,
              romanization: romanization,
              romanizationWords: _shiftWords(validWords, offsetMs),
              translation: alignedTranslation[l.time.inMilliseconds],
              words: _shiftWords(l.words, offsetMs),
            );
          }).toList();

    return ParsedLyrics(
      synced: synced,
      wordSynced: synced && sawWordTiming,
      lines: adjusted,
      plainText: plainBuffer.where((l) => l.isNotEmpty).join('\n'),
    );
  }

  /// Older files may have centisecond line times alongside millisecond
  /// supplement times. Resolve each supplement to one nearest line, keeping
  /// exact matches when multiple metadata entries compete for that line.
  static Map<int, T> _alignSupplements<T>(
    List<LyricLine> lines,
    Map<int, T> supplements,
  ) {
    final matched = <int, (int, T)>{};
    for (final entry in supplements.entries) {
      var lo = 0;
      var hi = lines.length;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (lines[mid].time.inMilliseconds < entry.key) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      int? nearest;
      var distance = 11;
      for (final index in [lo - 1, lo]) {
        if (index < 0 || index >= lines.length) continue;
        final time = lines[index].time.inMilliseconds;
        final delta = (time - entry.key).abs();
        if (delta < distance) {
          nearest = time;
          distance = delta;
        }
      }
      if (nearest == null) continue;
      final previous = matched[nearest];
      if (previous == null || distance < previous.$1) {
        matched[nearest] = (distance, entry.value);
      }
    }
    return matched.map((time, match) => MapEntry(time, match.$2));
  }

  static List<LyricWord> _parseRomanizationWords(String raw) {
    final value = jsonDecode(raw);
    if (value is! List) return const [];
    final words = <LyricWord>[];
    for (final item in value) {
      if (item case {
        'text': final String text,
        'startTimeMs': final int start,
        'endTimeMs': final int end,
      }) {
        if (text.trim().isEmpty ||
            start < 0 ||
            end < start ||
            (words.isNotEmpty && words.last.time.inMilliseconds > start)) {
          return const [];
        }
        words.add(
          LyricWord(
            time: Duration(milliseconds: start),
            end: Duration(milliseconds: end),
            text: text,
          ),
        );
      } else {
        return const [];
      }
    }
    return words;
  }

  static List<LyricWord> _shiftWords(List<LyricWord> words, int offsetMs) {
    if (offsetMs == 0 || words.isEmpty) return words;
    return words
        .map(
          (word) => LyricWord(
            time: _shift(word.time, offsetMs),
            end: word.end == null ? null : _shift(word.end!, offsetMs),
            text: word.text,
          ),
        )
        .toList(growable: false);
  }

  static Duration _shift(Duration d, int offsetMs) {
    // LRC offset: positive value shifts lyrics earlier.
    final ms = d.inMilliseconds - offsetMs;
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  static List<LyricWord> _parseWords(String content) {
    final matches = _wordTimeTag.allMatches(content).toList();
    if (matches.isEmpty) return const [];

    final words = <LyricWord>[];
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      final d = _toDuration(m.group(1), m.group(2), m.group(3));
      if (d == null) continue;
      final start = m.end;
      final end = i + 1 < matches.length
          ? matches[i + 1].start
          : content.length;
      final word = content.substring(start, end);
      if (word.trim().isEmpty) {
        final previous = words.lastOrNull;
        if (previous != null && previous.end == null && d >= previous.time) {
          words[words.length - 1] = LyricWord(
            time: previous.time,
            end: d,
            text: previous.text,
          );
        }
        continue;
      }
      words.add(LyricWord(time: d, text: word));
    }
    return words;
  }

  static ParsedLyrics? _parseTtml(String text) {
    try {
      final doc = XmlDocument.parse(text);
      const metadataNamespace = 'http://www.w3.org/ns/ttml#metadata';
      final elements = doc.descendants.whereType<XmlElement>().toList();
      final paragraphs = elements.where((node) => node.name.local == 'p');
      if (paragraphs.isEmpty) return null;

      final voices = <String, LyricVoice>{};
      var individualIndex = 0;
      for (final agent in elements.where(
        (node) =>
            node.name.local == 'agent' &&
            node.name.namespaceUri == metadataNamespace,
      )) {
        final id = agent.getAttribute(
          'id',
          namespaceUri: 'http://www.w3.org/XML/1998/namespace',
        );
        if (id == null || id.isEmpty) continue;
        final group =
            agent.getAttribute('type') == 'group' || id.toLowerCase() == 'v3';
        voices[id] = LyricVoice(id: id, index: individualIndex, isGroup: group);
        if (!group) individualIndex++;
      }

      LyricVoice? voiceOf(XmlElement element, LyricVoice? inherited) {
        final id = element.getAttribute(
          'agent',
          namespaceUri: metadataNamespace,
        );
        if (id == null || id.isEmpty) return inherited;
        return voices.putIfAbsent(
          id,
          () => LyricVoice(
            id: id,
            index: individualIndex++,
            isGroup: id.toLowerCase() == 'v3',
          ),
        );
      }

      final lines = <LyricLine>[];
      final plain = <String>[];
      var sawWords = false;
      var nextVocalGroup = 0;

      for (final p in paragraphs) {
        final begin = _parseClock(p.getAttribute('begin'));
        final end = _parseClock(p.getAttribute('end'));

        LyricVoice? inheritedVoice;
        for (final ancestor
            in p.ancestors.whereType<XmlElement>().toList().reversed) {
          inheritedVoice = voiceOf(ancestor, inheritedVoice);
        }
        final runs = <_TtmlVocalRun>[];
        void visit(
          XmlNode node,
          LyricVoice? voice,
          bool background,
          Duration? wordBegin,
          Duration? wordEnd,
        ) {
          if (node is XmlText) {
            if (node.value.trim().isEmpty && runs.isEmpty) return;
            var run = runs
                .where(
                  (run) =>
                      run.voice?.id == voice?.id &&
                      run.background == background,
                )
                .firstOrNull;
            if (run == null) {
              if (node.value.trim().isEmpty) return;
              run = _TtmlVocalRun(voice, background);
              runs.add(run);
            }
            run.add(node.value, wordBegin, wordEnd);
          } else if (node is XmlElement) {
            final nextVoice = voiceOf(node, voice);
            final nextBackground =
                background ||
                node.getAttribute('role', namespaceUri: metadataNamespace) ==
                    'x-bg';
            final spanBegin = node == p
                ? null
                : _parseClock(node.getAttribute('begin'));
            final spanEnd = node == p
                ? null
                : _parseClock(node.getAttribute('end'));
            for (final child in node.children) {
              visit(
                child,
                nextVoice,
                nextBackground,
                spanBegin ?? wordBegin,
                spanEnd ?? wordEnd,
              );
            }
          }
        }

        visit(p, inheritedVoice, false, null, null);
        final leadGroups = {
          for (final run in runs)
            if (!run.background && run.text.isNotEmpty) run: nextVocalGroup++,
        };
        for (final run in runs) {
          final lineText = run.text;
          if (lineText.isEmpty) continue;
          plain.add(lineText);
          final words = run.words;
          final lineBegin = runs.length == 1
              ? begin
              : words.firstOrNull?.time ?? begin;
          if (lineBegin == null) continue;
          sawWords |= words.isNotEmpty;
          final lead = run.background
              ? leadGroups.keys
                        .where((lead) => lead.voice?.id == run.voice?.id)
                        .firstOrNull ??
                    leadGroups.keys.firstOrNull
              : run;
          lines.add(
            LyricLine(
              time: lineBegin,
              end: runs.length == 1 ? end : words.lastOrNull?.end ?? end,
              text: lineText,
              words: words,
              voice: run.voice,
              isBackground: run.background,
              vocalGroup:
                  leadGroups[lead] ??
                  (run.background ? lines.lastOrNull?.vocalGroup : null),
            ),
          );
        }
      }

      if (lines.isEmpty) {
        return ParsedLyrics(
          synced: false,
          wordSynced: false,
          lines: const [],
          plainText: plain.join('\n'),
        );
      }

      _sortLines(lines);
      final synced = _hasUsableTiming(lines);
      return ParsedLyrics(
        synced: synced,
        wordSynced: synced && sawWords,
        lines: lines,
        plainText: plain.where((l) => l.isNotEmpty).join('\n'),
      );
    } catch (_) {
      return null;
    }
  }

  // TTML clock value: "mm:ss.fff", "hh:mm:ss.fff" or "12.5s".
  static Duration? _parseClock(String? value) {
    if (value == null || value.isEmpty) return null;
    final v = value.trim();

    if (v.endsWith('s') && !v.contains(':')) {
      final seconds = double.tryParse(v.substring(0, v.length - 1));
      if (seconds == null) return null;
      return Duration(milliseconds: (seconds * 1000).round());
    }

    final parts = v.split(':');
    try {
      if (parts.length == 3) {
        final h = int.parse(parts[0]);
        final m = int.parse(parts[1]);
        final s = double.parse(parts[2]);
        return Duration(hours: h, minutes: m, milliseconds: (s * 1000).round());
      } else if (parts.length == 2) {
        final m = int.parse(parts[0]);
        final s = double.parse(parts[1]);
        return Duration(minutes: m, milliseconds: (s * 1000).round());
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  static int activeIndex(List<LyricLine> lines, Duration position) {
    if (lines.isEmpty) return -1;
    var lo = 0;
    var hi = lines.length - 1;
    var result = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].time <= position) {
        result = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return result;
  }

  static void _sortLines(List<LyricLine> lines) {
    // Simultaneous singers retain their document order.
    final order = {for (var i = 0; i < lines.length; i++) lines[i]: i};
    lines.sort((a, b) {
      final timing = a.time.compareTo(b.time);
      return timing != 0 ? timing : order[a]!.compareTo(order[b]!);
    });
  }
}

class _TtmlVocalRun {
  final LyricVoice? voice;
  final bool background;
  final List<(String, Duration?, Duration?)> _fragments = [];

  _TtmlVocalRun(this.voice, this.background);

  void add(String value, Duration? begin, Duration? end) {
    var text = value.replaceAll(RegExp(r'\s+'), ' ');
    if (_fragments.isEmpty || _fragments.last.$1.endsWith(' ')) {
      text = text.trimLeft();
    }
    if (text.isEmpty) return;
    if (_fragments.isNotEmpty &&
        (text.trim().isEmpty ||
            (begin == _fragments.last.$2 && end == _fragments.last.$3))) {
      final previous = _fragments.removeLast();
      _fragments.add(('${previous.$1}$text', previous.$2, previous.$3));
    } else {
      _fragments.add((text, begin, end));
    }
  }

  String get text => _fragments.map((fragment) => fragment.$1).join().trim();

  List<LyricWord> get words {
    // Never drop untimed text from a partially timed paragraph.
    if (_fragments.any((fragment) => fragment.$2 == null)) return const [];
    return [
      for (var i = 0; i < _fragments.length; i++)
        LyricWord(
          time: _fragments[i].$2!,
          end:
              _fragments[i].$3 != null && _fragments[i].$3! >= _fragments[i].$2!
              ? _fragments[i].$3
              : null,
          text: i == _fragments.length - 1
              ? _fragments[i].$1.trimRight()
              : _fragments[i].$1,
        ),
    ];
  }
}
