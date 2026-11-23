import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/cast_output.dart';
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/cast_device_picker.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';

enum _OutputChoice { system, cast, otherCast, disconnect }

/// One sheet for both kinds of output: the system's routes (Android's
/// output switcher, or AirPlay and Bluetooth on iOS) and casting. Android
/// opens Google's device dialog for Google Cast and the app's list for the
/// other kinds; iOS lists every kind in the app.
class AudioOutputButton extends StatefulWidget {
  const AudioOutputButton({
    super.key,
    this.color,
    this.backgroundColor,
    this.width = 48,
    this.onPickerChanged,
    this.output,
  });

  final Color? color;

  /// Fills a pill [width] wide behind the icon, as Material's player footer
  /// does beside its shuffle and repeat group; transparent when null.
  final Color? backgroundColor;
  final double width;
  final ValueChanged<bool>? onPickerChanged;

  /// The Cast session; [CastOutput.instance] when null.
  final CastOutput? output;

  @override
  State<AudioOutputButton> createState() => _AudioOutputButtonState();
}

class _AudioOutputButtonState extends State<AudioOutputButton> {
  static const _systemChannel = MethodChannel('com.zarz.mornye/audio_output');
  bool _opening = false;

  CastOutput get _output => widget.output ?? CastOutput.instance;

  bool get _ios => defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> _showPicker() async {
    if (_opening) return;
    _opening = true;
    widget.onPickerChanged?.call(true);
    var opened = false;
    _OutputChoice? chosen;
    try {
      final output = _output;
      // With Google's dialog, the Cast row is Google Cast only and a second
      // row lists the other kinds in the app.
      final split = output.nativePicker;
      final choice = await showAppBottomSheet<_OutputChoice>(
        context: context,
        title: context.l10n.nowPlayingAudioOutput,
        builder: (context) => ListenableBuilder(
          listenable: output,
          builder: (context, _) {
            final l10n = context.l10n;
            final other = output.kind != CastKind.cast;
            final castLive = output.connected && (!split || !other);
            final otherLive = split && output.connected && other;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppSheetOptions(
                  children: [
                    AppSheetOption(
                      title: Text(
                        _ios ? l10n.audioOutputAirPlay : l10n.audioOutputSystem,
                      ),
                      leading: Icon(
                        _ios ? Icons.airplay : Icons.speaker_group_outlined,
                      ),
                      onTap: () => Navigator.pop(context, _OutputChoice.system),
                    ),
                    AppSheetOption(
                      key: const ValueKey('audio-output-cast'),
                      title: Text(
                        castLive
                            ? output.deviceName ?? l10n.audioOutputCast
                            : l10n.audioOutputCast,
                      ),
                      subtitle: Text(
                        l10n.audioOutputCastDescription(
                          castKindNames(l10n, split ? {CastKind.cast} : null),
                        ),
                      ),
                      leading: Icon(
                        castLive ? Icons.cast_connected : Icons.cast,
                      ),
                      onTap: () => Navigator.pop(context, _OutputChoice.cast),
                    ),
                    if (split)
                      AppSheetOption(
                        key: const ValueKey('audio-output-cast-other'),
                        title: Text(
                          otherLive
                              ? output.deviceName ?? l10n.audioOutputCastOther
                              : l10n.audioOutputCastOther,
                        ),
                        subtitle: Text(
                          l10n.audioOutputCastDescription(
                            castKindNames(l10n, CastKind.others),
                          ),
                        ),
                        leading: Icon(
                          otherLive
                              ? Icons.cast_connected
                              : Icons.speaker_outlined,
                        ),
                        onTap: () =>
                            Navigator.pop(context, _OutputChoice.otherCast),
                      ),
                    if (output.connected)
                      AppSheetOption(
                        key: const ValueKey('audio-output-stop'),
                        title: Text(l10n.audioOutputStopCasting),
                        leading: const Icon(Icons.stop_circle_outlined),
                        onTap: () =>
                            Navigator.pop(context, _OutputChoice.disconnect),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      );
      if (choice == null || !mounted) return;
      chosen = choice;
      switch (choice) {
        case _OutputChoice.system:
          opened = await _systemChannel.invokeMethod<bool>('show') ?? false;
        case _OutputChoice.cast when output.nativePicker:
          await LocalNetworkAccess.instance.ensureGranted();
          await initMusicPlayer();
          opened = await output.showPicker();
        case _OutputChoice.cast:
          await showCastDevicePicker(context, output: output);
          opened = true;
        case _OutputChoice.otherCast:
          // Finding receivers from the app needs local network access.
          await LocalNetworkAccess.instance.ensureGranted();
          if (!mounted) return;
          await showCastDevicePicker(
            context,
            output: output,
            kinds: CastKind.others,
          );
          opened = true;
        case _OutputChoice.disconnect:
          await output.command('disconnect');
          opened = true;
      }
    } on PlatformException {
      // Show a visible failure instead of leaving an unresponsive control.
    } on MissingPluginException {
      // The native bridge is not available on unsupported builds.
    } on LocalNetworkPermissionException {
      // The picker can be opened again after network access is granted.
    } on Object catch (error) {
      AppLogger('AudioOutput').w('Could not open output picker: $error');
    } finally {
      _opening = false;
      if (mounted) widget.onPickerChanged?.call(false);
    }
    if (mounted && !opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(switch (chosen) {
            null || _OutputChoice.system =>
              context.l10n.nowPlayingAudioOutputUnavailable,
            // Only Google's dialog depends on Google Play services.
            _OutputChoice.cast when _output.nativePicker =>
              context.l10n.audioOutputCastUnavailable,
            _ => context.l10n.audioOutputCastNetworkUnavailable,
          }),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink();
    return switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS => ListenableBuilder(
        listenable: _output,
        builder: (context, _) => _button(context),
      ),
      _ => const SizedBox.shrink(),
    };
  }

  Widget _button(BuildContext context) {
    final icon = _output.connected
        ? Icons.cast_connected
        : _ios
        ? Icons.airplay
        : Icons.speaker_group_outlined;
    if (widget.backgroundColor case final background?) {
      return ExpressiveIconButton(
        tooltip: context.l10n.nowPlayingAudioOutput,
        width: widget.width,
        foregroundColor: widget.color,
        backgroundColor: background,
        icon: Icon(icon),
        onPressed: _showPicker,
      );
    }
    return AppIconButton(
      tooltip: context.l10n.nowPlayingAudioOutput,
      color: widget.color,
      icon: Icon(icon),
      onPressed: _showPicker,
    );
  }
}
