import 'dart:convert';

/// One line of a [LyricsDraft]: its time, its text, and the raw LRC that
/// rides along with it (word timing, a singer prefix, translations and
/// backing vocals) so saving an edit keeps what the editor does not show.
class LyricsDraftLine {
  const LyricsDraftLine({
    required this.time,
    required this.text,
    this.voice = '',
    this.content,
    this.contentTime,
    this.supplements = const [],
    this.background = const [],
  });

  /// An empty line to type into.
  const LyricsDraftLine.blank()
    : time = null,
      text = '',
      voice = '',
      content = null,
      contentTime = null,
      supplements = const [],
      background = const [];

  /// When the line is sung, or null while it has no time yet.
  final Duration? time;

  /// The words shown in the player.
  final String text;

  /// The singer prefix, such as `v2:`, written before the text.
  final String voice;

  /// The original LRC after the timestamp, with enhanced word timing, valid
  /// while [text] is unchanged.
  final String? content;

  /// The line time [content]'s word timing was written for.
  final Duration? contentTime;

  /// `[x-...:<ms>:...]` translation and pronunciation tags keyed to this
  /// line, as (kind, payload).
  final List<(String, String)> supplements;

  /// `[bg:...]` backing vocals sung with this line, as the raw content.
  final List<String> background;

  LyricsDraftLine copyWith({
    Duration? time,
    bool clearTime = false,
    String? text,
  }) => LyricsDraftLine(
    time: clearTime ? null : time ?? this.time,
    text: text ?? this.text,
    voice: voice,
    content: content,
    contentTime: contentTime,
    supplements: supplements,
    background: background,
  );
}

/// Editable lyrics read from LRC or plain text, written back as LRC.
///
/// Times are where each line is sung: an `[offset:]` tag is applied on
/// reading and dropped on writing. Other tags, word timing, translations
/// and backing vocals are kept; word timing moves with its line and is
/// dropped from a line whose text changes.
class LyricsDraft {
  const LyricsDraft({
    required this.lines,
    this.header = const [],
    this.footer = const [],
  });

  /// Tag lines such as `[ti:...]`, written first and unchanged.
  final List<String> header;
  final List<LyricsDraftLine> lines;

  /// A trailing "Written by:" credit, written last and unchanged.
  final List<String> footer;

  static final _lineTime = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  static final _wordTime = RegExp(r'<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>');
  static final _voice = RegExp(
    r'^((?:<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>\s*)*)(v[1-9]\d*:[ \t]*)',
    caseSensitive: false,
  );
  static final _idTag = RegExp(
    r'^\[(ti|ar|al|by|offset|length|re|ve|tool|au|la|encoder|instrumental|x-[a-z0-9_-]+):.*\]$',
    caseSensitive: false,
  );
  static final _supplement = RegExp(
    r'^\[x-(romaji-words|romaji|translation):(\d+):([^\]]*)\]$',
    caseSensitive: false,
  );
  static final _background = RegExp(r'^\[bg:(.*)\]$', caseSensitive: false);
  static final _credit = RegExp(r'^Written\s+by\s*:', caseSensitive: false);

  /// Whether [raw] is lyrics the editor can read: LRC or plain text, not
  /// TTML.
  static bool canEdit(String raw) {
    // The player's TTML check.
    final head = raw.trimLeft();
    return !(head.startsWith('<?xml') ||
        head.startsWith('<tt') ||
        head.contains('<tt ') ||
        head.contains('http://www.w3.org/ns/ttml'));
  }

  factory LyricsDraft.parse(String raw) {
    final header = <String>[];
    final footer = <String>[];
    final lines = <LyricsDraftLine>[];
    final supplements = <int, List<(String, String)>>{};
    var offsetMs = 0;
    for (final source in raw.split(RegExp(r'\r\n|\r|\n'))) {
      final row = source.trim();
      if (row.isEmpty) continue;
      final background = _background.firstMatch(row);
      if (background != null) {
        if (lines.isEmpty) {
          header.add(row);
        } else {
          final lead = lines.removeLast();
          lines.add(
            LyricsDraftLine(
              time: lead.time,
              text: lead.text,
              voice: lead.voice,
              content: lead.content,
              contentTime: lead.contentTime,
              background: [...lead.background, background.group(1)!.trim()],
            ),
          );
        }
        continue;
      }
      final supplement = _supplement.firstMatch(row);
      if (supplement != null) {
        final ms = int.parse(supplement.group(2)!);
        (supplements[ms] ??= []).add((
          supplement.group(1)!.toLowerCase(),
          supplement.group(3)!,
        ));
        continue;
      }
      final tag = _idTag.firstMatch(row);
      if (tag != null) {
        if (tag.group(1)!.toLowerCase() == 'offset') {
          offsetMs =
              int.tryParse(
                row.substring(row.indexOf(':') + 1, row.length - 1).trim(),
              ) ??
              0;
        } else {
          header.add(row);
        }
        continue;
      }
      final stamps = <Duration>[];
      var rest = row;
      while (true) {
        final match = _lineTime.matchAsPrefix(rest);
        if (match == null) break;
        stamps.add(_duration(match));
        rest = rest.substring(match.end);
      }
      // A timestamp later in the row is part of its text, as in the player.
      rest = rest.trim();
      final voiceMatch = _voice.firstMatch(rest);
      final voice = voiceMatch?.group(2)?.trim() ?? '';
      final body = voiceMatch == null
          ? rest
          : rest.replaceRange(0, voiceMatch.end, voiceMatch.group(1)!);
      final text = body.replaceAll(_wordTime, '').trim();
      final hasWords = _wordTime.hasMatch(body);
      if (stamps.isEmpty) {
        lines.add(
          LyricsDraftLine(
            time: null,
            text: text,
            voice: voice,
            content: hasWords ? body : null,
          ),
        );
        continue;
      }
      for (final stamp in stamps) {
        lines.add(
          LyricsDraftLine(
            time: stamp,
            text: text,
            voice: voice,
            content: hasWords ? body : null,
            contentTime: stamp,
          ),
        );
      }
    }

    // Supplements are keyed to the written line time, before the offset.
    // Older files mix centisecond lines with millisecond keys, so match the
    // nearest line within 10ms as the player does.
    final matched = List.generate(lines.length, (_) => <(String, String)>[]);
    for (final entry in supplements.entries) {
      int? nearest;
      var distance = 11;
      for (var i = 0; i < lines.length; i++) {
        final time = lines[i].time;
        if (time == null) continue;
        final delta = (time.inMilliseconds - entry.key).abs();
        if (delta < distance) {
          nearest = i;
          distance = delta;
        }
      }
      if (nearest != null) matched[nearest].addAll(entry.value);
    }

    Duration? shifted(Duration? time) {
      if (time == null || offsetMs == 0) return time;
      final ms = time.inMilliseconds - offsetMs;
      return Duration(milliseconds: ms < 0 ? 0 : ms);
    }

    final drafted = [
      for (final (index, line) in lines.indexed)
        LyricsDraftLine(
          time: shifted(line.time),
          text: line.text,
          voice: line.voice,
          content: line.content,
          contentTime: shifted(line.contentTime),
          supplements: List.unmodifiable(matched[index]),
          background: List.unmodifiable(line.background),
        ),
    ];
    // The player drops a final "Written by:" line from the lyrics and shows
    // it as the credit; keep it out of the lines to time.
    if (drafted.isNotEmpty &&
        drafted.last.time == null &&
        _credit.hasMatch(drafted.last.text)) {
      footer.add(drafted.removeLast().text);
    }
    // Word timing written against the file's offset moves with its line.
    final lead = offsetMs == 0
        ? drafted
        : [
            for (final line in drafted)
              LyricsDraftLine(
                time: line.time,
                text: line.text,
                voice: line.voice,
                content: line.content == null
                    ? null
                    : _shiftWords(line.content!, -offsetMs),
                contentTime: line.contentTime,
                supplements: _shiftSupplements(line.supplements, -offsetMs),
                background: [
                  for (final row in line.background)
                    _shiftWords(row, -offsetMs),
                ],
              ),
          ];
    return LyricsDraft(
      header: List.unmodifiable(header),
      lines: List.unmodifiable(lead),
      footer: List.unmodifiable(footer),
    );
  }

  /// Whether any line has a time, so the lyrics play in sync.
  bool get synced => lines.any((line) => line.time != null);

  /// The draft as LRC, or as plain text while no line has a time.
  String toLrc() {
    final out = <String>[];
    final synced = this.synced;
    if (synced) out.addAll(header);
    for (final line in lines) {
      final time = line.time;
      final delta = time != null && line.contentTime != null
          ? (time - line.contentTime!).inMilliseconds
          : 0;
      final keepsWords =
          line.content != null &&
          time != null &&
          line.contentTime != null &&
          line.content!.replaceAll(_wordTime, '').trim() == line.text.trim();
      final body = keepsWords
          ? _shiftWords(line.content!, delta)
          : line.text.trim();
      final voiced = line.voice.isEmpty
          ? body
          : body.isEmpty
          ? line.voice
          : '${line.voice} $body';
      if (time == null) {
        if (line.text.trim().isNotEmpty) out.add(voiced);
        continue;
      }
      out.add('[${formatLyricsTime(time)}]$voiced');
      final shifted = line.contentTime == null
          ? line.supplements
          : _shiftSupplements(line.supplements, delta);
      for (final (kind, payload) in shifted) {
        out.add('[x-$kind:${time.inMilliseconds}:$payload]');
      }
      for (final row in line.background) {
        out.add('[bg:${_shiftWords(row, delta)}]');
      }
    }
    out.addAll(footer);
    return out.join('\n');
  }

  static Duration _duration(Match match) {
    final fraction = match.group(3) ?? '0';
    final ms = switch (fraction.length) {
      1 => int.parse(fraction) * 100,
      2 => int.parse(fraction) * 10,
      _ => int.parse(fraction),
    };
    return Duration(
      minutes: int.parse(match.group(1)!),
      seconds: int.parse(match.group(2)!),
      milliseconds: ms,
    );
  }

  static String _shiftWords(String content, int deltaMs) {
    if (deltaMs == 0) return content;
    return content.replaceAllMapped(_wordTime, (match) {
      final ms = _duration(match).inMilliseconds + deltaMs;
      return '<${formatLyricsTime(Duration(milliseconds: ms < 0 ? 0 : ms))}>';
    });
  }

  static List<(String, String)> _shiftSupplements(
    List<(String, String)> supplements,
    int deltaMs,
  ) {
    if (deltaMs == 0) return supplements;
    return [
      for (final (kind, payload) in supplements)
        kind == 'romaji-words'
            ? (kind, _shiftRomanizationWords(payload, deltaMs))
            : (kind, payload),
    ];
  }

  /// Pronunciation word timing is absolute JSON; it moves with its line.
  static String _shiftRomanizationWords(String payload, int deltaMs) {
    try {
      final words = jsonDecode(utf8.decode(base64.decode(payload)));
      if (words is! List) return payload;
      int shift(Object? value) {
        final ms = (value is int ? value : 0) + deltaMs;
        return ms < 0 ? 0 : ms;
      }

      return base64.encode(
        utf8.encode(
          jsonEncode([
            for (final word in words)
              if (word is Map)
                {
                  ...word,
                  'startTimeMs': shift(word['startTimeMs']),
                  'endTimeMs': shift(word['endTimeMs']),
                },
          ]),
        ),
      );
    } on FormatException {
      return payload;
    }
  }
}

/// `mm:ss.xx` as LRC writes it, with milliseconds when centiseconds would
/// round them.
String formatLyricsTime(Duration time) {
  final ms = time.inMilliseconds < 0 ? 0 : time.inMilliseconds;
  final minutes = (ms ~/ 60000).toString().padLeft(2, '0');
  final seconds = (ms ~/ 1000 % 60).toString().padLeft(2, '0');
  final fraction = ms % 1000;
  final tail = fraction % 10 == 0
      ? (fraction ~/ 10).toString().padLeft(2, '0')
      : fraction.toString().padLeft(3, '0');
  return '$minutes:$seconds.$tail';
}
