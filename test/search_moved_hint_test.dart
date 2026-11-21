import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/widgets/search_moved_hint.dart';

const _hint = 'Search is here now';

Future<void> _pumpAnchor(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SearchMovedHintAnchor(child: Icon(Icons.search)),
              TextButton(
                onPressed: SearchMovedHint.request,
                child: const Text('Old search spot'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(SearchMovedHint.debugReset);
  tearDown(SearchMovedHint.debugReset);

  testWidgets('shows above the Search icon once, then goes by itself', (
    tester,
  ) async {
    await _pumpAnchor(tester);
    expect(find.text(_hint), findsNothing);

    await tester.tap(find.text('Old search spot'));
    await tester.pumpAndSettle();
    expect(find.text(_hint), findsOneWidget);
    expect(SearchMovedHint.debugShown, isTrue);
    // Above the icon, not over it.
    expect(
      tester.getBottomLeft(find.text(_hint)).dy,
      lessThan(tester.getTopLeft(find.byIcon(Icons.search)).dy),
    );

    await tester.pump(SearchMovedHintAnchor.showFor);
    await tester.pumpAndSettle();
    expect(find.text(_hint), findsNothing);

    // Once per app run: another tap where the field was shows nothing.
    await tester.tap(find.text('Old search spot'));
    await tester.pumpAndSettle();
    expect(find.text(_hint), findsNothing);
  });

  testWidgets('a request with no Search icon on screen keeps it for later', (
    tester,
  ) async {
    SearchMovedHint.request();
    expect(SearchMovedHint.debugShown, isFalse);

    await _pumpAnchor(tester);
    await tester.tap(find.text('Old search spot'));
    await tester.pumpAndSettle();
    expect(find.text(_hint), findsOneWidget);

    await tester.pump(SearchMovedHintAnchor.showFor);
    await tester.pumpAndSettle();
  });
}
