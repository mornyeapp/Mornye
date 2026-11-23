import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/cast_output.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_snack_bar.dart';

/// The protocol names of [kinds] (every named kind when null) as one phrase,
/// such as "Google Cast, DLNA and FCast".
String castKindNames(AppLocalizations l10n, [Set<CastKind>? kinds]) {
  var names = [
    for (final kind in CastKind.named)
      if (kinds == null || kinds.contains(kind)) kind.label!,
  ];
  if (names.isEmpty) names = [...?kinds?.map((kind) => kind.label).nonNulls];
  if (names.length < 2) return names.join();
  return l10n.audioOutputCastKindList(
    names.sublist(0, names.length - 1).join(', '),
    names.last,
  );
}

/// The app's own receiver list, of [kinds] or of every kind when null: all
/// of them on iOS and desktop, the ones Google's dialog does not offer on
/// Android. Looks for receivers while open; a row connects on tap and closes
/// the sheet, and a connected session offers Stop Casting.
Future<void> showCastDevicePicker(
  BuildContext context, {
  CastOutput? output,
  Set<CastKind>? kinds,
}) {
  final l10n = context.l10n;
  return showAppBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    title: kinds == null || kinds.contains(CastKind.cast)
        ? l10n.audioOutputCast
        : l10n.audioOutputCastOther,
    subtitle: l10n.audioOutputCastDescription(castKindNames(l10n, kinds)),
    builder: (context) =>
        CastDeviceList(output: output ?? CastOutput.instance, kinds: kinds),
  );
}

class CastDeviceList extends StatefulWidget {
  const CastDeviceList({super.key, required this.output, this.kinds});

  final CastOutput output;

  /// The kinds listed; every kind when null.
  final Set<CastKind>? kinds;

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
      await widget.output.discover(on, kinds: widget.kinds);
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
      // The player moves its queue to the receiver once the session reports in.
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

  static IconData _icon(CastKind kind, bool connected) => switch (kind) {
    CastKind.dlna => Icons.speaker_outlined,
    _ => connected ? Icons.cast_connected : Icons.cast,
  };

  /// The protocol, then the model when the receiver gives one.
  static Widget? _describe(CastDevice device) {
    final text = [
      ?device.kind.label,
      if (device.model.isNotEmpty) device.model,
    ].join(' · ');
    return text.isEmpty ? null : Text(text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final kinds = widget.kinds;
    return ListenableBuilder(
      listenable: widget.output,
      builder: (context, _) {
        final output = widget.output;
        final devices = [
          for (final device in output.devices)
            if (kinds == null || kinds.contains(device.kind)) device,
        ];
        // A session of a kind this sheet does not list belongs to another row.
        final connected =
            output.connected && (kinds == null || kinds.contains(output.kind));
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                    Expanded(
                      child: Text(
                        l10n.audioOutputCastSearching(
                          castKindNames(l10n, kinds),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (devices.isNotEmpty || connected)
              AppSheetOptions(
                children: [
                  for (final device in devices)
                    AppSheetOption.choice(
                      key: ValueKey('cast-device-${device.id}'),
                      title: Text(device.name),
                      subtitle: _describe(device),
                      leading: _connecting == device.id
                          ? const AppLoadingIndicator(
                              size: 24,
                              strokeWidth: 2.5,
                            )
                          : Icon(
                              _icon(
                                device.kind,
                                connected && output.deviceId == device.id,
                              ),
                            ),
                      selected: connected && output.deviceId == device.id,
                      onTap: () => _connect(device),
                    ),
                  if (connected)
                    AppSheetOption(
                      key: const ValueKey('cast-stop'),
                      title: Text(l10n.audioOutputStopCasting),
                      leading: const Icon(Icons.stop_circle_outlined),
                      onTap: _stop,
                    ),
                ],
              ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }
}
