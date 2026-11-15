import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/playback_settings_page.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/settings_search_catalog.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/playback_tempo_sheet.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/slider_value_header.dart';

const _speedSlider = ValueKey('playback-speed-slider');
const _pitchSlider = ValueKey('playback-pitch-slider');

ThemeData _theme(bool mornye) => mornye
    ? MornyeTheme.build(Brightness.dark, accent: MornyeAccent.blue)
    : AppTheme.light();

/// Pumps a page whose button opens the sheet, and opens it.
Future<ProviderContainer> _openSheet(
  WidgetTester tester, {
  required bool mornye,
  AppSettings settings = const AppSettings(),
}) async {
  tester.view.physicalSize = const Size(420, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [initialSettingsProvider.overrideWithValue(settings)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: _theme(mornye),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showPlaybackTempoSheet(context),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return container;
}

AppSlider _slider(WidgetTester tester, Key key) =>
    tester.widget<AppSlider>(find.byKey(key));

SettingsSwitchItem _keepPitch(WidgetTester tester) =>
    tester.widget<SettingsSwitchItem>(find.byType(SettingsSwitchItem));

/// [text] in a slider's value header.
Finder _value(String text) => find.descendant(
  of: find.byType(SliderValueHeader),
  matching: find.text(text),
);

/// The quick choice labelled [text].
Finder _choice(String text) => find.text(text).hitTestable().first;

ExpressiveButton _reset(WidgetTester tester) => tester.widget(
  find.ancestor(
    of: find.text('Reset'),
    matching: find.byType(ExpressiveButton),
  ),
);

/// Drags the slider [key] from its start to [fraction] of its width, then
/// runs [whileDragging] before releasing.
Future<void> _drag(
  WidgetTester tester,
  Key key,
  double fraction, {
  required void Function() whileDragging,
}) async {
  final rect = tester.getRect(find.byKey(key));
  final gesture = await tester.startGesture(
    Offset(rect.left + 24, rect.center.dy),
  );
  await tester.pump();
  await gesture.moveBy(const Offset(30, 0));
  await tester.pump();
  await gesture.moveTo(
    Offset(rect.left + rect.width * fraction, rect.center.dy),
  );
  await tester.pump();
  whileDragging();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDown(() {
    playbackSpeed.value = 1;
    playbackPitch.value = PlaybackPitch.none;
    playbackTempoSupport.value = PlaybackTempoSupport.full;
  });

  test('labels use the locale, a real minus sign and the unit', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final id = lookupAppLocalizations(const Locale('id'));
    expect(playbackSpeedLabel(en, 1), '1x');
    expect(playbackSpeedLabel(en, 1.25), '1.25x');
    expect(playbackSpeedLabel(id, 1.25), '1,25x');
    expect(playbackPitchLabel(en, 2), '+2');
    expect(playbackPitchLabel(en, -3), '−3');
    expect(playbackPitchLabel(id, -12), '−12');
    expect(playbackPitchLabel(en, 0), '0');
    expect(
      playbackTempoSummary(en, speed: 1, keepPitch: true, pitch: 0),
      isNull,
    );
    expect(
      playbackTempoSummary(en, speed: 1.25, keepPitch: true, pitch: 2),
      '1.25x, +2 semitones',
    );
    expect(
      playbackTempoSummary(en, speed: 1, keepPitch: true, pitch: -1),
      '−1 semitone',
    );
    expect(
      playbackTempoSummary(en, speed: 1, keepPitch: true, pitch: 3),
      '+3 semitones',
    );
    expect(
      playbackTempoSummary(en, speed: 1, keepPitch: false, pitch: 0),
      'Pitch follows speed',
    );
    expect(
      playbackTempoSummary(id, speed: 0.75, keepPitch: true, pitch: 1),
      '0,75x, +1 semiton',
    );
  });

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('$style sheet shows the saved values and resets them', (
      tester,
    ) async {
      final container = await _openSheet(
        tester,
        mornye: mornye,
        settings: const AppSettings(
          playbackSpeed: 1.25,
          playbackKeepPitch: false,
          playbackPitch: 2,
        ),
      );
      expect(find.text('Speed and pitch'), findsOneWidget);
      expect(_value('1.25x'), findsOneWidget);
      expect(_value('+2'), findsOneWidget);
      expect(_slider(tester, _speedSlider).value, 1.25);
      expect(_slider(tester, _pitchSlider).value, 2);
      // Few enough stops to read: 0.1x and one semitone apart.
      expect(_slider(tester, _speedSlider).divisions, 15);
      expect(_slider(tester, _pitchSlider).divisions, 24);
      expect(_keepPitch(tester).value, isFalse);
      expect(_reset(tester).onPressed, isNotNull);

      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      final settings = container.read(settingsProvider);
      expect(settings.playbackSpeed, 1);
      expect(settings.playbackKeepPitch, isTrue);
      expect(settings.playbackPitch, 0);
      expect(_value('1x'), findsOneWidget);
      expect(_value('0'), findsOneWidget);
      expect(_keepPitch(tester).value, isTrue);
      expect(_reset(tester).onPressed, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style speed slider previews live and saves on release', (
      tester,
    ) async {
      final container = await _openSheet(tester, mornye: mornye);
      expect(_reset(tester).onPressed, isNull);
      await _drag(
        tester,
        _speedSlider,
        0.8,
        whileDragging: () {
          expect(container.read(settingsProvider).playbackSpeed, 1);
          expect(playbackSpeed.value, greaterThan(1.4));
        },
      );
      final saved = container.read(settingsProvider).playbackSpeed;
      expect(saved, greaterThan(1.4));
      expect(saved * 10, closeTo((saved * 10).roundToDouble(), 1e-9));
      expect(playbackSpeed.value, saved);
      expect(_reset(tester).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style pitch slider previews live and saves on release', (
      tester,
    ) async {
      final container = await _openSheet(
        tester,
        mornye: mornye,
        settings: const AppSettings(playbackKeepPitch: false),
      );
      await _drag(
        tester,
        _pitchSlider,
        0.2,
        whileDragging: () {
          expect(container.read(settingsProvider).playbackPitch, 0);
          expect(playbackPitch.value.semitones, lessThan(-5));
          expect(playbackPitch.value.followsRate, isTrue);
        },
      );
      final saved = container.read(settingsProvider).playbackPitch;
      expect(saved, lessThan(-5));
      expect(saved, saved.roundToDouble());
      expect(
        _value(
          playbackPitchLabel(lookupAppLocalizations(const Locale('en')), saved),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style quick choices and Keep pitch save at once', (
      tester,
    ) async {
      final container = await _openSheet(tester, mornye: mornye);
      await tester.tap(_choice('1.5x'));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).playbackSpeed, 1.5);

      await tester.tap(find.text('Keep pitch'));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).playbackKeepPitch, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style sheet disables what the output cannot do', (
      tester,
    ) async {
      final container = await _openSheet(
        tester,
        mornye: mornye,
        settings: const AppSettings(playbackSpeed: 1.25),
      );
      final l10n = AppLocalizations.of(
        tester.element(find.byKey(_speedSlider)),
      );
      expect(find.text(l10n.playbackTempoSpeedOnly), findsNothing);
      expect(find.text(l10n.playbackTempoUnavailable), findsNothing);

      playbackTempoSupport.value = PlaybackTempoSupport.speedOnly;
      await tester.pumpAndSettle();
      expect(find.text(l10n.playbackTempoSpeedOnly), findsOneWidget);
      expect(_slider(tester, _speedSlider).onChanged, isNotNull);
      expect(_slider(tester, _pitchSlider).onChanged, isNull);
      expect(_keepPitch(tester).enabled, isFalse);
      expect(_reset(tester).onPressed, isNotNull);

      playbackTempoSupport.value = PlaybackTempoSupport.none;
      await tester.pumpAndSettle();
      expect(find.text(l10n.playbackTempoUnavailable), findsOneWidget);
      expect(find.text(l10n.playbackTempoSpeedOnly), findsNothing);
      expect(_slider(tester, _speedSlider).onChanged, isNull);
      expect(_slider(tester, _pitchSlider).onChanged, isNull);
      expect(_keepPitch(tester).enabled, isFalse);
      expect(_reset(tester).onPressed, isNull);
      // The quick choices show their disabled style and ignore taps.
      expect(
        tester
            .widget<SettingsSegmentedChoice<double>>(
              find.byType(SettingsSegmentedChoice<double>),
            )
            .enabled,
        isFalse,
      );
      await tester.tap(find.text('1.5x').first, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).playbackSpeed, 1.25);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style Playback settings row opens the sheet', (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          initialSettingsProvider.overrideWithValue(
            const AppSettings(playbackSpeed: 1.25, playbackPitch: 2),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: _theme(mornye),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const PlaybackSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byWidgetPredicate(
        (widget) => widget is SettingsItem && widget.title == 'Speed and pitch',
      );
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<SettingsItem>(row).subtitle, '1.25x, +2 semitones');
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byKey(_speedSlider), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('settings search finds Speed and pitch', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    for (final query in ['speed', 'pitch', 'tempo', 'semitone']) {
      expect(
        SettingsSearchCatalog(l10n).playback.any(
          (entry) =>
              entry.title == l10n.playbackTempoTitle &&
              entry.matches(SettingsSearchQuery(query)),
        ),
        isTrue,
        reason: query,
      );
    }
  });
}
