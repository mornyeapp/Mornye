import 'package:material_3_expressive/material_3_expressive.dart'
    show
        M3EButtonGroup,
        M3EButtonGroupAction,
        M3EButtonGroupType,
        M3EButtonSize,
        M3EButtonStyle;
import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/material_expressive.dart';

/// A switch between the views of a Library page, such as Albums | Singles:
/// a connected button group, or a segmented button where the expressive
/// components are off.
class LibraryViewToggle extends StatelessWidget {
  const LibraryViewToggle({
    super.key,
    required this.labels,
    required this.selected,
    required this.onChanged,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    if (materialExpressiveEnabled(context)) {
      return MaterialExpressiveScope(
        skipAutofocus: true,
        child: M3EButtonGroup(
          type: M3EButtonGroupType.connected,
          style: M3EButtonStyle.filled,
          // Connected segments get no inflated target; keep 48 dp.
          size: M3EButtonSize.sm.copyWith(height: 48),
          selectedIndex: selected,
          selectionRequired: true,
          onSelectedIndexChanged: (index) {
            if (index != null) onChanged(index);
          },
          actions: [
            for (final label in labels)
              M3EButtonGroupAction(label: Text(label)),
          ],
        ),
      );
    }
    return SegmentedButton<int>(
      showSelectedIcon: false,
      segments: [
        for (final (index, label) in labels.indexed)
          ButtonSegment(value: index, label: Text(label)),
      ],
      selected: {selected},
      onSelectionChanged: (value) => onChanged(value.first),
    );
  }
}
