import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/slider_value_header.dart';

class AutoplayRandomnessSlider extends ConsumerStatefulWidget {
  const AutoplayRandomnessSlider({super.key});

  @override
  ConsumerState<AutoplayRandomnessSlider> createState() =>
      _AutoplayRandomnessSliderState();
}

class _AutoplayRandomnessSliderState
    extends ConsumerState<AutoplayRandomnessSlider> {
  double? _draft;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final enabled = settings.playerMode == 'internal';
    final value = autoplayRandomnessFromJson(
      _draft ?? settings.autoplayRandomness,
    );
    final l10n = context.l10n;
    final tokens = context.tokens;
    final theme = Theme.of(context);
    final format = NumberFormat.percentPattern(l10n.localeName);
    final label = format.format(value);
    final content = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.rowPaddingH,
        vertical: tokens.rowPaddingV,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SliderValueHeader(
            title: l10n.autoplayRandomness,
            value: label,
            enabled: enabled,
          ),
          AppSlider(
            value: value,
            divisions: 20,
            label: label,
            semanticLabel: l10n.autoplayRandomness,
            semanticFormatterCallback: format.format,
            onChanged: enabled
                ? (value) => setState(() => _draft = value)
                : null,
            onChangeEnd: enabled
                ? (value) {
                    ref
                        .read(settingsProvider.notifier)
                        .setAutoplayRandomness(value);
                    setState(() => _draft = null);
                  }
                : null,
          ),
          DefaultTextStyle(
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Text(l10n.autoplayLeastRecent)),
                SizedBox(width: tokens.gapMd),
                Expanded(
                  child: Text(
                    l10n.autoplayMoreRandom,
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.gapSm),
          Text(
            l10n.autoplayRandomnessDescription,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
    return SettingsSearchTarget(label: l10n.autoplayRandomness, child: content);
  }
}
