import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/link_transfers.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/desktop/desktop_link_devices_sheet.dart';
import 'package:mornye/widgets/link/link_transfer_tile.dart';
import 'package:mornye/widgets/link/link_transfers_view.dart';

/// Opens the same device choices as the phone player. Active transfers ring
/// the glyph without changing the player bar's layout.
class DesktopLinkDevicesButton extends ConsumerWidget {
  const DesktopLinkDevicesButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(linkDevicesAvailableProvider)) {
      return const SizedBox.shrink();
    }
    final progress = ref.watch(
      linkTransfersProvider.select(linkTransfersProgress),
    );
    final mornye = context.isMornye;
    final size = mornye ? 18.0 : 24.0;
    final glyph = AppIcon(
      mornye ? CupertinoIcons.device_phone_portrait : Icons.phonelink,
      size: progress == null ? size : size * 0.75,
    );
    final outset = size / 6;
    return AppIconButton(
      key: const ValueKey('desktop-link-devices-button'),
      tooltip: context.l10n.linkDevicesTitle,
      color: mornye ? Theme.of(context).colorScheme.onSurface : null,
      onPressed: () => showDesktopLinkDevicesSheet(context),
      icon: progress == null
          ? glyph
          : SizedBox.square(
              dimension: size,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    left: -outset,
                    top: -outset,
                    right: -outset,
                    bottom: -outset,
                    child: LinkTransferRing(
                      key: const ValueKey('desktop-link-transfers-ring'),
                      value: progress,
                      strokeWidth: 2,
                    ),
                  ),
                  glyph,
                ],
              ),
            ),
    );
  }
}
