import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/automix_options.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/widgets/automix_settings.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_slider.dart';

void main() {
  testWidgets(
    'manual duration saves at end of drag and USB disables DSP controls',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          initialSettingsProvider.overrideWithValue(
            const AppSettings(
              autoMix: true,
              autoMixDuration: 5,
              autoMixEffect: AutoMixEffect.custom,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(child: AutoMixSettings()),
            ),
          ),
        ),
      );
      final slider = tester.widget<AppSlider>(find.byType(AppSlider).first);
      slider.onChanged!(45);
      await tester.pump();
      expect(container.read(settingsProvider).autoMixDuration, 5);
      expect(find.text('45 s'), findsOneWidget);
      slider.onChangeEnd!(45);
      await tester.pump();
      expect(container.read(settingsProvider).autoMixDuration, 45);
      container.read(settingsProvider.notifier).setUsbBitPerfect(true);
      await tester.pump();
      for (final slider in tester.widgetList<AppSlider>(
        find.byType(AppSlider),
      )) {
        expect(slider.onChanged, isNull);
      }
      await tester.tap(find.text('Transition effect'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('beat matching saves the level and rests under Crossfade', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        initialSettingsProvider.overrideWithValue(
          const AppSettings(autoMix: true),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SingleChildScrollView(child: AutoMixSettings())),
        ),
      ),
    );
    expect(find.text('Standard'), findsOneWidget);
    await tester.tap(find.text('Beat matching'));
    await tester.pumpAndSettle();
    expect(find.byType(AppSheetOption), findsNWidgets(3));
    await tester.tap(find.text('Most often'));
    await tester.pumpAndSettle();
    expect(
      container.read(settingsProvider).autoMixMatching,
      AutoMixMatching.most,
    );
    expect(find.byType(AppBottomSheet), findsNothing);
    expect(find.text('Most often'), findsOneWidget);
    // A Crossfade transition never mixes on the beat.
    container
        .read(settingsProvider.notifier)
        .setAutoMixEffect(AutoMixEffect.crossfade);
    await tester.pump();
    await tester.tap(find.text('Beat matching'));
    await tester.pumpAndSettle();
    expect(find.byType(AppBottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final mornye in [false, true]) {
    testWidgets(
      'effect picker follows app theme and saves selection ($mornye)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(350, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final container = ProviderContainer(
          overrides: [
            initialSettingsProvider.overrideWithValue(
              const AppSettings(autoMix: true),
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
                  : AppTheme.light(seedColor: Colors.blue),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const MornyeSettingsTheme(
                child: Scaffold(
                  body: SingleChildScrollView(child: AutoMixSettings()),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Transition effect'));
        await tester.pumpAndSettle();
        expect(find.byType(AppBottomSheet), findsOneWidget);
        expect(find.byType(AppSheetOption), findsNWidgets(6));
        final context = tester.element(find.byType(AppBottomSheet));
        expect(context.isMornye, mornye);
        final selected = tester
            .widgetList<AppSheetOption>(find.byType(AppSheetOption))
            .singleWhere((option) => option.trailing != null);
        expect((selected.title as Text).data, 'Auto');
        expect(
          (selected.trailing as Icon).color,
          Theme.of(context).colorScheme.primary,
        );
        final custom = find.descendant(
          of: find.byType(AppBottomSheet),
          matching: find.text('Custom'),
        );
        await tester.ensureVisible(custom);
        await tester.pumpAndSettle();
        await tester.tap(custom);
        await tester.pumpAndSettle();
        expect(
          container.read(settingsProvider).autoMixEffect,
          AutoMixEffect.custom,
        );
        expect(find.byType(BottomSheet), findsNothing);
        expect(find.text('Custom'), findsOneWidget);
        expect(find.byType(AppSlider), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
