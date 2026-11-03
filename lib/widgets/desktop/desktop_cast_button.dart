import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/cast_output.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/cast_device_picker.dart';

/// Opens the Google Cast receivers on the network. The glyph shows an active
/// session, whose name the tooltip gives.
class DesktopCastButton extends StatelessWidget {
  const DesktopCastButton({super.key, this.output});

  /// The Cast session; [CastOutput.instance] when null.
  final CastOutput? output;

  @override
  Widget build(BuildContext context) {
    final output = this.output ?? CastOutput.instance;
    return ListenableBuilder(
      listenable: output,
      builder: (context, _) {
        final mornye = context.isMornye;
        final colorScheme = Theme.of(context).colorScheme;
        return AppIconButton(
          key: const ValueKey('desktop-cast-button'),
          tooltip: output.connected
              ? output.deviceName ?? context.l10n.audioOutputCast
              : context.l10n.audioOutputCast,
          color: output.connected
              ? colorScheme.primary
              : mornye
              ? colorScheme.onSurface
              : null,
          icon: AppIcon(
            output.connected ? Icons.cast_connected : Icons.cast,
            size: mornye ? 18 : 24,
          ),
          onPressed: () => showCastDevicePicker(context, output: output),
        );
      },
    );
  }
}
