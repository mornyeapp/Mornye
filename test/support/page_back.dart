import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoNavigationBarBackButton;
import 'package:flutter_test/flutter_test.dart';

import 'tooltip_finder.dart';

/// Taps the back button, as `tester.pageBack()` does.
///
/// `pageBack()` only knows the back buttons of Flutter's built-in Material
/// and Cupertino libraries, so it misses the `material_ui` and `cupertino_ui`
/// ones the app builds.
Future<void> pageBack(WidgetTester tester) async {
  var backButton = findByTooltip('Back');
  if (backButton.evaluate().isEmpty) {
    backButton = find.byType(CupertinoNavigationBarBackButton);
  }
  expect(
    backButton,
    findsOneWidget,
    reason: 'One back button expected on screen',
  );
  await tester.tap(backButton);
}
