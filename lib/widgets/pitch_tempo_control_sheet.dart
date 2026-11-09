import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';

/// Liquid Glass modal sheet for independent pitch (semitones) and tempo (BPM) control.
class PitchTempoControlSheet extends ConsumerStatefulWidget {
  const PitchTempoControlSheet({super.key});

  static Future<void> show(BuildContext context) =>
      showAppModalBottomSheet<void>(
        context: context,
        builder: (_) => const PitchTempoControlSheet(),
      );

  @override
  ConsumerState<PitchTempoControlSheet> createState() =>
      _PitchTempoControlSheetState();
}

class _PitchTempoControlSheetState
    extends ConsumerState<PitchTempoControlSheet> {
  late double _pitch;
  late double _speed;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _pitch = settings.playbackPitch;
    _speed = settings.playbackSpeed;
  }

  void _applySpeed(double speed) {
    setState(() => _speed = speed);
    ref.read(settingsProvider.notifier).setPlaybackSpeed(speed);
    ref.read(musicPlayerControllerProvider).setSpeed(speed);
  }

  void _applyPitch(double pitch) {
    setState(() => _pitch = pitch);
    ref.read(settingsProvider.notifier).setPlaybackPitch(pitch);
  }

  @override
  Widget build(BuildContext context) {
    final mornye = context.isMornye;
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.speed_rounded,
                    color: mornye ? Colors.white : scheme.primary,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Pitch & Tempo Shifter',
                    style: TextStyle(
                      fontFamily: AppTheme.bundledFontFamily,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: mornye ? Colors.white : scheme.onSurface,
                    ),
                  ),
                ],
              ),
              TextButton(
                onPressed: () {
                  _applyPitch(0.0);
                  _applySpeed(1.0);
                },
                child: Text(
                  'Ripristina',
                  style: TextStyle(
                    fontFamily: AppTheme.bundledFontFamily,
                    color: mornye
                        ? Colors.white.withValues(alpha: 0.75)
                        : scheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // --- PITCH CONTROLS ---
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: mornye
                  ? Colors.white.withValues(alpha: 0.06)
                  : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: mornye
                    ? Colors.white.withValues(alpha: 0.12)
                    : scheme.outlineVariant,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Tonalità (Pitch)',
                      style: TextStyle(
                        fontFamily: AppTheme.bundledFontFamily,
                        fontWeight: FontWeight.w600,
                        fontSize: 14.5,
                        color: mornye ? Colors.white : scheme.onSurface,
                      ),
                    ),
                    Text(
                      _pitch == 0.0
                          ? 'Standard (0 ST)'
                          : '${_pitch > 0 ? '+' : ''}${_pitch.toStringAsFixed(1)} ST',
                      style: TextStyle(
                        fontFamily: AppTheme.bundledFontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: mornye
                            ? const Color(0xff93c5fd)
                            : scheme.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Slider(
                  value: _pitch,
                  min: -12.0,
                  max: 12.0,
                  divisions: 24,
                  activeColor: mornye ? Colors.white : scheme.primary,
                  inactiveColor: mornye
                      ? Colors.white.withValues(alpha: 0.15)
                      : scheme.outlineVariant,
                  onChanged: _applyPitch,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // --- TEMPO / SPEED CONTROLS ---
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: mornye
                  ? Colors.white.withValues(alpha: 0.06)
                  : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: mornye
                    ? Colors.white.withValues(alpha: 0.12)
                    : scheme.outlineVariant,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Velocità (BPM / Tempo)',
                      style: TextStyle(
                        fontFamily: AppTheme.bundledFontFamily,
                        fontWeight: FontWeight.w600,
                        fontSize: 14.5,
                        color: mornye ? Colors.white : scheme.onSurface,
                      ),
                    ),
                    Text(
                      '${_speed.toStringAsFixed(2)}x',
                      style: TextStyle(
                        fontFamily: AppTheme.bundledFontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: mornye
                            ? const Color(0xff93c5fd)
                            : scheme.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Slider(
                  value: _speed,
                  min: 0.5,
                  max: 2.0,
                  divisions: 30,
                  activeColor: mornye ? Colors.white : scheme.primary,
                  inactiveColor: mornye
                      ? Colors.white.withValues(alpha: 0.15)
                      : scheme.outlineVariant,
                  onChanged: _applySpeed,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
