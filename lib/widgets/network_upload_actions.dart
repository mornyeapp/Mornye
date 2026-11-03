import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/network_offline_provider.dart';
import 'package:mornye/providers/network_upload_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/network_storage_screen.dart';
import 'package:mornye/services/network_library_upload.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';

/// Whether "Upload to network storage" applies to [items]: some are files on
/// this device and a saved connection accepts uploads. [connections] is the
/// [networkUploadConnectionsProvider] value, null while it loads.
bool networkUploadOffered(
  List<NetworkConnection>? connections,
  Iterable<UnifiedLibraryItem> items,
) => (connections?.isNotEmpty ?? false) && items.any(canUploadLibraryItem);

/// Asks where to upload [items], then uploads them with the progress sheet.
/// While an upload runs, it shows that upload's progress instead.
Future<void> uploadToNetworkStorage(
  BuildContext context,
  WidgetRef ref,
  List<UnifiedLibraryItem> items,
) async {
  // Menus and selection bars close as this starts, so their ref may go.
  final container = ProviderScope.containerOf(context, listen: false);
  final root = Navigator.of(context, rootNavigator: true).context;
  if (container.read(networkUploadProvider) == null) {
    if (!items.any(canUploadLibraryItem)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.networkUploadNoSongs)),
      );
      return;
    }
    final folder = await chooseNetworkUploadFolder(root, container);
    if (folder == null || !root.mounted) return;
    final messenger = ScaffoldMessenger.of(root);
    final l10n = root.l10n;
    final controller = container.read(networkUploadProvider.notifier);
    unawaited(() async {
      try {
        final result = await controller.upload(items, folder);
        if (result != null && messenger.mounted) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                result.cancelled
                    ? l10n.networkUploadCancelled
                    : l10n.networkUploadResult(
                        result.saved,
                        result.skipped,
                        result.failed,
                      ),
              ),
            ),
          );
        }
      } on NetworkUploadReadOnly {
        if (messenger.mounted) {
          messenger.showSnackBar(
            SnackBar(content: Text(l10n.networkUploadReadOnly)),
          );
        }
      } catch (_) {
        if (messenger.mounted) {
          messenger.showSnackBar(
            SnackBar(content: Text(l10n.networkUploadFailed)),
          );
        }
      }
    }());
  }
  if (!root.mounted) return;
  await showAppBottomSheet<void>(
    context: root,
    useRootNavigator: true,
    title: root.l10n.networkUploading,
    builder: (_) => const _UploadProgress(),
  );
}

/// The network download destination when it accepts uploads, or a
/// connection whose folders the person then browses. Null when cancelled.
Future<String?> chooseNetworkUploadFolder(
  BuildContext context,
  ProviderContainer container,
) async {
  final List<NetworkConnection> connections;
  try {
    connections = await container.read(networkUploadConnectionsProvider.future);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.networkUploadFailed)));
    }
    return null;
  }
  if (!context.mounted) return null;
  if (connections.isEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.networkUploadReadOnly)));
    return null;
  }
  final settings = container.read(settingsProvider);
  final destination =
      canUploadToNetworkFolder(settings.networkDownloadFolder, connections)
      ? settings.networkDownloadFolder
      : null;
  final choice = await showAppBottomSheet<Object>(
    context: context,
    useRootNavigator: true,
    title: context.l10n.networkUpload,
    builder: (sheetContext) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (destination != null)
          AppSheetOption(
            leading: const AppIcon.adaptive(Icons.download_outlined),
            title: Text(settings.networkDownloadLabel),
            subtitle: Text(sheetContext.l10n.networkDownloadDestination),
            onTap: () => Navigator.pop(sheetContext, destination),
          ),
        for (final connection in connections)
          AppSheetOption(
            leading: const AppIcon.adaptive(Icons.dns_outlined),
            title: Text(connection.name),
            subtitle: Text(sheetContext.l10n.networkUploadChooseFolder),
            trailing: const AppIcon.adaptive(Icons.chevron_right),
            onTap: () => Navigator.pop(sheetContext, connection),
          ),
        const SizedBox(height: 8),
      ],
    ),
  );
  if (choice is String) return choice;
  if (choice is NetworkConnection && context.mounted) {
    return browseNetworkUploadFolder(
      context,
      choice,
      service: container.read(networkOfflineStorageProvider),
    );
  }
  return null;
}

class _UploadProgress extends ConsumerStatefulWidget {
  const _UploadProgress();

  @override
  ConsumerState<_UploadProgress> createState() => _UploadProgressState();
}

class _UploadProgressState extends ConsumerState<_UploadProgress> {
  bool _closing = false;

  @override
  Widget build(BuildContext context) {
    final progress = ref.watch(networkUploadProvider);
    if (progress == null && !_closing) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.of(context).pop();
        }
      });
    }
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            progress?.title ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),
          AppProgressIndicator.linear(value: progress?.fraction),
          const SizedBox(height: 8),
          Text('${progress?.done ?? 0} / ${progress?.total ?? 0}'),
          const SizedBox(height: 16),
          AppSheetOption(
            title: Text(context.l10n.dialogCancel),
            onTap: () => ref.read(networkUploadProvider.notifier).cancel(),
          ),
        ],
      ),
    );
  }
}

/// The album header action: uploads the album's songs on this device.
class NetworkUploadButton extends ConsumerWidget {
  const NetworkUploadButton({super.key, required this.items});
  final List<UnifiedLibraryItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connections = ref.watch(networkUploadConnectionsProvider).value;
    if (!networkUploadOffered(connections, items)) {
      return const SizedBox.shrink();
    }
    return HeaderCircleButton(
      icon: Icons.cloud_upload_outlined,
      tooltip: context.l10n.networkUpload,
      onPressed: () => uploadToNetworkStorage(context, ref, items),
    );
  }
}
