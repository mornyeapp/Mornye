import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/activity_attachment.dart';

void main() {
  testWidgets('startup waits until an Activity reports its lifecycle', (
    tester,
  ) async {
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    expect(isActivityAttached(binding), isFalse);
    var attached = false;
    final waiting = waitForActivityAttachment(
      binding,
    ).then((_) => attached = true);
    await tester.pump();
    expect(attached, isFalse);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await waiting;
    expect(attached, isTrue);
    expect(isActivityAttached(binding), isTrue);
  });

  testWidgets('an attached Activity does not delay startup', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var attached = false;
    await waitForActivityAttachment(
      tester.binding,
    ).then((_) => attached = true);
    expect(attached, isTrue);
  });
}
