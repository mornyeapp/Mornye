import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/supported_locales.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';
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
    NotifierProvider<NetworkUploadNotifier, NetworkUploadStatus?>(
      NetworkUploadNotifier.new,
    );

/// The upload that runs, or the last one until the next starts or
/// [NetworkUploadNotifier.clear] drops it, so its progress and result stay
/// reachable after the progress sheet closes.
class NetworkUploadStatus {
  const NetworkUploadStatus(this.progress, {this.result, this.error});

  final LinkOfflineProgress progress;

  /// How the run ended; null while it runs or when it failed as a whole.
  final NetworkUploadResult? result;

  /// Why the run failed as a whole, such as [NetworkUploadReadOnly].
  final Object? error;

  bool get running => result == null && error == null;
}

/// One upload at a time, shared by both themes and every Library entry
/// point, like Save offline. Leaving a screen keeps it running.
class NetworkUploadNotifier extends Notifier<NetworkUploadStatus?> {
  LinkOfflineCancel? _cancel;

  @override
  NetworkUploadStatus? build() {
    ref.onDispose(() => _cancel?.cancel());
    return null;
  }

  void cancel() => _cancel?.cancel();

  /// Drops the result of the last upload; a running one stays.
  void clear() {
    if (_cancel == null) state = null;
  }

  Future<NetworkUploadResult?> upload(
    List<UnifiedLibraryItem> items,
    String folder,
  ) async {
    if (_cancel != null) return null;
    final uploadable = networkUploadItems(items);
    if (uploadable.isEmpty) return null;
    final cancel = LinkOfflineCancel();
    _cancel = cancel;
    final storage = ref.read(networkOfflineStorageProvider);
    final notices = NotificationService();
    final settings = ref.read(settingsProvider);
    final queue = ref.read(downloadQueueProvider.notifier);
    final l10n = appLocalizationsFor(settings.locale);
    state = NetworkUploadStatus(
      LinkOfflineProgress(done: 0, total: uploadable.length, title: ''),
    );
    var lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await notices.beginBackgroundWork(
        'network_upload',
        title: l10n.networkUploading,
      );
      // The folders downloads get on this device, from the songs' tags.
      final songs = await networkUploadSongs(
        uploadable,
        folderFor: (item) => queue.libraryFolderFor(item, settings),
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
              final shown = state?.progress;
              if (ref.mounted &&
                  (shown?.title != progress.title ||
                      shown?.done != progress.done ||
                      now.difference(lastProgressAt).inMilliseconds >= 120)) {
                lastProgressAt = now;
                state = NetworkUploadStatus(progress);
              }
            },
          );
      if (ref.mounted) {
        state = NetworkUploadStatus(
          LinkOfflineProgress(
            done: result.saved + result.skipped + result.failed,
            total: songs.length,
            title: '',
          ),
          result: result,
        );
        if (result.uploaded.isNotEmpty) _rescan(result.uploaded);
      }
      return result;
    } on Object catch (error) {
      if (ref.mounted) {
        state = NetworkUploadStatus(
          state?.progress ??
              LinkOfflineProgress(done: 0, total: uploadable.length, title: ''),
          error: error,
        );
      }
      rethrow;
    } finally {
      try {
        await notices.endBackgroundWork('network_upload');
      } finally {
        _cancel = null;
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
