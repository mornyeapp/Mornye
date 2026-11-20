import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/screens/lyrics_share_screen.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    // The row is centered with the 2dp gap below it, so its ink sits 1dp up.
    expect(row.center.dy, moreOrLessEquals(list.center.dy, epsilon: 1.5));
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
      // The list shows about four rows at a time.
      await tester.ensureVisible(choice(i));
      await tester.pumpAndSettle();
      await tester.tap(choice(i));
    }
    await tester.pumpAndSettle();
    expect(share().onPressed, isNotNull);
    // The card quotes a line as well as the list showing it selected.
    expect(find.text('Line 4'), findsNWidgets(2));

    await tester.scrollUntilVisible(choice(6), 100);
    // Fully reveal the row; a partly clipped one cannot be tapped.
    await tester.ensureVisible(choice(6));
    await tester.pumpAndSettle();
    await tester.tap(choice(6));
    await tester.pump();
    expect(find.text('You can share up to 5 lines'), findsOneWidget);
    expect(find.text('Line 6'), findsOneWidget);
  });

  test('a saved card style comes back, and unknown parts fall back', () {
    const style = LyricsCardStyle(
      background: LyricsCardBackground.light,
      shape: LyricsCardShape.wide,
      textSize: LyricsCardTextSize.large,
      align: LyricsCardAlign.center,
    );
    final restored = LyricsCardStyle.decode(style.encode());
    expect(restored.background, LyricsCardBackground.light);
    expect(restored.shape, LyricsCardShape.wide);
    expect(restored.textSize, LyricsCardTextSize.large);
    expect(restored.align, LyricsCardAlign.center);
    for (final saved in [null, '', 'neon,round', 'dark']) {
      final style = LyricsCardStyle.decode(saved);
      expect(
        style.background,
        saved == 'dark'
            ? LyricsCardBackground.dark
            : LyricsCardBackground.artwork,
      );
      expect(style.shape, LyricsCardShape.story);
      expect(style.textSize, LyricsCardTextSize.auto);
      expect(style.align, LyricsCardAlign.start);
    }
  });

  for (final shape in LyricsCardShape.values) {
    testWidgets('the ${shape.name} card keeps its size with a long quote', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final align in LyricsCardAlign.values) {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Center(
              child: LyricsShareCard(
                title: 'A song with a long title that has to be cut short',
                artist: 'Artist',
                artUri: null,
                lines: [
                  for (var i = 0; i < lyricsShareMaxLines; i++)
                    (text: 'Line $i ${'that wraps ' * 8}', background: i == 2),
                ],
                background: LyricsCardBackground.dark,
                shape: shape,
                textSize: LyricsCardTextSize.large,
                align: align,
              ),
            ),
          ),
        );
        expect(tester.getSize(find.byType(LyricsShareCard)), shape.size);
        // The quote and the app's mark stay inside the card.
        final card = tester.getRect(find.byType(LyricsShareCard));
        for (final inside in [
          find.textContaining('Line 4'),
          find.text('Mornye'),
        ]) {
          final rect = tester.getRect(inside);
          expect(card.contains(rect.topLeft), isTrue, reason: '$align');
          expect(card.contains(rect.bottomRight), isTrue, reason: '$align');
        }
        expect(tester.takeException(), isNull);
      }
      // 1080 wide for a story or a square post, 1920 for the wide card.
      expect(
        shape.size.width * shape.pixelRatio,
        shape == LyricsCardShape.wide ? 1920 : 1080,
      );
    });
  }

  testWidgets('a quote too tall for the wide card takes smaller type and '
      'keeps the full width', (tester) async {
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const first = 'The morning opens like a window in the rain';
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Center(
          child: LyricsShareCard(
            title: 'Track',
            artist: 'Artist',
            artUri: null,
            lines: [
              (text: first, background: false),
              (
                text: 'Every street remembers how we used to run',
                background: false,
              ),
              (
                text: 'Hold the light a little longer if you can',
                background: false,
              ),
            ],
            background: LyricsCardBackground.dark,
            shape: LyricsCardShape.wide,
          ),
        ),
      ),
    );
    final line = tester.widget<Text>(find.text(first));
    // 26 is the size the card picks for a quote of this length.
    expect(line.style!.fontSize, lessThan(26));
    // Shrinking the block as a whole would leave it narrower than the card.
    expect(
      tester.getRect(find.text(first)).width,
      closeTo(LyricsCardShape.wide.size.width - 44, 0.5),
    );
  });

  testWidgets('text size and alignment change the quote', (tester) async {
    Future<Text> quote(LyricsCardTextSize size, LyricsCardAlign align) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Center(
            child: LyricsShareCard(
              title: 'Track',
              artist: '',
              artUri: null,
              lines: const [(text: 'Short', background: false)],
              background: LyricsCardBackground.dark,
              textSize: size,
              align: align,
            ),
          ),
        ),
      );
      return tester.widget<Text>(find.text('Short'));
    }

    final auto = await quote(LyricsCardTextSize.auto, LyricsCardAlign.start);
    final small = await quote(LyricsCardTextSize.small, LyricsCardAlign.start);
    final large = await quote(LyricsCardTextSize.large, LyricsCardAlign.center);
    expect(auto.style!.fontSize, 36);
    expect(small.style!.fontSize, lessThan(36));
    expect(large.style!.fontSize, greaterThan(36));
    expect(auto.textAlign, isNull);
    expect(large.textAlign, TextAlign.center);
  });

  for (final mornye in [false, true]) {
    testWidgets('the style is chosen, kept and the card saved '
        '(Mornye: $mornye)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final temp = Directory.systemTemp.createTempSync('lyrics_card_test');
      messenger.setMockMethodCallHandler(paths, (_) async => temp.path);
      addTearDown(() {
        messenger.setMockMethodCallHandler(paths, null);
        temp.deleteSync(recursive: true);
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final saved = <(String, int)>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: LyricsShareScreen(
            mediaItem: const MediaItem(id: 'track', title: 'Track: one/two'),
            lines: const [(text: 'Line 0', background: false)],
            initialSelection: const {0},
            saveImage: (name, png) async {
              saved.add((name, png.length));
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      double previewRatio() => tester
          .widget<AspectRatio>(find.byType(AspectRatio).first)
          .aspectRatio;
      expect(previewRatio(), closeTo(9 / 16, 1e-9));
      // The style choices take the place of the lines.
      expect(find.text('Square').hitTestable(), findsNothing);
      await tester.tap(find.text('Style').hitTestable().first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Square').hitTestable().first);
      await tester.pumpAndSettle();
      expect(previewRatio(), 1);
      expect(
        tester.widget<LyricsShareCard>(find.byType(LyricsShareCard)).shape,
        LyricsCardShape.square,
      );
      // A connected choice lays a label out twice to size its buttons.
      await tester.ensureVisible(
        find.text('Center', skipOffstage: false).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Center').hitTestable().first);
      await tester.pumpAndSettle();
      final kept = (await SharedPreferences.getInstance()).getString(
        'lyrics_card_style',
      );
      expect(kept, 'artwork,square,auto,center');
      expect((await LyricsCardStyle.load()).shape, LyricsCardShape.square);

      await tester.runAsync(() async {
        await tester.tap(find.text('Save').hitTestable().first);
        for (var i = 0; i < 40 && saved.isEmpty; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      });
      await tester.pump();
      expect(saved, hasLength(1));
      // Characters a file name cannot hold are replaced.
      expect(saved.single.$1, 'Track_ one_two lyrics.png');
      expect(saved.single.$2, greaterThan(1000));
      expect(find.text('Lyrics card saved'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
