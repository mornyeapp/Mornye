import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/controllers/selection_mode_mixin.dart';
import 'package:mornye/utils/ordered_range_selection.dart';
import 'package:mornye/widgets/drag_select.dart';

const _rowHeight = 60.0;

class _List extends StatefulWidget {
  const _List({this.count = 40});

  final int count;

  @override
  State<_List> createState() => _ListState();
}

class _ListState extends State<_List> with SelectionModeMixin<_List> {
  @override
  Widget build(BuildContext context) {
    slideSelectIds = [for (var i = 0; i < widget.count; i++) 'row$i'];
    return ListView.builder(
      itemExtent: _rowHeight,
      itemCount: widget.count,
      itemBuilder: (context, index) {
        final id = 'row$index';
        return DragSelectItem(
          controller: slideSelect,
          id: id,
          child: InkWell(
            onTap: isSelectionMode ? () => toggleSelection(id) : null,
            onLongPress: () => holdToSelect(id),
            child: Center(child: Text(id)),
          ),
        );
      },
    );
  }
}

Future<_ListState> _pump(WidgetTester tester, {int count = 40}) async {
  tester.view.physicalSize = const Size(400, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: _List(count: count)),
    ),
  );
  return tester.state<_ListState>(find.byType(_List));
}

/// Holds a finger on [row] until its long press fires.
Future<TestGesture> _hold(WidgetTester tester, String row) async {
  final gesture = await tester.startGesture(tester.getCenter(find.text(row)));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  return gesture;
}

void main() {
  test('a slide selects the passed rows on top of the earlier selection', () {
    final rows = ['a', 'b', 'c', 'd', 'e'];
    final selected = {'a', 'c'};
    final base = {...selected};
    void slide(String target) => applySlideSelection(
      selected: selected,
      base: base,
      visibleItems: rows,
      anchor: 'c',
      target: target,
    );
    slide('e');
    expect(selected, {'a', 'c', 'd', 'e'});
    // Sliding back releases the rows passed, not the earlier selection.
    slide('d');
    expect(selected, {'a', 'c', 'd'});
    slide('b');
    expect(selected, {'a', 'c', 'b'});
    slide('gone');
    expect(selected, {'a', 'c', 'b'});
  });

  testWidgets('a held finger selects the rows it slides over', (tester) async {
    final state = await _pump(tester);
    final gesture = await _hold(tester, 'row1');
    expect(state.selectedIds, {'row1'});
    expect(state.slideSelect.isActive, isTrue);

    await gesture.moveBy(const Offset(0, _rowHeight * 3));
    await tester.pump();
    expect(state.selectedIds, {'row1', 'row2', 'row3', 'row4'});
    // The list did not scroll under the finger.
    expect(tester.getTopLeft(find.text('row0')).dy, lessThan(_rowHeight));

    // Back up past the first row: the rows below it are released.
    await gesture.moveBy(const Offset(0, -_rowHeight * 4));
    await tester.pump();
    expect(state.selectedIds, {'row1', 'row0'});

    await gesture.up();
    await tester.pump();
    expect(state.slideSelect.isActive, isFalse);
    expect(state.selectedIds, {'row1', 'row0'});
  });

  testWidgets('a second slide adds to the selection', (tester) async {
    final state = await _pump(tester);
    var gesture = await _hold(tester, 'row0');
    await gesture.moveBy(const Offset(0, _rowHeight));
    await gesture.up();
    await tester.pump();
    expect(state.selectedIds, {'row0', 'row1'});

    gesture = await _hold(tester, 'row5');
    await gesture.moveBy(const Offset(0, _rowHeight * 2));
    await tester.pump();
    expect(state.selectedIds, {'row0', 'row1', 'row5', 'row6', 'row7'});
    await gesture.moveBy(const Offset(0, -_rowHeight));
    await gesture.up();
    await tester.pump();
    expect(state.selectedIds, {'row0', 'row1', 'row5', 'row6'});

    // A tap still toggles one row.
    await tester.tap(find.text('row6'));
    await tester.pump();
    expect(state.selectedIds, {'row0', 'row1', 'row5'});
  });

  testWidgets('resting near the bottom edge scrolls and keeps selecting', (
    tester,
  ) async {
    final state = await _pump(tester);
    final gesture = await _hold(tester, 'row2');
    await gesture.moveTo(const Offset(200, 590));
    await tester.pump();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scroll.position.pixels, greaterThan(_rowHeight * 4));
    // Every row from the first held one to the one now under the finger.
    final last = ((scroll.position.pixels + 590) / _rowHeight).floor();
    expect(state.selectedIds, {for (var i = 2; i <= last; i++) 'row$i'});

    // Away from the edge the list rests.
    await gesture.moveTo(const Offset(200, 300));
    await tester.pump();
    final rested = scroll.position.pixels;
    await tester.pump(const Duration(milliseconds: 100));
    expect(scroll.position.pixels, rested);
    await gesture.up();
    await tester.pump();
  });

  testWidgets('a drag without a long press scrolls and selects nothing', (
    tester,
  ) async {
    final state = await _pump(tester);
    await tester.drag(find.text('row3'), const Offset(0, -200));
    await tester.pump();
    expect(state.isSelectionMode, isFalse);
    expect(
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
      greaterThan(0),
    );
  });
}
