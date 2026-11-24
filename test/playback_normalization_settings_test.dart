import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/playback_normalization_settings.dart';

void main() {
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    bool enabled = true,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        initialSettingsProvider.overrideWithValue(
          const AppSettings(playbackNormalization: true),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: PlaybackNormalizationSettings(enabled: enabled),
            ),
          ),
        ),
      ),
    );
    return container;
  }

  testWidgets('pre-amp shows its target and saves at the end of a drag', (
    tester,
  ) async {
    final container = await pump(tester);
    expect(find.text('Pre-amp'), findsOneWidget);
    expect(find.text('0 dB (target -18 LUFS)'), findsOneWidget);

    final slider = tester.widget<AppSlider>(find.byType(AppSlider));
    slider.onChanged!(-7);
    await tester.pump();
    expect(find.text('-7 dB (target -25 LUFS)'), findsOneWidget);
    expect(container.read(settingsProvider).playbackNormalizationPreamp, 0);

    slider.onChangeEnd!(-7);
    await tester.pump();
    expect(container.read(settingsProvider).playbackNormalizationPreamp, -7);

    // The expressive segmented group also lays out a measuring copy.
    await tester.tap(find.text('Album').first);
    await tester.pump();
    expect(container.read(settingsProvider).playbackNormalizationMode, 'album');
  });

  testWidgets('bit-perfect output disables the controls', (tester) async {
    await pump(tester, enabled: false);
    expect(tester.widget<AppSlider>(find.byType(AppSlider)).onChanged, isNull);
  });

  testWidgets('the never clips promise goes once quiet songs rise', (
    tester,
  ) async {
    final container = await pump(tester);
    expect(find.textContaining('never clips'), findsOneWidget);

    container
        .read(settingsProvider.notifier)
        .setPlaybackNormalizationBoost(true);
    await tester.pump();
    expect(container.read(settingsProvider).playbackNormalizationBoost, isTrue);
    expect(find.textContaining('never clips'), findsNothing);
    expect(find.text('Lower values play quieter.'), findsOneWidget);
  });
}
