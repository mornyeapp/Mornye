import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/android_keyboard_lifecycle.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';

/// Run with android_keyboard_resume_driver.dart on a dedicated emulator.
/// Uses the real Android keyboard, Home action and native touch dispatch.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.shouldPropagateDevicePointerEvents = true;
  testWidgets('keyboard background/resume restores usable viewport', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Unfinished search');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);

    Future<void> waitFor(bool Function() ready, String description) async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!ready()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Timed out waiting for $description');
        }
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // audio_service warms up the engine before MainActivity attaches its view.
    await tester.pumpWidget(const SizedBox.shrink());
    await waitFor(
      () =>
          tester.view.physicalSize.height > 0 &&
          binding.lifecycleState == AppLifecycleState.resumed,
      'activity attachment',
    );

    for (var cycle = 0; cycle < 4; cycle++) {
      final mornye = cycle >= 2;
      final sheet = cycle.isOdd;
      var tapped = false;
      final lifecycle = _BackgroundRoundTrip();
      binding.addObserver(lifecycle);
      Widget editor() => Column(
        children: [
          TextField(focusNode: focus, controller: controller),
          const Spacer(),
          FilledButton(
            key: const ValueKey('bottom-control'),
            onPressed: () => tapped = true,
            child: const Text('Bottom control'),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [settingsProvider.overrideWith(_Settings.new)],
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.light)
                : AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (_, child) => AndroidKeyboardLifecycle(child: child!),
            home: Scaffold(
              body: SafeArea(
                child: sheet
                    ? Builder(
                        builder: (context) => TextButton(
                          onPressed: () => showAppModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            builder: (context) => Padding(
                              padding: MediaQuery.viewInsetsOf(context),
                              child: SizedBox(
                                height: MediaQuery.sizeOf(context).height * 0.8,
                                child: SafeArea(child: editor()),
                              ),
                            ),
                          ),
                          child: const Text('Open editor'),
                        ),
                      )
                    : editor(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (sheet) {
        final openPosition =
            tester.getCenter(find.text('Open editor')) *
            tester.view.devicePixelRatio;
        // ignore: avoid_print
        print(
          'KEYBOARD_RESUME_OPEN_$cycle ${openPosition.dx.round()} ${openPosition.dy.round()}',
        );
        await waitFor(
          () => find.byType(TextField).evaluate().isNotEmpty,
          'sheet opening',
        );
        await tester.pumpAndSettle();
      }
      await tester.pumpAndSettle();
      final editorPosition =
          tester.getCenter(find.byType(TextField)) *
          tester.view.devicePixelRatio;
      // Wait for a native tap, so the window has focus before requesting IME.
      // ignore: avoid_print
      print(
        'KEYBOARD_RESUME_EDIT_$cycle ${editorPosition.dx.round()} ${editorPosition.dy.round()}',
      );
      await waitFor(
        () => focus.hasFocus && tester.view.viewInsets.bottom > 0,
        'keyboard opening',
      );
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
      // ignore: avoid_print
      print('KEYBOARD_RESUME_READY_$cycle');
      await lifecycle.resumed.future.timeout(const Duration(seconds: 30));
      binding.removeObserver(lifecycle);
      await waitFor(
        () => tester.view.viewInsets.bottom == 0,
        'keyboard closing',
      );
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isFalse);
      expect(tester.view.viewInsets.bottom, 0);
      expect(controller.text, 'Unfinished search');
      final bottom = find.byKey(const ValueKey('bottom-control'));
      final position = tester.getCenter(bottom) * tester.view.devicePixelRatio;
      expect(position.dy, greaterThan(tester.view.physicalSize.height / 2));
      // The host sends a real tap into the area previously occupied by the IME.
      // ignore: avoid_print
      print(
        'KEYBOARD_RESUME_TAP_$cycle ${position.dx.round()} ${position.dy.round()}',
      );
      await waitFor(() => tapped, 'native bottom-control tap');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
    binding.reportData = {'keyboardResumeCycles': 4, 'nativeBottomTaps': 4};
  });
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

class _BackgroundRoundTrip with WidgetsBindingObserver {
  bool hidden = false;
  final resumed = Completer<void>();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) hidden = true;
    if (hidden && state == AppLifecycleState.resumed && !resumed.isCompleted) {
      resumed.complete();
    }
  }
}
