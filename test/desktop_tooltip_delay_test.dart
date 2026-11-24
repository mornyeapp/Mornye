import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';

void main() {
  tearDown(() => debugDesktopPlatformOverride = null);

  for (final (style, delay) in [('Material', 500), ('Mornye', 800)]) {
    ThemeData theme() => style == 'Mornye'
        ? MornyeTheme.build(Brightness.light)
        : AppTheme.light();

    testWidgets('$style desktop tooltips wait $delay ms for a hover', (
      tester,
    ) async {
      debugDesktopPlatformOverride = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme(),
          home: const Scaffold(
            body: Center(
              child: Tooltip(message: 'Shuffle', child: Icon(Icons.shuffle)),
            ),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byIcon(Icons.shuffle)));
      await tester.pump();

      await tester.pump(Duration(milliseconds: delay - 100));
      expect(find.text('Shuffle'), findsNothing);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Shuffle'), findsOneWidget);

      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
    });

    test('$style phones keep the platform tooltip timing', () {
      debugDesktopPlatformOverride = false;
      expect(theme().tooltipTheme.waitDuration, isNull);
    });
  }
}
