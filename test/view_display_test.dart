import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/view_display.dart';

/// A view whose display the engine no longer lists, as while a desktop
/// window is dragged to another screen.
class _MovingView extends Fake implements FlutterView {
  @override
  Display get display => (null as Display?)!;
}

void main() {
  testWidgets('a view between screens has no display instead of an error', (
    tester,
  ) async {
    expect(() => _MovingView().display, throwsA(isA<Error>()));
    expect(displayOf(_MovingView()), isNull);
    expect(displayOf(null), isNull);
    expect(displayOf(tester.view), isNotNull);
  });
}
