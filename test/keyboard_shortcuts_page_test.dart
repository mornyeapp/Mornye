import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/keyboard_shortcuts_page.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

class _ExternalSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(playerMode: 'external');
}

void main() {
  testWidgets('another app leaves out the keys of the player', (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsProvider.overrideWith(_ExternalSettings.new)],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const KeyboardShortcutsPage(platform: TargetPlatform.macOS),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(KeyboardShortcutsPage)),
    );

    expect(find.text(l10n.desktopMenuPlayPause), findsNothing);
    expect(find.text(l10n.desktopMenuControls), findsNothing);
    expect(find.text(l10n.nowPlayingUpNext), findsNothing);
    expect(find.text(l10n.desktopMenuMiniPlayer), findsNothing);
    expect(find.text(l10n.desktopShortcutToggleSidebar), findsOneWidget);
    expect(find.text(l10n.openAudioFiles), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final mornye in [false, true]) {
    for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
      final style = mornye ? 'Mornye' : 'Material';
      testWidgets('$style lists every ${platform.name} shortcut', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1200, 3000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [settingsProvider.overrideWith(_Settings.new)],
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.light)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: KeyboardShortcutsPage(platform: platform),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final shown = tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data ?? '')
            .join('\n');
        final destinations = desktopDestinationTabs(
          showStore: const AppSettings().showExtensionStore,
        ).length;
        final bound = desktopShortcutBindings(platform).keys;
        for (final activator in bound.cast<SingleActivator>()) {
          // Unused destination numbers have no page to describe.
          final number = int.tryParse(activator.trigger.keyLabel);
          if (number != null && number > destinations) continue;
          expect(
            shown,
            contains(desktopShortcutLabel(activator, platform)),
            reason: '${activator.trigger.keyLabel} is not listed',
          );
        }
        expect(find.text('Play/Pause'), findsOneWidget);
        expect(
          find.text(
            desktopShortcutLabel(
              desktopCommandShortcut(DesktopCommand.settings, platform)!,
              platform,
            ),
          ),
          findsNothing,
          reason: 'Settings lists its command and destination in one row',
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
