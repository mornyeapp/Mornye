import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/slider_value_header.dart';

/// The quick speed choices under the speed slider.
const playbackTempoQuickSpeeds = [0.75, 1.0, 1.25, 1.5];

/// Speed slider steps of 0.1x from 0.5x to 2x. Fewer stops keep the track
/// readable; the quick choices add 0.75x and 1.25x between them.
const _speedDivisions = 15;

/// Pitch slider steps of one semitone from -12 to +12.
const _pitchDivisions = 24;

/// [speed] on the 0.05 grid the slider steps and quick choices share.
double _snapSpeed(double speed) =>
    playbackSpeedFromJson((speed * 20).round() / 20);

/// [semitones] in whole semitones.
double _snapPitch(double semitones) => playbackPitchFromJson(semitones);

/// [speed] with its unit, such as `1.25x`, in the locale's number format.
String playbackSpeedLabel(AppLocalizations l10n, double speed) =>
    l10n.playbackTempoSpeedValue(
      NumberFormat('0.##', l10n.localeName).format(speed),
    );

/// [semitones] with its sign, such as `+2`, `−1` (a real minus sign) or
/// `0`, in the locale's number format.
String playbackPitchLabel(AppLocalizations l10n, double semitones) {
  final number = NumberFormat('0.#', l10n.localeName).format(semitones.abs());
  if (semitones > 0) return '+$number';
  if (semitones < 0) return '−$number';
  return number;
}

/// The `playbackSpeed`, `playbackKeepPitch` and `playbackPitch` settings.
final _tempoSettings = settingsProvider.select(
  (settings) => (
    settings.playbackSpeed,
    settings.playbackKeepPitch,
    settings.playbackPitch,
  ),
);

bool _isDefaultTempo(double speed, bool keepPitch, double pitch) =>
    speed == 1 && keepPitch && pitch == 0;

/// What the speed and pitch settings change, such as `1.25x, +2 semitones`
/// or `Pitch follows speed`; null at the defaults.
String? playbackTempoSummary(
  AppLocalizations l10n, {
  required double speed,
  required bool keepPitch,
  required double pitch,
}) {
  final parts = [
    if (speed != 1) playbackSpeedLabel(l10n, speed),
    if (!keepPitch) l10n.playbackTempoPitchFollows,
    if (pitch != 0)
      l10n.playbackTempoSemitones(pitch.abs(), playbackPitchLabel(l10n, pitch)),
  ];
  return parts.isEmpty ? null : parts.join(', ');
}

/// [playbackTempoSummary] of [settings], for menu rows.
String? playbackTempoSettingsSummary(
  AppLocalizations l10n,
  AppSettings settings,
) => playbackTempoSummary(
  l10n,
  speed: settings.playbackSpeed,
  keepPitch: settings.playbackKeepPitch,
  pitch: settings.playbackPitch,
);

/// Opens the Speed and pitch controls: a sheet on phones, a compact dialog
/// on desktop.
Future<void> showPlaybackTempoSheet(BuildContext context) =>
    showAppBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      title: context.l10n.playbackTempoTitle,
      maxHeightFactor: 0.85,
      dialogSize: AppDialogSize.compact,
      builder: (_) => const SingleChildScrollView(
        padding: EdgeInsets.only(bottom: 16),
        child: PlaybackTempoControls(),
      ),
    );

/// Speed, Keep pitch and pitch for every song. The sliders preview on the
/// shared [playbackSpeed] and [playbackPitch] while dragging and save on
/// release; [playbackTempoSupport] disables what the output can't do.
class PlaybackTempoControls extends ConsumerStatefulWidget {
  const PlaybackTempoControls({super.key});

  @override
  ConsumerState<PlaybackTempoControls> createState() =>
      _PlaybackTempoControlsState();
}

class _PlaybackTempoControlsState extends ConsumerState<PlaybackTempoControls> {
  double? _speedDraft;
  double? _pitchDraft;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: playbackTempoSupport,
    builder: (context, support, _) => _build(context, support),
  );

  Widget _build(BuildContext context, PlaybackTempoSupport support) {
    final (savedSpeed, keepPitch, savedPitch) = ref.watch(_tempoSettings);
    final notifier = ref.read(settingsProvider.notifier);
    final l10n = context.l10n;
    final tokens = context.tokens;
    final theme = Theme.of(context);
    final speedEnabled = support != PlaybackTempoSupport.none;
    final pitchEnabled = support == PlaybackTempoSupport.full;
    final speed = _snapSpeed(_speedDraft ?? savedSpeed);
    final pitch = _snapPitch(_pitchDraft ?? savedPitch);
    final speedLabel = playbackSpeedLabel(l10n, speed);
    final pitchLabel = playbackPitchLabel(l10n, pitch);
    final note = switch (support) {
      PlaybackTempoSupport.full => null,
      PlaybackTempoSupport.speedOnly => l10n.playbackTempoSpeedOnly,
      PlaybackTempoSupport.none => l10n.playbackTempoUnavailable,
    };
    final rowPadding = EdgeInsets.symmetric(
      horizontal: tokens.rowPaddingH,
      vertical: tokens.rowPaddingV,
    );
    final quickChoices = SettingsSegmentedChoice<double>(
      selected: speed,
      enabled: speedEnabled,
      semanticLabel: l10n.playbackTempoSpeed,
      onChanged: (value) {
        setState(() => _speedDraft = null);
        notifier.setPlaybackSpeed(value);
      },
      options: [
        for (final value in playbackTempoQuickSpeeds)
          SettingsSegmentOption(
            value: value,
            label: playbackSpeedLabel(l10n, value),
          ),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (note != null)
          Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              tokens.gapXl,
              0,
              tokens.gapXl,
              tokens.gapSm,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppIcon.adaptive(
                  Icons.info_outline,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                SizedBox(width: tokens.gapSm),
                Expanded(
                  child: Text(
                    note,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        SettingsGroup(
          connected: true,
          children: [
            Padding(
              padding: rowPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SliderValueHeader(
                    title: l10n.playbackTempoSpeed,
                    value: speedLabel,
                    enabled: speedEnabled,
                  ),
                  AppSlider(
                    key: const ValueKey('playback-speed-slider'),
                    value: speed,
                    min: minPlaybackSpeed,
                    max: maxPlaybackSpeed,
                    divisions: _speedDivisions,
                    label: speedLabel,
                    semanticLabel: l10n.playbackTempoSpeed,
                    semanticFormatterCallback: (value) =>
                        playbackSpeedLabel(l10n, _snapSpeed(value)),
                    onChanged: speedEnabled
                        ? (value) {
                            final snapped = _snapSpeed(value);
                            playbackSpeed.value = snapped;
                            setState(() => _speedDraft = snapped);
                          }
                        : null,
                    onChangeEnd: speedEnabled
                        ? (value) {
                            notifier.setPlaybackSpeed(_snapSpeed(value));
                            setState(() => _speedDraft = null);
                          }
                        : null,
                  ),
                  SizedBox(height: tokens.gapSm),
                  quickChoices,
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: tokens.gapSm),
        SettingsGroup(
          connected: true,
          children: [
            SettingsSwitchItem(
              title: l10n.playbackTempoKeepPitch,
              subtitle: l10n.playbackTempoKeepPitchDescription,
              value: keepPitch,
              enabled: pitchEnabled,
              onChanged: notifier.setPlaybackKeepPitch,
            ),
            Padding(
              padding: rowPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SliderValueHeader(
                    title: l10n.playbackTempoPitch,
                    value: pitchLabel,
                    enabled: pitchEnabled,
                  ),
                  AppSlider(
                    key: const ValueKey('playback-pitch-slider'),
                    value: pitch,
                    min: -maxPlaybackPitch,
                    max: maxPlaybackPitch,
                    divisions: _pitchDivisions,
                    centered: true,
                    label: pitchLabel,
                    semanticLabel: l10n.playbackTempoPitch,
                    semanticFormatterCallback: (value) =>
                        playbackPitchLabel(l10n, _snapPitch(value)),
                    onChanged: pitchEnabled
                        ? (value) {
                            final snapped = _snapPitch(value);
                            playbackPitch.value = PlaybackPitch(
                              semitones: snapped,
                              followsRate: !keepPitch,
                            );
                            setState(() => _pitchDraft = snapped);
                          }
                        : null,
                    onChangeEnd: pitchEnabled
                        ? (value) {
                            notifier.setPlaybackPitch(_snapPitch(value));
                            setState(() => _pitchDraft = null);
                          }
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            tokens.gapXl,
            tokens.gapSm,
            tokens.gapXl,
            0,
          ),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: ExpressiveButton(
              text: true,
              icon: const AppIcon(Icons.restart_alt),
              onPressed:
                  !speedEnabled || _isDefaultTempo(speed, keepPitch, pitch)
                  ? null
                  : () {
                      setState(() {
                        _speedDraft = null;
                        _pitchDraft = null;
                      });
                      notifier.resetPlaybackTempo();
                    },
              child: Text(l10n.playbackTempoReset),
            ),
          ),
        ),
      ],
    );
  }
}

/// The speed and pitch in Now Playing while either differs from normal,
/// beside the audio format and in Material's compact player; a tap opens
/// [showPlaybackTempoSheet].
class PlaybackTempoBadge extends ConsumerWidget {
  const PlaybackTempoBadge({super.key, required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (speed, keepPitch, pitch) = ref.watch(_tempoSettings);
    if (speed == 1 && pitch == 0) return const SizedBox.shrink();
    final l10n = context.l10n;
    final text = [
      if (speed != 1) playbackSpeedLabel(l10n, speed),
      if (pitch != 0) playbackPitchLabel(l10n, pitch),
    ].join(' · ');
    final label = [
      l10n.playbackTempoTitle,
      ?playbackTempoSummary(
        l10n,
        speed: speed,
        keepPitch: keepPitch,
        pitch: pitch,
      ),
    ].join(', ');
    // Styled like the audio format label beside it.
    final mornye = context.isMornye;
    final radius = BorderRadius.circular(20);
    final pill = Container(
      padding: EdgeInsets.symmetric(
        horizontal: mornye ? 8 : 10,
        vertical: mornye ? 2 : 5,
      ),
      decoration: mornye
          ? null
          : BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: radius,
            ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon.adaptive(
            Icons.speed,
            size: mornye ? 11 : 14,
            color: colorScheme.onSurfaceVariant,
          ),
          SizedBox(width: mornye ? 5 : 6),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontSize: mornye ? 10.5 : 12,
                color: colorScheme.onSurfaceVariant,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 4),
      child: Semantics(
        button: true,
        label: label,
        child: Tooltip(
          message: label,
          excludeFromSemantics: true,
          child: Material(
            key: const ValueKey('playback-tempo-badge'),
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: radius,
              onTap: () => showPlaybackTempoSheet(context),
              child: pill,
            ),
          ),
        ),
      ),
    );
  }
}
