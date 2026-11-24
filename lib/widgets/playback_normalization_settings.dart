import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_choice_chip.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/slider_value_header.dart';

/// Gain mode and pre-amp shown under the volume normalization switch.
class PlaybackNormalizationSettings extends ConsumerStatefulWidget {
  const PlaybackNormalizationSettings({super.key, required this.enabled});

  final bool enabled;

  @override
  ConsumerState<PlaybackNormalizationSettings> createState() =>
      _PlaybackNormalizationSettingsState();
}

class _PlaybackNormalizationSettingsState
    extends ConsumerState<PlaybackNormalizationSettings> {
  /// ReplayGain 2.0 reference loudness the gain tags are written against.
  static const _referenceLufs = -18;

  double? _preamp;

  static String _signed(int value) => value > 0 ? '+$value' : '$value';

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(
      settingsProvider.select((s) => s.playbackNormalizationMode),
    );
    final savedPreamp = ref.watch(
      settingsProvider.select((s) => s.playbackNormalizationPreamp),
    );
    final notifier = ref.read(settingsProvider.notifier);
    final l10n = context.l10n;
    final preamp = (_preamp ?? savedPreamp).round();
    final value = l10n.playbackNormalizationPreampValue(
      _signed(preamp),
      '${_referenceLufs + preamp}',
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.playbackNormalizationMode),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final (id, label) in [
                ('track', l10n.playbackNormalizationModeTrack),
                ('album', l10n.playbackNormalizationModeAlbum),
              ])
                AppChoiceChip(
                  label: Text(label),
                  selected: mode == id,
                  singleChoice: true,
                  onSelected: widget.enabled
                      ? (_) => notifier.setPlaybackNormalizationMode(id)
                      : null,
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (context.isMornye)
            Text('${l10n.playbackNormalizationPreamp}: $value')
          else
            SliderValueHeader(
              title: l10n.playbackNormalizationPreamp,
              value: value,
              enabled: widget.enabled,
            ),
          AppSlider(
            value: preamp.toDouble(),
            min: -15,
            max: 6,
            divisions: 21,
            label: '${_signed(preamp)} dB',
            semanticLabel: l10n.playbackNormalizationPreamp,
            onChanged: widget.enabled
                ? (value) => setState(() => _preamp = value)
                : null,
            onChangeEnd: widget.enabled
                ? (value) {
                    notifier.setPlaybackNormalizationPreamp(value);
                    setState(() => _preamp = null);
                  }
                : null,
          ),
          Text(
            l10n.playbackNormalizationPreampHint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
