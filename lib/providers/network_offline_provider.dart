import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/l10n/supported_locales.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/network_offline_saver.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/notification_service.dart';
import 'package:mornye/utils/file_access.dart';

final networkOfflineProvider =
    NotifierProvider<NetworkOfflineNotifier, LinkOfflineProgress?>(
      NetworkOfflineNotifier.new,
    );

final networkOfflineStorageProvider = Provider<NetworkStorageService>(
  (ref) => NetworkStorageService.instance,
);

/// One owned transfer at a time, shared by both themes and every Library
/// entry point. Leaving a screen keeps it running; cancellation closes only
/// the transfer's own network connections.
class NetworkOfflineNotifier extends Notifier<LinkOfflineProgress?> {
  LinkOfflineCancel? _cancel;

  @override
  LinkOfflineProgress? build() {
    ref.onDispose(() => _cancel?.cancel());
    return null;
  }

  void cancel() => _cancel?.cancel();

  Future<LinkOfflineResult?> save(List<UnifiedLibraryItem> items) async {
    if (_cancel != null) return null;
    final songs = networkOfflineSongs(items);
    if (songs.isEmpty) return null;
    final songsByOrigin = {for (final song in songs) song.songId: song};
    final cancel = LinkOfflineCancel();
    _cancel = cancel;
    final storage = ref.read(networkOfflineStorageProvider);
    final transport = NetworkOfflineTransport(storage: storage);
    final settings = ref.read(settingsProvider);
    final history = ref.read(downloadHistoryProvider.notifier);
    final library = ref.read(localLibraryProvider.notifier);
    final remoteHistoryIds = {
      for (final item in items)
        if (item.historyItem != null && item.filePath.startsWith('network://'))
          item.filePath: item.historyItem!.id,
    };
    final remoteHistory = {
      for (final item in items)
        if (item.historyItem != null && networkOfflineOrigin(item) != null)
          networkOfflineOrigin(item)!: item.historyItem!,
    };
    final notices = NotificationService();
    final l10n = appLocalizationsFor(settings.locale);
    state = LinkOfflineProgress(done: 0, total: songs.length, title: '');
    var lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await notices.beginBackgroundWork(
        'network_offline',
        title: l10n.offlineSave,
      );
      final originSources = remoteHistoryIds.isEmpty
          ? <LocalLibrarySource>[]
          : [...await LibraryDatabase.instance.getSources()];
      return await LinkOfflineSaver(
        serverId: 'network',
        idPrefix: 'offline',
        serviceName: 'Network offline',
        openTransport: () => transport,
        prepareSong: transport.prepare,
        destination: LinkDownloadFolderDestination(settings),
        historyIdForSong: (song) =>
            remoteHistoryIds[song.songId] ??
            networkOfflineHistoryId(song.songId),
        record: (item) async {
          final origin = item.originFilePath!;
          if (remoteHistoryIds.containsKey(origin)) {
            // Downloads sent directly to NAS originally have only a History
            // row. Retain a scanned server row before its local alias can be
            // removed, just as for an ordinary scanned network song.
            final uri = Uri.parse(origin);
            final candidates =
                originSources
                    .where(
                      (source) =>
                          source.path == origin ||
                          origin.startsWith(
                            source.path.endsWith('/')
                                ? source.path
                                : '${source.path}/',
                          ),
                    )
                    .toList()
                  ..sort((a, b) => b.path.length.compareTo(a.path.length));
            final connection = await storage.connection(uri.host);
            final source =
                candidates.firstOrNull ??
                await library.addSource(
                  path: NetworkStorageService.source(
                    uri.host,
                    '${uri.pathSegments.take(uri.pathSegments.length - 1).join('/')}/',
                  ),
                  displayName: connection.name,
                );
            if (candidates.isEmpty) originSources.add(source);
            if (ref.mounted &&
                !ref.read(settingsProvider).localLibraryEnabled) {
              ref.read(settingsProvider.notifier).setLocalLibraryEnabled(true);
            }
            final song = songsByOrigin[origin]!;
            await LibraryDatabase.instance.retainOfflineOrigin(
              song.item,
              source.id,
            );
          }
          final original = remoteHistory[origin];
          await history.saveOfflineCopy(
            original == null
                ? item
                : DownloadHistoryItem.fromJson({
                    ...item.toJson(),
                    'service': original.service,
                    'spotifyId': original.spotifyId,
                  }),
          );
        },
        existsOrigin: (origin) async {
          final row = await HistoryDatabase.instance.findOfflineCopy(origin);
          final path = row?['filePath'] as String?;
          return path != null &&
              !path.startsWith('network://') &&
              await fileExists(path);
        },
        temporaryDirectory: getTemporaryDirectory,
        exists: (id) async {
          final row = await HistoryDatabase.instance.getById(id);
          final path = row?['filePath'] as String?;
          return path != null &&
              !path.startsWith('network://') &&
              await fileExists(path);
        },
      ).save(
        songs,
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
    } finally {
      transport.close();
      try {
        if (ref.mounted) await library.reloadFromStorage();
      } finally {
        try {
          await notices.endBackgroundWork('network_offline');
        } finally {
          _cancel = null;
          if (ref.mounted) state = null;
        }
      }
    }
  }
}
