import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/player_lyrics.dart';
import 'package:mornye/widgets/player_lyrics_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Invented lines: "a small cat on the window", "a small cat", "the blue
// door", "my cat hello door".
const _arabic = 'قطة صغيرة على الشباك';
const _arabicCat = 'قطة صغيرة';
const _arabicDoor = 'الباب الأزرق';
const _arabicMixed = 'قطتي hello باب';
const _latin = 'Lanterns';
const _latinPath = 'Garden path';
const _viewWidth = 600.0;

LyricWord _word(String text, int from, int to) => LyricWord(
  time: Duration(seconds: from),
  end: Duration(seconds: to),
  text: text,
);

ThemeData _theme(bool mornye) =>
    mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark();

Future<void> _pumpLyrics(
  WidgetTester tester,
  List<LyricLine> lines, {
  required bool mornye,
  Duration at = Duration.zero,
  bool showTranslation = false,
  TextDirection? appDirection,
}) async {
  tester.view.physicalSize = const Size(_viewWidth, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final preview = ValueNotifier<Duration?>(at);
  addTearDown(preview.dispose);
  final theme = _theme(mornye);
  Widget view = SyncedLyricsView(
    lyrics: ParsedLyrics(
      synced: true,
      wordSynced: lines.any((line) => line.hasWordTiming),
      plainText: lines.map((line) => line.text).join('\n'),
      lines: lines,
    ),
    seekPreview: preview,
    colorScheme: theme.colorScheme,
    isActive: true,
    showPronunciation: false,
    showTranslation: showTranslation,
  );
  if (appDirection != null) {
    view = Directionality(textDirection: appDirection, child: view);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playbackStateProvider.overrideWith(
          (ref) => Stream.value(PlaybackState()),
        ),
      ],
      child: MaterialApp(
        theme: theme,
        home: Scaffold(
          body: SizedBox(width: _viewWidth, child: view),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The word sweep painting [text], found by its semantics label.
Finder _sweep(String text) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.label == text,
  ),
  matching: find.byType(CustomPaint),
);

typedef _SweepLayout = ({
  List<List<Rect>> boxes,
  List<List<TextDirection>> directions,
  RenderBox paint,
});

_SweepLayout _sweepLayout(WidgetTester tester, String text) {
  final finder = _sweep(text);
  expect(finder, findsOneWidget);
  // ignore: avoid_dynamic_calls
  final painter = tester.widget<CustomPaint>(finder).painter as dynamic;
  return (
    // ignore: avoid_dynamic_calls
    boxes: painter.segmentBoxes as List<List<Rect>>,
    // ignore: avoid_dynamic_calls
    directions: painter.segmentDirections as List<List<TextDirection>>,
    paint: tester.renderObject<RenderBox>(finder),
  );
}

/// The right edge of a sweep's letters on screen.
double _sweepRight(_SweepLayout layout) => layout.paint
    .localToGlobal(
      Offset(
        layout.boxes
            .expand((boxes) => boxes)
            .map((box) => box.right)
            .reduce(math.max),
        0,
      ),
    )
    .dx;

/// How many fully sung pixels lie in the start and end quarter of a word's
/// [box], reading in [direction], and how many letter pixels the end
/// quarter has at all. Sung letters are opaque, unsung ones translucent in
/// both styles.
Future<({int start, int end, int endLetters})> _sungInk(
  WidgetTester tester,
  String text,
  Rect box,
  TextDirection direction,
) async {
  final finder = _sweep(text);
  final painter = tester.widget<CustomPaint>(finder).painter!;
  final size = tester.renderObject<RenderBox>(finder).size;
  final pixels = (await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.ceil(), size.height.ceil());
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final result = bytes.buffer.asUint8List().toList();
    image.dispose();
    picture.dispose();
    return result;
  }))!;
  final width = size.width.ceil();
  int count(double from, double to, int alpha) {
    var count = 0;
    for (var y = 0; y < size.height.ceil(); y++) {
      for (var x = from.ceil(); x < to.floor(); x++) {
        if (pixels[(y * width + x) * 4 + 3] >= alpha) count++;
      }
    }
    return count;
  }

  final quarter = box.width / 4;
  final (startFrom, endFrom) = direction == TextDirection.rtl
      ? (box.right - quarter, box.left)
      : (box.left, box.right - quarter);
  return (
    start: count(startFrom, startFrom + quarter, 230),
    end: count(endFrom, endFrom + quarter, 230),
    endLetters: count(endFrom, endFrom + quarter, 40),
  );
}

/// Where [text]'s letters sit on screen, the edges of the space it is laid
/// out in, and the direction it reads in.
({
  double left,
  double right,
  double boxLeft,
  double boxRight,
  TextDirection direction,
  TextAlign align,
})
_ink(WidgetTester tester, String text) {
  final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: text.length),
  );
  // Rows away from the current line are scaled, so each edge is mapped.
  double x(double local) => paragraph.localToGlobal(Offset(local, 0)).dx;
  return (
    left: x(boxes.map((box) => box.left).reduce(math.min)),
    right: x(boxes.map((box) => box.right).reduce(math.max)),
    boxLeft: x(0),
    boxRight: x(paragraph.size.width),
    direction: paragraph.textDirection,
    align: paragraph.textAlign,
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final mornye in [true, false]) {
    final style = mornye ? 'Mornye' : 'Material';
    // Spaces lead the next word, so each word's box holds only letters.
    final mixedLine = LyricLine(
      time: Duration.zero,
      end: const Duration(seconds: 30),
      text: _arabicMixed,
      words: [
        _word('قطتي', 0, 10),
        _word(' hello', 10, 20),
        _word(' باب', 20, 30),
      ],
    );
    Rect latinBox(_SweepLayout layout) =>
        layout.boxes[1][layout.directions[1].indexOf(TextDirection.ltr)];

    testWidgets('a right-to-left word-synced line sweeps from the right '
        '($style)', (tester) async {
      await _pumpLyrics(
        tester,
        [mixedLine],
        mornye: mornye,
        at: const Duration(seconds: 5),
      );
      final layout = _sweepLayout(tester, _arabicMixed);
      final first = layout.boxes[0].single;
      final latin = latinBox(layout);
      final last = layout.boxes[2].last;
      // The line reads from the right: its first word is rightmost.
      expect(layout.directions[0].single, TextDirection.rtl);
      expect(layout.directions[2].last, TextDirection.rtl);
      expect([first.top, latin.top, last.top], everyElement(first.top));
      expect(first.left, greaterThan(latin.right - 0.5));
      expect(latin.left, greaterThan(last.right - 0.5));
      expect(first.right, greaterThan(_viewWidth / 2));

      // Halfway through the first word, its right part is sung, its left
      // part not yet.
      final ink = await _sungInk(
        tester,
        _arabicMixed,
        first,
        TextDirection.rtl,
      );
      expect(ink.start, greaterThan(0));
      expect(ink.end, 0);
      expect(ink.endLetters, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a left-to-right word in a right-to-left line sweeps from '
        'its left ($style)', (tester) async {
      await _pumpLyrics(
        tester,
        [mixedLine],
        mornye: mornye,
        at: const Duration(seconds: 16),
      );
      final layout = _sweepLayout(tester, _arabicMixed);
      final ink = await _sungInk(
        tester,
        _arabicMixed,
        latinBox(layout),
        TextDirection.ltr,
      );
      expect(ink.start, greaterThan(0));
      expect(ink.end, 0);
      expect(ink.endLetters, greaterThan(0));
      // The word before it is sung through.
      final done = await _sungInk(
        tester,
        _arabicMixed,
        layout.boxes[0].single,
        TextDirection.rtl,
      );
      expect(done.start, greaterThan(0));
      expect(done.end, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a left-to-right word-synced line still sweeps from the '
        'left ($style)', (tester) async {
      const text = 'Lanterns glow';
      await _pumpLyrics(
        tester,
        [
          LyricLine(
            time: Duration.zero,
            end: const Duration(seconds: 20),
            text: text,
            words: [_word('Lanterns', 0, 10), _word(' glow', 10, 20)],
          ),
        ],
        mornye: mornye,
        at: const Duration(seconds: 5),
      );
      final layout = _sweepLayout(tester, text);
      final first = layout.boxes[0].single;
      expect(layout.directions[0].single, TextDirection.ltr);
      expect(first.right, lessThan(layout.boxes[1].first.left + 0.5));
      expect(first.left, lessThan(_viewWidth / 2));
      final ink = await _sungInk(tester, text, first, TextDirection.ltr);
      expect(ink.start, greaterThan(0));
      expect(ink.end, 0);
      expect(ink.endLetters, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    for (final appDirection in TextDirection.values) {
      testWidgets('each line of a mixed song keeps its own direction '
          '($style, ${appDirection.name} app)', (tester) async {
        await _pumpLyrics(
          tester,
          const [
            LyricLine(time: Duration.zero, text: _arabicCat),
            LyricLine(time: Duration(seconds: 5), text: _latin),
            LyricLine(time: Duration(seconds: 10), text: '...'),
            LyricLine(
              time: Duration(seconds: 15),
              text: _arabicDoor,
              voice: LyricVoice(id: 'v2', index: 1),
            ),
            LyricLine(
              time: Duration(seconds: 20),
              text: _latinPath,
              voice: LyricVoice(id: 'v2', index: 1),
            ),
            LyricLine(time: Duration(seconds: 25), text: 'qitta'),
          ],
          mornye: mornye,
          appDirection: appDirection,
        );
        // Every line is much shorter than its row, so the side it sits on
        // shows.
        void sits(String text, TextDirection direction, {required bool left}) {
          final ink = _ink(tester, text);
          expect(ink.direction, direction, reason: text);
          expect(
            ink.right - ink.left,
            lessThan(ink.boxRight - ink.boxLeft - 80),
          );
          if (left) {
            expect(ink.left, moreOrLessEquals(ink.boxLeft, epsilon: 1));
          } else {
            expect(ink.right, moreOrLessEquals(ink.boxRight, epsilon: 1));
          }
        }

        // Lines start on their own reading side.
        sits(_arabicCat, TextDirection.rtl, left: false);
        sits(_latin, TextDirection.ltr, left: true);
        // A line without letters reads like the line before it.
        sits('...', TextDirection.ltr, left: true);
        // A duet's second voice keeps the end of its own line: the left
        // of a right-to-left line, the right of a left-to-right one.
        sits(_arabicDoor, TextDirection.rtl, left: true);
        sits(_latinPath, TextDirection.ltr, left: false);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a translation stays on the side of its right-to-left line '
        '($style)', (tester) async {
      const translation = 'A small cat';
      await _pumpLyrics(
        tester,
        const [
          LyricLine(
            time: Duration.zero,
            text: _arabic,
            translation: translation,
          ),
          LyricLine(time: Duration(seconds: 10), text: _latin),
        ],
        mornye: mornye,
        showTranslation: true,
      );
      final line = _ink(tester, _arabic);
      final shown = _ink(tester, translation);
      expect(shown.direction, TextDirection.ltr);
      expect(shown.align, TextAlign.right);
      expect(shown.right, moreOrLessEquals(line.right, epsilon: 1));
      expect(shown.left, greaterThan(_viewWidth / 2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a timed translation reads left to right on the side of its '
        'right-to-left line ($style)', (tester) async {
      const translation = 'A small cat';
      await _pumpLyrics(
        tester,
        [
          LyricLine(
            time: Duration.zero,
            end: const Duration(seconds: 20),
            text: _arabicCat,
            words: [_word('قطة ', 0, 10), _word('صغيرة', 10, 20)],
            translation: translation,
            translationWords: [
              _word('A ', 0, 5),
              _word('small ', 5, 10),
              _word('cat', 10, 20),
            ],
          ),
        ],
        mornye: mornye,
        at: const Duration(seconds: 2),
        showTranslation: true,
      );
      final line = _sweepLayout(tester, _arabicCat);
      final shown = _sweepLayout(tester, translation);
      expect(
        shown.directions.expand((directions) => directions),
        everyElement(TextDirection.ltr),
      );
      // Its first word is leftmost, and it ends under the line's start.
      expect(
        shown.boxes.first.first.right,
        lessThan(shown.boxes.last.first.left + 0.5),
      );
      expect(
        _sweepRight(shown),
        moreOrLessEquals(_sweepRight(line), epsilon: 1),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('plain lyrics mixing directions keep each line\'s own '
        '($style)', (tester) async {
      final metadata = PlayerMetadataController(
        readMetadata: (_) async => const {
          'lyrics': '$_arabicCat\n$_latin\n...\n$_arabicDoor',
        },
        parseLyrics: (raw) async => LyricsParser.parse(raw),
      );
      final preview = PlaybackSeekPreview();
      addTearDown(metadata.dispose);
      addTearDown(preview.dispose);
      await metadata.load(
        MediaItem(
          id: 'example-song',
          title: 'Example Song',
          artist: 'Example Artist',
          extras: const {'source': '/music/example.flac'},
        ),
      );
      expect(metadata.lyrics.synced, isFalse);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: _theme(mornye),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: PlayerLyricsSection(
                metadata: metadata,
                seekPreview: preview,
                colorScheme: const ColorScheme.dark(),
                isActive: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_ink(tester, _arabicCat).direction, TextDirection.rtl);
      expect(_ink(tester, _latin).direction, TextDirection.ltr);
      expect(_ink(tester, '...').direction, TextDirection.ltr);
      expect(_ink(tester, _arabicDoor).direction, TextDirection.rtl);
      expect(tester.takeException(), isNull);
    });
  }
}
