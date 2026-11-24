import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/material_expressive.dart';

/// Checkbox row for Material dialogs and sheets. Expressive builds use the
/// M3E checkbox; reduced motion falls back to the static Material tile.
/// Mornye call sites keep their own check-circle rows.
class AppCheckboxListTile extends StatelessWidget {
  const AppCheckboxListTile({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.secondary,
    this.contentPadding,
    this.controlAffinity = ListTileControlAffinity.platform,
  });

  final bool value;
  final ValueChanged<bool?>? onChanged;
  final Widget title;
  final Widget? subtitle;

  /// Icon on the side opposite the checkbox.
  final Widget? secondary;
  final EdgeInsetsGeometry? contentPadding;
  final ListTileControlAffinity controlAffinity;

  @override
  Widget build(BuildContext context) {
    if (!materialExpressiveEnabled(context)) {
      return CheckboxListTile(
        value: value,
        onChanged: onChanged,
        title: title,
        subtitle: subtitle,
        secondary: secondary,
        contentPadding: contentPadding,
        controlAffinity: controlAffinity,
      );
    }
    final checkbox = MaterialExpressiveScope(
      child: M3ECheckbox(value: value, onChanged: onChanged),
    );
    final checkboxLeads = controlAffinity == ListTileControlAffinity.leading;
    return MergeSemantics(
      child: ListTile(
        title: title,
        subtitle: subtitle,
        contentPadding: contentPadding,
        enabled: onChanged != null,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        leading: checkboxLeads ? checkbox : secondary,
        trailing: checkboxLeads ? secondary : checkbox,
      ),
    );
  }
}
