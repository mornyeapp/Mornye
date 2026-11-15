import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/settings_group.dart';

/// A page with a connected group below an app-level idle focus node, as the
/// desktop shortcuts hold one to read Space for playback.
Widget _page(FocusNode idle) => MaterialApp(
  theme: AppTheme.light(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) =>
      Focus(focusNode: idle, autofocus: true, child: child!),
  home: Scaffold(
    body: SettingsSegmentedChoice<int>(
      options: const [
        SettingsSegmentOption(value: 0, label: 'One'),
        SettingsSegmentOption(value: 1, label: 'Two'),
      ],
      selected: 0,
      onChanged: (_) {},
    ),
  ),
);

bool _focusInGroup(WidgetTester tester) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  return find
      .ancestor(
        of: find.byWidgetPredicate(
          (widget) => identical(widget, focused.widget),
        ),
        matching: find.byType(SettingsSegmentedChoice<int>),
      )
      .evaluate()
      .isNotEmpty;
}

void main() {
  testWidgets('a connected group does not take focus as it mounts', (
    tester,
  ) async {
    final idle = FocusNode(debugLabel: 'idle');
    addTearDown(idle.dispose);
    await tester.pumpWidget(_page(idle));
    await tester.pumpAndSettle();

    final primary = FocusManager.instance.primaryFocus;
    expect(primary == idle || primary is FocusScopeNode, isTrue);
    expect(_focusInGroup(tester), isFalse);
  });

  testWidgets('Tab still reaches the group', (tester) async {
    final idle = FocusNode(debugLabel: 'idle');
    addTearDown(idle.dispose);
    await tester.pumpWidget(_page(idle));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_focusInGroup(tester), isTrue);
  });
}
