import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/desktop_scroll_arrows.dart';

void main() {
  late ScrollController controller;

  Future<void> pumpShelf(WidgetTester tester) async {
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

  testWidgets('desktop shows arrows on hover in the open directions', (
    tester,
  ) async {
    debugDesktopPlatformOverride = true;
    await pumpShelf(tester);
    expect(find.byTooltip('Scroll forward'), findsNothing);

    await hover(tester);
    expect(find.byTooltip('Scroll forward'), findsOneWidget);
    expect(find.byTooltip('Scroll back'), findsNothing);

    await tester.tap(find.byTooltip('Scroll forward'));
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(240, 0.1));
    expect(find.byTooltip('Scroll back'), findsOneWidget);

    await tester.tap(find.byTooltip('Scroll back'));
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    expect(find.byTooltip('Scroll back'), findsNothing);
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
    expect(find.byTooltip('Scroll forward'), findsOneWidget);
    expect(cardBuilds, {for (final i in visible) i: i == 1 ? 2 : 1});

    await mouse.moveTo(tester.getCenter(find.text('Card 2')));
    await tester.pumpAndSettle();
    expect(cardBuilds, {
      for (final i in visible) i: i == 1 ? 3 : (i == 2 ? 2 : 1),
    });

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Scroll forward'), findsNothing);
    expect(cardBuilds, {
      for (final i in visible) i: i == 1 ? 3 : (i == 2 ? 3 : 1),
    });
    expect(lists, 1);
  });

  testWidgets('phones and tablets keep the plain list', (tester) async {
    debugDesktopPlatformOverride = false;
    await pumpShelf(tester);
    await hover(tester);
    expect(find.byTooltip('Scroll forward'), findsNothing);
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
