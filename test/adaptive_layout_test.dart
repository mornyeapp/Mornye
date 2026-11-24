import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/desktop/desktop_window.dart';

void main() {
  group('adaptive navigation', () {
    test('keeps phone and tablet widths on reachable bottom navigation', () {
      expect(useNavigationRailForWidth(390), isFalse);
      expect(useNavigationRailForWidth(1032), isFalse);
      expect(useNavigationRailForWidth(1366), isFalse);
    });

    test('reserves the navigation rail for desktop-width windows', () {
      expect(useNavigationRailForWidth(navigationRailBreakpoint - 1), isFalse);
      expect(useNavigationRailForWidth(navigationRailBreakpoint), isTrue);
    });
  });

  group('adaptive navigation (Material)', () {
    test('switches to the rail at the expanded window class', () {
      expect(useMaterialNavigationRailForWidth(390), isFalse);
      expect(useMaterialNavigationRailForWidth(683), isFalse);
      expect(
        useMaterialNavigationRailForWidth(expandedLayoutBreakpoint),
        isTrue,
      );
    });
  });

  group('wide content', () {
    test('fills compact widths and centers at the reading width', () {
      expect(wideInsetForWidth(640), 0);
      expect(wideInsetForWidth(defaultWideContentMaxWidth), 0);
      expect(wideInsetForWidth(1040), 100);
    });

    test('caps content at the reading width', () {
      expect(adaptiveContentMaxWidth(600), 600);
      expect(adaptiveContentMaxWidth(1366), defaultWideContentMaxWidth);
    });
  });

  group('adaptive UI scale', () {
    test('keeps phone density unchanged', () {
      expect(adaptiveUiScaleForSize(const Size(430, 932)), 1);
    });

    test('enlarges compact and large tablet touch surfaces', () {
      expect(adaptiveUiScaleForSize(const Size(700, 1000)), 1.1);
      expect(adaptiveUiScaleForSize(const Size(1024, 1366)), 1.2);
      expect(adaptiveUiScaleForSize(const Size(1366, 1024)), 1.2);
    });

    test('keeps desktop-width windows at native density', () {
      expect(adaptiveUiScaleForSize(const Size(1440, 900)), 1);
    });

    testWidgets('reflows the tablet viewport and preserves touch mapping', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(2048, 2732);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      Size? innerSize;
      var taps = 0;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData.fromView(tester.view),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: AdaptiveUiScaler(
              child: Builder(
                builder: (context) {
                  innerSize = MediaQuery.sizeOf(context);
                  return Align(
                    alignment: Alignment.topLeft,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => taps++,
                      child: const SizedBox.square(dimension: 100),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );

      expect(innerSize!.width, closeTo(1024 / 1.2, 0.01));
      expect(innerSize!.height, closeTo(1366 / 1.2, 0.01));
      await tester.tapAt(const Offset(110, 110));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('applies the Interface size on phones and keeps app state', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      Size? innerSize;
      double? innerScale;
      final counterKey = GlobalKey<_CounterState>();
      Widget app(double userScale) => MediaQuery(
        data: MediaQueryData.fromView(tester.view),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AdaptiveUiScaler(
            userScale: userScale,
            child: Builder(
              builder: (context) {
                innerSize = MediaQuery.sizeOf(context);
                innerScale = AdaptiveUiScale.of(context);
                return _Counter(key: counterKey);
              },
            ),
          ),
        ),
      );

      await tester.pumpWidget(app(1));
      expect(innerSize, const Size(360, 780));
      expect(innerScale, 1);
      expect(find.byType(FittedBox), findsNothing);
      counterKey.currentState!.increment();

      await tester.pumpWidget(app(0.9));
      expect(innerSize!.width, closeTo(400, 0.01));
      expect(innerSize!.height, closeTo(780 / 0.9, 0.01));
      expect(innerScale, 0.9);
      expect(counterKey.currentState!.count, 1);

      await tester.pumpWidget(app(1));
      expect(innerSize, const Size(360, 780));
      expect(counterKey.currentState!.count, 1);
    });

    testWidgets('keeps the macOS title bar row at its native size', (
      tester,
    ) async {
      late double height;
      late double controlsWidth;
      await tester.pumpWidget(
        AdaptiveUiScale(
          scale: 0.8,
          child: Builder(
            builder: (context) {
              height = desktopTitleBarHeightFor(context);
              controlsWidth = desktopWindowControlsWidthFor(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(height * 0.8, closeTo(desktopTitleBarHeight, 0.001));
      expect(controlsWidth * 0.8, closeTo(desktopWindowControlsWidth, 0.001));
    });
  });
}

class _Counter extends StatefulWidget {
  const _Counter({super.key});

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int count = 0;

  void increment() => setState(() => count++);

  @override
  Widget build(BuildContext context) => Text('$count');
}
