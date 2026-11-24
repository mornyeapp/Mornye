import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/desktop/desktop_inspector.dart';

void main() {
  testWidgets('the pane beside the content never grows past its width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final contentWidths = <double>[];
    late StateSetter rebuild;
    DesktopInspectorPanel? panel;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      contentWidths.add(constraints.maxWidth);
                      return const SizedBox.expand();
                    },
                  ),
                ),
                DesktopInspectorTransition(
                  panel: panel,
                  builder: (context, panel) =>
                      const SizedBox(width: desktopInspectorWidth),
                ),
              ],
            );
          },
        ),
      ),
    );
    expect(contentWidths.last, 1000);

    // The Material open spring overshoots; the content must not narrow
    // past its final width on the way, or its breakpoints flip twice.
    rebuild(() => panel = DesktopInspectorPanel.lyrics);
    contentWidths.clear();
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    const settled = 1000 - desktopInspectorWidth;
    expect(contentWidths.last, settled);
    expect(contentWidths.where((width) => width < settled), isEmpty);
    // The first opening animates too: the content narrows over frames.
    expect(contentWidths.where((width) => width > settled), isNotEmpty);
  });

  for (final mornye in [false, true]) {
    testWidgets('${mornye ? 'Mornye' : 'Material'}: a pane reversed mid-move '
        'goes on from where it is', (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final contentWidths = <double>[];
      late StateSetter rebuild;
      DesktopInspectorPanel? panel;
      await tester.pumpWidget(
        MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.light) : null,
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        contentWidths.add(constraints.maxWidth);
                        return const SizedBox.expand();
                      },
                    ),
                  ),
                  DesktopInspectorTransition(
                    panel: panel,
                    builder: (context, panel) =>
                        const SizedBox(width: desktopInspectorWidth),
                  ),
                ],
              );
            },
          ),
        ),
      );

      /// The largest change of the content width between two frames.
      Future<double> largestStep(int frames) async {
        var largest = 0.0;
        for (var i = 0; i < frames; i++) {
          final before = contentWidths.last;
          await tester.pump(const Duration(milliseconds: 16));
          largest = math.max(largest, (contentWidths.last - before).abs());
        }
        return largest;
      }

      rebuild(() => panel = DesktopInspectorPanel.lyrics);
      await tester.pump();
      await largestStep(5);
      final opening = contentWidths.last;
      expect(opening, inExclusiveRange(1000 - desktopInspectorWidth, 1000));

      // Closing mid-open, then opening mid-close: no frame jumps.
      rebuild(() => panel = null);
      expect(await largestStep(4), lessThan(desktopInspectorWidth / 5));
      rebuild(() => panel = DesktopInspectorPanel.lyrics);
      expect(await largestStep(4), lessThan(desktopInspectorWidth / 5));

      await tester.pumpAndSettle();
      expect(contentWidths.last, 1000 - desktopInspectorWidth);
    });
  }
}
