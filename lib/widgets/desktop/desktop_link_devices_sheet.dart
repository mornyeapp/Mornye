import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/link_library_jobs.dart';
import 'package:mornye/services/link/link_transfers.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/desktop/desktop_link_library_jobs_view.dart';
import 'package:mornye/widgets/link/link_transfers_view.dart';
import 'package:mornye/widgets/settings_group.dart';

Future<void> showDesktopLinkDevicesSheet(BuildContext context) =>
    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.linkDevicesTitle,
      builder: (context, scroll) =>
          DesktopLinkDevicesSheet(scrollController: scroll),
    );

/// Desktop counterpart of the phone's Devices sheet. The main player drives
/// the selected device, so this sheet needs no separate transport controls.
class DesktopLinkDevicesSheet extends ConsumerWidget {
  const DesktopLinkDevicesSheet({super.key, this.scrollController});

  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(linkDesktopHostProvider);
    final host = ref.read(linkDesktopHostProvider.notifier);
    final transfers = ref.watch(linkTransfersProvider);
    final l10n = context.l10n;
    final check = AppIcon(
      Icons.check,
      color: Theme.of(context).colorScheme.primary,
    );

    void choose(Future<bool> Function() action) {
      final root = Navigator.of(context, rootNavigator: true).context;
      Navigator.pop(context);
      unawaited(() async {
        try {
          if (await action()) return;
        } on Object {
          // The selected player stays in place when delivery fails.
        }
        if (root.mounted) {
          showAppSnackBar(root, content: Text(l10n.linkDesktopNotDelivered));
        }
      }());
    }

    void open(Future<void> Function(BuildContext) show) {
      final root = Navigator.of(context, rootNavigator: true).context;
      Navigator.pop(context);
      unawaited(show(root));
    }

    final activeJobs = state.libraryJobs
        .where(
          (entry) =>
              entry.job.active &&
              entry.job.action != LinkLibraryAction.readMetadata &&
              entry.job.action != LinkLibraryAction.reEnrichPreview,
        )
        .length;
    return SingleChildScrollView(
      key: const ValueKey('desktop-link-devices-sheet'),
      controller: scrollController,
      padding: EdgeInsets.only(bottom: context.tokens.gapMd),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsGroup(
            children: [
              SettingsItem(
                key: const ValueKey('link-device-computer'),
                icon: Icons.computer,
                title: l10n.linkDesktopSectionComputer,
                subtitle: state.name,
                selected: state.followedPhone == null,
                trailing: state.followedPhone == null ? check : null,
                onTap: state.followedPhone == null
                    ? null
                    : () => choose(host.continueOnComputer),
                showDivider: state.clients.isNotEmpty,
              ),
              for (final (i, client) in state.clients.indexed)
                SettingsItem(
                  key: ValueKey('link-device-phone-${client.deviceId}'),
                  icon: Icons.phone_android,
                  title: client.name,
                  subtitle: l10n.linkConnectionConnected,
                  selected: state.followedPhone == client.deviceId,
                  trailing: state.followedPhone == client.deviceId
                      ? check
                      : null,
                  onTap: state.followedPhone == client.deviceId
                      ? null
                      : () => choose(() async {
                          if (state.followedPhone == null &&
                              host.hasCurrentTrack) {
                            return host.continueOnPhone(client.deviceId);
                          }
                          return host.followPhone(client.deviceId);
                        }),
                  showDivider: i < state.clients.length - 1,
                ),
            ],
          ),
          SettingsGroup(
            children: [
              SettingsItem(
                key: const ValueKey('link-file-changes-entry'),
                icon: Icons.history,
                title: l10n.linkFileJobs,
                subtitle: l10n.linkDesktopFileJobsSubtitle,
                trailing: activeJobs == 0 ? null : Text('$activeJobs'),
                onTap: () => open(showDesktopLinkLibraryJobs),
                showDivider: transfers.isNotEmpty,
              ),
              if (transfers.isNotEmpty)
                SettingsItem(
                  key: const ValueKey('link-transfers-entry'),
                  icon: Icons.swap_horiz_rounded,
                  title: l10n.linkTransfersTitle,
                  subtitle: linkTransfersSummary(l10n, transfers),
                  onTap: () => open(showLinkTransfers),
                  showDivider: false,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
