import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/automix_options.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/slider_value_header.dart';

class AutoMixSettings extends ConsumerStatefulWidget {
  const AutoMixSettings({super.key});

  @override
  ConsumerState<AutoMixSettings> createState() => _AutoMixSettingsState();
}

class _AutoMixSettingsState extends ConsumerState<AutoMixSettings> {
  double? _duration;
  double? _pitch;
  double? _speed;

  void _showEffectPicker(
    BuildContext context,
    AutoMixEffect current,
    Map<AutoMixEffect, String> names,
  ) {
    final notifier = ref.read(settingsProvider.notifier);
    showAppBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      title: context.l10n.autoMixEffect,
      maxHeightFactor: 0.85,
      builder: (sheetContext) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final effect in AutoMixEffect.values)
              Semantics(
                selected: effect == current,
                child: AppSheetOption(
                  leading: Icon(switch (effect) {
                    AutoMixEffect.auto => Icons.auto_awesome,
                    AutoMixEffect.crossfade => Icons.compare_arrows,
                    AutoMixEffect.muffled => Icons.graphic_eq,
                    AutoMixEffect.echo => Icons.surround_sound,
                    AutoMixEffect.pitch => Icons.music_note,
                    AutoMixEffect.vinylBrake => Icons.album,
                    AutoMixEffect.custom => Icons.tune,
                  }),
                  title: Text(names[effect]!),
                  selected: effect == current,
                  trailing: effect == current
                      ? Icon(
                          Icons.check,
                          color: Theme.of(sheetContext).colorScheme.primary,
                        )
                      : null,
                  onTap: () {
                    notifier.setAutoMixEffect(effect);
                    Navigator.pop(sheetContext);
                  },
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final enabled = settings.autoMix && !settings.usbBitPerfect;
    final l10n = context.l10n;
    final names = {
      AutoMixEffect.auto: l10n.autoMixEffectAuto,
      AutoMixEffect.crossfade: l10n.autoMixEffectCrossfade,
      AutoMixEffect.muffled: l10n.autoMixEffectMuffled,
      AutoMixEffect.echo: l10n.autoMixEffectEcho,
      AutoMixEffect.pitch: l10n.autoMixEffectPitch,
      AutoMixEffect.vinylBrake: 'Vinyl Brake',
      AutoMixEffect.custom: l10n.autoMixEffectCustom,
    };
    Widget slider(
      String label,
      String valueLabel,
      double value,
      double min,
      double max,
      int divisions,
      ValueChanged<double> draft,
      ValueChanged<double> save,
    ) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (context.isMornye)
              Text('$label: $valueLabel')
            else
              SliderValueHeader(
                title: label,
                value: valueLabel,
                enabled: enabled,
              ),
            AppSlider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              label: value.toStringAsFixed(2),
              semanticLabel: '$label: $valueLabel',
              onChanged: enabled ? draft : null,
              onChangeEnd: enabled ? save : null,
            ),
          ],
        ),
      );
    }

    return SettingsGroup(
      connected: true,
      children: [
        SettingsSwitchItem(
          icon: Icons.timer_outlined,
          title: l10n.autoMixAutomaticDuration,
          value: settings.autoMixDuration == 0,
          enabled: enabled,
          onChanged: (automatic) =>
              notifier.setAutoMixDuration(automatic ? 0 : 5),
        ),
        if (settings.autoMixDuration != 0)
          slider(
            l10n.autoMixDuration,
            '${(_duration ?? settings.autoMixDuration.toDouble()).round()} s',
            _duration ?? settings.autoMixDuration.toDouble(),
            3,
            60,
            57,
            (value) => setState(() => _duration = value),
            (value) {
              notifier.setAutoMixDuration(value.round());
              setState(() => _duration = null);
            },
          ),
        SettingsItem(
          icon: Icons.tune,
          title: l10n.autoMixEffect,
          subtitle: names[settings.autoMixEffect],
          onTap: enabled
              ? () => _showEffectPicker(context, settings.autoMixEffect, names)
              : null,
        ),
        if (settings.autoMixEffect == AutoMixEffect.pitch ||
            settings.autoMixEffect == AutoMixEffect.custom)
          slider(
            l10n.autoMixPitch,
            (_pitch ?? settings.autoMixPitch).toStringAsFixed(1),
            _pitch ?? settings.autoMixPitch,
            -6,
            6,
            24,
            (value) => setState(() => _pitch = value),
            (value) {
              notifier.setAutoMixPitch(value);
              setState(() => _pitch = null);
            },
          ),
        if (settings.autoMixEffect == AutoMixEffect.custom) ...[
          slider(
            l10n.autoMixSpeed,
            '${(_speed ?? settings.autoMixSpeed).toStringAsFixed(2)}×',
            _speed ?? settings.autoMixSpeed,
            0.8,
            1.2,
            40,
            (value) => setState(() => _speed = value),
            (value) {
              notifier.setAutoMixSpeed(value);
              setState(() => _speed = null);
            },
          ),
          SettingsSwitchItem(
            icon: Icons.surround_sound,
            title: l10n.autoMixEcho,
            value: settings.autoMixEcho,
            enabled: enabled,
            onChanged: notifier.setAutoMixEcho,
          ),
          SettingsSwitchItem(
            icon: Icons.graphic_eq,
            title: l10n.autoMixLowPass,
            value: settings.autoMixLowPass,
            enabled: enabled,
            onChanged: notifier.setAutoMixLowPass,
          ),
        ],
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            l10n.autoMixEffectsHelp,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
