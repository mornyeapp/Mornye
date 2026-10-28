import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/system_volume_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/desktop/desktop_volume_scroll.dart';
import 'package:mornye/widgets/mornye_player_slider.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/services/music_playback_deck.dart';

export 'package:mornye/providers/system_volume_provider.dart';

/// System (or USB hardware) volume slider for the player and USB settings.
/// Mornye draws its glass slider between speaker glyphs; Material draws the
/// expressive slider between volume icons.
class PlayerVolumeControl extends ConsumerStatefulWidget {
  const PlayerVolumeControl({super.key, this.foreground = Colors.white});

  /// Mornye only: the tint of the slider and glyphs over the player artwork.
  final Color foreground;

  @override
  ConsumerState<PlayerVolumeControl> createState() =>
      _PlayerVolumeControlState();
}

class _PlayerVolumeControlState extends ConsumerState<PlayerVolumeControl> {
  double? _preview;
  double? _pendingVolume;
  bool _dragging = false;
  bool _writing = false;

  void _setVolume(double value) {
    setState(() => _preview = value);
    _pendingVolume = value;
    if (!_writing) unawaited(_flushVolume());
  }

  Future<void> _flushVolume() async {
    _writing = true;
    final remote = ref.read(activeRemotePlaybackProvider);
    final write = remote == null
        ? ref.read(systemVolumeWriterProvider)
        : remote.setVolume;
    final usbToken = usbHardwareVolume.value?.token;
    try {
      // Send changes during the gesture. If the platform is still processing
      // a write, keep only the newest value instead of queuing stale positions.
      while (mounted && _pendingVolume != null) {
        if (usbHardwareVolume.value?.token != usbToken) {
          _pendingVolume = null;
          break;
        }
        final value = _pendingVolume!;
        _pendingVolume = null;
        try {
          await write(value);
        } catch (error) {
          AppLogger('PlayerVolume').w('Could not set system volume: $error');
        }
      }
    } finally {
      _writing = false;
      if (mounted && !_dragging) setState(() => _preview = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    // While another device plays in this one's place, the slider sets its
    // volume.
    final remote = ref.watch(activeRemotePlaybackProvider) != null;
    final usb = remote
        ? null
        : ref.watch(usbVolumeProvider).value ?? usbHardwareVolume.value;
    final volume = remote
        ? ref.watch(activeRemoteVolumeProvider).value
        : usb == null
        ? ref.watch(systemVolumeProvider).value
        : usb.available
        ? usb.fraction
        : null;
    final value = (_preview ?? volume ?? 0).clamp(0.0, 1.0);
    String percentage(double volume) => '${(volume * 100).round()}%';
    final control = Semantics(
      label: usb == null
          ? context.l10n.nowPlayingVolume
          : context.l10n.usbHardwareVolume,
      slider: true,
      enabled: volume != null,
      excludeSemantics: true,
      value: volume == null ? null : percentage(value),
      increasedValue: volume == null
          ? null
          : percentage((value + 0.05).clamp(0, 1)),
      decreasedValue: volume == null
          ? null
          : percentage((value - 0.05).clamp(0, 1)),
      onIncrease: volume == null
          ? null
          : () => _setVolume((value + 0.05).clamp(0, 1)),
      onDecrease: volume == null
          ? null
          : () => _setVolume((value - 0.05).clamp(0, 1)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: !context.isMornye
            ? _materialSlider(context, value, enabled: volume != null)
            : Row(
                children: [
                  Icon(
                    CupertinoIcons.speaker_fill,
                    size: 16,
                    color: widget.foreground.withValues(alpha: 0.54),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) => IgnorePointer(
                        ignoring: volume == null,
                        child: Opacity(
                          opacity: volume == null ? 0.4 : 1,
                          child: MornyePlayerSlider(
                            value: value,
                            activeColor: widget.foreground.withValues(
                              alpha: 0.70,
                            ),
                            inactiveColor: widget.foreground.withValues(
                              alpha: 0.12,
                            ),
                            onChangeStart: (_) => _dragging = true,
                            onChanged: _setVolume,
                            onChangeEnd: (value) {
                              _dragging = false;
                              _setVolume(value);
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(
                    CupertinoIcons.speaker_3_fill,
                    size: 16,
                    color: widget.foreground.withValues(alpha: 0.54),
                  ),
                ],
              ),
      ),
    );
    return DesktopVolumeScroll(child: control);
  }

  /// The expressive slider has no drag-start callback, so the pointer marks
  /// the drag that keeps system-volume echoes from resetting the thumb.
  Widget _materialSlider(
    BuildContext context,
    double value, {
    required bool enabled,
  }) {
    final colors = Theme.of(context).colorScheme;
    void release() {
      if (!_dragging) return;
      _dragging = false;
      if (!_writing && mounted) setState(() => _preview = null);
    }

    return Row(
      children: [
        AppIcon(
          value <= 0 ? Icons.volume_mute_rounded : Icons.volume_down_rounded,
          size: 20,
          color: colors.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: IgnorePointer(
            ignoring: !enabled,
            child: Opacity(
              opacity: enabled ? 1 : 0.4,
              child: Listener(
                onPointerDown: (_) => _dragging = true,
                onPointerUp: (_) => release(),
                onPointerCancel: (_) => release(),
                child: AppSlider(
                  // As thin as the seek bar above it, with a shorter handle,
                  // so volume stays secondary to it.
                  trackThickness: 4,
                  thumbLength: 20,
                  value: value,
                  onChanged: enabled ? _setVolume : null,
                  onChangeEnd: _setVolume,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        AppIcon(
          Icons.volume_up_rounded,
          size: 20,
          color: colors.onSurfaceVariant,
        ),
      ],
    );
  }
}
