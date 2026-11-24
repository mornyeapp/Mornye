import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/tutorial_screen.dart';
import 'package:mornye/widgets/animation_utils.dart';

Widget _tutorial({bool reduced = false}) => ProviderScope(
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(400, 800),
        disableAnimations: reduced,
      ),
      child: const TutorialScreen(),
    ),
  ),
);

double _page(WidgetTester tester) =>
    tester.widget<PageView>(find.byType(PageView)).controller!.page!;

Finder _next(WidgetTester tester) => find.text(
  AppLocalizations.of(tester.element(find.byType(TutorialScreen))).setupNext,
);

void main() {
  testWidgets('Next turns the page on a spring that stops at the page', (
    tester,
  ) async {
    await tester.pumpWidget(_tutorial());
    await tester.pumpAndSettle();
    // The welcome tips rise in on the shared staggered reveal.
    expect(find.byType(StaggeredListItem), findsNWidgets(3));

    await tester.tap(_next(tester));
    await tester.pump();
    var highest = _page(tester);
    var moved = false;
    for (var frame = 0; frame < 60; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      moved = moved || (_page(tester) > 0 && _page(tester) < 1);
      highest = highest > _page(tester) ? highest : _page(tester);
    }
    expect(moved, isTrue);
    // A page never travels past the next one.
    expect(highest, lessThan(1.001));
    await tester.pumpAndSettle();
    expect(_page(tester), 1);
  });

  testWidgets('reduced motion shows the next page at once', (tester) async {
    await tester.pumpWidget(_tutorial(reduced: true));
    await tester.pumpAndSettle();
    expect(find.byType(StaggeredListItem), findsNWidgets(3));

    await tester.tap(_next(tester));
    await tester.pump();
    // The page is there in the first frame, not on the way.
    expect(_page(tester), 1);
  });
}
