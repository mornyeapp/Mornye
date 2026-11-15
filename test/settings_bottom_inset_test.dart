import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/files_settings_page.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

void main() {
  for (final mornye in [false, true]) {
    testWidgets('Files scrolls its last row above floating chrome ($mornye)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      debugDesktopPlatformOverride = true;
      addTearDown(() => debugDesktopPlatformOverride = null);
      tester.view.physicalSize = const Size(1200, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const inset = 88.0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [settingsProvider.overrideWith(FixedSettingsNotifier.new)],
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark)
                : AppTheme.dark(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(padding: const EdgeInsets.only(bottom: inset)),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const MornyeSettingsTheme(child: FilesSettingsPage()),
                    const Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: inset,
                      child: ColoredBox(color: Colors.black),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final filters = find.byWidgetPredicate(
        (widget) =>
            widget is SettingsItem && widget.title == 'Artist Name Filters',
      );
      expect(tester.getBottomRight(filters).dy, lessThanOrEqualTo(700 - inset));
      await tester.tap(filters);
      await tester.pumpAndSettle();
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final contributing = find.byWidgetPredicate(
        (widget) =>
            widget is SettingsSwitchItem &&
            widget.title == 'Filter Contributing Artists',
      );
      expect(
        tester.getBottomRight(contributing).dy,
        lessThanOrEqualTo(700 - inset),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
