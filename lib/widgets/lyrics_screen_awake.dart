import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LyricsScreenAwake');

/// Holds only the visible lyrics screen awake, never background audio playback.
class LyricsScreenAwake extends ConsumerStatefulWidget {
  const LyricsScreenAwake({
    required this.visible,
    required this.child,
    super.key,
  });

  final bool visible;
  final Widget child;

  @override
  ConsumerState<LyricsScreenAwake> createState() => _LyricsScreenAwakeState();
}

class _LyricsScreenAwakeState extends ConsumerState<LyricsScreenAwake>
    with WidgetsBindingObserver {
  bool _wanted = false;
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _update({bool force = false}) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final enabled =
        _wanted &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
    if (!force && enabled == _requested) return;
    _requested = enabled;
    unawaited(_setAwake(enabled));
  }

  Future<void> _setAwake(bool enabled) async {
    try {
      await PlatformBridge.setScreenAwake(enabled);
    } catch (error) {
      _log.w('Could not update screen timeout: $error');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Reapply after resuming: Android may have recreated the Activity/window.
    _update(force: state == AppLifecycleState.resumed);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(
      settingsProvider.select((settings) => settings.keepScreenOnLyrics),
    );
    _wanted =
        widget.visible && enabled && (ModalRoute.isCurrentOf(context) ?? true);
    _update();
    return widget.child;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_requested) unawaited(_setAwake(false));
    super.dispose();
  }
}
