import 'package:mornye/utils/lyrics_parser.dart';

/// Visual order is separate from the chronological timeline: a backing part
/// stays directly under its lead, including when another singer starts first.
class LyricDisplayLayout {
  final List<int> lineOrder;
  final List<int> rowForLine;
  final List<int> leadForLine;
  final List<int> focusForLine;

  LyricDisplayLayout(List<LyricLine> lines)
    : lineOrder = [],
      rowForLine = List.filled(lines.length, 0),
      leadForLine = List.generate(lines.length, (index) => index),
      focusForLine = List.filled(lines.length, 0) {
    final leads = {
      for (var i = 0; i < lines.length; i++)
        if (!lines[i].isBackground && lines[i].vocalGroup != null)
          lines[i].vocalGroup!: i,
    };
    final backing = <int, List<int>>{};
    int? previousLead;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!line.isBackground) {
        if (line.text.isNotEmpty) previousLead = i;
        continue;
      }
      final lead = line.vocalGroup == null
          ? previousLead
          : leads[line.vocalGroup];
      if (lead == null) continue;
      leadForLine[i] = lead;
      backing.putIfAbsent(lead, () => []).add(i);
    }
    for (var i = 0; i < lines.length; i++) {
      if (leadForLine[i] != i) continue;
      lineOrder.add(i);
      lineOrder.addAll(backing[i] ?? const []);
    }
    for (var row = 0; row < lineOrder.length; row++) {
      rowForLine[lineOrder[row]] = row;
    }
    var latestLead = 0;
    Duration? latestLeadStart;
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].isBackground && lines[i].time != latestLeadStart) {
        latestLead = i;
        latestLeadStart = lines[i].time;
      }
      // Simultaneous leads share the first row as their scroll anchor, so the
      // earlier singer cannot be pushed above the viewport while still singing.
      // A delayed echo must not scroll backwards after the next lead starts.
      focusForLine[i] = lines[i].isBackground && leadForLine[i] > latestLead
          ? leadForLine[i]
          : latestLead;
    }
  }
}

/// Indexed playback queries retain overlapping voices without walking every
/// preceding line on each position report. Build once for a lyrics snapshot.
class LyricTimelineIndex {
  LyricTimelineIndex(this.lines)
    : starts = List.unmodifiable(lines.map((line) => line.time)),
      _heldLeads = List.filled(lines.length, -1) {
    var heldLead = -1;
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (!line.isBackground &&
          line.text.isNotEmpty &&
          (heldLead < 0 || line.time != lines[heldLead].time)) {
        heldLead = index;
      }
      _heldLeads[index] = heldLead;
    }
    while (_leafCount < lines.length) {
      _leafCount *= 2;
    }
    _latestEnds = List.filled(_leafCount * 2, null);
    for (var index = 0; index < lines.length; index++) {
      if (lines[index].text.isNotEmpty) {
        _latestEnds[_leafCount + index] = lines[index].end;
      }
    }
    for (var index = _leafCount - 1; index > 0; index--) {
      final left = _latestEnds[index * 2];
      final right = _latestEnds[index * 2 + 1];
      _latestEnds[index] = left == null || (right != null && right > left)
          ? right
          : left;
    }
  }

  final List<LyricLine> lines;
  final List<Duration> starts;
  final List<int> _heldLeads;
  int _leafCount = 1;
  late final List<Duration?> _latestEnds;

  Set<int> activeIndices(Duration position, int currentIndex) {
    if (currentIndex < 0) return {};
    final active = <int>{};
    void collect(int node, int start, int end) {
      final latestEnd = _latestEnds[node];
      if (start >= currentIndex || latestEnd == null || latestEnd <= position) {
        return;
      }
      if (end - start == 1) {
        active.add(start);
        return;
      }
      final middle = (start + end) ~/ 2;
      collect(node * 2, start, middle);
      collect(node * 2 + 1, middle, end);
    }

    collect(1, 0, _leafCount);
    final current = lines[currentIndex];
    final boundedVoice =
        (current.voice != null || current.isBackground) &&
        current.text.isNotEmpty &&
        current.end != null;
    if (!boundedVoice || current.end! > position) active.add(currentIndex);
    for (
      var index = currentIndex - 1;
      index >= 0 && lines[index].time == current.time;
      index--
    ) {
      if (lines[index].text.isNotEmpty && lines[index].end == null) {
        active.add(index);
      }
    }
    final heldLead = _heldLeads[currentIndex];
    if (heldLead >= 0) active.add(heldLead);
    return active;
  }
}

/// Inserts empty, bounded rows for instrumental countdowns in the player.
/// Unmarked gaps in plain LRC cannot be distinguished from held vocals: only
/// use explicit empty timestamps or known line/word ends, never an estimate.
List<LyricLine> lyricsTimelineWithGaps(List<LyricLine> lines) {
  const minimumGap = Duration(seconds: 3);
  final timeline = <LyricLine>[];
  Duration? gapStart;
  Duration? latestVocalEnd;

  for (final line in lines) {
    if (line.text.trim().isEmpty) {
      gapStart ??= line.time;
      continue;
    }

    var start = timeline.isEmpty ? Duration.zero : gapStart;
    // A second vocal line may overlap a previous, longer one.
    if (start != null && latestVocalEnd != null && start < latestVocalEnd) {
      start = latestVocalEnd;
    }
    if (start != null && line.time - start >= minimumGap) {
      timeline.add(LyricLine(time: start, end: line.time, text: ''));
    }
    timeline.add(line);

    final lastWord = line.words.lastOrNull;
    var end = line.end;
    if (lastWord != null) {
      if (lastWord.end != null && (end == null || lastWord.end! > end)) {
        end = lastWord.end;
      }
      if (end != null && end < lastWord.time) end = null;
    }
    if (end != null && end < line.time) end = null;
    gapStart = end;
    if (end != null && (latestVocalEnd == null || end > latestVocalEnd)) {
      latestVocalEnd = end;
    }
  }
  // No following vocal means no countdown: trailing blank timestamps are
  // intentionally omitted, and credits stay after the last sung line.
  return List.unmodifiable(timeline);
}

/// Gives every word-timed line a known end for the player. Enhanced LRC often
/// omits the closing timestamp after the final word, which used to stop its
/// sweep after a fixed moment while the word was still being held.
///
/// A following line within [nearGap] receives the remaining time, so the last
/// word keeps sweeping slowly into it. A distant line usually follows a break:
/// the word then ends after a duration derived from the line's own pace.
/// Apply after [lyricsTimelineWithGaps]; countdown rows never use estimates.
List<LyricLine> lyricsWithDisplayEnds(
  List<LyricLine> timeline, {
  Duration nearGap = const Duration(seconds: 4),
}) {
  final result = <LyricLine>[];
  for (var i = 0; i < timeline.length; i++) {
    final line = timeline[i];
    final last = line.words.lastOrNull;
    if (line.text.isEmpty || last == null) {
      result.add(line);
      continue;
    }
    var end = line.end;
    if (last.end != null && (end == null || last.end! > end)) end = last.end;
    var words = line.words;
    if (last.end == null || last.end! <= last.time) {
      // An explicit line end still bounds an untimed final word.
      final estimate = end != null && end > last.time
          ? end
          : _estimatedFinalWordEnd(
              line.words,
              _nextBoundary(timeline, i),
              nearGap,
            );
      words = [
        ...line.words.take(line.words.length - 1),
        LyricWord(time: last.time, end: estimate, text: last.text),
      ];
      if (end == null || end < estimate) end = estimate;
    }
    if (end == line.end && identical(words, line.words)) {
      result.add(line);
      continue;
    }
    result.add(
      LyricLine(
        time: line.time,
        end: end,
        text: line.text,
        words: words,
        romanization: line.romanization,
        romanizationWords: line.romanizationWords,
        translation: line.translation,
        voice: line.voice,
        isBackground: line.isBackground,
        vocalGroup: line.vocalGroup,
      ),
    );
  }
  return List.unmodifiable(result);
}

/// The next lead line or countdown after [index]; backing parts and singers
/// starting together do not end a line.
Duration? _nextBoundary(List<LyricLine> lines, int index) {
  final start = lines[index].time;
  for (var i = index + 1; i < lines.length; i++) {
    final line = lines[i];
    if (!line.isBackground && line.time > start) return line.time;
  }
  return null;
}

Duration _estimatedFinalWordEnd(
  List<LyricWord> words,
  Duration? next,
  Duration nearGap,
) {
  final start = words.last.time;
  final paces = <int>[
    for (var i = 0; i + 1 < words.length; i++)
      ((words[i].end ?? words[i + 1].time) - words[i].time).inMilliseconds,
  ].where((value) => value > 0).toList()..sort();
  final pace = paces.isEmpty ? 600 : paces[paces.length ~/ 2];
  // A final word is usually held longer than the line's typical syllable.
  final estimate =
      start + Duration(milliseconds: (pace * 2.5).clamp(700, 3000).round());
  if (next == null) return estimate;
  if (next <= start) {
    return start + Duration(milliseconds: pace.clamp(150, 400));
  }
  if (next - start <= nearGap) return next;
  return estimate;
}

/// Moves every line and word [offset] later (earlier when negative), for the
/// listener's lyrics timing setting. Times stop at the start of the track.
List<LyricLine> lyricsShiftedBy(List<LyricLine> lines, Duration offset) {
  if (offset == Duration.zero) return lines;
  Duration shift(Duration time) {
    final shifted = time + offset;
    return shifted < Duration.zero ? Duration.zero : shifted;
  }

  List<LyricWord> shiftWords(List<LyricWord> words) => [
    for (final word in words)
      LyricWord(
        time: shift(word.time),
        end: word.end == null ? null : shift(word.end!),
        text: word.text,
      ),
  ];

  return List.unmodifiable([
    for (final line in lines)
      LyricLine(
        time: shift(line.time),
        end: line.end == null ? null : shift(line.end!),
        text: line.text,
        words: shiftWords(line.words),
        romanization: line.romanization,
        romanizationWords: shiftWords(line.romanizationWords),
        translation: line.translation,
        voice: line.voice,
        isBackground: line.isBackground,
        vocalGroup: line.vocalGroup,
      ),
  ]);
}
