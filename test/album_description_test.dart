import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/editorial_notes.dart';
import 'package:mornye/widgets/album_description.dart';

import 'support/tooltip_finder.dart';

void main() {
  test(
    'editorial notes prefer full text and fall back to a usable summary',
    () {
      expect(
        albumDescriptionFromMetadata({
          'editorial_notes': {
            'standard': '<p>Full notes.</p>',
            'short': 'Short notes.',
          },
        }),
        '<p>Full notes.</p>',
      );
      expect(
        albumDescriptionFromMetadata({
          'editorial_notes': {
            'standard': '<p>&nbsp;</p>',
            'short': 'Short notes.',
          },
        }),
        'Short notes.',
      );
      expect(
        albumDescriptionFromMetadata({'description': 'Plain notes.'}),
        'Plain notes.',
      );
      expect(albumDescriptionFromMetadata({'editorial_notes': null}), isNull);
      expect(albumDescriptionFromMetadata({'editorial_notes': 42}), isNull);
      expect(
        albumDescriptionFromMetadata({
          'editorial_notes': {'standard': '<script>hidden</script>'},
        }),
        isNull,
      );
    },
  );

  for (final style in ['mornye-light', 'mornye-dark', 'material']) {
    testWidgets('short album notes have no More action ($style)', (
      tester,
    ) async {
      final mornye = style.startsWith('mornye');
      tester.view.physicalSize = const Size(393, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final description in [
        'A short description.',
        '<p>A <b>bold</b> sound.</p>\n\n',
        '<div><p>First line.<br>Second line.</p></div>',
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: mornye
                ? MornyeTheme.build(
                    style.endsWith('light')
                        ? Brightness.light
                        : Brightness.dark,
                  )
                : ThemeData(),
            home: Scaffold(
              body: AlbumDescription(title: 'Album', description: description),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(mornye ? 'MORE' : 'More'), findsNothing);
        final tap = tester.widget<InkWell>(find.byType(InkWell));
        expect(tap.onTap, isNull);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('More responds to album preview width and text size ($style)', (
      tester,
    ) async {
      final mornye = style.startsWith('mornye');
      final scale = ValueNotifier(1.0);
      addTearDown(scale.dispose);
      tester.view.physicalSize = const Size(393, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: mornye
              ? MornyeTheme.build(
                  style.endsWith('light') ? Brightness.light : Brightness.dark,
                )
              : ThemeData(),
          home: ValueListenableBuilder<double>(
            valueListenable: scale,
            builder: (context, value, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(value)),
              child: child!,
            ),
            child: const Scaffold(
              body: AlbumDescription(
                title: 'Album',
                description: 'New sounds and new stories.',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final more = find.text(mornye ? 'MORE' : 'More');
      expect(more, findsNothing);
      tester.view.physicalSize = const Size(180, 700);
      await tester.pumpAndSettle();
      expect(more, findsOneWidget);
      tester.view.physicalSize = const Size(393, 700);
      await tester.pumpAndSettle();
      expect(more, findsNothing);
      scale.value = 2.5;
      await tester.pumpAndSettle();
      expect(more, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('album description opens a formatted reading sheet ($style)', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(393, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final mornye = style.startsWith('mornye');
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(
                    style.endsWith('light')
                        ? Brightness.light
                        : Brightness.dark,
                  )
                : ThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: AlbumDescription(
                    title: 'Example Album',
                    description:
                        'A <i>new direction</i> &amp; a <b>bold sound</b>.\n\n'
                        'A second paragraph.\nOne line break remains.\n\n'
                        '${List.filled(12, '<p>The artists explore melodies and new ideas in these songs.</p>').join()}'
                        '<p>Final paragraph.</p><script>hidden script</script>',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final preview = tester.widget<Text>(
        find.byWidgetPredicate(
          (widget) => widget is Text && widget.textSpan != null,
        ),
      );
      expect(preview.maxLines, 2);
      expect(
        preview.textSpan!.toPlainText(),
        contains('new direction & a bold sound.\n\n'),
      );
      expect(preview.textSpan!.toPlainText(), isNot(contains('hidden script')));
      expect(
        preview.textSpan!.toPlainText(),
        contains('sound.\n\nA second paragraph.\nOne line break remains.\n\n'),
      );

      Iterable<TextSpan> spans(InlineSpan span) sync* {
        if (span is TextSpan) {
          yield span;
          for (final child in span.children ?? <InlineSpan>[]) {
            yield* spans(child);
          }
        }
      }

      expect(
        spans(preview.textSpan!).any(
          (span) =>
              span.style?.fontStyle == FontStyle.italic &&
              span.toPlainText() == 'new direction',
        ),
        isTrue,
      );

      await tester.tap(find.text(mornye ? 'MORE' : 'More'));
      await tester.pumpAndSettle();
      expect(find.text('Example Album'), findsOneWidget);
      expect(find.byType(SelectionArea), findsOneWidget);
      expect(
        ModalRoute.of(tester.element(find.byType(SelectionArea)))!.navigator,
        tester.state<NavigatorState>(find.byType(Navigator).first),
      );
      expect(findByTooltip('Close').hitTestable(), findsOneWidget);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      final scroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(SingleChildScrollView),
          matching: find.byType(Scrollable),
        ),
      );
      expect(scroll.position.pixels, greaterThan(0));
      expect(findByTooltip('Close').hitTestable(), findsOneWidget);
      await tester.tap(findByTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectionArea), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
