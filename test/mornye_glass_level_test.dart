import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show AdaptiveGlass, GlassBackdropGroup, GlassBodyMode, LiquidGlassSettings;
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/extension_repo_card.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_liquid_backdrop.dart';
import 'package:mornye/widgets/mornye_selection_pill.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();

  @override
  void setForceBackdropBlur(bool enabled) {
    state = state.copyWith(forceBackdropBlur: enabled);
  }
}

MornyeGlassLevel _levelFor({
  required bool lowEnd,
  required bool blur,
  required bool liquidCapable,
}) {
  final container = ProviderContainer(
    overrides: [
      lowEndDeviceProvider.overrideWithValue(lowEnd),
      // Device default or the user's "always use blur effects" override.
      backdropBlurEnabledProvider.overrideWithValue(blur),
      deviceSupportsLiquidGlassProvider.overrideWithValue(liquidCapable),
    ],
  );
  addTearDown(container.dispose);
  return container.read(mornyeGlassLevelProvider);
}

void main() {
  for (final brightness in Brightness.values) {
    for (final reduceMotion in [false, true]) {
      testWidgets(
        'glass override preserves accessibility ($brightness, motion: $reduceMotion)',
        (tester) async {
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              FakeAccessibilityFeatures(
                highContrast: true,
                disableAnimations: reduceMotion,
              );
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                settingsProvider.overrideWith(_Settings.new),
                // A capable GPU must not implicitly override contrast.
                deviceSupportsBackdropBlurProvider.overrideWithValue(true),
              ],
              child: MaterialApp(
                theme: MornyeTheme.build(brightness, glassClarity: 1),
                home: Scaffold(
                  body: Column(
                    children: [
                      const MornyeGlass.navigation(
                        blurEnabled: true,
                        child: SizedBox(width: 200, height: 50),
                      ),
                      MornyeSegmentedControl(
                        labels: const ['One', 'Two'],
                        selectedIndex: 0,
                        onChanged: (_) {},
                      ),
                      MornyeTabBar(
                        destinations: const [
                          NavigationDestination(
                            icon: Icon(Icons.home),
                            label: 'Home',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.music_note),
                            label: 'Library',
                          ),
                        ],
                        selectedIndex: 0,
                        onSelected: (_) {},
                        blurEnabled: true,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          final context = tester.element(find.byType(MornyeTabBar));
          final container = ProviderScope.containerOf(context);
          // Turn the override on and off while the system request stays on.
          for (final forceBlur in [false, true, false]) {
            container
                .read(settingsProvider.notifier)
                .setForceBackdropBlur(forceBlur);
            await tester.pumpAndSettle();
            expect(
              find.byType(BackdropFilter),
              findsNWidgets(forceBlur ? 3 : 0),
            );
            final pills = tester.widgetList<MornyeSelectionPill>(
              find.byType(MornyeSelectionPill),
            );
            expect(
              pills.every((pill) => pill.contrastBlocked == !forceBlur),
              isTrue,
            );
            expect(pills.last.liquidInteraction, forceBlur && !reduceMotion);
            expect(MediaQuery.highContrastOf(context), isTrue);
            expect(MediaQuery.disableAnimationsOf(context), reduceMotion);
            expect(
              MornyeTabBar.usesLiquidGlass(
                context,
                blurEnabled: true,
                liquidGlass: true,
                contrastBlocked: container.read(
                  mornyeGlassContrastBlockedProvider(true),
                ),
              ),
              forceBlur && !reduceMotion,
            );
          }
          // A live system-contrast change restores normal glass automatically.
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              FakeAccessibilityFeatures(disableAnimations: reduceMotion);
          await tester.pumpAndSettle();
          expect(find.byType(BackdropFilter), findsNWidgets(3));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  test('runtime tiers map to Mornye glass levels', () {
    // Low tier: arm32-only or low-RAM Android.
    expect(
      _levelFor(lowEnd: true, blur: false, liquidCapable: false),
      MornyeGlassLevel.flat,
    );
    // Standard Android: frosted blur without shader passes.
    expect(
      _levelFor(lowEnd: false, blur: false, liquidCapable: false),
      MornyeGlassLevel.frosted,
    );
    // iOS runs the standard tier but keeps the full material.
    expect(
      _levelFor(lowEnd: false, blur: false, liquidCapable: true),
      MornyeGlassLevel.liquid,
    );
    // High-tier Android.
    expect(
      _levelFor(lowEnd: false, blur: true, liquidCapable: true),
      MornyeGlassLevel.liquid,
    );
    // "Always use blur effects" restores the full material on any tier.
    for (final lowEnd in [true, false]) {
      expect(
        _levelFor(lowEnd: lowEnd, blur: true, liquidCapable: false),
        MornyeGlassLevel.liquid,
      );
    }
  });

  testWidgets('frosted level keeps blur but drops every shader surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceSupportsLiquidGlassProvider.overrideWithValue(false),
          backdropBlurEnabledProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: Scaffold(
            body: Column(
              children: [
                const MornyeGlass.navigation(
                  blurEnabled: true,
                  child: SizedBox(width: 200, height: 50),
                ),
                MornyeSegmentedControl(
                  labels: const ['One', 'Two'],
                  selectedIndex: 0,
                  onChanged: (_) {},
                ),
                AppSwitch(value: true, onChanged: (_) {}),
                Consumer(
                  builder: (context, ref, _) => MornyeTabBar(
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.home),
                        label: 'Home',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.music_note),
                        label: 'Library',
                      ),
                    ],
                    selectedIndex: 0,
                    onSelected: (_) {},
                    blurEnabled: ref.watch(mornyeBlurEnabledProvider),
                    liquidGlass: ref.watch(mornyeLiquidGlassProvider),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(MornyeSelectionPill), findsNWidgets(2));
    expect(find.byType(ImageFiltered), findsNothing);
    // The frosted material still samples the page behind it.
    expect(find.byType(BackdropFilter), findsWidgets);
    expect(find.text('Library'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clear glass reduces blur and mid-range glass caps its radius', (
    tester,
  ) async {
    Future<ui.ImageFilter?> filterFor(double clarity, bool liquid) async {
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            mornyeGlassLevelProvider.overrideWithValue(
              liquid ? MornyeGlassLevel.liquid : MornyeGlassLevel.frosted,
            ),
          ],
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.light, glassClarity: clarity),
            home: const MornyeGlass.navigation(
              blurEnabled: true,
              child: SizedBox(width: 200, height: 50),
            ),
          ),
        ),
      );
      final filters = tester.widgetList<BackdropFilter>(
        find.byType(BackdropFilter),
      );
      return filters.isEmpty ? null : filters.single.filter;
    }

    expect(await filterFor(0, false), isNull);
    expect(await filterFor(0.1, false), isNull);
    expect(await filterFor(0.25, false), isNull);
    expect(await filterFor(0.5, false), isNull);
    expect(await filterFor(0.1, true), isNull);
    expect(await filterFor(0.2, true), isNull);
    expect(
      await filterFor(0.25, true),
      ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
    );
    expect(
      await filterFor(kDefaultMornyeGlassClarity, true),
      ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
    );
    expect(
      await filterFor(1, false),
      ui.ImageFilter.blur(sigmaX: 3, sigmaY: 3),
    );
    expect(await filterFor(1, true), ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2));
  });

  for (final clarity in [0.0, 0.5]) {
    testWidgets('liquid tab and segment pills follow clarity ($clarity)', (
      tester,
    ) async {
      late BuildContext context;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.dark, glassClarity: clarity),
            home: Scaffold(
              body: Builder(
                builder: (builderContext) {
                  context = builderContext;
                  return Column(
                    children: [
                      MornyeSegmentedControl(
                        labels: const ['One', 'Two'],
                        selectedIndex: 0,
                        onChanged: (_) {},
                      ),
                      MornyeTabBar(
                        destinations: const [
                          NavigationDestination(
                            icon: Icon(Icons.home),
                            label: 'Home',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.music_note),
                            label: 'Library',
                          ),
                        ],
                        selectedIndex: 0,
                        onSelected: (_) {},
                        blurEnabled: true,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final liquid = clarity > 0;
      // Overlays aligned with the bar share this decision.
      expect(
        MornyeTabBar.usesLiquidGlass(
          context,
          blurEnabled: true,
          liquidGlass: true,
          contrastBlocked: false,
        ),
        liquid,
      );
      // Every tier draws just one copy of each label and a painted pill.
      expect(find.byType(MornyeSelectionPill), findsNWidgets(2));
      expect(find.byType(BackdropFilter), findsNWidgets(liquid ? 2 : 0));
      expect(find.text('Two'), findsOneWidget);
      expect(find.text('Library'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('plain-page panels keep the glass tint without a backdrop pass', (
    tester,
  ) async {
    Color? tintOf(Finder panel) {
      final decorated = tester
          .widgetList<DecoratedBox>(
            find.descendant(of: panel, matching: find.byType(DecoratedBox)),
          )
          .map((box) => box.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((decoration) => decoration.color != null);
      return decorated.color;
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: Scaffold(
            body: Column(
              children: [
                const MornyeGlass.navigation(
                  key: ValueKey('sampled'),
                  blurEnabled: true,
                  child: SizedBox(width: 200, height: 40),
                ),
                const MornyeGlass.navigation(
                  key: ValueKey('plain-page'),
                  blurEnabled: true,
                  samplesBackdrop: false,
                  child: SizedBox(width: 200, height: 40),
                ),
                const ExtensionRepoCard(
                  child: SizedBox(width: 200, height: 40),
                ),
                const MornyeGlassPanel.overlay(
                  samplesBackdrop: false,
                  child: SizedBox(width: 200, height: 40),
                ),
                MornyeSegmentedControl(
                  labels: const ['One', 'Two'],
                  selectedIndex: 0,
                  onChanged: (_) {},
                  samplesBackdrop: false,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final sampled = find.byKey(const ValueKey('sampled'));
    final plain = find.byKey(const ValueKey('plain-page'));
    expect(
      find.descendant(of: sampled, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: plain, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
    for (final type in [
      ExtensionRepoCard,
      MornyeGlassPanel,
      MornyeSegmentedControl,
    ]) {
      expect(
        find.descendant(
          of: find.byType(type),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
      );
    }
    // Same translucent material, so the page looks identical behind it.
    expect(tintOf(plain), tintOf(sampled));
    expect(tintOf(plain)!.a, lessThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('full-quality glass has one blur; switches have none', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: Scaffold(
            body: Column(
              children: [
                const MornyeGlass.navigation(
                  blurEnabled: true,
                  child: SizedBox(width: 200, height: 50),
                ),
                AppSwitch(value: true, onChanged: (_) {}),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AppSwitch),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'the default clarity is the iOS 27 material (${brightness.name})',
      (tester) async {
        MornyeGlass.debugShaderFilterSupport = true;
        addTearDown(() => MornyeGlass.debugShaderFilterSupport = null);
        Future<LiquidGlassSettings> lensAt(
          double clarity, {
          Color? tintColor,
        }) async {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                mornyeGlassLevelProvider.overrideWithValue(
                  MornyeGlassLevel.liquid,
                ),
              ],
              child: MaterialApp(
                theme: MornyeTheme.build(brightness, glassClarity: clarity),
                home: Scaffold(
                  body: Center(
                    child: MornyeGlass.navigation(
                      blurEnabled: true,
                      tintColor: tintColor,
                      child: const SizedBox(width: 80, height: 40),
                    ),
                  ),
                ),
              ),
            ),
          );
          // A changed theme is animated in.
          await tester.pumpAndSettle();
          return tester
              .widget<AdaptiveGlass>(find.byType(AdaptiveGlass))
              .settings;
        }

        // Mornye's labels on dark glass stay white, so its dark glass pulls
        // a bright backdrop down further. Nothing else leaves the preset.
        final material = brightness == Brightness.dark
            ? LiquidGlassSettings.ios27Dark.copyWith(bodyShade: 0.55)
            : LiquidGlassSettings.ios27Light;
        expect(MornyeLiquidBackdrop.material(brightness), material);
        // Only the shadow differs: the app draws the material's own.
        expect(
          await lensAt(kDefaultMornyeGlassClarity),
          material.copyWith(shadow: const []),
        );

        final tinted = await lensAt(0.4);
        expect(tinted.glassColor.a, greaterThan(material.glassColor.a));
        expect(tinted.blur, greaterThan(material.blur));
        expect(tinted.frost, material.frost);
        expect(tinted.bodyMode, GlassBodyMode.clear);

        final thinned = await lensAt(1);
        // The color is what keeps labels readable, so only the frost thins.
        expect(thinned.glassColor, material.glassColor);
        expect(thinned.frost, lessThan(material.frost));
        expect(thinned.blur, material.blur);
        expect(thinned.bodyMode, material.bodyMode);

        // A neutral tint is only density, which the material sets itself. A
        // colored one is a meaning, such as a state, and stays.
        final neutral = await lensAt(
          kDefaultMornyeGlassClarity,
          tintColor: Colors.black,
        );
        expect(neutral.glassColor, material.glassColor);
        final colored = await lensAt(
          kDefaultMornyeGlassClarity,
          tintColor: const Color(0xffff3b30),
        );
        expect(colored.bodyMode, GlassBodyMode.clear);
        expect(colored.glassColor.r, greaterThan(colored.glassColor.b + 0.2));
        expect(colored.glassColor.a, greaterThan(0.4));
        expect(colored.frost, material.frost);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('lenses share a backdrop read only inside one group', (
    tester,
  ) async {
    MornyeGlass.debugShaderFilterSupport = true;
    addTearDown(() => MornyeGlass.debugShaderFilterSupport = null);
    Widget glass(String key, {Widget? child}) => MornyeGlass.navigation(
      key: ValueKey(key),
      blurEnabled: true,
      child: child ?? const SizedBox(width: 80, height: 40),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mornyeGlassLevelProvider.overrideWithValue(MornyeGlassLevel.liquid),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: Scaffold(
            body: Column(
              children: [
                // Overlapping standalone glass must not share a backdrop.
                Stack(children: [glass('back'), glass('front')]),
                glass('outer', child: glass('inner')),
                MornyeGlassPanel.overlay(child: const SizedBox(height: 40)),
                MornyeSegmentedControl(
                  labels: const ['One', 'Two'],
                  selectedIndex: 0,
                  onChanged: (_) {},
                ),
                GlassBackdropGroup(
                  child: Row(children: [glass('chip-a'), glass('chip-b')]),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final lenses = find.byType(AdaptiveGlass).evaluate().toList();
    // The nested glass paints on its parent's surface without a lens.
    expect(lenses, hasLength(7));
    BackdropKey? keyOf(String glass) => GlassBackdropGroup.keyOf(
      tester.element(
        find.descendant(
          of: find.byKey(ValueKey(glass)),
          matching: find.byType(AdaptiveGlass),
        ),
      ),
    );
    expect(keyOf('chip-a'), isNotNull);
    expect(keyOf('chip-a'), same(keyOf('chip-b')));
    // Glass outside a group reads alone, so overlapping glass sees glass.
    expect(keyOf('back'), isNull);
    expect(keyOf('front'), isNull);
    expect(
      lenses.where((lens) => GlassBackdropGroup.keyOf(lens) != null),
      hasLength(2),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a lens under an interface scale measures the window', (
    tester,
  ) async {
    MornyeGlass.debugShaderFilterSupport = true;
    addTearDown(() => MornyeGlass.debugShaderFilterSupport = null);
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(800, 1600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    MediaQueryData? content;

    Future<void> pumpAt(double scale) => tester.pumpWidget(
      ProviderScope(
        overrides: [
          mornyeGlassLevelProvider.overrideWithValue(MornyeGlassLevel.liquid),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          builder: (context, child) =>
              AdaptiveUiScaler(userScale: scale, child: child!),
          home: Scaffold(
            body: MornyeGlass.navigation(
              blurEnabled: true,
              child: Builder(
                builder: (context) {
                  content = MediaQuery.of(context);
                  return const SizedBox(width: 80, height: 40);
                },
              ),
            ),
          ),
        ),
      ),
    );

    for (final scale in [0.8, 1.0, 1.3]) {
      await pumpAt(scale);
      // The lens turns its place in the window into pixels with these two.
      final glass = find.byType(AdaptiveGlass);
      final lens = MediaQuery.of(tester.element(glass));
      expect(lens.size.width, closeTo(400, 0.001), reason: '$scale');
      expect(lens.size.height, closeTo(800, 0.001), reason: '$scale');
      expect(lens.devicePixelRatio, closeTo(2, 0.001), reason: '$scale');
      // It is laid out in window pixels, and nothing scales it on the way
      // to the screen: its shaders assume as much.
      final box = tester.renderObject<RenderBox>(glass);
      expect(box.size.width, closeTo(80 * scale, 0.001), reason: '$scale');
      expect(
        box.getTransformTo(null).getMaxScaleOnAxis(),
        closeTo(1, 0.000001),
        reason: '$scale',
      );
      // What sits on the glass still lays out in the scaled viewport, and
      // covers the glass.
      expect(content!.size.width, closeTo(400 / scale, 0.001));
      expect(content!.devicePixelRatio, closeTo(2 * scale, 0.001));
      final onGlass = find.byWidgetPredicate(
        (widget) => widget is SizedBox && widget.width == 80,
      );
      expect(tester.getSize(onGlass), const Size(80, 40));
      final shown = tester.getRect(onGlass);
      final surface = tester.getRect(glass);
      expect(shown.left, closeTo(surface.left, 0.001), reason: '$scale');
      expect(shown.width, closeTo(surface.width, 0.001), reason: '$scale');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a lens under an interface scale keeps its build on a '
      'keyboard inset change', (tester) async {
    MornyeGlass.debugShaderFilterSupport = true;
    addTearDown(() => MornyeGlass.debugShaderFilterSupport = null);
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(800, 1600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    MediaQueryData? content;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mornyeGlassLevelProvider.overrideWithValue(MornyeGlassLevel.liquid),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          builder: (context, child) =>
              AdaptiveUiScaler(userScale: 0.9, child: child!),
          home: Scaffold(
            resizeToAvoidBottomInset: false,
            body: MornyeGlass.navigation(
              blurEnabled: true,
              child: Builder(
                builder: (context) {
                  content = MediaQuery.of(context);
                  return const SizedBox(width: 80, height: 40);
                },
              ),
            ),
          ),
        ),
      ),
    );
    final lens = tester.widget<AdaptiveGlass>(find.byType(AdaptiveGlass));
    expect(content!.viewInsets.bottom, 0);

    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    await tester.pump();

    // A lens rebuild repaints its glass.
    expect(
      tester.widget<AdaptiveGlass>(find.byType(AdaptiveGlass)),
      same(lens),
    );
    expect(content!.viewInsets.bottom, closeTo(300 / 0.9, 0.001));
    final window = MediaQuery.of(tester.element(find.byType(AdaptiveGlass)));
    expect(window.size.width, closeTo(400, 0.001));
    expect(window.devicePixelRatio, closeTo(2, 0.001));
    expect(tester.takeException(), isNull);
  });
}
