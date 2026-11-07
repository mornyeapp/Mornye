import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mornye/widgets/lyric_supplement_transition.dart';
import 'package:mornye/utils/lyrics_parser.dart';

final _rtlLyricCharacter = RegExp(
  r'[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFF\u{10800}-\u{10FFF}\u{1EE00}-\u{1EEFF}]',
  unicode: true,
);

/// Whether [text] contains right-to-left script characters (such as Arabic or
/// Hebrew).
bool isRtlLyricText(String text) => _rtlLyricCharacter.hasMatch(text);

/// Resolves the paragraph direction for [text], falling back to [ambient]
/// when the line does not use a right-to-left script.
TextDirection lyricTextDirection(
  String text, [
  TextDirection ambient = TextDirection.ltr,
]) => isRtlLyricText(text) ? TextDirection.rtl : ambient;

/// Keeps each pronunciation phrase under the lyric with the same start time.
/// Only shared word boundaries are used; line-only timing cannot identify
/// which original characters a pronunciation belongs to.
class LyricPronunciationLayout {
  final List<_PronunciationRow> _rows;
  final TextDirection textDirection;

  const LyricPronunciationLayout._(
    this._rows, [
    this.textDirection = TextDirection.ltr,
  ]);

  static const _phraseGap = 4.0;
  static const _pronunciationGap = 2.0;
  static const _rowGap = 6.0;
  static final _whitespaceRun = RegExp(r'\s+');
  static final _endsWithWhitespace = RegExp(r'\s$');
  static final _startsWithWhitespace = RegExp(r'^\s');

  double get primaryHeight =>
      _rows.fold(0.0, (height, row) => height + row.primaryHeight) +
      (_rows.length - 1) * _rowGap;

  double get pronunciationHeight => _rows.fold(
    0.0,
    (height, row) => height + _pronunciationGap + row.pronunciationHeight,
  );

  static LyricPronunciationLayout? measure({
    required LyricLine line,
    required TextStyle primaryStyle,
    required TextStyle pronunciationStyle,
    required double maxWidth,
    required TextScaler textScaler,
    required TextDirection textDirection,
    Locale? locale,
  }) {
    final original = line.words;
    final pronunciation = line.romanizationWords;
    if (original.isEmpty ||
        pronunciation.isEmpty ||
        !maxWidth.isFinite ||
        maxWidth <= 0 ||
        isRtlLyricText(line.text) ||
        isRtlLyricText(line.romanization ?? '')) {
      return null;
    }
    String normalize(String text) => text.replaceAll(_whitespaceRun, '');
    if (normalize(original.map((word) => word.text).join()) !=
            normalize(line.text) ||
        normalize(pronunciation.map((word) => word.text).join()) !=
            normalize(line.romanization ?? '') ||
        (original.first.time - pronunciation.first.time).inMilliseconds.abs() >
            10) {
      return null;
    }

    final boundaries = <(int, int)>[(0, 0)];
    var originalIndex = 1;
    for (var i = 1; i < pronunciation.length; i++) {
      // Preserve syllables inside a word. Providers may split a romanized
      // word into several timed spans without adding whitespace.
      if (!_endsWithWhitespace.hasMatch(pronunciation[i - 1].text) &&
          !_startsWithWhitespace.hasMatch(pronunciation[i].text)) {
        continue;
      }
      final start = pronunciation[i].time.inMilliseconds;
      while (originalIndex < original.length &&
          original[originalIndex].time.inMilliseconds < start - 10) {
        originalIndex++;
      }
      if (originalIndex < original.length &&
          (original[originalIndex].time.inMilliseconds - start).abs() <= 10) {
        boundaries.add((originalIndex, i));
        originalIndex++;
      }
    }
    if (boundaries.length < 2) return null;
    boundaries.add((original.length, pronunciation.length));

    final painter = TextPainter(
      textDirection: textDirection,
      textScaler: textScaler,
      locale: locale,
    );
    Size measureText(String text, TextStyle style) {
      painter.text = TextSpan(text: text, style: style);
      painter.layout(maxWidth: maxWidth);
      return Size(painter.width.ceilToDouble(), painter.height);
    }

    final rows = <_PronunciationRow>[];
    var groups = <_PronunciationGroup>[];
    var rowWidth = 0.0;
    var primaryHeight = 0.0;
    var pronunciationHeight = 0.0;
    for (var i = 0; i < boundaries.length - 1; i++) {
      final start = boundaries[i];
      final end = boundaries[i + 1];
      final primaryWords = _sliceWords(original, start.$1, end.$1);
      final pronunciationWords = _sliceWords(pronunciation, start.$2, end.$2);
      final primarySize = measureText(
        primaryWords.map((word) => word.text).join(),
        primaryStyle,
      );
      final pronunciationSize = measureText(
        pronunciationWords.map((word) => word.text).join(),
        pronunciationStyle,
      );
      final width = math.min(
        maxWidth,
        math.max(primarySize.width, pronunciationSize.width),
      );
      if (groups.isNotEmpty && rowWidth + _phraseGap + width > maxWidth) {
        rows.add(_PronunciationRow(groups, primaryHeight, pronunciationHeight));
        groups = [];
        rowWidth = primaryHeight = pronunciationHeight = 0;
      }
      if (groups.isNotEmpty) rowWidth += _phraseGap;
      groups.add(_PronunciationGroup(primaryWords, pronunciationWords, width));
      rowWidth += width;
      primaryHeight = math.max(primaryHeight, primarySize.height);
      pronunciationHeight = math.max(
        pronunciationHeight,
        pronunciationSize.height,
      );
    }
    rows.add(_PronunciationRow(groups, primaryHeight, pronunciationHeight));
    painter.dispose();
    return LyricPronunciationLayout._(rows, textDirection);
  }

  static List<LyricWord> _sliceWords(
    List<LyricWord> words,
    int start,
    int end,
  ) => [
    for (var i = start; i < end; i++)
      LyricWord(
        time: words[i].time,
        end: words[i].end ?? words.elementAtOrNull(i + 1)?.time,
        text: i == start && i == end - 1
            ? words[i].text.trim()
            : i == start
            ? words[i].text.trimLeft()
            : i == end - 1
            ? words[i].text.trimRight()
            : words[i].text,
      ),
  ];
}

class _PronunciationGroup {
  final List<LyricWord> original;
  final List<LyricWord> pronunciation;
  final double width;

  const _PronunciationGroup(this.original, this.pronunciation, this.width);
}

class _PronunciationRow {
  final List<_PronunciationGroup> groups;
  final double primaryHeight;
  final double pronunciationHeight;

  const _PronunciationRow(
    this.groups,
    this.primaryHeight,
    this.pronunciationHeight,
  );
}

class AlignedLyricPronunciation extends StatelessWidget {
  final LyricPronunciationLayout layout;
  final double visibility;
  final TextStyle primaryStyle;
  final TextStyle pronunciationStyle;
  final TextAlign textAlign;
  final Widget Function(String, List<LyricWord>, TextStyle) textBuilder;
  final Widget Function(String, List<LyricWord>, TextStyle)?
  pronunciationBuilder;

  const AlignedLyricPronunciation({
    super.key,
    required this.layout,
    required this.visibility,
    required this.primaryStyle,
    required this.pronunciationStyle,
    required this.textBuilder,
    this.pronunciationBuilder,
    this.textAlign = TextAlign.start,
  });

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < layout._rows.length; i++) ...[
        if (i > 0) const SizedBox(height: LyricPronunciationLayout._rowGap),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: textAlign == TextAlign.center
              ? MainAxisAlignment.center
              : (textAlign == TextAlign.right &&
                        Directionality.of(context) == TextDirection.ltr) ||
                    (textAlign == TextAlign.left &&
                        Directionality.of(context) == TextDirection.rtl) ||
                    textAlign == TextAlign.end
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: [
            for (var j = 0; j < layout._rows[i].groups.length; j++) ...[
              if (j > 0)
                const SizedBox(width: LyricPronunciationLayout._phraseGap),
              _buildGroup(layout._rows[i].groups[j], layout._rows[i]),
            ],
          ],
        ),
      ],
    ],
  );

  Widget _buildGroup(_PronunciationGroup group, _PronunciationRow row) =>
      SizedBox(
        width: group.width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: double.infinity,
              height: row.primaryHeight,
              child: textBuilder(
                group.original.map((word) => word.text).join(),
                group.original,
                primaryStyle,
              ),
            ),
            if (visibility > 0)
              LyricSupplementTransition(
                visibility: visibility,
                child: Padding(
                  padding: const EdgeInsets.only(
                    top: LyricPronunciationLayout._pronunciationGap,
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    height: row.pronunciationHeight,
                    child: (pronunciationBuilder ?? textBuilder)(
                      group.pronunciation.map((word) => word.text).join(),
                      group.pronunciation,
                      pronunciationStyle,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}
