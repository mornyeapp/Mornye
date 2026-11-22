import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/equalizer_filter_text.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/providers/equalizer_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/equalizer_screen.dart';
import 'package:mornye/services/playback_equalizer.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _peak = EqualizerFilter(frequency: 1000, gain: 6, q: 1.4);
const _low = EqualizerFilter(
  type: EqualizerFilterType.lowShelf,
  frequency: 200,
  gain: -5,
  q: 0.707,
);
const _high = EqualizerFilter(
  type: EqualizerFilterType.highShelf,
  frequency: 4000,
  gain: 4,
  q: 0.707,
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    playbackEqualizer.value = const EqualizerSettings();
    playbackEqualizerError.value = null;
  });

  test('a filter has its gain where its kind puts it', () {
    expect(_peak.responseAt(1000), closeTo(6, 1e-9));
    expect(_peak.responseAt(40), closeTo(0, 0.05));
    expect(_peak.responseAt(18000), closeTo(0, 0.05));
    // The gain is halved (in dB) at the edges of the bandwidth 1 / Q.
    final edge = 1000 * (0.5 / 1.4 + math.sqrt(1 + 0.25 / (1.4 * 1.4)));
    expect(_peak.responseAt(edge), closeTo(3, 0.01));

    expect(_low.responseAt(20), closeTo(-5, 0.05));
    expect(_low.responseAt(200), closeTo(-2.5, 1e-9));
    expect(_low.responseAt(8000), closeTo(0, 0.01));
    expect(_high.responseAt(50), closeTo(0, 0.01));
    expect(_high.responseAt(4000), closeTo(2, 1e-9));
    expect(_high.responseAt(20000), closeTo(4, 0.2));

    expect(_peak.copyWith(enabled: false).responseAt(1000), 0);
    expect(_peak.copyWith(gain: 0).responseAt(1000), 0);
  });

  test('parametric settings play the filters, not the bands', () {
    final settings = const EqualizerSettings(enabled: true).copyWith(
      parametric: true,
      filters: [_peak, _low, _high.copyWith(enabled: false)],
      gains: [9, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      bass: 6,
    );
    // The bands and the tone controls wait for the way back.
    expect(settings.responseAt(1000), closeTo(6, 0.05));
    expect(settings.responseAt(31.25), closeTo(-5, 0.1));
    expect(settings.headroom, closeTo(6, 0.05));
    expect(settings.inputGain, closeTo(-6, 0.05));

    final native = settings.toNative();
    expect(native['gains'], List.filled(10, 0.0));
    expect((native['frequencies'] as List).length, 10);
    expect(native['inputGain'], closeTo(-6, 0.05));
    expect(native['filters'], [
      {'type': 'peak', 'frequency': 1000.0, 'gain': 6.0, 'q': 1.4},
      {'type': 'lowshelf', 'frequency': 200.0, 'gain': -5.0, 'q': 0.707},
    ]);

    final graphic = settings.copyWith(parametric: false);
    expect(graphic.toNative()['filters'], isNull);
    expect(graphic.responseAt(31.25), greaterThan(9));
    expect(graphic.filters, hasLength(3));
  });

  test('headroom finds a narrow peak between the grid points', () {
    final settings = const EqualizerSettings(enabled: true).copyWith(
      parametric: true,
      filters: [const EqualizerFilter(frequency: 1013, gain: 9, q: 20)],
    );
    expect(settings.headroom, closeTo(9, 1e-9));
  });

  test('settings survive saving, and bad filters are left out', () {
    final settings = const EqualizerSettings().copyWith(
      parametric: true,
      filters: [_peak, _low],
    );
    final restored = EqualizerSettings.fromJson(settings.toJson());
    expect(restored.parametric, isTrue);
    expect(restored.filters, [_peak, _low]);

    final old = EqualizerSettings.fromJson({'gains': List.filled(10, 0)});
    expect(old.parametric, isFalse);
    expect(old.filters, isEmpty);

    final messy = EqualizerSettings.fromJson({
      'gains': List.filled(10, 0),
      'parametric': true,
      'filters': [
        {'type': 'peak', 'frequency': 5, 'gain': 99, 'q': 0},
        {'type': 'notch', 'frequency': 500, 'gain': 1, 'q': 1},
        'nothing',
        {'frequency': 'x', 'gain': 1, 'q': 1},
        for (var i = 0; i < 30; i++)
          {'type': 'peak', 'frequency': 100.0 + i, 'gain': 1, 'q': 1},
      ],
    });
    expect(messy.filters, hasLength(EqualizerSettings.maxFilters));
    expect(messy.filters.first.frequency, 20);
    expect(messy.filters.first.gain, 24);
    expect(messy.filters.first.q, 0.1);
    // An unknown kind plays as a peak rather than being lost.
    expect(messy.filters[1].type, EqualizerFilterType.peak);
  });

  test('a preset carries its filters; a graphic one keeps them', () {
    final current = const EqualizerSettings(
      enabled: true,
      limiter: false,
    ).copyWith(parametric: true, filters: [_peak]);
    final graphic = current.withToneOf(EqualizerPreset.builtIn[1].settings);
    expect(graphic.parametric, isFalse);
    expect(graphic.filters, [_peak]);
    expect(graphic.limiter, isFalse);

    final parametric = graphic.withToneOf(
      const EqualizerSettings().copyWith(parametric: true, filters: [_low]),
    );
    expect(parametric.parametric, isTrue);
    expect(parametric.filters, [_low]);
  });

  group('filter list text', () {
    test('reads the usual lines', () {
      final text = EqualizerFilterText.parse(
        'Preamp: -6.2 dB\r\n'
        'Filter 1: ON PK Fc 105 Hz Gain -2.1 dB Q 0.70\r\n'
        'Filter 2: ON LSC Fc 80 Hz Gain 4 dB Q 0.71\n'
        'Filter 3: OFF HSC Fc 10000 Hz Gain -3,5 dB Q 0,5\n'
        'Filter 4: ON LS Fc 60 Hz Gain 2 dB\n'
        'Filter 5: ON LP Fc 18000 Hz\n'
        'Filter 6: ON None\n'
        'Filter 7: ON NO Fc 1000 Hz Gain 1 dB Q 1\n'
        '# a comment\n',
      );
      expect(text.preamp, -6.2);
      expect(text.skipped, 2);
      expect(text.filters, const [
        EqualizerFilter(frequency: 105, gain: -2.1, q: 0.7),
        EqualizerFilter(
          type: EqualizerFilterType.lowShelf,
          frequency: 80,
          gain: 4,
          q: 0.71,
        ),
        EqualizerFilter(
          type: EqualizerFilterType.highShelf,
          frequency: 10000,
          gain: -3.5,
          q: 0.5,
          enabled: false,
        ),
        EqualizerFilter(
          type: EqualizerFilterType.lowShelf,
          frequency: 60,
          gain: 2,
          q: EqualizerFilter.shelfQ,
        ),
      ]);
    });

    test('rejects text without a filter and keeps at most twenty', () {
      expect(
        () => EqualizerFilterText.parse('Preamp: -3 dB\nhello'),
        throwsFormatException,
      );
      final many = EqualizerFilterText.parse(
        [
          for (var i = 1; i <= 25; i++)
            'Filter $i: ON PK Fc ${100 * i} Hz Gain 1 dB Q 1',
        ].join('\n'),
      );
      expect(many.filters, hasLength(20));
      expect(many.skipped, 5);
      expect(many.preamp, isNull);
    });

    test('writes what it reads, with the gain that plays', () {
      final settings = const EqualizerSettings(enabled: true).copyWith(
        parametric: true,
        filters: [_peak, _low, _high.copyWith(enabled: false)],
      );
      final text = EqualizerFilterText.format(settings);
      expect(
        text,
        'Preamp: -6.0 dB\n'
        'Filter 1: ON PK Fc 1000 Hz Gain 6.0 dB Q 1.40\n'
        'Filter 2: ON LSC Fc 200 Hz Gain -5.0 dB Q 0.71\n'
        'Filter 3: OFF HSC Fc 4000 Hz Gain 4.0 dB Q 0.71\n',
      );
      final read = EqualizerFilterText.parse(text);
      expect(read.preamp, -6);
      expect(read.filters.map((filter) => filter.type), [
        EqualizerFilterType.peak,
        EqualizerFilterType.lowShelf,
        EqualizerFilterType.highShelf,
      ]);
      expect(read.filters.last.enabled, isFalse);
    });
  });

  test(
    'importing a filter list plays it with the list\'s own preamp',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(equalizerProvider.notifier);
      await notifier.ensureLoaded();
      notifier.update(const EqualizerSettings(enabled: true, preamp: 2));

      expect(
        notifier.importFile(
          'Preamp: -4 dB\n'
          'Filter 1: ON PK Fc 3000 Hz Gain 4 dB Q 2\n'
          'Filter 2: ON BP Fc 500 Hz Q 1\n',
        ),
        1,
      );
      var settings = container.read(equalizerProvider).settings;
      expect(settings.parametric, isTrue);
      expect(settings.enabled, isTrue);
      expect(settings.filters, [
        const EqualizerFilter(frequency: 3000, gain: 4, q: 2),
      ]);
      // The list's preamp is its headroom: none is taken twice.
      expect(settings.preamp, -4);
      expect(settings.autoHeadroom, isFalse);
      expect(settings.inputGain, -4);
      expect(playbackEqualizer.value.filters, settings.filters);
      expect(
        notifier.exportFilters(),
        startsWith('Preamp: -4.0 dB\nFilter 1: ON PK'),
      );

      // Without a preamp line the listener's own choices stay.
      notifier.update(settings.copyWith(autoHeadroom: true, preamp: 1));
      expect(notifier.importFile('Filter 1: ON PK Fc 60 Hz Gain 3 dB Q 1'), 0);
      settings = container.read(equalizerProvider).settings;
      expect(settings.preamp, 1);
      expect(settings.autoHeadroom, isTrue);

      expect(() => notifier.importFile('not a list'), throwsFormatException);
      // The app's own preset file still goes the old way.
      notifier.importFile(notifier.exportPreset('Mine'));
      expect(container.read(equalizerProvider).presets.single.name, 'Mine');
      expect(
        container.read(equalizerProvider).presets.single.settings.filters,
        settings.filters,
      );
    },
  );

  for (final mornye in [false, true]) {
    testWidgets('the page edits filters (Mornye=$mornye)', (tester) async {
      tester.view.physicalSize = const Size(420, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer();
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
            home: const EqualizerScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      EqualizerSettings settings() =>
          container.read(equalizerProvider).settings;

      expect(find.text('Bands'), findsOneWidget);
      expect(find.text('Bass'), findsOneWidget);
      // A Material segment lays its label out twice.
      await tester.tap(find.text('Parametric').first);
      await tester.pumpAndSettle();
      expect(settings().parametric, isTrue);
      expect(find.text('Filters'), findsOneWidget);
      expect(find.text('Bass'), findsNothing);
      expect(find.text('Treble'), findsNothing);
      expect(find.text('Balance'), findsOneWidget);
      expect(
        find.text('No filters yet. Add one, or import a filter list.'),
        findsOneWidget,
      );

      // Tests run as Android: the filters need the new engine there.
      expect(defaultTargetPlatform, TargetPlatform.android);
      expect(find.textContaining('new playback engine'), findsOneWidget);
      await tester.tap(find.text('Turn on'));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).media3Engine, isTrue);
      expect(find.textContaining('new playback engine'), findsNothing);

      await tester.tap(find.text('Add filter'));
      await tester.pumpAndSettle();
      expect(settings().filters, [const EqualizerFilter()]);
      expect(find.text('Filter 1'), findsOneWidget);
      await tester.tap(find.text('Low shelf').first);
      await tester.pumpAndSettle();
      expect(settings().filters.single.type, EqualizerFilterType.lowShelf);

      // An exact value is typed; the slider only gets near it.
      await tester.tap(find.byTooltip('Type the value: Frequency'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), '105,5');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(settings().filters.single.frequency, 105.5);
      await tester.tap(find.byTooltip('Type the value: Gain'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), '-99');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(settings().filters.single.gain, -24);
      expect(find.text('105.5 Hz'), findsWidgets);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Low shelf · −24.0 dB · Q 1.00'),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(EqualizerScreen),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is AppSwitch &&
                (widget.semanticLabel ?? '').startsWith('Filter 1'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(settings().filters.single.enabled, isFalse);

      await tester.tap(find.text('105.5 Hz'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove filter'));
      await tester.pumpAndSettle();
      expect(settings().filters, isEmpty);

      await tester.tap(find.text('Graphic').first);
      await tester.pumpAndSettle();
      expect(settings().parametric, isFalse);
      expect(find.text('Bass'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
