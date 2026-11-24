import 'package:flutter/painting.dart' show TextDirection;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/text_direction.dart';

void main() {
  group('strongTextDirection', () {
    test('takes the first letter of a script', () {
      expect(strongTextDirection('قطة صغيرة على الشباك'), TextDirection.rtl);
      expect(strongTextDirection('הדלת הכחולה בגינה'), TextDirection.rtl);
      expect(
        strongTextDirection('qitta saghira ala ashubbak'),
        TextDirection.ltr,
      );
      expect(strongTextDirection('Ein kleines Beispiel'), TextDirection.ltr);
      expect(strongTextDirection('ねこ が いる'), TextDirection.ltr);
      expect(strongTextDirection('Όμορφη μέρα'), TextDirection.ltr);
    });

    test('a single word of the other script does not turn the line', () {
      expect(
        strongTextDirection('The blue door says قطة tonight'),
        TextDirection.ltr,
      );
      expect(strongTextDirection('قطة صغيرة says hello'), TextDirection.rtl);
    });

    test('digits, punctuation, spaces and marks decide nothing', () {
      expect(strongTextDirection('  2026, (...) "قطة"'), TextDirection.rtl);
      expect(strongTextDirection('١٢٣ - qitta'), TextDirection.ltr);
      expect(strongTextDirection('\u{1F3B5} ♪ qitta'), TextDirection.ltr);
      expect(strongTextDirection('\u{064E}\u{0650} qitta'), TextDirection.ltr);
    });

    test('a byte order mark is not right to left', () {
      expect(strongTextDirection('\u{FEFF}qitta saghira'), TextDirection.ltr);
      expect(strongTextDirection('\u{FEFF}قطة'), TextDirection.rtl);
      expect(strongTextDirection('\u{FEFF}'), isNull);
    });

    test('directional marks count as their direction', () {
      expect(strongTextDirection('\u{200F}123 qitta'), TextDirection.rtl);
      expect(strongTextDirection('\u{200E}123 قطة'), TextDirection.ltr);
    });

    test('text without a letter has no direction', () {
      for (final text in [
        '',
        '   ',
        '...',
        '♪ ♪',
        '2026',
        '١٢٣',
        '\u{1F3B6}',
      ]) {
        expect(strongTextDirection(text), isNull, reason: text);
      }
    });
  });

  test('lines without a letter follow their neighbours', () {
    expect(
      lyricLineDirections([
        '...',
        'قطة صغيرة',
        '♪',
        'qitta saghira',
        '',
        'على الشباك',
        '...',
      ]),
      [
        TextDirection.rtl,
        TextDirection.rtl,
        TextDirection.rtl,
        TextDirection.ltr,
        TextDirection.ltr,
        TextDirection.rtl,
        TextDirection.rtl,
      ],
    );
    expect(lyricLineDirections(['...', '♪']), [null, null]);
    expect(lyricLineDirections(const []), isEmpty);
  });
}
