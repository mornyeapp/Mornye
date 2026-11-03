import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/supported_locales.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/network_offline_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/network_library_upload.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/notification_service.dart';

/// The saved connections that accept uploads. Invalidate it after a
/// connection is added, edited or removed.
final networkUploadConnectionsProvider =
    FutureProvider<List<NetworkConnection>>((ref) async {
      final storage = ref.watch(networkOfflineStorageProvider);
      return [
        for (final connection in await storage.connections())
          if (connection.writable && storage.virtualFor(connection.id) == null)
            connection,
      ];
    });

final networkUploadProvider =
    NotifierProvider<NetworkUploadNotifier, LinkOfflineProgress?>(
      NetworkUploadNotifier.new,
    );

/// One upload at a time, shared by both themes and every Library entry
/// point, like Save offline. Leaving a screen keeps it running.
class NetworkUploadNotifier extends Notifier<LinkOfflineProgress?> {
  LinkOfflineCancel? _cancel;

  @override
  LinkOfflineProgress? build() {
    ref.onDispose(() => _cancel?.cancel());
    return null;
  }

  void cancel() => _cancel?.cancel();

  Future<NetworkUploadResult?> upload(
    List<UnifiedLibraryItem> items,
    String folder,
  ) async {
    if (_cancel != null) return null;
    final songs = networkUploadSongs(items);
    if (songs.isEmpty) return null;
    final cancel = LinkOfflineCancel();
    _cancel = cancel;
    final storage = ref.read(networkOfflineStorageProvider);
    final notices = NotificationService();
    final l10n = appLocalizationsFor(ref.read(settingsProvider).locale);
    state = LinkOfflineProgress(done: 0, total: songs.length, title: '');
    var lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await notices.beginBackgroundWork(
        'network_upload',
        title: l10n.networkUploading,
      );
      final result =
          await NetworkLibraryUploader(
            connections: storage.connections,
            prepare: storage.prepareNewUpload,
            publish: storage.publishUpload,
          ).upload(
            songs,
            folder: folder,
            cancel: cancel,
            onProgress: (progress) {
              final now = DateTime.now();
              if (ref.mounted &&
                  (state?.title != progress.title ||
                      state?.done != progress.done ||
                      now.difference(lastProgressAt).inMilliseconds >= 120)) {
                lastProgressAt = now;
                state = progress;
              }
            },
          );
      if (ref.mounted && result.uploaded.isNotEmpty) {
        _rescan(result.uploaded);
      }
      return result;
    } finally {
      try {
        await notices.endBackgroundWork('network_upload');
      } finally {
        _cancel = null;
        if (ref.mounted) state = null;
      }
    }
  }

  /// Network Library folders that received files scan again, so the new
  /// songs appear there; browsing the connection lists them directly.
  void _rescan(List<String> uploaded) {
    final library = ref.read(localLibraryProvider.notifier);
    final ids = networkUploadSourcesToRescan(
      ref.read(localLibraryProvider).sources,
      uploaded,
    );
    if (ids.isEmpty) return;
    unawaited(() async {
      try {
        for (final id in ids) {
          if (!ref.mounted) return;
          await library.startSourceScan(
            id,
            notify: false,
            waitForCurrentScan: true,
          );
        }
      } catch (_) {
        // The next scan of that folder finds the files.
      }
    }());
  }
}
