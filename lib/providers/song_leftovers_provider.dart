import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/folder_cover_file.dart'
    show folderCoverFileNames;
import 'package:mornye/services/lyrics_sidecar.dart' show mlrcExtension;
import 'package:mornye/services/motion_artwork_folder.dart'
    show motionArtworkFileName;
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('SongLeftovers');

/// An entry of a folder holding songs. [id] is its path, or its uri for an
/// Android document.
typedef SongFolderEntry = ({String name, String id, bool folder});

abstract interface class SongFolderStore {
  /// The entries of [folder], or null when it cannot be listed.
  Future<List<SongFolderEntry>?> list(String folder);

  /// Deletes the file or empty folder [id]; false when it stays.
  Future<bool> delete(String id, {required bool folder});
}

/// Folders and files on a plain path.
class LocalSongFolderStore implements SongFolderStore {
  const LocalSongFolderStore();

  @override
  Future<List<SongFolderEntry>?> list(String folder) async {
    try {
      final entries = <SongFolderEntry>[];
      await for (final entity in Directory(folder).list(followLinks: false)) {
        entries.add((
          name: p.basename(entity.path),
          id: entity.path,
          // A link counts as a folder, so it always keeps its folder.
          folder: entity is! File,
        ));
      }
      return entries;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> delete(String id, {required bool folder}) async {
    try {
      // Never recursive: a folder goes only when nothing is left in it.
      await (folder ? Directory(id).delete() : File(id).delete());
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Folders and files in an Android storage access tree.
class DocumentSongFolderStore implements SongFolderStore {
  const DocumentSongFolderStore();

  @override
  Future<List<SongFolderEntry>?> list(String folder) async {
    final entries = await PlatformBridge.listSafFolder(folder);
    return entries
        ?.map(
          (entry) => (name: entry.name, id: entry.uri, folder: entry.folder),
        )
        .toList();
  }

  @override
  Future<bool> delete(String id, {required bool folder}) async {
    try {
      // A document folder is deleted with what it holds, so check that
      // nothing arrived since it was listed.
      if (folder && (await PlatformBridge.listSafFolder(id))?.isEmpty != true) {
        return false;
      }
      return await PlatformBridge.safDelete(id);
    } catch (_) {
      return false;
    }
  }
}

/// Where a song sits, found before it is deleted.
class _SongPlace {
  const _SongPlace({
    required this.store,
    required this.name,
    required this.folder,
    required this.removable,
  });

  final SongFolderStore store;

  final String name;

  final String folder;

  /// The folders the song may leave empty, nearest first: inside the
  /// download or Local Library folder, never that folder itself.
  final List<String> removable;
}

final songLeftoversProvider = Provider<SongLeftovers>(SongLeftovers.new);

/// Deletes the songs the user removes together with what they leave behind:
/// their `.lrc` and `.mlrc` lyrics files, and, while Remove Empty Folders is
/// on, the album and artist folders they leave empty inside the download
/// and Local Library folders. A folder still counts as empty when it only
/// holds system index files, Mornye's `cover.mp4` or lyrics files of songs
/// that are gone, or the `folder.jpg` downloads save while Save Album
/// Covers is on. Folders are removed while the download queue is idle, so
/// a download never loses the folder it is writing into. Network songs and
/// CUE tracks are only deleted.
class SongLeftovers {
  SongLeftovers(
    this._ref, {
    Future<bool> Function(String? source)? deleteSong,
    SongFolderStore files = const LocalSongFolderStore(),
    SongFolderStore documents = const DocumentSongFolderStore(),
    Future<({String name, List<({String uri, bool root})> folders})?> Function(
      String source,
    )?
    documentPlace,
    String? home,
    Future<bool> Function(String source)? orphanedNetworkSong,
  }) : _deleteSong = deleteSong ?? deleteFile,
       _orphanedNetworkSong =
           orphanedNetworkSong ??
           NetworkStorageService.instance.isOrphanedSource,
       _files = files,
       _documents = documents,
       _documentPlace = documentPlace ?? PlatformBridge.safSongFolders,
       _home = home {
    _ref.listen(downloadQueueProvider.select((queue) => queue.isProcessing), (
      _,
      processing,
    ) {
      if (!processing) flushFolders();
    });
    _ref.onDispose(dispose);
  }

  final Ref _ref;
  final Future<bool> Function(String? source) _deleteSong;
  final Future<bool> Function(String source) _orphanedNetworkSong;
  final SongFolderStore _files;
  final SongFolderStore _documents;
  final Future<({String name, List<({String uri, bool root})> folders})?>
  Function(String source)
  _documentPlace;
  final String? _home;

  final _folders = Queue<_SongPlace>();
  var _removing = false;
  var _disposed = false;

  /// Deletes the song at [source] as [deleteFile] does, then what it leaves
  /// behind. Returns whether the song is gone.
  ///
  /// A network song whose server connection was removed cannot be reached
  /// to delete. It counts as gone, so the caller removes it from the
  /// Library instead of keeping a song nothing can delete.
  Future<bool> delete(String? source) async {
    if (source != null &&
        source.startsWith('network://') &&
        await _orphanedNetworkSong(source)) {
      _log.i('Removing a song of a removed network server from the Library');
      return true;
    }
    final place = await _placeOf(source);
    if (!await _deleteSong(source)) return false;
    if (place == null || _disposed) return true;
    try {
      await _deleteLyricsFiles(place);
    } catch (error) {
      _log.w('Could not delete the lyrics files of ${place.name}: $error');
    }
    if (place.removable.isNotEmpty &&
        _ref.read(settingsProvider).removeEmptyFolders) {
      _folders.add(place);
      flushFolders();
    }
    return true;
  }

  Future<_SongPlace?> _placeOf(String? source) async {
    if (source == null) return null;
    final path = source.startsWith('EXISTS:')
        ? source.substring(7).trim()
        : source;
    if (path.isEmpty ||
        path.startsWith('network://') ||
        isCueVirtualPath(path)) {
      return null;
    }
    try {
      if (isContentUri(path)) {
        final place = await _documentPlace(path);
        if (place == null || place.folders.isEmpty) return null;
        return _SongPlace(
          store: _documents,
          name: place.name,
          folder: place.folders.first.uri,
          removable: [
            for (final folder in place.folders.takeWhile((f) => !f.root))
              folder.uri,
          ],
        );
      }
      final uri = Uri.tryParse(path);
      final file = uri?.scheme == 'file' ? uri!.toFilePath() : path;
      if (!p.isAbsolute(file)) return null;
      final folder = p.dirname(p.normalize(file));
      return _SongPlace(
        store: _files,
        name: p.basename(file),
        folder: folder,
        removable: _removableFolders(folder),
      );
    } catch (error) {
      _log.w('Could not find the folder of $path: $error');
      return null;
    }
  }

  /// [folder] and the folders above it, up to the download or Local Library
  /// folder holding them.
  List<String> _removableFolders(String folder) {
    final settings = _ref.read(settingsProvider);
    final roots = [
      for (final root in {
        settings.downloadDirectory,
        _ref.read(downloadQueueProvider).outputDir,
        settings.localLibraryPath,
        for (final source in _ref.read(localLibraryProvider).sources)
          source.path,
      })
        if (root.trim() case final root
            when root.isNotEmpty && !isContentUri(root) && p.isAbsolute(root))
          root,
    ];
    final folders = <String>[];
    var current = folder;
    while (roots.any((root) => p.isWithin(root, current)) &&
        !isSharedTopFolder(current, home: _home)) {
      folders.add(current);
      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
    return folders;
  }

  /// The song's own `.lrc` and `.mlrc` files, unless another song in the
  /// folder has the same name.
  Future<void> _deleteLyricsFiles(_SongPlace place) async {
    final entries = await place.store.list(place.folder);
    if (entries == null) return;
    final stem = _stem(place.name);
    final files = entries.where((entry) => !entry.folder);
    if (files.any((entry) => _stem(entry.name) == stem && !_isLyrics(entry))) {
      return;
    }
    for (final entry in files) {
      if (_stem(entry.name) == stem && _isLyrics(entry)) {
        await place.store.delete(entry.id, folder: false);
      }
    }
  }

  /// Removes the folders waiting for an idle download queue.
  void flushFolders() {
    if (_removing || _disposed || _folders.isEmpty) return;
    if (_ref.read(downloadQueueProvider).isProcessing) return;
    unawaited(_removeAll());
  }

  Future<void> _removeAll() async {
    _removing = true;
    try {
      while (_folders.isNotEmpty && !_disposed) {
        // A queue that starts again holds the rest until it is idle.
        if (_ref.read(downloadQueueProvider).isProcessing) return;
        final place = _folders.removeFirst();
        try {
          await _removeEmptyFolders(place);
        } catch (error) {
          _log.w('Could not remove the folders of ${place.name}: $error');
        }
      }
    } finally {
      _removing = false;
    }
  }

  Future<void> _removeEmptyFolders(_SongPlace place) async {
    final store = place.store;
    final covers = _ref.read(settingsProvider).saveFolderCover;
    for (final folder in place.removable) {
      final entries = await store.list(folder);
      if (entries == null ||
          entries.any((entry) => _keepsFolder(entry, covers: covers))) {
        return;
      }
      for (final entry in entries) {
        if (!await store.delete(entry.id, folder: false)) return;
      }
      if (!await store.delete(folder, folder: true)) return;
      _log.d('Removed the empty folder $folder');
    }
  }

  static String _stem(String name) => p.posix.basenameWithoutExtension(name);

  static bool _isLyrics(SongFolderEntry entry) => const {
    '.lrc',
    '.$mlrcExtension',
  }.contains(p.posix.extension(entry.name).toLowerCase());

  /// Whether [entry] is something of the user's that keeps its folder:
  /// anything but system index files, Mornye's `cover.mp4` and lyrics files
  /// left by songs that are gone. With [covers], while downloads save
  /// `folder.jpg`, that cover is no longer the user's either.
  static bool _keepsFolder(SongFolderEntry entry, {required bool covers}) {
    if (entry.folder) return true;
    final name = entry.name.toLowerCase();
    final leftover =
        const {'.ds_store', 'thumbs.db', 'desktop.ini'}.contains(name) ||
        name == motionArtworkFileName ||
        (covers && folderCoverFileNames.contains(name)) ||
        name.startsWith('._') ||
        _isLyrics(entry);
    return !leftover;
  }

  void dispose() {
    _disposed = true;
    _folders.clear();
  }
}
