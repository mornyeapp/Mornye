import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/system_volume_provider.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/logger.dart';

/// Scrolls the desktop app's output volume over a speaker or volume slider.
class DesktopVolumeScroll extends ConsumerWidget {
  const DesktopVolumeScroll({super.key, required this.child});

  final Widget child;

  Future<void> _changeVolume(WidgetRef ref, double delta) async {
    // Read the live gain on every event so rapid wheel ticks accumulate even
    // before the volume stream has rebuilt the controls.
    final current = playbackOutputVolume.value;
    final next = (current + (delta < 0 ? 0.05 : -0.05)).clamp(0.0, 1.0);
    if (next == current) return;
    try {
      await ref.read(systemVolumeWriterProvider)(next);
    } catch (error) {
      AppLogger('PlayerVolume').w('Could not set desktop volume: $error');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isDesktopPlatform) return child;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent ||
            !event.scrollDelta.dy.isFinite ||
            event.scrollDelta.dy == 0) {
          return;
        }
        GestureBinding.instance.pointerSignalResolver.register(event, (_) {
          unawaited(_changeVolume(ref, event.scrollDelta.dy));
        });
      },
      child: child,
    );
  }
}
