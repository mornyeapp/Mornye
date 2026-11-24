import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/nav_destination_icons.dart';

void main() {
  Future<void> pumpIcon(
    WidgetTester tester, {
    bool mornye = false,
    bool reduced = false,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: const Center(child: BouncingIcon(child: Icon(Icons.home))),
      ),
    ),
  );

  double scale(WidgetTester tester) => tester
      .widget<ScaleTransition>(
        find.descendant(
          of: find.byType(BouncingIcon),
          matching: find.byType(ScaleTransition),
        ),
      )
      .scale
      .value;

  testWidgets('Material springs the selected icon in past its size', (
    tester,
  ) async {
    await pumpIcon(tester);
    expect(scale(tester), closeTo(0.1, 0.001));
    var largest = 0.0;
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (scale(tester) > largest) largest = scale(tester);
    }
    // The expressive spatial spring overshoots by itself, then lands.
    expect(largest, greaterThan(1.01));
    await tester.pumpAndSettle();
    expect(scale(tester), 1);
  });

  for (final mornye in [true, false]) {
    testWidgets(
      '${mornye ? 'Mornye' : 'Reduced motion'} shows the selected icon at '
      'rest',
      (tester) async {
        await pumpIcon(tester, mornye: mornye, reduced: !mornye);
        expect(scale(tester), 1);
        expect(tester.binding.transientCallbackCount, 0);
      },
    );
  }
}
