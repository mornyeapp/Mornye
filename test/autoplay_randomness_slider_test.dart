import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/settings_search_catalog.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/autoplay_randomness_slider.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/slider_value_header.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final mornye in [false, true]) {
    for (final locale in ['en', 'id', 'ar']) {
      testWidgets(
        'Autoplay slider follows style and text scale ($mornye, $locale)',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          tester.view.physicalSize = const Size(320, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final container = ProviderContainer(
            overrides: [
              initialSettingsProvider.overrideWithValue(
                const AppSettings(autoplayPersonalization: false),
              ),
            ],
          );
          addTearDown(container.dispose);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: mornye
                    ? MornyeTheme.build(
                        Brightness.dark,
                        accent: MornyeAccent.blue,
                      )
                    : AppTheme.light(),
                locale: Locale(locale),
                localizationsDelegates: appLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(2)),
                  child: child!,
                ),
                home: const Scaffold(
                  body: SingleChildScrollView(
                    child: SettingsGroup(
                      children: [AutoplayRandomnessSlider()],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(SliderValueHeader), findsOneWidget);
          final slider = find.byType(AppSlider);
          final l10n = AppLocalizations.of(tester.element(slider));
          expect(find.text(l10n.autoplayLeastRecent), findsOneWidget);
          expect(find.text(l10n.autoplayMoreRandom), findsOneWidget);
          expect(
            SettingsSearchCatalog(l10n).playback.any(
              (entry) =>
                  entry.title == l10n.autoplayRandomness &&
                  entry.matches(SettingsSearchQuery('variety')),
            ),
            isTrue,
          );

          await tester.ensureVisible(slider);
          await tester.pumpAndSettle();
          expect(slider.hitTestable(), findsOneWidget);
          expect(tester.widget<AppSlider>(slider).onChanged, isNotNull);
          final rect = tester.getRect(slider);
          final rtl = locale == 'ar';
          final gesture = await tester.startGesture(
            Offset(rtl ? rect.right - 24 : rect.left + 24, rect.center.dy),
          );
          await tester.pump();
          await gesture.moveBy(Offset(rtl ? -30 : 30, 0));
          await tester.pump();
          await gesture.moveTo(
            Offset(
              rtl ? rect.left + rect.width * 0.2 : rect.left + rect.width * 0.8,
              rect.center.dy,
            ),
          );
          await tester.pump();
          expect(container.read(settingsProvider).autoplayRandomness, 0);
          expect(tester.widget<AppSlider>(slider).value, greaterThan(0.5));
          await gesture.up();
          await tester.pumpAndSettle();
          final value = container.read(settingsProvider).autoplayRandomness;
          expect(value, greaterThan(0.5));
          expect(
            container.read(settingsProvider).autoplayPersonalization,
            isFalse,
          );
          final prefs = await SharedPreferences.getInstance();
          expect(
            AppSettings.fromJson(
              jsonDecode(prefs.getString('app_settings')!)
                  as Map<String, dynamic>,
            ).autoplayRandomness,
            value,
          );

          container.read(settingsProvider.notifier).setPlayerMode('external');
          await tester.pump();
          expect(tester.widget<AppSlider>(slider).onChanged, isNull);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
