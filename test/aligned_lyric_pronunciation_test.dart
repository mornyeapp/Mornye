import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/aligned_lyric_pronunciation.dart';

const _primaryStyle = TextStyle(fontSize: 34, height: 1.3);
const _pronunciationStyle = TextStyle(fontSize: 22, height: 1.35);

LyricWord _word(String text, int start, [int? end]) => LyricWord(
  text: text,
  time: Duration(milliseconds: start),
  end: end == null ? null : Duration(milliseconds: end),
);

LyricLine _line({int pronunciationOffset = 0}) => LyricLine(
  time: Duration.zero,
  text: '今日も歌う',
  words: [
    _word('今', 0),
    _word('日', 200),
    _word('も', 500),
    _word('歌う', 800, 1500),
  ],
  romanization: 'kyou mo utau',
  romanizationWords: [
    _word('kyo', pronunciationOffset, 200),
    _word('u ', 200, 400),
    _word('mo ', 500, 750),
    _word('utau', 800, 1500),
  ],
);

LyricPronunciationLayout? _layout(
  LyricLine line, {
  double width = 320,
  double scale = 1,
}) => LyricPronunciationLayout.measure(
  line: line,
  primaryStyle: _primaryStyle,
  pronunciationStyle: _pronunciationStyle,
  maxWidth: width,
  textScaler: TextScaler.linear(scale),
  textDirection: TextDirection.ltr,
);

void main() {
  testWidgets('right-aligned voices move original and pronunciation together', (
    tester,
  ) async {
    Future<void> pump(TextAlign alignment) => tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            child: AlignedLyricPronunciation(
              layout: _layout(_line(), width: 400)!,
              visibility: 1,
              textAlign: alignment,
              primaryStyle: _primaryStyle,
              pronunciationStyle: _pronunciationStyle,
              textBuilder: (text, words, style) => Text(text, style: style),
            ),
          ),
        ),
      ),
    );
    await pump(TextAlign.left);
    final original = tester.getTopLeft(find.text('今日'));
    final reading = tester.getTopLeft(find.text('kyou'));
    await pump(TextAlign.right);
    final shift = tester.getTopLeft(find.text('今日')) - original;
    expect(shift.dx, greaterThan(0));
    expect(shift.dy, 0);
    expect(tester.getTopLeft(find.text('kyou')) - reading, shift);
    expect(tester.takeException(), isNull);
  });

  test('does not guess alignment without matching word timing', () {
    expect(_layout(_line(pronunciationOffset: 100)), isNull);
    expect(
      _layout(
        const LyricLine(
          time: Duration.zero,
          text: 'Original',
          romanization: 'Pronunciation',
        ),
      ),
      isNull,
    );
  });

  test('does not split right-to-left lyrics into left-to-right word boxes', () {
    expect(isRtlLyricText('كان عندك كام سنة'), isTrue);
    expect(isRtlLyricText('kan andak kam sana'), isFalse);
    expect(lyricTextDirection('كان عندك كام سنة'), TextDirection.rtl);
    expect(lyricTextDirection('kan andak kam sana'), TextDirection.ltr);
    expect(
      _layout(
        LyricLine(
          time: Duration.zero,
          text: 'كان عندك كام سنة',
          words: [
            _word('كان ', 0, 400),
            _word('عندك ', 400, 800),
            _word('كام ', 800, 1200),
            _word('سنة', 1200, 1600),
          ],
          romanization: 'kan andak kam sana',
          romanizationWords: [
            _word('kan ', 0, 400),
            _word('andak ', 400, 800),
            _word('kam ', 800, 1200),
            _word('sana', 1200, 1600),
          ],
        ),
      ),
      isNull,
    );
  });

  for (final width in [320.0, 170.0]) {
    for (final scale in [1.0, 1.8]) {
      testWidgets(
        'phrases stay paired when wrapping and hiding ($width, $scale)',
        (tester) async {
          final layout = _layout(_line(), width: width, scale: scale)!;
          final renderedWords = <String, List<LyricWord>>{};
          Future<void> pump(double visibility) => tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    child: AlignedLyricPronunciation(
                      layout: layout,
                      visibility: visibility,
                      primaryStyle: _primaryStyle,
                      pronunciationStyle: _pronunciationStyle,
                      textBuilder: (text, words, style) {
                        renderedWords[text] = words;
                        return Text(text, style: style);
                      },
                    ),
                  ),
                ),
              ),
            ),
          );

          await pump(1);
          final block = find.byType(AlignedLyricPronunciation);
          final bounds = tester.getRect(block);
          expect(
            bounds.height,
            closeTo(layout.primaryHeight + layout.pronunciationHeight, 0.01),
          );
          final primaryPositions = <Offset>[];
          for (final (original, pronunciation) in [
            ('今日', 'kyou'),
            ('も', 'mo'),
            ('歌う', 'utau'),
          ]) {
            final primary = tester.getRect(find.text(original));
            final secondary = tester.getRect(find.text(pronunciation));
            primaryPositions.add(primary.topLeft);
            expect(primary.left, closeTo(secondary.left, 0.01));
            expect(secondary.top, greaterThanOrEqualTo(primary.bottom));
            expect(secondary.right, lessThanOrEqualTo(bounds.right + 0.01));
          }
          // Syllables stay together, and the end of a sliced phrase still
          // points to the next original word, not the end of the whole line.
          expect(renderedWords['kyou']!.map((word) => word.text), ['kyo', 'u']);
          expect(renderedWords['今日']!.last.end!.inMilliseconds, 500);
          expect(renderedWords['kyou']!.last.end!.inMilliseconds, 400);
          expect(renderedWords['utau']!.single.end!.inMilliseconds, 1500);
          final firstPosition = primaryPositions.first;
          for (final visibility in [0.5, 0.0]) {
            await pump(visibility);
            expect(
              tester.getSize(block).height,
              closeTo(
                layout.primaryHeight + layout.pronunciationHeight * visibility,
                0.01,
              ),
            );
            expect(tester.getTopLeft(find.text('今日')), firstPosition);
            expect(
              tester.getTopLeft(find.text('も')).dx,
              primaryPositions[1].dx,
            );
            expect(tester.takeException(), isNull);
          }
          expect(find.text('kyou'), findsNothing);
        },
      );
    }
  }
}
