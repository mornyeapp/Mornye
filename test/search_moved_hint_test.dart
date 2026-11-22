import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/widgets/search_moved_hint.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _hint = 'Search is here now';

Future<void> _pumpAnchor(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(
        body: Center(child: SearchMovedHintAnchor(child: Icon(Icons.search))),
      ),
    ),
  );
}

Future<bool> _owed() async =>
    (await SharedPreferences.getInstance()).getBool(searchMovedHintOwedKey) ??
    false;

void main() {
  setUp(() {
    SearchMovedHint.debugReset();
    SharedPreferences.setMockInitialValues({searchMovedHintOwedKey: true});
  });
  tearDown(SearchMovedHint.debugReset);

  testWidgets('shows above the Search icon once and is then settled', (
    tester,
  ) async {
    await _pumpAnchor(tester);
    expect(find.text(_hint), findsNothing);

    await SearchMovedHint.showIfOwed();
    await tester.pumpAndSettle();
    expect(find.text(_hint), findsOneWidget);
    // Above the icon, not over it.
    expect(
      tester.getBottomLeft(find.text(_hint)).dy,
      lessThan(tester.getTopLeft(find.byIcon(Icons.search)).dy),
    );
    expect(await _owed(), isTrue);

    await tester.pump(SearchMovedHintAnchor.readAfter);
    await tester.pump();
    expect(await _owed(), isFalse);

    await tester.pump(SearchMovedHintAnchor.showFor);
    await tester.pumpAndSettle();
    expect(find.text(_hint), findsNothing);

    // Settled: asking again shows nothing, in this run or a later one.
    SearchMovedHint.debugReset();
    await SearchMovedHint.showIfOwed();
    await tester.pumpAndSettle();
    expect(find.text(_hint), findsNothing);
  });

  testWidgets('a touch before it could be read leaves it owed', (tester) async {
    await _pumpAnchor(tester);
    await SearchMovedHint.showIfOwed();
    await tester.pumpAndSettle();
    expect(find.text(_hint), findsOneWidget);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.text(_hint), findsNothing);
    await tester.pump(SearchMovedHintAnchor.showFor);
    expect(await _owed(), isTrue);

    // Once per app run: it waits for the next launch.
    await SearchMovedHint.showIfOwed();
    await tester.pumpAndSettle();
    expect(find.text(_hint), findsNothing);
  });

  testWidgets('shows nothing when it is not owed', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpAnchor(tester);

    await SearchMovedHint.showIfOwed();
    await tester.pumpAndSettle();
    expect(find.text(_hint), findsNothing);
    expect(SearchMovedHint.debugShown, isFalse);
  });

  testWidgets('a request with no Search icon on screen keeps it for later', (
    tester,
  ) async {
    await SearchMovedHint.showIfOwed();
    expect(SearchMovedHint.debugShown, isFalse);

    await _pumpAnchor(tester);
    await SearchMovedHint.showIfOwed();
    await tester.pumpAndSettle();
    expect(find.text(_hint), findsOneWidget);

    await tester.pump(SearchMovedHintAnchor.showFor);
    await tester.pumpAndSettle();
  });
}
