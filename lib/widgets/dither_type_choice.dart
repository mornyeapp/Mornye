import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Plain or high-pass TPDF: a two-way choice under its [title] and the
/// current choice's description.
class DitherTypeChoice extends StatelessWidget {
  const DitherTypeChoice({
    super.key,
    required this.title,
    required this.plainDescription,
    required this.highPassDescription,
    required this.highPass,
    this.enabled = true,
    this.showDivider = false,
    required this.onChanged,
  });

  final String title;
  final String plainDescription;
  final String highPassDescription;
  final bool highPass;
  final bool enabled;

  /// True when another row follows in the same group.
  final bool showDivider;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final showIcon = !context.isMornye;
    final content = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.tokens.rowPaddingH,
        vertical: context.tokens.rowPaddingVCompact,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (showIcon) ...[
                AppIcon(
                  Icons.waves,
                  color: enabled
                      ? colorScheme.onSurfaceVariant
                      : colorScheme.outline,
                  size: 24,
                ),
                SizedBox(width: context.tokens.rowIconGap),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: textTheme.bodyLarge?.copyWith(
                        color: enabled ? null : colorScheme.outline,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      highPass ? highPassDescription : plainDescription,
                      style: textTheme.bodyMedium?.copyWith(
                        color: enabled
                            ? colorScheme.onSurfaceVariant
                            : colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SettingsSegmentedChoice<bool>(
            selected: highPass,
            enabled: enabled,
            onChanged: onChanged,
            semanticLabel: title,
            options: [
              SettingsSegmentOption(
                value: false,
                label: l10n.trackConvertDitherTriangular,
              ),
              SettingsSegmentOption(
                value: true,
                label: l10n.trackConvertDitherTriangularHp,
              ),
            ],
          ),
        ],
      ),
    );
    final row = SettingsSearchTarget(label: title, child: content);
    if (!showDivider || settingsRowsConnected(context)) return row;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        Divider(
          height: 1,
          indent: showIcon
              ? context.tokens.rowIconDividerIndent
              : context.tokens.rowPaddingH,
          endIndent: context.tokens.rowPaddingH,
          color: context.isMornye
              ? colorScheme.outlineVariant
              : colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ],
    );
  }
}
