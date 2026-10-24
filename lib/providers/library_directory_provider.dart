import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_directory_index.dart';
import 'package:mornye/services/network_storage_service.dart';

/// Libraries up to this many songs are arranged on the UI isolate, where a
/// background isolate would cost more than the work itself.
const _backgroundIndexThreshold = 3000;

/// The Library's songs by folder. Rebuilt when downloads or the scanned
/// Library change, or the scanned Library is turned on or off.
final libraryDirectoryIndexProvider =
    FutureProvider.autoDispose<LibraryDirectoryIndex>((ref) async {
      ref.watch(
        downloadHistoryProvider.select((state) => state.loadedIndexVersion),
      );
      final includeLocal = ref.watch(
        settingsProvider.select((s) => s.localLibraryEnabled),
      );
      if (includeLocal) {
        ref.watch(
          localLibraryProvider.select((state) => state.loadedIndexVersion),
        );
      }
      final rows = await LibraryDatabase.instance.getDirectoryEntries(
        includeLocal: includeLocal,
      );
      final entries = rows
          .map(LibraryDirectoryEntry.fromRow)
          .toList(growable: false);
      final networkNames = <String, String>{};
      if (entries.any((entry) => entry.path.startsWith('network://'))) {
        try {
          for (final connection
              in await NetworkStorageService.instance.connections()) {
            networkNames[connection.id] = connection.name;
          }
        } catch (_) {
          // Roots fall back to the connection id.
        }
      }
      if (entries.length <= _backgroundIndexThreshold) {
        return LibraryDirectoryIndex.build(entries, networkNames: networkNames);
      }
      return Isolate.run(
        () => LibraryDirectoryIndex.build(entries, networkNames: networkNames),
      );
    });

/// Reads the Library records of folder songs, in the order given.
typedef LibraryDirectoryItemsLoader =
    Future<List<UnifiedLibraryItem>> Function(
      Iterable<LibraryDirectoryTrack> tracks,
    );

/// How folder songs are read: from the history and Library databases.
final libraryDirectoryItemsLoaderProvider =
    Provider<LibraryDirectoryItemsLoader>((ref) => loadLibraryDirectoryItems);

/// The songs directly in the folder with the given key, in folder order.
final libraryDirectoryTracksProvider = FutureProvider.autoDispose
    .family<List<UnifiedLibraryItem>, String>((ref, key) async {
      final index = await ref.watch(libraryDirectoryIndexProvider.future);
      final folder = index[key];
      if (folder == null) return const [];
      return ref.read(libraryDirectoryItemsLoaderProvider)(folder.tracks);
    });

/// The Library records of [tracks], in the same order. Songs removed since
/// the index was built are left out.
Future<List<UnifiedLibraryItem>> loadLibraryDirectoryItems(
  Iterable<LibraryDirectoryTrack> tracks,
) async {
  final list = tracks.toList(growable: false);
  final downloads = await HistoryDatabase.instance.getByIds([
    for (final track in list)
      if (track.source != 'local') track.id,
  ]);
  final scanned = {
    for (final row in await LibraryDatabase.instance.getByIds([
      for (final track in list)
        if (track.source == 'local') track.id,
    ]))
      row['id'] as String: row,
  };
  UnifiedLibraryItem? item(LibraryDirectoryTrack track) {
    if (track.source == 'local') {
      final row = scanned[track.id];
      return row == null
          ? null
          : UnifiedLibraryItem.fromLocalLibrary(LocalLibraryItem.fromJson(row));
    }
    final row = downloads[track.id];
    return row == null
        ? null
        : UnifiedLibraryItem.fromDownloadHistory(
            DownloadHistoryItem.fromJson(row),
          );
  }

  return [for (final track in list) ?item(track)];
}
