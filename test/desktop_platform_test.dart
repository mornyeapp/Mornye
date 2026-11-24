import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/app.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  tearDown(() {
    debugDesktopPlatformOverride = null;
    debugDefaultTargetPlatformOverride = null;
  });

  void simulateDesktop(TargetPlatform platform) {
    debugDesktopPlatformOverride = true;
    debugDefaultTargetPlatformOverride = platform;
  }

  test('tests see a mobile app unless they opt in', () {
    expect(isDesktopPlatform, isFalse);
    debugDesktopPlatformOverride = true;
    expect(isDesktopPlatform, isTrue);
  });

  group('default theme style', () {
    test('stays Material on mobile', () {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(defaultAppThemeStyle(), AppThemeStyle.material);
        expect(themeStyleFromString(null), AppThemeStyle.material);
      }
    });

    test('is Mornye on macOS and Material on Windows and Linux', () {
      simulateDesktop(TargetPlatform.macOS);
      expect(themeStyleFromString(null), AppThemeStyle.mornye);
      simulateDesktop(TargetPlatform.windows);
      expect(themeStyleFromString(null), AppThemeStyle.material);
      simulateDesktop(TargetPlatform.linux);
      expect(themeStyleFromString(null), AppThemeStyle.material);
    });

    test('applies only when no style is stored', () async {
      simulateDesktop(TargetPlatform.macOS);
      SharedPreferences.setMockInitialValues({});
      var prefs = await SharedPreferences.getInstance();
      expect(loadBootstrapThemeSettings(prefs).style, AppThemeStyle.mornye);

      SharedPreferences.setMockInitialValues({kThemeStyleKey: 'material'});
      prefs = await SharedPreferences.getInstance();
      expect(loadBootstrapThemeSettings(prefs).style, AppThemeStyle.material);
    });
  });

  test('desktop windows keep native density at tablet sizes', () {
    const tabletSize = Size(1024, 1366);
    expect(adaptiveUiScaleForSize(tabletSize), 1.2);
    debugDesktopPlatformOverride = true;
    expect(adaptiveUiScaleForSize(tabletSize), 1);
  });

  group('scroll behavior', () {
    Future<ScrollPhysics> physicsFor(WidgetTester tester) async {
      late ScrollPhysics physics;
      final behavior = appScrollBehavior(disableOverscrollEffects: false);
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            physics = behavior.getScrollPhysics(context);
            return const SizedBox.shrink();
          },
        ),
      );
      return physics;
    }

    testWidgets('bounces on mobile', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(await physicsFor(tester), isA<BouncingScrollPhysics>());
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('bounces on macOS', (tester) async {
      simulateDesktop(TargetPlatform.macOS);
      expect(await physicsFor(tester), isA<BouncingScrollPhysics>());
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('clamps with scrollbars on Windows and Linux', (tester) async {
      for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
        simulateDesktop(platform);
        expect(await physicsFor(tester), isA<ClampingScrollPhysics>());
        final behavior = appScrollBehavior(disableOverscrollEffects: false);
        expect(behavior, isA<MaterialScrollBehavior>());
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: ScrollConfiguration(
              behavior: behavior,
              child: ListView(children: const [SizedBox(height: 2000)]),
            ),
          ),
        );
        expect(find.byType(Scrollbar), findsOneWidget);
      }
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('desktop rows that scroll sideways show no scrollbar', (
      tester,
    ) async {
      for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
        simulateDesktop(platform);
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: ScrollConfiguration(
              behavior: appScrollBehavior(disableOverscrollEffects: false),
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: const [SizedBox(width: 4000)],
              ),
            ),
          ),
        );
        expect(find.byType(Scrollbar), findsNothing);
      }
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
