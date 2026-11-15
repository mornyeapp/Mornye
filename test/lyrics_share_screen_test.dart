import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/screens/lyrics_share_screen.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/expressive_button.dart';

void main() {
  test('timed lyrics share their sung lines, plain lyrics their text', () {
    final timed = LyricsParser.parse('''
[00:01.00]First line
[00:03.00]
[00:05.00]Second line
''');
    expect(lyricsShareLines(timed).map((line) => line.text), [
      'First line',
      'Second line',
    ]);
    final plain = LyricsParser.parse('Verse one\n\nVerse two\n');
    expect(lyricsShareLines(plain).map((line) => line.text), [
      'Verse one',
      'Verse two',
    ]);
  });

  test('the sung line maps to its share row as the player highlights it', () {
    final timed = LyricsParser.parse('''
[00:01.00]First line
[00:03.00]
[00:08.00]Second line
[00:20.00]Third line
''');
    expect(lyricsShareRowAt(timed, const Duration(milliseconds: 500)), -1);
    expect(lyricsShareRowAt(timed, const Duration(seconds: 2)), 0);
    // The player counts down a marked pause instead of holding a line.
    expect(lyricsShareRowAt(timed, const Duration(seconds: 4)), -1);
    expect(lyricsShareRowAt(timed, const Duration(seconds: 9)), 1);
    expect(lyricsShareRowAt(timed, const Duration(seconds: 25)), 2);
    // The listener's timing setting moves lines later.
    expect(
      lyricsShareRowAt(
        timed,
        const Duration(milliseconds: 2500),
        offset: const Duration(seconds: 2),
      ),
      -1,
    );
    expect(
      lyricsShareRowAt(
        timed,
        const Duration(seconds: 21),
        offset: const Duration(seconds: 2),
      ),
      1,
    );
    final plain = LyricsParser.parse('Verse one\nVerse two\n');
    expect(lyricsShareRowAt(plain, const Duration(seconds: 6)), -1);
  });

  test('an ended word-timed line leaves the gap after it unselected', () {
    const lead = LyricLine(
      time: Duration(seconds: 1),
      end: Duration(seconds: 3),
      text: 'Lead line',
      words: [
        LyricWord(
          time: Duration(seconds: 1),
          end: Duration(seconds: 3),
          text: 'Lead line',
        ),
      ],
    );
    const backing = LyricLine(
      time: Duration(seconds: 2),
      end: Duration(seconds: 3),
      text: 'Backing',
      isBackground: true,
    );
    const next = LyricLine(time: Duration(seconds: 10), text: 'Next line');
    const lyrics = ParsedLyrics(
      lines: [lead, backing, next],
      plainText: '',
      synced: true,
      wordSynced: true,
    );
    // The backing vocal selects the line it backs.
    expect(lyricsShareRowAt(lyrics, const Duration(milliseconds: 2500)), 0);
    // The player shows a countdown once the line ended.
    expect(lyricsShareRowAt(lyrics, const Duration(seconds: 6)), -1);
    expect(lyricsShareRowAt(lyrics, const Duration(seconds: 11)), 2);
  });

  testWidgets('a preselected line opens centered in the list', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LyricsShareScreen(
          mediaItem: const MediaItem(id: 'track', title: 'Track'),
          lines: [
            for (var i = 0; i < 40; i++)
              (
                text: i == 3 ? 'Line $i ${'that wraps ' * 12}' : 'Line $i',
                background: false,
              ),
          ],
          initialSelection: const {25},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final list = tester.getRect(find.byType(ListView));
    final row = tester.getRect(
      find.ancestor(of: find.text('Line 25'), matching: find.byType(InkWell)),
    );
    expect(row.center.dy, moreOrLessEquals(list.center.dy, epsilon: 1));
    final share = tester.widget<ExpressiveButton>(
      find.ancestor(
        of: find.text('Share'),
        matching: find.byType(ExpressiveButton),
      ),
    );
    expect(share.onPressed, isNotNull);
    // The card quotes the line as well as the list showing it selected.
    expect(find.text('Line 25'), findsNWidgets(2));
  });

  testWidgets('a line near the end scrolls no further than the list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LyricsShareScreen(
          mediaItem: const MediaItem(id: 'track', title: 'Track'),
          lines: [
            for (var i = 0; i < 40; i++) (text: 'Line $i', background: false),
          ],
          initialSelection: const {39},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    expect(position.pixels, position.maxScrollExtent);
    expect(
      tester.getRect(find.byType(ListView)).bottom,
      greaterThanOrEqualTo(tester.getRect(find.text('Line 39').first).bottom),
    );
  });

  test('short quotes use larger type than long ones', () {
    expect(
      LyricsShareCard.fontSizeFor([(text: 'Short', background: false)]),
      greaterThan(
        LyricsShareCard.fontSizeFor([(text: 'A' * 200, background: false)]),
      ),
    );
  });

  testWidgets('selection is limited and required before sharing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LyricsShareScreen(
          mediaItem: const MediaItem(id: 'track', title: 'Track'),
          lines: [
            for (var i = 0; i < 7; i++) (text: 'Line $i', background: false),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    ExpressiveButton share() => tester.widget<ExpressiveButton>(
      find.ancestor(
        of: find.text('Share'),
        matching: find.byType(ExpressiveButton),
      ),
    );
    expect(share().onPressed, isNull);

    Finder choice(int index) => find.descendant(
      of: find.byType(ListView),
      matching: find.text('Line $index'),
    );
    for (var i = 0; i < lyricsShareMaxLines; i++) {
      await tester.tap(choice(i));
    }
    await tester.pumpAndSettle();
    expect(share().onPressed, isNotNull);
    expect(find.text('Line 0'), findsNWidgets(2));

    await tester.scrollUntilVisible(choice(6), 100);
    // Fully reveal the row; a partly clipped one cannot be tapped.
    await tester.ensureVisible(choice(6));
    await tester.pumpAndSettle();
    await tester.tap(choice(6));
    await tester.pump();
    expect(find.text('You can share up to 5 lines'), findsOneWidget);
    expect(find.text('Line 6'), findsOneWidget);
  });
}
