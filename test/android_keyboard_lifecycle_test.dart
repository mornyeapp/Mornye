import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/widgets/android_keyboard_lifecycle.dart';

void _setLifecycle(AppLifecycleState state) {
  final binding = TestWidgetsFlutterBinding.instance;
  if (state == AppLifecycleState.resumed) {
    if (binding.lifecycleState == AppLifecycleState.paused) {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    }
    if (binding.lifecycleState == AppLifecycleState.hidden) {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    }
  } else if (state == AppLifecycleState.paused) {
    if (binding.lifecycleState == AppLifecycleState.resumed) {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    }
    if (binding.lifecycleState == AppLifecycleState.inactive) {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    }
  }
  binding.handleAppLifecycleStateChanged(state);
}

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    debugAndroidTvOverride = null;
  });

  for (final mornye in [false, true]) {
    testWidgets(
      'background ends editing without losing text, Mornye: $mornye',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final focus = FocusNode();
        final controller = TextEditingController();
        addTearDown(focus.dispose);
        addTearDown(controller.dispose);
        _setLifecycle(AppLifecycleState.resumed);
        await tester.pumpWidget(
          MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.light)
                : AppTheme.light(),
            builder: (_, child) => AndroidKeyboardLifecycle(child: child!),
            home: Scaffold(
              body: TextField(focusNode: focus, controller: controller),
            ),
          ),
        );
        await tester.enterText(find.byType(TextField), 'Unfinished search');
        expect(focus.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        _setLifecycle(AppLifecycleState.inactive);
        await tester.pump();
        expect(focus.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        tester.testTextInput.log.clear();
        _setLifecycle(AppLifecycleState.hidden);
        await tester.idle();
        expect(tester.testTextInput.isVisible, isFalse);
        _setLifecycle(AppLifecycleState.paused);
        // No background frame is needed to send the native hide request.
        expect(tester.testTextInput.isVisible, isFalse);
        _setLifecycle(AppLifecycleState.resumed);
        await tester.pump();
        expect(focus.hasFocus, isFalse);
        expect(controller.text, 'Unfinished search');
        expect(tester.testTextInput.isVisible, isFalse);

        await tester.tap(find.byType(TextField));
        await tester.pump();
        expect(focus.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        await tester.enterText(find.byType(TextField), 'Continued search');
        _setLifecycle(AppLifecycleState.paused);
        _setLifecycle(AppLifecycleState.resumed);
        await tester.pump();
        expect(focus.hasFocus, isFalse);
        expect(controller.text, 'Continued search');
        expect(tester.testTextInput.isVisible, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  for (final tv in [false, true]) {
    testWidgets('does not close desktop or TV input, TV: $tv', (tester) async {
      debugDefaultTargetPlatformOverride = tv
          ? TargetPlatform.android
          : TargetPlatform.windows;
      debugAndroidTvOverride = tv;
      _setLifecycle(AppLifecycleState.resumed);
      await tester.pumpWidget(
        const MaterialApp(
          home: AndroidKeyboardLifecycle(child: Scaffold(body: TextField())),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Keep editing');
      tester.testTextInput.log.clear();
      _setLifecycle(AppLifecycleState.paused);
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.hide',
        ),
        isEmpty,
      );
      _setLifecycle(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('disposing the wrapper removes its lifecycle observer', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(
      const AndroidKeyboardLifecycle(child: SizedBox.shrink()),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (call) async => calls.add(call),
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.textInput,
        null,
      ),
    );
    _setLifecycle(AppLifecycleState.paused);
    expect(calls, isEmpty);
    _setLifecycle(AppLifecycleState.resumed);
    debugDefaultTargetPlatformOverride = null;
  });
}
