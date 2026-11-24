import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';

/// The title row above a settings slider, with the slider's current value.
///
/// Material shows the value with its unit in a tonal pill at the trailing
/// end, so it reads without touching the slider. Mornye shows it as iOS
/// detail text in the secondary label color.
class SliderValueHeader extends StatelessWidget {
  const SliderValueHeader({
    super.key,
    required this.title,
    required this.value,
    this.subtitle,
    this.leading,
    this.trailing,
    this.enabled = true,
  });

  final String title;

  /// The formatted value with its unit, such as `45 s` or `+1.5 dB`.
  final String value;

  final String? subtitle;

  /// A glyph before the title, like the settings rows around it.
  final Widget? leading;

  /// A control after the value, such as a reset button.
  final Widget? trailing;

  /// False while the slider is disabled, which dims the row with it.
  final bool enabled;

  static const _tabular = [FontFeature.tabularFigures()];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = context.tokens;
    final disabled = colors.onSurface.withValues(alpha: 0.38);
    return Row(
      children: [
        if (leading != null) ...[leading!, SizedBox(width: tokens.rowIconGap)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: enabled
                    ? theme.textTheme.bodyLarge
                    : theme.textTheme.bodyLarge?.copyWith(color: disabled),
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontFeatures: _tabular,
                  ),
                ),
            ],
          ),
        ),
        SizedBox(width: tokens.gapSm),
        if (context.isMornye)
          Text(
            value,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: enabled ? colors.onSurfaceVariant : disabled,
              fontFeatures: _tabular,
            ),
          )
        else
          DecoratedBox(
            decoration: ShapeDecoration(
              color: enabled
                  ? colors.secondaryContainer
                  : colors.onSurface.withValues(alpha: 0.12),
              shape: const StadiumBorder(),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: tokens.gapMd,
                vertical: tokens.gapXs,
              ),
              child: Text(
                value,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: enabled ? colors.onSecondaryContainer : disabled,
                  fontFeatures: _tabular,
                ),
              ),
            ),
          ),
        if (trailing != null) ...[SizedBox(width: tokens.gapXs), trailing!],
      ],
    );
  }
}
