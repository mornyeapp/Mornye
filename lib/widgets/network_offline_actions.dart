import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/link/features/link_library_lookup.dart';
import 'package:mornye/providers/deleted_library_files.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/utils/file_access.dart' show deleteFile, fileExists;
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/providers/network_offline_provider.dart';
import 'package:mornye/services/network_offline_saver.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/link/link_library_actions.dart';
import 'package:mornye/services/link/link_library_jobs.dart';

export 'package:mornye/services/network_offline_saver.dart'
    show canSaveNetworkOfflineSource;

String offlineDeviceFilterLabel(BuildContext context) =>
    switch (defaultTargetPlatform) {
      TargetPlatform.iOS => context.l10n.offlineOnIPhone,
      TargetPlatform.android => context.l10n.offlineOnPhone,
      _ => context.l10n.offlineOnDevice,
    };

Future<void> savePlayingNetworkOffline(
  BuildContext context,
  WidgetRef ref,
  MediaItem media,
) async {
  final source = media.extras?['source']?.toString() ?? '';
  if (!source.startsWith('network://')) return;
  final history = await ref
      .read(downloadHistoryProvider.notifier)
      .getByFilePathAsync(source);
  if (!context.mounted) return;
  final local = history == null
      ? await ref.read(localLibraryProvider.notifier).getById(media.id)
      : null;
  if (!context.mounted) return;
  await saveNetworkOffline(context, ref, [
    if (history != null)
      UnifiedLibraryItem.fromDownloadHistory(history)
    else
      UnifiedLibraryItem.fromLocalLibrary(
        local ??
            LocalLibraryItem(
              id: media.id,
              filePath: source,
              trackName: media.title,
              artistName: media.artist ?? '',
              albumName: media.album ?? '',
              coverPath: media.artUri?.toString(),
              duration: media.duration?.inSeconds,
              format: media.extras?['format']?.toString(),
              scannedAt: DateTime.now(),
            ),
      ),
  ]);
}

String? offlineAvailabilityLabel(
  BuildContext context,
  UnifiedLibraryItem item,
) {
  if (item.historyItem?.originFilePath != null) {
    return item.historyItem!.originAvailable
        ? context.l10n.offlineServerAndDevice
        : context.l10n.offlineDeviceOnly;
  }
  return item.filePath.startsWith('network://')
      ? context.l10n.offlineServerOnly
      : null;
}

Future<void> deleteOfflineServerCopies(
  BuildContext context,
  WidgetRef ref,
  List<UnifiedLibraryItem> items,
) async {
  final origins = {
    for (final item in items)
      if (item.historyItem?.originFilePath case final String origin) origin,
  };
  if (origins.isEmpty) return;
  for (final item in items) {
    if (!await fileExists(item.filePath)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.offlineCopyUnavailable)),
        );
      }
      return;
    }
  }
  if (!context.mounted) return;
  final container = ProviderScope.containerOf(context, listen: false);
  final originalItems = [
    for (final item in items)
      if (item.historyItem case final history?
          when history.originFilePath != null)
        UnifiedLibraryItem.fromLocalLibrary(
          LocalLibraryItem.fromJson({
            ...history.toJson(),
            'filePath': history.originFilePath,
            'coverPath': history.coverUrl,
            'scannedAt': history.downloadedAt.toIso8601String(),
          }),
        ),
  ];
  if (hasLinkLibrarySongs(container, originalItems)) {
    await runLinkLibraryAction(
      context,
      container,
      originalItems,
      LinkLibraryAction.delete,
    );
    return;
  }
  final storage = NetworkStorageService.instance;
  for (final origin in origins) {
    if (!await storage.canDeleteFile(origin)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.offlineServerReadOnly)),
        );
      }
      return;
    }
  }
  if (!context.mounted ||
      !await showAppConfirmDialog(
        context,
        title: context.l10n.offlineDeleteServer,
        message: context.l10n.offlineDeleteServerMessage,
        confirmLabel: context.l10n.dialogDelete,
        destructive: true,
        cancelIsDefault: true,
      )) {
    return;
  }
  final deleted = <String>[];
  for (final origin in origins) {
    try {
      if (await deleteFile(origin)) deleted.add(origin);
    } catch (_) {
      // Keep failed sources indexed; never touch the independent local path.
    }
  }
  await removeDeletedLibraryFileEntries(container, deleted);
  if (deleted.isNotEmpty) {
    await container.read(downloadHistoryProvider.notifier).reloadFromStorage();
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          deleted.length == origins.length
              ? context.l10n.snackbarDeletedTracks(deleted.length)
              : context.l10n.snackbarDeleteTracksFailed(
                  origins.length - deleted.length,
                ),
        ),
      ),
    );
  }
}

Future<void> saveNetworkOffline(
  BuildContext context,
  WidgetRef ref,
  List<UnifiedLibraryItem> items,
) async {
  final controller = ref.read(networkOfflineProvider.notifier);
  final root = Navigator.of(context, rootNavigator: true).context;
  if (ref.read(networkOfflineProvider) == null) {
    if (!items.any((item) => networkOfflineOrigin(item) != null)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.offlineNoSongs)));
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    unawaited(() async {
      try {
        final result = await controller.save(items);
        if (result != null && messenger.mounted) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                result.cancelled
                    ? l10n.linkSaveToPhoneCancelled
                    : l10n.offlineResult(
                        result.saved,
                        result.skipped,
                        result.failed,
                      ),
              ),
            ),
          );
        }
      } catch (_) {
        if (messenger.mounted) {
          messenger.showSnackBar(SnackBar(content: Text(l10n.offlineFailed)));
        }
      }
    }());
  }
  if (!root.mounted) return;
  await showAppBottomSheet<void>(
    context: root,
    useRootNavigator: true,
    title: root.l10n.offlineSaving,
    builder: (_) => const _OfflineProgress(),
  );
}

class _OfflineProgress extends ConsumerStatefulWidget {
  const _OfflineProgress();

  @override
  ConsumerState<_OfflineProgress> createState() => _OfflineProgressState();
}

class _OfflineProgressState extends ConsumerState<_OfflineProgress> {
  bool _closing = false;

  @override
  Widget build(BuildContext context) {
    final progress = ref.watch(networkOfflineProvider);
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
            onTap: () => ref.read(networkOfflineProvider.notifier).cancel(),
          ),
        ],
      ),
    );
  }
}

class NetworkOfflineButton extends ConsumerWidget {
  const NetworkOfflineButton({super.key, required this.items});
  final List<UnifiedLibraryItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!items.any((item) => networkOfflineOrigin(item) != null)) {
      return const SizedBox.shrink();
    }
    return HeaderCircleButton(
      icon: Icons.download_for_offline_outlined,
      tooltip: context.l10n.offlineSave,
      onPressed: () => saveNetworkOffline(context, ref, items),
    );
  }
}

class NetworkOfflineTracksButton extends ConsumerWidget {
  const NetworkOfflineTracksButton({super.key, required this.tracks});
  final List<Track> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) => HeaderCircleButton(
    icon: Icons.download_for_offline_outlined,
    tooltip: context.l10n.offlineSave,
    onPressed: () async {
      final items = await linkLibraryItemsFor(
        tracks,
        includeLocal: ref.read(settingsProvider).localLibraryEnabled,
      );
      if (context.mounted) {
        await saveNetworkOffline(context, ref, items);
      }
    },
  );
}

class OfflineAvailabilityCover extends StatelessWidget {
  const OfflineAvailabilityCover({
    super.key,
    required this.item,
    required this.child,
  });
  final UnifiedLibraryItem item;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final label = offlineAvailabilityLabel(context, item);
    if (label == null) return child;
    final local = item.historyItem?.originFilePath != null;
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: Stack(
        children: [
          child,
          PositionedDirectional(
            bottom: 0,
            end: 0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: AppIcon.adaptive(
                  local ? Icons.offline_pin_outlined : Icons.cloud_outlined,
                  size: 14,
                  color: colors.onSurface,
                  semanticLabel: label,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
