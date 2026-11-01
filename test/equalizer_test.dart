import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/providers/equalizer_provider.dart';
import 'package:mornye/screens/equalizer_screen.dart';
import 'package:mornye/services/playback_equalizer.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_level_slider.dart';

class _CountedSettings extends EqualizerSettings {
  _CountedSettings(double preamp, this.serialized) : super(preamp: preamp);

  final VoidCallback serialized;

  @override
  Map<String, dynamic> toJson() {
    serialized();
    return super.toJson();
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    playbackEqualizer.value = const EqualizerSettings();
    playbackEqualizerError.value = null;
  });

  testWidgets('slider bursts serialize only the final persisted snapshot', (
    tester,
  ) async {
    final container = ProviderContainer();
    final notifier = container.read(equalizerProvider.notifier);
    await tester.pump();
    var serializations = 0;
    final presets = container.read(equalizerProvider).presets;
    for (var i = 0; i < 100; i++) {
      notifier.update(_CountedSettings(-i / 10, () => serializations++));
    }
    expect(serializations, 0);
    expect(container.read(equalizerProvider).presets, same(presets));
    expect(playbackEqualizer.value.preamp, -9.9);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(serializations, 1);
    final prefs = await SharedPreferences.getInstance();
    Object? savedPreamp() {
      final stored =
          jsonDecode(prefs.getString(EqualizerController.storageKey)!)
              as Map<String, dynamic>;
      return (stored['settings'] as Map<String, dynamic>)['preamp'];
    }

    expect(savedPreamp(), -9.9);
    notifier.update(_CountedSettings(-5, () => serializations++));
    container.dispose();
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(serializations, 2);
    expect(savedPreamp(), -5);
  });

  for (final mornye in [false, true]) {
    testWidgets(
      'EQ drags retain unrelated controls and current edits ($mornye)',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 3000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.dark)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const EqualizerScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final notifier = container.read(equalizerProvider.notifier);
        notifier.update(
          container.read(equalizerProvider).settings.copyWith(preamp: -1),
        );
        await tester.pumpAndSettle();
        final page = tester.widget<Scaffold>(find.byType(Scaffold));
        final picker = find.byType(
          mornye ? MornyeSegmentedControl : M3EButtonGroup,
        );
        final bandPicker = tester.widget(picker);
        Widget bass() => mornye
            ? tester
                  .widgetList<MornyeLevelSlider>(find.byType(MornyeLevelSlider))
                  .firstWhere((slider) => slider.semanticLabel == 'Bass')
            : tester
                  .widgetList<AppSlider>(find.byType(AppSlider))
                  .firstWhere((slider) => slider.semanticLabel == 'Bass');
        final bassSlider = bass();
        final gainSlider = mornye
            ? tester
                  .widgetList<MornyeLevelSlider>(find.byType(MornyeLevelSlider))
                  .first
            : tester.widgetList<AppSlider>(find.byType(AppSlider)).first;
        for (var i = 1; i <= 20; i++) {
          notifier.update(
            container.read(equalizerProvider).settings.copyWith(preamp: -i / 2),
          );
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.widget<Scaffold>(find.byType(Scaffold)), same(page));
          expect(tester.widget(picker), same(bandPicker));
          expect(bass(), same(bassSlider));
        }
        if (gainSlider is MornyeLevelSlider) {
          gainSlider.onChanged!(5);
        } else {
          (gainSlider as AppSlider).onChanged!(5);
        }
        await tester.pump();
        if (bassSlider is MornyeLevelSlider) {
          bassSlider.onChanged!(3);
        } else {
          (bassSlider as AppSlider).onChanged!(3);
        }
        await tester.pump();
        final settings = container.read(equalizerProvider).settings;
        expect(settings.preamp, -10);
        expect(settings.gains.first, 5);
        expect(settings.bass, 3);
        expect(playbackEqualizer.value, same(settings));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 350));
      },
    );
  }

  test('band resampling preserves flat curves and center gains', () {
    for (final count in EqualizerSettings.bandCounts) {
      final settings = const EqualizerSettings().withBandCount(count);
      expect(settings.gains, everyElement(0));
      expect(settings.frequencies.length, count);
      final raised = settings.copyWith(gains: List.filled(count, 6));
      for (final hz in raised.frequencies) {
        expect(raised.gainAt(hz), closeTo(6, 1e-9));
      }
      expect(raised.withBandCount(31).gains, everyElement(closeTo(6, 1e-9)));
    }
    expect(const EqualizerSettings().withBandCount(31).frequencies.take(3), [
      20,
      25,
      31.5,
    ]);
    expect(
      () => const EqualizerSettings().withBandCount(32),
      throwsFormatException,
    );
  });

  test('tone controls and automatic headroom reach the native payload', () {
    const settings = EqualizerSettings(
      enabled: true,
      bass: 6,
      treble: -3,
      preamp: -2,
    );
    final payload = settings.toNative();
    expect(settings.effectiveGains.first, greaterThan(5));
    expect(settings.effectiveGains.last, lessThan(-2));
    expect(payload['inputGain'], lessThan(-7));
    expect(payload['gains'], settings.effectiveGains);
    expect(settings.copyWith(autoHeadroom: false).inputGain, -2);
  });

  test('presets change the sound but keep output safety choices', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(equalizerProvider.notifier);
    notifier.update(
      const EqualizerSettings(
        enabled: true,
        balance: 0.25,
        autoHeadroom: false,
        limiter: false,
        compressor: true,
        ratio: 6,
      ),
    );
    final bassBoost = EqualizerPreset.builtIn.firstWhere(
      (preset) => preset.name == 'Bass boost',
    );
    notifier.applyPreset(bassBoost);
    final settings = container.read(equalizerProvider).settings;
    expect(settings.gains, bassBoost.settings.gains);
    expect(settings.enabled, isTrue);
    expect(settings.balance, 0.25);
    expect(settings.autoHeadroom, isFalse);
    expect(settings.limiter, isFalse);
    expect(settings.compressor, isTrue);
    expect(settings.ratio, 6);
    expect(settings.inputGain, 0);
  });

  test(
    'malformed and nonfinite imports cannot create unsafe native settings',
    () {
      final json = const EqualizerSettings().toJson();
      expect(
        () => EqualizerSettings.fromJson({
          ...json,
          'gains': [1, 2],
        }),
        throwsFormatException,
      );
      expect(
        () => EqualizerSettings.fromJson({
          ...json,
          'gains': List.filled(10, double.nan),
        }),
        throwsFormatException,
      );
      final bounded = EqualizerSettings.fromJson({
        ...json,
        'gains': List.filled(10, 100),
        'preamp': 1000,
        'balance': -100,
        'ratio': double.infinity,
      });
      expect(bounded.gains, everyElement(15));
      expect(bounded.preamp, 12);
      expect(bounded.balance, -1);
      expect(bounded.ratio, 3);
    },
  );

  testWidgets('presets survive fast edits during startup and reload', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      EqualizerController.storageKey: jsonEncode({
        'settings': const EqualizerSettings(preamp: -4).toJson(),
        'presets': [
          const EqualizerPreset(
            'Headphones',
            EqualizerSettings(bass: 3),
          ).toJson(),
        ],
      }),
    });
    final container = ProviderContainer();
    container.read(equalizerProvider);
    container
        .read(equalizerProvider.notifier)
        .update(const EqualizerSettings(enabled: true, treble: 2));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump(const Duration(milliseconds: 500));
    expect(container.read(equalizerProvider).settings.treble, 2);
    expect(container.read(equalizerProvider).presets.single.name, 'Headphones');
    final notifier = container.read(equalizerProvider.notifier);
    notifier.savePreset('Desk');
    notifier.update(const EqualizerSettings(enabled: true, preamp: -8));
    final export = notifier.exportPreset('Portable');
    expect(
      (jsonDecode(export) as Map<String, dynamic>)['format'],
      'mornye-equalizer',
    );
    notifier.importPreset(export);
    notifier.importPreset(
      export.replaceFirst('mornye-equalizer', 'spotiflac-equalizer'),
    );
    expect(container.read(equalizerProvider).presets.map((v) => v.name), [
      'Headphones',
      'Desk',
      'Portable',
    ]);
    expect(container.read(equalizerProvider).settings.enabled, isTrue);
    expect(() => notifier.importPreset('{}'), throwsFormatException);
    expect(() => notifier.importPreset('x' * 65537), throwsFormatException);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    container.dispose();
    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    restored.read(equalizerProvider);
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(restored.read(equalizerProvider).settings.preamp, -8);
    expect(restored.read(equalizerProvider).presets.length, 3);
  });

  for (final mornye in [false, true]) {
    testWidgets(
      'EQ editing and dialogs fit a narrow screen with large text ($mornye)',
      (tester) async {
        tester.view.physicalSize = const Size(320, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.dark)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.8)),
                child: child!,
              ),
              home: const EqualizerScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final picker = find.byType(
          mornye ? MornyeSegmentedControl : M3EButtonGroup,
        );
        await tester.scrollUntilVisible(
          picker,
          150,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        // The picker sits on an opaque group card.
        expect(
          find.descendant(of: picker, matching: find.byType(BackdropFilter)),
          findsNothing,
        );
        await tester.tap(
          find.descendant(of: picker, matching: find.text('31')).first,
        );
        await tester.pumpAndSettle();
        expect(container.read(equalizerProvider).settings.gains.length, 31);
        expect(tester.takeException(), isNull);
        // The first slider on the page is the lowest band's fader.
        final onChanged = mornye
            ? tester
                  .widgetList<MornyeLevelSlider>(find.byType(MornyeLevelSlider))
                  .first
                  .onChanged
            : tester
                  .widgetList<AppSlider>(find.byType(AppSlider))
                  .first
                  .onChanged;
        onChanged!(5);
        await tester.pump();
        expect(container.read(equalizerProvider).settings.gains.first, 5);
        // Drags over the vertical faders adjust gains instead of scrolling.
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(0);
        await tester.pumpAndSettle();
        final save = find.text('Save preset');
        await tester.scrollUntilVisible(
          save,
          150,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(save);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(EditableText), 'My headphones');
        await tester.tap(find.text('Save').last);
        await tester.pumpAndSettle();
        expect(
          container.read(equalizerProvider).presets.single.name,
          'My headphones',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
