import 'dart:ui' show SemanticsAction;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/settings_group.dart';

void main() {
  Future<void> pumpSwitch(
    WidgetTester tester, {
    required Widget Function(StateSetter setState) builder,
    bool reduceMotion = false,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.light),
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduceMotion),
            child: Scaffold(
              body: Center(
                child: StatefulBuilder(
                  builder: (context, setState) => builder(setState),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
  }

  testWidgets('glass switch supports tap, keyboard and accessible activation', (
    tester,
  ) async {
    var value = false;
    final changes = <bool>[];
    await pumpSwitch(
      tester,
      builder: (setState) => AppSwitch(
        value: value,
        semanticLabel: 'Example setting',
        onChanged: (next) {
          changes.add(next);
          setState(() => value = next);
        },
      ),
    );

    await tester.tap(find.byType(AppSwitch));
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(changes, [true]);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(changes, [true, false]);

    final node = tester.getSemantics(find.bySemanticsLabel('Example setting'));
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(changes, [true, false, true]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled glass switch has no toggle action', (tester) async {
    await pumpSwitch(
      tester,
      builder: (_) => const AppSwitch(
        value: true,
        onChanged: null,
        semanticLabel: 'Disabled setting',
      ),
    );
    final node = tester.getSemantics(find.bySemanticsLabel('Disabled setting'));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final grouped in [false, true]) {
    testWidgets('row and thumb each toggle once (grouped=$grouped)', (
      tester,
    ) async {
      var value = false;
      final changes = <bool>[];
      await pumpSwitch(
        tester,
        reduceMotion: true,
        builder: (setState) {
          void update(bool next) {
            changes.add(next);
            setState(() => value = next);
          }

          return grouped
              ? SettingsGroup(
                  children: [
                    SettingsSwitchItem(
                      title: 'Example setting',
                      value: value,
                      onChanged: update,
                    ),
                  ],
                )
              : AppSwitchListTile(
                  title: const Text('Example setting'),
                  value: value,
                  onChanged: update,
                );
        },
      );
      expect(find.byType(BackdropFilter), findsNothing);
      await tester.tap(find.text('Example setting'));
      await tester.pumpAndSettle();
      expect(changes, [true]);
      await tester.tap(find.byType(AppSwitch));
      await tester.pumpAndSettle();
      expect(changes, [true, false]);
      expect(tester.takeException(), isNull);
    });
  }
}
