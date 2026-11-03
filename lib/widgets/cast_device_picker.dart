import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/cast_output.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_snack_bar.dart';

/// Google Cast receivers for platforms without Google's device dialog (iOS
/// and desktop). Looks for receivers while open; a row connects on tap and
/// closes the sheet, and a connected session offers Stop Casting.
Future<void> showCastDevicePicker(BuildContext context, {CastOutput? output}) =>
    showAppBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      title: context.l10n.audioOutputCast,
      subtitle: context.l10n.audioOutputCastDescription,
      builder: (context) =>
          CastDeviceList(output: output ?? CastOutput.instance),
    );

class CastDeviceList extends StatefulWidget {
  const CastDeviceList({super.key, required this.output});

  final CastOutput output;

  @override
  State<CastDeviceList> createState() => _CastDeviceListState();
}

class _CastDeviceListState extends State<CastDeviceList> {
  String? _connecting;

  @override
  void initState() {
    super.initState();
    unawaited(_discover(true));
  }

  @override
  void dispose() {
    unawaited(_discover(false));
    super.dispose();
  }

  Future<void> _discover(bool on) async {
    try {
      await widget.output.discover(on);
    } on Object catch (error) {
      AppLogger(
        'Cast',
      ).w('Could not ${on ? 'start' : 'stop'} discovery: $error');
    }
  }

  Future<void> _connect(CastDevice device) async {
    if (_connecting != null) return;
    final output = widget.output;
    if (output.connected && output.deviceId == device.id) {
      Navigator.pop(context);
      return;
    }
    setState(() => _connecting = device.id);
    try {
      // The player moves its queue to the TV once the session reports in.
      if (identical(output, CastOutput.instance)) await initMusicPlayer();
      await output.connect(device.id);
      if (mounted) Navigator.pop(context);
    } on Object catch (error) {
      AppLogger('Cast').w('Could not connect to ${device.name}: $error');
      if (!mounted) return;
      setState(() => _connecting = null);
      showAppSnackBar(
        context,
        content: Text(context.l10n.audioOutputCastConnectFailed(device.name)),
      );
    }
  }

  Future<void> _stop() async {
    try {
      await widget.output.command('disconnect');
    } on Object catch (error) {
      AppLogger('Cast').w('Could not end Cast session: $error');
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: widget.output,
      builder: (context, _) {
        final output = widget.output;
        final devices = output.devices;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final device in devices)
              AppSheetOption.choice(
                key: ValueKey('cast-device-${device.id}'),
                title: Text(device.name),
                subtitle: device.model.isEmpty ? null : Text(device.model),
                leading: _connecting == device.id
                    ? const AppLoadingIndicator(size: 24, strokeWidth: 2.5)
                    : AppIcon(
                        output.connected && output.deviceId == device.id
                            ? Icons.cast_connected
                            : Icons.cast,
                      ),
                selected: output.connected && output.deviceId == device.id,
                onTap: () => _connect(device),
              ),
            if (devices.isEmpty)
              Padding(
                key: const ValueKey('cast-device-searching'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 20,
                ),
                child: Row(
                  children: [
                    const AppLoadingIndicator(size: 24, strokeWidth: 2.5),
                    const SizedBox(width: 16),
                    Expanded(child: Text(l10n.audioOutputCastSearching)),
                  ],
                ),
              ),
            if (output.connected)
              AppSheetOption(
                key: const ValueKey('cast-stop'),
                title: Text(l10n.audioOutputStopCasting),
                leading: const AppIcon(Icons.stop_circle_outlined),
                onTap: _stop,
              ),
          ],
        );
      },
    );
  }
}
