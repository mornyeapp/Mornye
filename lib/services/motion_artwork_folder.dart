import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/services/motion_artwork_store.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/saf_siblings.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';

/// The name an album's animated cover has in the album's folder.
const motionArtworkFileName = 'cover.mp4';
const _maxBytes = 64 << 20;

typedef MotionArtworkDocument = ({String uri, int size, int modified});

/// An album's animated cover kept as `cover.mp4` in the album's own folder,
/// where file managers and other players find it. Downloads write it there
/// when the settings ask; the player shows one it finds beside a song.
class MotionArtworkFolder {
  MotionArtworkFolder({
    Future<Directory> Function()? directory,
    Future<MotionArtworkDocument?> Function(String song, String name)? sibling,
    Future<String?> Function(String uri)? copyDocument,
    Future<bool> Function(
      String treeUri,
      String relativeDir,
      String name,
      String path,
    )?
    createDocument,
    Future<bool> Function(String target, File file)? upload,
    bool? documents,
  }) : _directory = directory ?? MotionArtworkStore.defaultDirectory,
       _sibling = sibling ?? _findSibling,
       _copyDocument = copyDocument ?? PlatformBridge.copyContentUriToTemp,
       _createDocument = createDocument ?? _createSafDocument,
       _upload = upload ?? _uploadToNetwork,
       _documents = documents ?? Platform.isAndroid;

  final Future<Directory> Function() _directory;
  final Future<MotionArtworkDocument?> Function(String song, String name)
  _sibling;
  final Future<String?> Function(String uri) _copyDocument;
  final Future<bool> Function(
    String treeUri,
    String relativeDir,
    String name,
    String path,
  )
  _createDocument;
  final Future<bool> Function(String target, File file) _upload;
  final bool _documents;
  final _saving = <String, Future<bool>>{};
  final _done = <String>{};
  final _copying = <String, Future<MotionArtwork?>>{};

  /// Android document lookups by song, so moving between songs does not ask
  /// the provider again; a cover added later shows within minutes.
  final _found = <String, (DateTime, Future<MotionArtwork?>)>{};
  static const _foundFor = Duration(minutes: 5);
  static final _log = AppLogger('MotionArtworkFolder');

  /// Forgets document lookups, after their copies were cleared.
  void forget() => _found.clear();

  /// Saves [video] as the `cover.mp4` of the folder holding [song]: a local
  /// path, an Android document in [treeUri]/[relativeDir], or a network
  /// song. A cover already there stays. True when one was written.
  Future<bool> save(
    File video, {
    required String song,
    String? treeUri,
    String? relativeDir,
  }) {
    final String folder;
    final Future<bool> Function() write;
    if (song.startsWith('network://')) {
      final uri = Uri.tryParse(song);
      if (uri == null || uri.host.isEmpty) return Future.value(false);
      final parent = p.posix.dirname(uri.pathSegments.join('/'));
      folder = NetworkStorageService.source(
        uri.host,
        parent == '.'
            ? motionArtworkFileName
            : '$parent/$motionArtworkFileName',
      );
      write = () => _upload(folder, video);
    } else if (isContentUri(song)) {
      if (treeUri == null || treeUri.isEmpty || relativeDir == null) {
        return Future.value(false);
      }
      folder = '$treeUri\n$relativeDir';
      write = () => _createDocument(
        treeUri,
        relativeDir,
        motionArtworkFileName,
        video.path,
      );
    } else {
      final path = _localPath(song);
      if (path == null) return Future.value(false);
      folder = p.dirname(path);
      write = () => _copyLocal(video, folder);
    }
    // Songs of one album finish together: the first writes, the rest wait
    // for it, and later ones in this session do not look again.
    if (_done.contains(folder)) return Future.value(false);
    final pending = _saving[folder];
    if (pending != null) return pending.then((_) => false);
    final saving = () async {
      try {
        if (!await video.exists() || await video.length() == 0) return false;
        final written = await write();
        if (_done.length >= 256) _done.clear();
        _done.add(folder);
        return written;
      } catch (error) {
        _log.w('Animated cover was not saved to the folder: $error');
        return false;
      }
    }();
    _saving[folder] = saving;
    return saving.whenComplete(() => _saving.remove(folder));
  }

  Future<bool> _copyLocal(File video, String folder) async {
    final target = File(p.join(folder, motionArtworkFileName));
    if (await target.exists()) return false;
    final staged = File('${target.path}.partial');
    try {
      await video.copy(staged.path);
      if (await target.exists()) return false;
      await staged.rename(target.path);
      return true;
    } finally {
      if (await staged.exists()) await deleteFileQuietly(staged);
    }
  }

  /// The `cover.mp4` in [song]'s folder as a local file the player can show,
  /// or null when there is none. Android documents are copied into the app
  /// once, since the video player only opens files.
  Future<MotionArtwork?> find(String song) async {
    if (song.isEmpty || song.startsWith('network://')) return null;
    if (isContentUri(song)) {
      if (!_documents) return null;
      final now = DateTime.now();
      final found = _found[song];
      if (found != null && now.difference(found.$1) < _foundFor) {
        return found.$2;
      }
      if (_found.length >= 64) _found.clear();
      final lookup = _findDocument(song);
      _found[song] = (now, lookup);
      return lookup;
    }
    final path = _localPath(song);
    if (path == null) return null;
    try {
      final file = File(p.join(p.dirname(path), motionArtworkFileName));
      if (!await file.exists()) return null;
      final length = await file.length();
      if (length == 0 || length > _maxBytes) return null;
      return MotionArtwork(file.uri.toString());
    } catch (_) {
      return null;
    }
  }

  Future<MotionArtwork?> _findDocument(String song) async {
    try {
      final document = await _sibling(song, motionArtworkFileName);
      if (document == null || document.size <= 0 || document.size > _maxBytes) {
        return null;
      }
      // Songs of one album share a cover: copy it once.
      final pending = _copying[document.uri];
      if (pending != null) return await pending;
      final copying = _copyIn(document);
      _copying[document.uri] = copying;
      try {
        return await copying;
      } finally {
        _copying.remove(document.uri);
      }
    } catch (error) {
      _log.w('Could not read the folder animated cover: $error');
      return null;
    }
  }

  Future<MotionArtwork?> _copyIn(MotionArtworkDocument document) async {
    File? staged;
    try {
      final root = Directory(p.join((await _directory()).path, 'folder'));
      final key = sha256.convert(utf8.encode(document.uri)).toString();
      final file = File(p.join(root.path, '$key.mp4'));
      final info = File(p.join(root.path, '$key.json'));
      final stamp = jsonEncode({
        'size': document.size,
        'modified': document.modified,
      });
      if (await file.exists() &&
          await info.exists() &&
          await info.readAsString() == stamp) {
        return MotionArtwork(file.uri.toString());
      }
      final copied = await _copyDocument(document.uri);
      if (copied == null) return null;
      await root.create(recursive: true);
      staged = File(p.join(root.path, '$key.partial.mp4'));
      final source = File(copied);
      try {
        await source.rename(staged.path);
      } on FileSystemException {
        await source.copy(staged.path);
        await deleteFileQuietly(source);
      }
      if (await staged.length() != document.size) return null;
      await staged.rename(file.path);
      await info.writeAsString(stamp, flush: true);
      return MotionArtwork(file.uri.toString());
    } catch (error) {
      _log.w('Could not read the folder animated cover: $error');
      return null;
    } finally {
      if (staged != null && await staged.exists()) {
        await deleteFileQuietly(staged);
      }
    }
  }

  static String? _localPath(String song) {
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

  /// The song's folder is listed once for this and the song's lyrics.
  static Future<MotionArtworkDocument?> _findSibling(
    String song,
    String name,
  ) => SafSiblings.names.contains(name)
      ? SafSiblings.instance.file(song, name)
      : PlatformBridge.findSafSibling(song, name);

  static Future<bool> _createSafDocument(
    String treeUri,
    String relativeDir,
    String name,
    String path,
  ) async {
    final result = await PlatformBridge.createSafFileIfAbsentFromPath(
      treeUri: treeUri,
      relativeDir: relativeDir,
      fileName: name,
      mimeType: 'video/mp4',
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
    // Looking by name first: an upload over an existing file would download
    // it to compare, and a different one is the user's to keep.
    final entries = await storage.list(
      await storage.connection(uri.host),
      parent,
    );
    if (entries.any((e) => e.name.toLowerCase() == motionArtworkFileName)) {
      return false;
    }
    await storage.publishUpload(
      target,
      file,
      'motion-cover:$target',
      checkpoint: () {},
      progress: (_, _) {},
    );
    return true;
  }
}
