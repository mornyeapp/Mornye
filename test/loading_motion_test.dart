import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/decorative_phase.dart';
import 'package:mornye/widgets/loaded_sliver_fade_in.dart';

Widget _app(Widget child, {bool reduced = false}) => MaterialApp(
  theme: AppTheme.light(),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: Scaffold(body: child),
    ),
  ),
);

Widget _page({
  required bool loading,
  bool enabled = true,
  bool reduced = false,
  int build = 0,
}) => _app(
  CustomScrollView(
    slivers: [
      LoadedSliverFadeIn(
        key: const ValueKey('tracks'),
        loading: loading,
        enabled: enabled,
        sliver: SliverToBoxAdapter(
          child: SizedBox(
            height: 100,
            child: Text(loading ? 'skeleton' : 'loaded $build'),
          ),
        ),
      ),
    ],
  ),
  reduced: reduced,
);

double _sliverOpacity(WidgetTester tester) => tester
    .widget<SliverFadeTransition>(find.byType(SliverFadeTransition))
    .opacity
    .value;

void main() {
  tearDown(DecorativePhase.debugResetClock);

  group('LoadedSliverFadeIn', () {
    testWidgets('fades loaded content in once over the skeleton', (
      tester,
    ) async {
      await tester.pumpWidget(_page(loading: true));
      expect(_sliverOpacity(tester), 1);

      await tester.pumpWidget(_page(loading: false));
      final first = _sliverOpacity(tester);
      expect(first, greaterThan(0));
      expect(first, lessThan(1));

      await tester.pump(const Duration(milliseconds: 50));
      final mid = _sliverOpacity(tester);
      expect(mid, greaterThan(first));
      expect(mid, lessThan(1));

      await tester.pump(const Duration(milliseconds: 500));
      expect(_sliverOpacity(tester), 1);

      await tester.pumpWidget(_page(loading: false, build: 1));
      expect(_sliverOpacity(tester), 1);
      expect(find.text('loaded 1'), findsOneWidget);
    });

    testWidgets('content there on the first build does not fade', (
      tester,
    ) async {
      await tester.pumpWidget(_page(loading: false));
      expect(_sliverOpacity(tester), 1);
    });

    testWidgets('reduced motion and a disabled fade cut', (tester) async {
      await tester.pumpWidget(_page(loading: true, reduced: true));
      await tester.pumpWidget(_page(loading: false, reduced: true));
      expect(_sliverOpacity(tester), 1);

      await tester.pumpWidget(_page(loading: true, enabled: false));
      await tester.pumpWidget(_page(loading: false, enabled: false));
      expect(_sliverOpacity(tester), 1);
    });
  });

  group('StaggeredListItem', () {
    Iterable<double> itemOpacities(WidgetTester tester) => tester
        .widgetList<Opacity>(
          find.descendant(
            of: find.byType(StaggeredListItem),
            matching: find.byType(Opacity),
          ),
        )
        .map((opacity) => opacity.opacity);

    testWidgets('the first row shows on the first frame', (tester) async {
      await tester.pumpWidget(
        _app(
          ListView(
            children: [
              for (var i = 0; i < 3; i++)
                StaggeredListItem(
                  index: i,
                  child: SizedBox(height: 40, child: Text('row $i')),
                ),
            ],
          ),
        ),
      );
      final opacities = itemOpacities(tester).toList();
      expect(opacities.first, greaterThan(0));
      await tester.pump(const Duration(seconds: 1));
      expect(itemOpacities(tester), everyElement(1));
    });

    testWidgets('shelves built while the page scrolls do not replay it', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _app(
          ListView.builder(
            controller: controller,
            itemExtent: 200,
            itemCount: 30,
            itemBuilder: (context, shelf) => ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: 6,
              itemBuilder: (context, index) => StaggeredListItem(
                index: index,
                child: SizedBox(width: 120, child: Text('$shelf-$index')),
              ),
            ),
          ),
        ),
      );
      expect(itemOpacities(tester), isNotEmpty);
      await tester.pump(const Duration(seconds: 1));

      controller.jumpTo(1200);
      await tester.pump();
      expect(find.text('7-0'), findsOneWidget);
      expect(itemOpacities(tester), everyElement(1));
    });

    testWidgets('reduced motion shows rows at once', (tester) async {
      await tester.pumpWidget(
        _app(
          const StaggeredListItem(index: 0, child: Text('row')),
          reduced: true,
        ),
      );
      expect(itemOpacities(tester), isEmpty);
    });
  });

  group('ShimmerLoading', () {
    const box = SizedBox(
      width: 200,
      height: 20,
      child: ColoredBox(color: Colors.grey),
    );

    testWidgets('sweeps at most 30 times a second', (tester) async {
      await tester.pumpWidget(_app(const ShimmerLoading(child: box)));
      final masks = <Widget>{};
      for (var frame = 0; frame < 120; frame++) {
        await tester.pump(const Duration(microseconds: 8333));
        masks.add(tester.widget(find.byType(ShaderMask)));
      }
      // 120 frames at 120 Hz span one second.
      expect(masks.length, inInclusiveRange(20, 31));
      expect(DecorativePhase.debugClockRunning, isTrue);

      await tester.pumpWidget(_app(const SizedBox()));
      expect(DecorativePhase.debugClockRunning, isFalse);
    });

    testWidgets('reduced motion keeps the placeholders still', (tester) async {
      await tester.pumpWidget(
        _app(const ShimmerLoading(child: box), reduced: true),
      );
      expect(find.byType(ShaderMask), findsNothing);
      expect(DecorativePhase.debugClockRunning, isFalse);
    });
  });
}
