import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/cast_output.dart';
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';

enum _OutputChoice { system, cast, disconnect }

/// System routes and Google Cast have separate native device pickers.
class AudioOutputButton extends StatefulWidget {
  const AudioOutputButton({
    super.key,
    this.color,
    this.backgroundColor,
    this.width = 48,
    this.onPickerChanged,
  });

  final Color? color;

  /// Fills a pill [width] wide behind the icon, as Material's player footer
  /// does beside its shuffle and repeat group; transparent when null.
  final Color? backgroundColor;
  final double width;
  final ValueChanged<bool>? onPickerChanged;

  @override
  State<AudioOutputButton> createState() => _AudioOutputButtonState();
}

class _AudioOutputButtonState extends State<AudioOutputButton> {
  static const _androidChannel = MethodChannel('com.zarz.mornye/audio_output');
  MethodChannel? _viewChannel;
  bool _opening = false;

  Map<String, Object> get _appearance => {
    'color': (widget.color ?? Theme.of(context).colorScheme.onSurface)
        .toARGB32(),
    'label': context.l10n.nowPlayingAudioOutput,
  };

  @override
  void didUpdateWidget(AudioOutputButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateAppearance();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateAppearance();
  }

  void _updateAppearance() {
    final channel = _viewChannel;
    if (channel != null) {
      unawaited(channel.invokeMethod<void>('update', _appearance));
    }
  }

  void _attachView(int id) {
    _viewChannel?.setMethodCallHandler(null);
    _viewChannel = MethodChannel('com.zarz.mornye/audio_output/$id')
      ..setMethodCallHandler((call) async {
        if (mounted && call.method == 'pickerChanged') {
          widget.onPickerChanged?.call(call.arguments == true);
        }
      });
    _updateAppearance();
  }

  Future<void> _showAndroidPicker() async {
    if (_opening) return;
    _opening = true;
    widget.onPickerChanged?.call(true);
    var opened = false;
    var casting = false;
    try {
      final choice = await showAppBottomSheet<_OutputChoice>(
        context: context,
        title: context.l10n.nowPlayingAudioOutput,
        builder: (context) => ListenableBuilder(
          listenable: CastOutput.instance,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppSheetOption(
                title: Text(context.l10n.audioOutputSystem),
                leading: const Icon(Icons.speaker_group_outlined),
                onTap: () => Navigator.pop(context, _OutputChoice.system),
              ),
              AppSheetOption(
                title: Text(
                  CastOutput.instance.deviceName ??
                      context.l10n.audioOutputCast,
                ),
                subtitle: Text(context.l10n.audioOutputCastDescription),
                leading: Icon(
                  CastOutput.instance.connected
                      ? Icons.cast_connected
                      : Icons.cast,
                ),
                onTap: () => Navigator.pop(context, _OutputChoice.cast),
              ),
              if (CastOutput.instance.connected)
                AppSheetOption(
                  title: Text(context.l10n.audioOutputStopCasting),
                  leading: const Icon(Icons.stop_circle_outlined),
                  onTap: () => Navigator.pop(context, _OutputChoice.disconnect),
                ),
            ],
          ),
        ),
      );
      if (choice == null || !mounted) return;
      casting = choice != _OutputChoice.system;
      switch (choice) {
        case _OutputChoice.system:
          opened = await _androidChannel.invokeMethod<bool>('show') ?? false;
        case _OutputChoice.cast:
          await LocalNetworkAccess.instance.ensureGranted();
          await initMusicPlayer();
          opened = await CastOutput.instance.showPicker();
        case _OutputChoice.disconnect:
          await CastOutput.instance.command('disconnect');
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
          content: Text(
            casting
                ? context.l10n.audioOutputCastUnavailable
                : context.l10n.nowPlayingAudioOutputUnavailable,
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _viewChannel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink();
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        final picker = SizedBox.square(
          dimension: 48,
          child: UiKitView(
            viewType: 'com.zarz.mornye/audio_output',
            creationParams: _appearance,
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: _attachView,
          ),
        );
        final background = widget.backgroundColor;
        if (background == null) return picker;
        return DecoratedBox(
          decoration: ShapeDecoration(
            color: background,
            shape: const StadiumBorder(),
          ),
          child: SizedBox(
            width: widget.width,
            height: 48,
            child: Center(child: picker),
          ),
        );
      case TargetPlatform.android:
        return ListenableBuilder(
          listenable: CastOutput.instance,
          builder: (context, _) => _androidButton(context),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _androidButton(BuildContext context) {
    final icon = CastOutput.instance.connected
        ? Icons.cast_connected
        : Icons.speaker_group_outlined;
    if (widget.backgroundColor case final background?) {
      return ExpressiveIconButton(
        tooltip: context.l10n.nowPlayingAudioOutput,
        width: widget.width,
        foregroundColor: widget.color,
        backgroundColor: background,
        icon: Icon(icon),
        onPressed: _showAndroidPicker,
      );
    }
    return AppIconButton(
      tooltip: context.l10n.nowPlayingAudioOutput,
      color: widget.color,
      icon: Icon(icon),
      onPressed: _showAndroidPicker,
    );
  }
}
