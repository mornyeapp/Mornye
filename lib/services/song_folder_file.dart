import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';

/// A file to place in a song's folder under [name].
typedef SongFolderContent = ({File file, String name, String mimeType});

/// The path of [song] when it is a file on this device, without the track
/// suffix of a CUE sheet song.
String? localSongPath(String song) {
  if (song.isEmpty ||
      isContentUri(song) ||
      const {'http', 'https'}.contains(Uri.tryParse(song)?.scheme)) {
    return null;
  }
  final uri = Uri.tryParse(song);
  final path = uri?.scheme == 'file' ? uri!.toFilePath() : song;
  final real = isCueVirtualPath(path) ? stripCueTrackSuffix(path) : path;
  return p.isAbsolute(real) ? real : null;
}

/// Writes one kind of file that belongs to a whole album, such as its cover,
/// into the folder holding one of the album's songs: a local folder, an
/// Android document folder or a network folder. A file already there under
/// the same name stays.
class SongFolderFile {
  SongFolderFile({
    Future<bool> Function(
      String treeUri,
      String relativeDir,
      String name,
      String mimeType,
      String path,
    )?
    createDocument,
    Future<bool> Function(String target, File file)? upload,
  }) : _createDocument = createDocument ?? _createSafDocument,
       _upload = upload ?? _uploadToNetwork;

  final Future<bool> Function(
    String treeUri,
    String relativeDir,
    String name,
    String mimeType,
    String path,
  )
  _createDocument;
  final Future<bool> Function(String target, File file) _upload;
  final _saving = <String, Future<bool>>{};
  final _done = <String>{};
  static final _log = AppLogger('SongFolderFile');

  /// Saves what [content] gives into the folder holding [song]: a local
  /// path, an Android document in [treeUri]/[relativeDir], or a network
  /// song. True when a file was written.
  ///
  /// Songs of one album finish together: [content] is asked for the first
  /// of a folder, the rest wait for it, and later ones in this session do
  /// not ask again. A folder [content] gave nothing for is asked again.
  Future<bool> save({
    required String song,
    String? treeUri,
    String? relativeDir,
    required Future<SongFolderContent?> Function() content,
  }) {
    final String folder;
    final Future<bool> Function(SongFolderContent content) write;
    if (song.startsWith('network://')) {
      final uri = Uri.tryParse(song);
      if (uri == null || uri.host.isEmpty) return Future.value(false);
      final parent = p.posix.dirname(uri.pathSegments.join('/'));
      folder = '${uri.host}\n$parent';
      write = (content) => _upload(
        NetworkStorageService.source(
          uri.host,
          parent == '.' ? content.name : '$parent/${content.name}',
        ),
        content.file,
      );
    } else if (isContentUri(song)) {
      if (treeUri == null || treeUri.isEmpty || relativeDir == null) {
        return Future.value(false);
      }
      folder = '$treeUri\n$relativeDir';
      write = (content) => _createDocument(
        treeUri,
        relativeDir,
        content.name,
        content.mimeType,
        content.file.path,
      );
    } else {
      final path = localSongPath(song);
      if (path == null) return Future.value(false);
      folder = p.dirname(path);
      write = (content) => _copyLocal(content.file, folder, content.name);
    }
    if (_done.contains(folder)) return Future.value(false);
    final pending = _saving[folder];
    if (pending != null) return pending.then((_) => false);
    final saving = () async {
      try {
        final item = await content();
        if (item == null ||
            !await item.file.exists() ||
            await item.file.length() == 0) {
          return false;
        }
        final written = await write(item);
        if (_done.length >= 256) _done.clear();
        _done.add(folder);
        return written;
      } catch (error) {
        _log.w('An album file was not saved to the folder: $error');
        return false;
      }
    }();
    _saving[folder] = saving;
    return saving.whenComplete(() => _saving.remove(folder));
  }

  static Future<bool> _copyLocal(File file, String folder, String name) async {
    final target = File(p.join(folder, name));
    if (await target.exists()) return false;
    final staged = File('${target.path}.partial');
    try {
      await file.copy(staged.path);
      if (await target.exists()) return false;
      await staged.rename(target.path);
      return true;
    } finally {
      if (await staged.exists()) await deleteFileQuietly(staged);
    }
  }

  static Future<bool> _createSafDocument(
    String treeUri,
    String relativeDir,
    String name,
    String mimeType,
    String path,
  ) async {
    final result = await PlatformBridge.createSafFileIfAbsentFromPath(
      treeUri: treeUri,
      relativeDir: relativeDir,
      fileName: name,
      mimeType: mimeType,
      srcPath: path,
    );
    final uri = (result['uri'] as String? ?? '').trim();
    return uri.isNotEmpty && result['already_exists'] != true;
  }

  static Future<bool> _uploadToNetwork(String target, File file) async {
    final storage = NetworkStorageService.instance;
    final uri = Uri.parse(target);
    final path = networkPath(uri.pathSegments.join('/'));
    final slash = path.lastIndexOf('/');
    final parent = slash < 0 ? '' : path.substring(0, slash + 1);
    final name = path.substring(slash + 1).toLowerCase();
    // Looking by name first: an upload over an existing file would download
    // it to compare, and a different one is the user's to keep.
    final entries = await storage.list(
      await storage.connection(uri.host),
      parent,
    );
    if (entries.any((e) => e.name.toLowerCase() == name)) return false;
    await storage.publishUpload(
      target,
      file,
      'folder-file:$target',
      checkpoint: () {},
      progress: (_, _) {},
    );
    return true;
  }
}
