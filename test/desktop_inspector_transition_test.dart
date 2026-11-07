import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
