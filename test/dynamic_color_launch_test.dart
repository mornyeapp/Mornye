import 'dart:async';
import 'dart:typed_data';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/theme/dynamic_color_wrapper.dart';

class _ThemeReader extends StatelessWidget {
  const _ThemeReader(this.builds);

  final List<ThemeData> builds;

  @override
  Widget build(BuildContext context) {
    builds.add(Theme.of(context));
    return const SizedBox();
  }
}

// A wallpaper palette as Android sends it: five tonal palettes, 13 tones each.
final _primary = TonalPalette.of(340, 48);
final _secondary = TonalPalette.of(340, 16);
final _palette = Int32List.fromList([
  ..._primary.asList,
  ..._secondary.asList,
  ...TonalPalette.of(20, 24).asList,
  ...TonalPalette.of(340, 4).asList,
  ...TonalPalette.of(340, 8).asList,
]);
// The light scheme takes its primary and secondary from tone 40.
final _palettePrimary = Color(_primary.get(40));

/// Answers the dynamic color channel as Android 12+ does, or as a platform
/// without dynamic colors; counts the requests.
class _SystemColors {
  _SystemColors(WidgetTester tester, {this.palette = true}) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(DynamicColorPlugin.channel, (call) {
      requests.add(call.method);
      if (!palette || call.method != DynamicColorPlugin.methodName) {
        return Future.value();
      }
      return (gate?.future ?? Future.value()).then((_) => _palette);
    });
    addTearDown(
      () =>
          messenger.setMockMethodCallHandler(DynamicColorPlugin.channel, null),
    );
  }

  final bool palette;
  final requests = <String>[];
  Completer<void>? gate;
}

class _Launch {
  final builds = <ThemeData>[];
  int themeBuilds = 0;
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, {DynamicColors? colors}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [
        initialThemeSettingsProvider.overrideWithValue(
          loadBootstrapThemeSettings(prefs),
        ),
        initialDynamicColorsProvider.overrideWithValue(colors),
      ],
    );
    addTearDown(container.dispose);
    final reader = _ThemeReader(builds);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: DynamicColorWrapper(
          builder: (light, dark, mode) {
            themeBuilds++;
            // As MornyeApp animates theme changes.
            return MaterialApp(
              theme: light,
              darkTheme: dark,
              themeMode: mode,
              themeAnimationDuration: const Duration(milliseconds: 300),
              themeAnimationCurve: Curves.easeInOut,
              home: reader,
            );
          },
        ),
      ),
    );
  }

  /// Pumps frames until none is scheduled; returns how many it pumped.
  Future<int> settleFrames(WidgetTester tester) async {
    var frames = 0;
    while (tester.binding.hasScheduledFrame && frames < 100) {
      await tester.pump(const Duration(milliseconds: 16));
      frames++;
    }
    return frames;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a launch answer builds the first frame with the palette', (
    tester,
  ) async {
    final system = _SystemColors(tester);
    final colors = DynamicColors.request();
    await colors.settle(const Duration(milliseconds: 100));
    expect(colors.isSettled, isTrue);

    final launch = _Launch();
    await launch.pump(tester, colors: colors);
    expect(launch.builds.single.colorScheme.primary, _palettePrimary);
    expect(
      launch.builds.single.colorScheme.secondary,
      Color(_secondary.get(40)),
    );

    // Before: the seed first, then 20 theme reader builds over 21 frames
    // while the palette faded in.
    expect(await launch.settleFrames(tester), lessThanOrEqualTo(1));
    expect(launch.builds, hasLength(1));
    expect(launch.themeBuilds, 1);
    expect(system.requests, [DynamicColorPlugin.methodName]);
  });

  testWidgets('the theme does not rebuild or fade while the font loads', (
    tester,
  ) async {
    final system = _SystemColors(tester, palette: false);
    final launch = _Launch();
    await launch.pump(tester);
    await launch.settleFrames(tester);

    // Before: the font provider's first answer rebuilt an equal theme and
    // ran the 300 ms fade (20 reader builds).
    expect(launch.builds, hasLength(1));
    expect(launch.themeBuilds, 1);
    expect(system.requests, [
      DynamicColorPlugin.methodName,
      DynamicColorPlugin.accentColorMethodName,
    ]);
  });

  testWidgets('a late answer still applies the palette with the fade', (
    tester,
  ) async {
    final system = _SystemColors(tester)..gate = Completer<void>();
    final colors = DynamicColors.request();
    final settling = colors.settle(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await settling;
    expect(colors.isSettled, isFalse);

    final launch = _Launch();
    await launch.pump(tester, colors: colors);
    final seed = launch.builds.single.colorScheme.primary;
    expect(seed, isNot(_palettePrimary));

    system.gate!.complete();
    await tester.pump();
    expect(await launch.settleFrames(tester), greaterThan(10));
    expect(launch.builds.last.colorScheme.primary, _palettePrimary);
    expect(launch.themeBuilds, 2);
    // The theme reuses the launch request instead of asking again.
    expect(system.requests, [DynamicColorPlugin.methodName]);
  });

  testWidgets('without a launch request the theme asks, as before', (
    tester,
  ) async {
    final system = _SystemColors(tester);
    final launch = _Launch();
    await launch.pump(tester);
    expect(launch.builds.single.colorScheme.primary, isNot(_palettePrimary));
    await launch.settleFrames(tester);
    expect(launch.builds.last.colorScheme.primary, _palettePrimary);
    expect(system.requests, [DynamicColorPlugin.methodName]);
  });

  testWidgets('theme changes after launch still fade', (tester) async {
    _SystemColors(tester);
    final colors = DynamicColors.request();
    await colors.settle(const Duration(milliseconds: 100));
    final launch = _Launch();
    await launch.pump(tester, colors: colors);
    await launch.settleFrames(tester);

    await launch.container
        .read(themeProvider.notifier)
        .setUseDynamicColor(false);
    await tester.pump();
    expect(await launch.settleFrames(tester), greaterThan(10));
    expect(launch.builds.length, greaterThan(10));
    expect(
      launch.builds.last.colorScheme.primary,
      ColorScheme.fromSeed(seedColor: const Color(kDefaultSeedColor)).primary,
    );
  });
}
