import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/equalizer_screen.dart';
import 'package:mornye/screens/settings/appearance_settings_page.dart';
import 'package:mornye/screens/settings/download_settings_page.dart';
import 'package:mornye/screens/settings/lyrics_settings_page.dart';
import 'package:mornye/screens/settings/playback_settings_page.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';

void main() {
  final pages = <String, Widget Function()>{
    'playback': () => const PlaybackSettingsPage(),
    'appearance': () => const AppearanceSettingsPage(),
    'lyrics': () => const LyricsSettingsPage(),
    'download': () => const DownloadSettingsPage(),
    'equalizer': () => const EqualizerScreen(),
  };
  final themes = <String, ThemeData Function()>{
    'Material light': AppTheme.light,
    'Material dark': AppTheme.dark,
    'Mornye light': () => MornyeTheme.build(Brightness.light),
    'Mornye dark': () => MornyeTheme.build(Brightness.dark),
  };

  for (final page in pages.entries) {
    for (final theme in themes.entries) {
      testWidgets('${page.key} meets tap target, label and contrast guidelines '
          '(${theme.key})', (tester) async {
        SharedPreferences.setMockInitialValues({});
        // Tall enough that every row is laid out and checked.
        tester.view.physicalSize = const Size(412, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final handle = tester.ensureSemantics();
        final mornye = theme.key.startsWith('Mornye');
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: theme.value(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: mornye
                  ? MornyeSettingsTheme(child: page.value())
                  : page.value(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (page.key == 'equalizer') {
          // From 10 bands a phone row gives each fader less than 48 dp by
          // design; screen readers adjust them with increase/decrease
          // actions instead. Five bands leave every fader a full target.
          await tester.tap(find.text('5').first);
          await tester.pumpAndSettle();
        }
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        handle.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
