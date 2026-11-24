import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_text_field.dart';

Color metadataEditorFieldFill(BuildContext context, ColorScheme cs) {
  if (context.isMornye) return Colors.transparent;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark
      ? Color.alphaBlend(Colors.white.withValues(alpha: 0.05), cs.surface)
      : cs.surface;
}

class MetadataTextField extends StatelessWidget {
  final ColorScheme colorScheme;
  final String label;
  final TextEditingController controller;
  final String? hint;
  final TextInputType? keyboard;
  final int maxLines;
  final List<TextInputFormatter>? inputFormatters;

  const MetadataTextField(
    this.colorScheme,
    this.label,
    this.controller, {
    super.key,
    this.hint,
    this.keyboard,
    this.maxLines = 1,
    this.inputFormatters,
  });

  @override
  Widget build(BuildContext context) {
    final cs = colorScheme;
    final radius = BorderRadius.circular(14);
    if (materialExpressiveEnabled(context)) {
      // The expressive field floats its own label.
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: AppTextField(
          controller: controller,
          label: label,
          hint: hint,
          keyboardType: keyboard,
          inputFormatters: inputFormatters,
          maxLines: maxLines,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, bottom: 6),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
          ),
          if (context.isMornye) ...[
            CupertinoTextField(
              controller: controller,
              keyboardType: keyboard,
              inputFormatters: inputFormatters,
              maxLines: maxLines,
              placeholder: hint,
              cursorColor: cs.primary,
              style: Theme.of(context).textTheme.bodyLarge,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
              decoration: null,
            ),
            const Divider(height: 0.5),
          ] else
            TextField(
              controller: controller,
              keyboardType: keyboard,
              inputFormatters: inputFormatters,
              maxLines: maxLines,
              cursorColor: cs.primary,
              style: Theme.of(context).textTheme.bodyLarge,
              decoration: InputDecoration(
                hintText: hint,
                filled: true,
                fillColor: metadataEditorFieldFill(context, cs),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: radius,
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: radius,
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: radius,
                  borderSide: BorderSide(color: cs.primary, width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 15,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
