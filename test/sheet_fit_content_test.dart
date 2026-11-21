import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';

const _rowHeight = 48.0;

Widget _rows(ScrollController controller, int count) => ListView(
  controller: controller,
  children: [
    for (var i = 0; i < count; i++)
      SizedBox(height: _rowHeight, child: Text('Row $i')),
  ],
);

Future<void> _open(
  WidgetTester tester,
  Future<void> Function(BuildContext context) show,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
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
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

double _listHeight(WidgetTester tester) =>
    tester.getSize(find.byType(ListView)).height;

double _screenHeight(WidgetTester tester) =>
    tester.view.physicalSize.height / tester.view.devicePixelRatio;

void main() {
  testWidgets('a list that fills the sheet ends at its last row', (
    tester,
  ) async {
    await _open(
      tester,
      (context) => showAppScrollableBottomSheet<void>(
        context: context,
        title: 'Rows',
        builder: (context, controller) => _rows(controller, 3),
      ),
    );

    expect(_listHeight(tester), moreOrLessEquals(3 * _rowHeight));
    expect(
      tester.getBottomLeft(find.byType(ListView)).dy,
      moreOrLessEquals(_screenHeight(tester)),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a list longer than the sheet keeps the sheet at its cap', (
    tester,
  ) async {
    await _open(
      tester,
      (context) => showAppScrollableBottomSheet<void>(
        context: context,
        title: 'Rows',
        builder: (context, controller) => _rows(controller, 40),
      ),
    );

    expect(
      tester.getSize(find.byType(AppBottomSheet)).height,
      moreOrLessEquals(_screenHeight(tester) * 0.85),
    );
    expect(find.text('Row 39'), findsNothing);
  });

  testWidgets('the sheet grows with a list that gains rows', (tester) async {
    final count = ValueNotifier(2);
    addTearDown(count.dispose);
    await _open(
      tester,
      (context) => showAppScrollableBottomSheet<void>(
        context: context,
        title: 'Rows',
        builder: (context, controller) => ValueListenableBuilder(
          valueListenable: count,
          builder: (context, rows, _) => _rows(controller, rows),
        ),
      ),
    );
    expect(_listHeight(tester), moreOrLessEquals(2 * _rowHeight));

    count.value = 5;
    await tester.pumpAndSettle();
    expect(_listHeight(tester), moreOrLessEquals(5 * _rowHeight));
    expect(find.text('Row 4'), findsOneWidget);
  });

  testWidgets('a sheet with its own cap opens no taller than it', (
    tester,
  ) async {
    await _open(
      tester,
      (context) => showAppModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) => AppScrollableSheet(
          initialSize: 0.6,
          maxSize: 0.9,
          builder: (context, controller) => _rows(controller, 40),
        ),
      ),
    );
    expect(
      tester.getSize(find.byType(ListView)).height,
      moreOrLessEquals(_screenHeight(tester) * 0.6),
    );

    // A drag up grows it to the larger cap.
    await tester.drag(find.text('Row 2'), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(ListView)).height,
      moreOrLessEquals(_screenHeight(tester) * 0.9),
    );
  });
}
