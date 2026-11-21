import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/settings_group.dart';

const _choices = [
  AppChoice('a', Icons.looks_one, 'First'),
  AppChoice('b', Icons.looks_two, 'Second'),
  AppChoice('c', Icons.looks_3, 'Third'),
];

Future<void> _open(
  WidgetTester tester, {
  required bool mornye,
  required void Function(BuildContext context) show,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => show(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// The surface an option row sits on: the nearest shaped Material above it.
Finder _surface(String title) => find
    .ancestor(
      of: find.text(title),
      matching: find.byWidgetPredicate(
        (widget) => widget is Material && widget.shape != null,
      ),
    )
    .first;

BorderRadius _corners(WidgetTester tester, String title) =>
    (tester.widget<Material>(_surface(title)).shape! as RoundedRectangleBorder)
            .borderRadius
        as BorderRadius;

void _expectConnected(WidgetTester tester) {
  // Each option is its own surface, a small gap from the next.
  for (final (above, below) in [('First', 'Second'), ('Second', 'Third')]) {
    expect(
      tester.getTopLeft(_surface(below)).dy -
          tester.getBottomLeft(_surface(above)).dy,
      moreOrLessEquals(2),
    );
  }
  // Large corners close the group, small ones join the rows inside it.
  final first = _corners(tester, 'First');
  final middle = _corners(tester, 'Second');
  final last = _corners(tester, 'Third');
  expect(first.topLeft.x, greaterThan(first.bottomLeft.x));
  expect(middle.topLeft, middle.bottomLeft);
  expect(last.bottomLeft.x, greaterThan(last.topLeft.x));
  expect(first.bottomLeft, middle.topLeft);
}

void main() {
  testWidgets('a Material choice sheet joins its options as one group', (
    tester,
  ) async {
    await _open(
      tester,
      mornye: false,
      show: (context) => showAppChoiceSheet<String>(
        context: context,
        title: 'Pick',
        selected: 'a',
        choices: _choices,
        onSelected: (_) {},
      ),
    );

    _expectConnected(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a lazily built list joins its rows the same way', (
    tester,
  ) async {
    await _open(
      tester,
      mornye: false,
      show: (context) => showAppScrollableBottomSheet<void>(
        context: context,
        title: 'Pick',
        builder: (context, controller) => ListView.builder(
          controller: controller,
          itemCount: _choices.length,
          itemBuilder: (context, index) => ConnectedGroupRow(
            index: index,
            count: _choices.length,
            child: AppSheetOption(
              title: Text(_choices[index].title),
              onTap: () {},
            ),
          ),
        ),
      ),
    );

    _expectConnected(tester);
    // A row of the group is as wide as the group, 16 from the sheet's edges.
    final sheet = tester.getRect(find.byType(ListView));
    final row = tester.getRect(_surface('First'));
    expect(row.left - sheet.left, moreOrLessEquals(16));
    expect(sheet.right - row.right, moreOrLessEquals(16));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mornye keeps its options on the sheet itself', (tester) async {
    await _open(
      tester,
      mornye: true,
      show: (context) => showAppChoiceSheet<String>(
        context: context,
        title: 'Pick',
        selected: 'a',
        choices: _choices,
        onSelected: (_) {},
      ),
    );

    expect(find.text('First'), findsOneWidget);
    expect(find.byType(SettingsGroup), findsNothing);
    expect(
      tester.getTopLeft(find.byType(AppSheetOption).at(1)).dy,
      moreOrLessEquals(
        tester.getBottomLeft(find.byType(AppSheetOption).at(0)).dy,
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
