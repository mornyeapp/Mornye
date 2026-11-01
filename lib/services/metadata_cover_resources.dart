import 'dart:io';
import 'dart:typed_data';

import 'package:mornye/services/ffmpeg_metadata.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/network_metadata_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';

typedef MetadataCoverDetails = ({int width, int height, int bytes});

class MetadataCoverPreview {
  final String path;
  final String tempDir;
  final MetadataCoverDetails? details;

  const MetadataCoverPreview({
    required this.path,
    required this.tempDir,
    this.details,
  });
}

/// Owns editor artwork, including resources created after a sheet is closed.
/// A save lease keeps every owned file alive until the writer has finished.
class MetadataCoverResources {
  static final _log = AppLogger('MetadataCoverResources');
  final Set<String> _directories = {};
  final Set<String> _deferredReleases = {};
  bool _disposed = false;
  int _leases = 0;
  int _pending = 0;

  Future<void> Function() retain() {
    assert(!_disposed);
    _leases++;
    var released = false;
    return () async {
      if (released) return;
      released = true;
      _leases--;
      await _cleanupIfIdle();
    };
  }

  Future<void> dispose() async {
    _disposed = true;
    await _cleanupIfIdle();
  }

  Future<void> _cleanupIfIdle() async {
    if (_leases != 0) return;
    final directories = _disposed && _pending == 0
        ? _directories.toList()
        : _deferredReleases.toList();
    await Future.wait(directories.map(release));
  }

  Future<void> release(String? directory) async {
    if (directory == null || !_directories.contains(directory)) return;
    if (_leases != 0) {
      _deferredReleases.add(directory);
      return;
    }
    _directories.remove(directory);
    _deferredReleases.remove(directory);
    try {
      final dir = Directory(directory);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  Future<MetadataCoverDetails?> readDetails(String path) async {
    try {
      final dimensions = await FFmpegProbe.imageDimensions(path);
      if (dimensions == null) return null;
      return (
        width: dimensions.width,
        height: dimensions.height,
        bytes: await File(path).length(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<MetadataCoverPreview> _create(
    String prefix,
    String filename,
    Future<void> Function(String path) write, {
    bool probe = true,
  }) async {
    _pending++;
    String? directory;
    try {
      directory = (await Directory.systemTemp.createTemp(prefix)).path;
      _directories.add(directory);
      final path = '$directory${Platform.pathSeparator}$filename';
      await write(path);
      final file = File(path);
      if (!await file.exists() || await file.length() == 0) {
        throw StateError('Artwork file is empty or inaccessible');
      }
      return MetadataCoverPreview(
        path: path,
        tempDir: directory,
        details: probe ? await readDetails(path) : null,
      );
    } catch (_) {
      await release(directory);
      rethrow;
    } finally {
      _pending--;
      await _cleanupIfIdle();
    }
  }

  Future<MetadataCoverPreview?> download(String url) async {
    try {
      return await _create('metadata_cover_', 'cover.jpg', (path) async {
        final result = await PlatformBridge.downloadCoverToFile(url, path);
        if (result['error'] != null || result['success'] == false) {
          throw StateError(
            result['error']?.toString() ?? 'Cover download failed',
          );
        }
      });
    } catch (error) {
      _log.w('Could not download metadata artwork: $error');
      return null;
    }
  }

  Future<MetadataCoverPreview?> extract(String filePath) async {
    try {
      if (filePath.startsWith('network://')) {
        final metadata = await NetworkMetadataService.instance.read(filePath);
        final cover = metadata['cover_path'];
        if (cover is! String || cover.isEmpty) return null;
        return await copyPicked(extension: 'jpg', sourcePath: cover);
      }
      return await _create('metadata_embedded_cover_', 'cover.jpg', (
        path,
      ) async {
        final result = await PlatformBridge.extractCoverToFile(filePath, path);
        if (result['error'] != null) {
          throw StateError(result['error'].toString());
        }
      });
    } catch (_) {
      return null;
    }
  }

  Future<MetadataCoverPreview> copyPicked({
    required String extension,
    String? sourcePath,
    Uint8List? bytes,
  }) {
    return _create('metadata_selected_cover_', 'cover.$extension', (
      path,
    ) async {
      if (sourcePath?.isNotEmpty == true) {
        await File(sourcePath!).copy(path);
      } else if (bytes?.isNotEmpty == true) {
        await File(path).writeAsBytes(bytes!, flush: true);
      } else {
        throw StateError('Unable to read selected image');
      }
    }, probe: false);
  }

  Future<MetadataCoverPreview> resize(String source, int maxDimension) {
    return _create('metadata_resized_cover_', 'cover.jpg', (path) async {
      final resized = await FFmpegMetadata.resizeCoverArt(
        inputPath: source,
        outputPath: path,
        maxDimension: maxDimension,
      );
      if (!resized) throw StateError('Cover resize failed');
    }, probe: false);
  }
}
