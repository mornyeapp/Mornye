import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/isrc_utils.dart';
import 'package:mornye/utils/ordered_range_selection.dart';

void main() {
  group('issue 542 utility behavior', () {
    test('formats valid ISRC for display without changing canonical value', () {
      expect(formatIsrcForDisplay('aa9bq2200061'), 'AA-9BQ-22-00061');
      expect(normalizeIsrc('AA-9BQ-22-00061'), 'AA9BQ2200061');
      expect(canonicalIsrcForCopy('aa-9bq-22-00061'), 'AA9BQ2200061');
      expect(formatIsrcForDisplay('not-an-isrc'), 'not-an-isrc');
      expect(canonicalIsrcForCopy('not-an-isrc'), 'not-an-isrc');
    });

    test('range selection follows the user direction and insertion order', () {
      final selected = <String>{'d'};

      final anchor = addOrderedSelectionRange(
        selected: selected,
        visibleItems: const ['a', 'b', 'c', 'd', 'e'],
        anchor: 'd',
        target: 'b',
      );

      expect(anchor, 'b');
      expect(selected.toList(), const ['d', 'c', 'b']);
    });

    test('single selection toggle keeps the latest selected anchor', () {
      final selected = <String>{};
      expect(toggleOrderedSelection(selected: selected, target: 'a'), 'a');
      expect(toggleOrderedSelection(selected: selected, target: 'c'), 'c');
      expect(toggleOrderedSelection(selected: selected, target: 'c'), 'a');
      expect(selected.toList(), const ['a']);
    });
  });
}
