import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/settings/link_settings_page.dart';
import 'package:mornye/services/link/client/link_client_store.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/sync/link_sound_sync_runner.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/settings_group.dart';

import 'support/link_client_fakes.dart';

final _l10n = lookupAppLocalizations(const Locale('en'));

void main() {
  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('$style: Sync sound settings is an off switch row', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        LinkClientStore.serversKey: jsonEncode([
          const LinkServerRecord(
            serverId: 'a',
            name: 'Studio',
            connectionId: 'connection-a',
            address: 'https://10.0.0.2:47710',
            fingerprint: 'ab',
          ).toJson(),
        ]),
        LinkClientStore.activeServerKey: 'a',
      });
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: LinkClientHarness().overrides,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: mornye ? MornyeTheme.build(Brightness.light) : null,
            home: const LinkSettingsPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // The same switch row as the other phone options.
      final row = find.widgetWithText(
        SettingsSwitchItem,
        _l10n.linkSyncSoundTitle,
      );
      expect(row, findsOneWidget);
      expect(find.text(_l10n.linkSyncSoundSubtitle), findsOneWidget);
      expect(tester.widget<SettingsSwitchItem>(row).value, isFalse);
      expect(
        find.descendant(of: row, matching: find.byType(AppSwitch)),
        findsOneWidget,
      );

      await tester.ensureVisible(row);
      await tester.pump();
      await tester.tap(find.text(_l10n.linkSyncSoundTitle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.widget<SettingsSwitchItem>(row).value, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(LinkSoundSyncOptionNotifier.enabledKey), isTrue);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }
}
