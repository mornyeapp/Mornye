import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/automix_settings.dart';
import 'package:mornye/widgets/music_haptics_settings.dart';
import 'package:mornye/widgets/playback_normalization_settings.dart';
import 'package:mornye/widgets/slider_value_header.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Widget child, {
    bool mornye = false,
  }) async {
    final container = ProviderContainer(
      overrides: [
        initialSettingsProvider.overrideWithValue(
          const AppSettings(
            musicHaptics: true,
            playbackNormalization: true,
            autoMix: true,
            autoMixDuration: 5,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: mornye
              ? MornyeTheme.build(Brightness.light)
              : AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
    return container;
  }

  /// The tonal pill around [value], if Material drew one.
  ShapeDecoration? pill(WidgetTester tester, String value) {
    // Mornye's page transition draws its edge shadow in a DecoratedBox too.
    final boxes = find.ancestor(
      of: find.text(value),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox && widget.decoration is ShapeDecoration,
      ),
    );
    if (boxes.evaluate().isEmpty) return null;
    return tester.widget<DecoratedBox>(boxes.first).decoration
        as ShapeDecoration;
  }

  testWidgets('Material shows the value in a tonal pill', (tester) async {
    await pump(
      tester,
      const Column(
        children: [
          SliderValueHeader(title: 'Strength', value: '40%'),
          SliderValueHeader(title: 'Gain', value: '+2 dB', enabled: false),
        ],
      ),
    );
    final context = tester.element(find.text('Strength'));
    final scheme = Theme.of(context).colorScheme;
    final enabled = pill(tester, '40%')!;
    expect(enabled.color, scheme.secondaryContainer);
    expect(enabled.shape, isA<StadiumBorder>());
    final text = tester.widget<Text>(find.text('40%'));
    expect(text.style?.color, scheme.onSecondaryContainer);
    expect(
      text.style?.fontSize,
      Theme.of(context).textTheme.labelLarge?.fontSize,
    );
    expect(
      pill(tester, '+2 dB')!.color,
      scheme.onSurface.withValues(alpha: 0.12),
    );
  });

  testWidgets('Mornye shows the value as detail text', (tester) async {
    await pump(
      tester,
      const SliderValueHeader(title: 'Strength', value: '40%'),
      mornye: true,
    );
    expect(find.text('40%'), findsOneWidget);
    expect(pill(tester, '40%'), isNull);
  });

  testWidgets(
    'haptics sliders show a draft while dragging and save on release',
    (tester) async {
      final container = await pump(
        tester,
        const MusicHapticsSettings(enabled: true),
      );
      expect(find.text('Sensitivity'), findsOneWidget);
      expect(pill(tester, '50%'), isNotNull);

      final slider = tester.widget<AppSlider>(find.byType(AppSlider).first);
      slider.onChanged!(0.8);
      await tester.pump();
      expect(find.text('80%'), findsOneWidget);
      expect(container.read(settingsProvider).musicHapticsSensitivity, 0.5);

      slider.onChangeEnd!(0.8);
      await tester.pump();
      expect(container.read(settingsProvider).musicHapticsSensitivity, 0.8);
      expect(pill(tester, '80%'), isNotNull);
    },
  );

  testWidgets('Mornye settings sliders keep their inline labels', (
    tester,
  ) async {
    await pump(
      tester,
      const Column(
        children: [
          MusicHapticsSettings(enabled: true),
          PlaybackNormalizationSettings(enabled: true),
          AutoMixSettings(),
        ],
      ),
      mornye: true,
    );
    expect(find.text('Sensitivity: 50%'), findsOneWidget);
    expect(find.text('Pre-amp: 0 dB (target -18 LUFS)'), findsOneWidget);
    expect(find.text('Mix duration: 5 s'), findsOneWidget);
    expect(find.byType(SliderValueHeader), findsNothing);
  });
}
