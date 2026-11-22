import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';

void main() {
  Future<List<Offset>> pumpRegion(
    WidgetTester tester, {
    required bool touch,
  }) async {
    final opened = <Offset>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: DesktopContextMenuRegion(
              touch: touch,
              onContextMenu: opened.add,
              child: InkWell(
                onTap: () {},
                child: const SizedBox.square(
                  dimension: 100,
                  child: Text('Album'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return opened;
  }

  testWidgets('a long press opens the menu where the finger is, on phones', (
    tester,
  ) async {
    final opened = await pumpRegion(tester, touch: true);
    final center = tester.getCenter(find.text('Album'));
    await tester.longPressAt(center);
    await tester.pump();
    expect(opened, [center]);
  });

  testWidgets('an item with its own long press keeps it', (tester) async {
    final opened = await pumpRegion(tester, touch: false);
    await tester.longPress(find.text('Album'));
    await tester.pump();
    expect(opened, isEmpty);
  });
}
