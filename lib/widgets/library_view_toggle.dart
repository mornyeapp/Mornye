import 'package:material_3_expressive/material_3_expressive.dart'
    show
        M3EButtonGroup,
        M3EButtonGroupAction,
        M3EButtonGroupType,
        M3EButtonSize,
        M3EButtonStyle;
import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/mornye_chrome.dart';

/// A switch between the views of a Library page, such as Albums | Singles:
/// a connected button group on Material, a Mornye segmented control on Mornye,
/// or a segmented button where Material expressive components are off.
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
    if (context.isMornye) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final control = MornyeSegmentedControl(
            labels: labels,
            selectedIndex: selected,
            onChanged: onChanged,
            samplesBackdrop: false,
            compact: isDesktopPlatform,
          );
          if (constraints.hasBoundedWidth) return control;
          final textStyle = isDesktopPlatform
              ? Theme.of(context).textTheme.bodyMedium
              : Theme.of(context).textTheme.labelLarge;
          final scaler = MediaQuery.textScalerOf(context);
          var widest = 0.0;
          for (final label in labels) {
            final painter = TextPainter(
              text: TextSpan(text: label, style: textStyle),
              textDirection: Directionality.of(context),
              textScaler: scaler,
              maxLines: 1,
            )..layout();
            if (painter.width > widest) widest = painter.width;
            painter.dispose();
          }
          final segmentWidth = (widest + (isDesktopPlatform ? 24 : 28)).clamp(
            isDesktopPlatform ? 64.0 : 72.0,
            180.0,
          );
          return SizedBox(
            width: segmentWidth * labels.length + 8,
            child: control,
          );
        },
      );
    }
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
