import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/slider_value_header.dart';

/// Sensitivity and strength sliders shown under the music haptics switch.
class MusicHapticsSettings extends ConsumerStatefulWidget {
  const MusicHapticsSettings({super.key, required this.enabled});

  final bool enabled;

  @override
  ConsumerState<MusicHapticsSettings> createState() =>
      _MusicHapticsSettingsState();
}

class _MusicHapticsSettingsState extends ConsumerState<MusicHapticsSettings> {
  double? _sensitivity;
  double? _strength;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final l10n = context.l10n;
    Widget slider(
      String label,
      double value,
      ValueChanged<double> draft,
      ValueChanged<double> save,
    ) {
      final percent = '${(value * 100).round()}%';
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (context.isMornye)
              Text('$label: $percent')
            else
              SliderValueHeader(
                title: label,
                value: percent,
                enabled: widget.enabled,
              ),
            AppSlider(
              value: value,
              divisions: 20,
              label: percent,
              semanticLabel: label,
              onChanged: widget.enabled ? draft : null,
              onChangeEnd: widget.enabled ? save : null,
            ),
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        slider(
          l10n.musicHapticsSensitivity,
          _sensitivity ?? settings.musicHapticsSensitivity,
          (value) => setState(() => _sensitivity = value),
          (value) {
            notifier.setMusicHapticsSensitivity(value);
            setState(() => _sensitivity = null);
          },
        ),
        slider(
          l10n.musicHapticsStrength,
          _strength ?? settings.musicHapticsStrength,
          (value) => setState(() => _strength = value),
          (value) {
            notifier.setMusicHapticsStrength(value);
            setState(() => _strength = null);
          },
        ),
      ],
    );
  }
}
