import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/desktop_scroll_arrows.dart';
import 'package:mornye/widgets/mornye_chrome.dart';

import 'support/tooltip_finder.dart';

void main() {
  late ScrollController controller;
  var shelfBuilds = 0;

  Future<void> pumpShelf(WidgetTester tester) async {
    shelfBuilds = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Center(
          child: SizedBox(
            width: 300,
            height: 100,
            child: DesktopScrollArrows(
              builder: (context, scrollController) {
                controller = scrollController;
                shelfBuilds++;
                return ListView.builder(
                  controller: scrollController,
                  scrollDirection: Axis.horizontal,
                  itemCount: 20,
                  itemBuilder: (_, index) =>
                      SizedBox(width: 100, child: Text('Item $index')),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> hover(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(ListView)));
    await tester.pumpAndSettle();
  }

  tearDown(() => debugDesktopPlatformOverride = null);

  testWidgets('Mornye fades a tall glass paddle with the pointer', (
    tester,
  ) async {
    debugDesktopPlatformOverride = true;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Center(
            child: SizedBox(
              width: 300,
              height: 100,
              child: DesktopScrollArrows(
                builder: (context, scrollController) => ListView.builder(
                  controller: scrollController,
                  scrollDirection: Axis.horizontal,
                  itemCount: 20,
                  itemBuilder: (_, index) =>
                      SizedBox(width: 100, child: Text('Item $index')),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(ListView)));
    await tester.pump();

    final arrow = findByTooltip('Scroll forward');
    final fade = find.ancestor(of: arrow, matching: find.byType(Opacity));
    await tester.pump(const Duration(milliseconds: 125));
    expect(
      tester.widget<Opacity>(fade).opacity,
      inExclusiveRange(0.5, 1),
      reason: 'the effects spring is most of the way in by half its length',
    );
    await tester.pump(MornyeMotion.effects.duration);
    expect(tester.widget<Opacity>(fade).opacity, 1);
    expect(
      tester.getSize(
        find.descendant(of: arrow, matching: find.byType(MornyeGlassPanel)),
      ),
      const Size(28, 52),
    );

    await mouse.moveTo(const Offset(1, 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 125));
    expect(arrow, findsOneWidget);
    await tester.pumpAndSettle();
    expect(arrow, findsNothing);
  });

  for (final reduced in [false, true]) {
    testWidgets('Material fades its arrows in and out faster'
        '${reduced ? ' (reduced motion)' : ''}', (tester) async {
      if (reduced) {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
      }
      debugDesktopPlatformOverride = true;
      await pumpShelf(tester);
      final arrow = findByTooltip('Scroll forward');
      double opacity() => tester
          .widget<Opacity>(
            find.ancestor(of: arrow, matching: find.byType(Opacity)).first,
          )
          .opacity;
      // At rest the shelf holds a zero-size child and no arrows.
      expect(arrow, findsNothing);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byType(ListView)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      if (reduced) {
        expect(arrow, findsOneWidget);
        expect(
          find.ancestor(of: arrow, matching: find.byType(Opacity)),
          findsNothing,
        );
      } else {
        expect(opacity(), inExclusiveRange(0, 1));
        await tester.pumpAndSettle();
        expect(opacity(), 1);
      }

      await mouse.moveTo(Offset.zero);
      await tester.pump();
      if (reduced) {
        await tester.pump();
        expect(arrow, findsNothing);
      } else {
        await tester.pump(const Duration(milliseconds: 50));
        expect(opacity(), inExclusiveRange(0, 1));
        // The exit is shorter than the entrance.
        await tester.pump(const Duration(milliseconds: 60));
        await tester.pump();
        expect(arrow, findsNothing);
      }
      // Hovering never rebuilt the list.
      expect(shelfBuilds, 1);
    });
  }

  testWidgets('desktop shows arrows on hover in the open directions', (
    tester,
  ) async {
    debugDesktopPlatformOverride = true;
    await pumpShelf(tester);
    expect(findByTooltip('Scroll forward'), findsNothing);

    await hover(tester);
    expect(findByTooltip('Scroll forward'), findsOneWidget);
    expect(findByTooltip('Scroll back'), findsNothing);

    await tester.tap(findByTooltip('Scroll forward'));
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(240, 0.1));
    expect(findByTooltip('Scroll back'), findsOneWidget);

    await tester.tap(findByTooltip('Scroll back'));
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    expect(findByTooltip('Scroll back'), findsNothing);
  });

  testWidgets('hovering a card rebuilds only that card', (tester) async {
    debugDesktopPlatformOverride = true;
    var lists = 0;
    final cardBuilds = <int, int>{};
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Center(
          child: SizedBox(
            width: 300,
            height: 100,
            child: DesktopScrollArrows(
              builder: (context, scrollController) {
                lists++;
                return ListView.builder(
                  controller: scrollController,
                  scrollDirection: Axis.horizontal,
                  itemCount: 20,
                  itemBuilder: (_, index) =>
                      _HoverCard(index: index, builds: cardBuilds),
                );
              },
            ),
          ),
        ),
      ),
    );
    final visible = cardBuilds.keys.toList();
    expect(visible, hasLength(greaterThan(2)));
    expect(cardBuilds.values, everyElement(1));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Card 1')));
    await tester.pumpAndSettle();
    expect(findByTooltip('Scroll forward'), findsOneWidget);
    expect(cardBuilds, {for (final i in visible) i: i == 1 ? 2 : 1});

    await mouse.moveTo(tester.getCenter(find.text('Card 2')));
    await tester.pumpAndSettle();
    expect(cardBuilds, {
      for (final i in visible) i: i == 1 ? 3 : (i == 2 ? 2 : 1),
    });

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(findByTooltip('Scroll forward'), findsNothing);
    expect(cardBuilds, {
      for (final i in visible) i: i == 1 ? 3 : (i == 2 ? 3 : 1),
    });
    expect(lists, 1);
  });

  testWidgets('phones and tablets keep the plain list', (tester) async {
    debugDesktopPlatformOverride = false;
    await pumpShelf(tester);
    await hover(tester);
    expect(findByTooltip('Scroll forward'), findsNothing);
    expect(
      find.ancestor(of: find.byType(ListView), matching: find.byType(Stack)),
      findsNothing,
    );
  });
}

/// A shelf card with its own hover state that counts its builds.
class _HoverCard extends StatefulWidget {
  const _HoverCard({required this.index, required this.builds});

  final int index;
  final Map<int, int> builds;

  @override
  State<_HoverCard> createState() => _HoverCardState();
}

class _HoverCardState extends State<_HoverCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    widget.builds.update(widget.index, (n) => n + 1, ifAbsent: () => 1);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: SizedBox(
        width: 100,
        child: Text('Card ${widget.index}${_hovered ? ' hovered' : ''}'),
      ),
    );
  }
}
