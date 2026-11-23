import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/widgets/on_screen_listener.dart';

void main() {
  testWidgets('tells when the page scrolls its child away and back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final page = ScrollController();
    addTearDown(page.dispose);
    final calls = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          controller: page,
          child: Column(
            children: [
              const SizedBox(height: 100),
              OnScreenListener(
                onChanged: calls.add,
                child: const SizedBox(height: 300, width: 400),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    // On screen from the start: nothing to tell.
    expect(calls, isEmpty);

    // Its last rows still show.
    page.jumpTo(390);
    await tester.pump();
    page.jumpTo(395);
    await tester.pump();
    expect(calls, isEmpty);

    // The position is read from the frame before, so one more step.
    page.jumpTo(420);
    await tester.pump();
    page.jumpTo(430);
    await tester.pump();
    expect(calls, [false]);

    page.jumpTo(200);
    await tester.pump();
    page.jumpTo(190);
    await tester.pump();
    expect(calls, [false, true]);
  });

  testWidgets('a section above that grows or shrinks without a scroll '
      'moves the child off and back on', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final above = ValueNotifier<double>(100);
    addTearDown(above.dispose);
    final calls = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          child: Column(
            children: [
              ValueListenableBuilder<double>(
                valueListenable: above,
                builder: (context, height, _) => SizedBox(height: height),
              ),
              OnScreenListener(
                onChanged: calls.add,
                child: const SizedBox(height: 300, width: 400),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(calls, isEmpty);

    above.value = 1000;
    await tester.pump();
    await tester.pump();
    expect(calls, [false]);

    above.value = 100;
    await tester.pump();
    await tester.pump();
    expect(calls, [false, true]);
  });

  testWidgets('a page that opens scrolled past the child says so', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final page = ScrollController(initialScrollOffset: 900);
    addTearDown(page.dispose);
    final calls = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          controller: page,
          child: Column(
            children: [
              OnScreenListener(
                onChanged: calls.add,
                child: const SizedBox(height: 300, width: 400),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(calls, [false]);
  });
}
