import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/ffmpeg_support.dart';
import 'package:mornye/services/motion_artwork_download.dart';
import 'package:mornye/services/motion_artwork_proxy.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/string_utils.dart';

typedef MotionArtworkAlbum = ({String album, String artist});

class MotionArtwork {
  const MotionArtwork(this.source, {this.aspectRatio});

  final String source;
  final double? aspectRatio;
}

/// Durable, album-scoped artwork. Relative filenames survive iOS reinstalls
/// that relocate the app container; temporary cache cleanup does not remove it.
class MotionArtworkStore {
  MotionArtworkStore({
    Future<Directory> Function()? directory,
    Future<double?> Function(String source, String output)? download,
    Future<bool> Function(String path)? validate,
  }) : _directory = directory ?? defaultDirectory,
       _download = download ?? _downloadVideo,
       _validate = validate ?? _validateVideo;

  final Future<Directory> Function() _directory;
  final Future<double?> Function(String source, String output) _download;
  final Future<bool> Function(String path) _validate;
  final _pending = <String, Future<MotionArtwork?>>{};
  final _legacyChecks = <String, Future<bool>>{};
  final _invalid = <String>{};
  bool _clearing = false;
  static final _log = AppLogger('MotionArtwork');
  static const _cacheVersion = 2;

  static Future<Directory> defaultDirectory() async => Directory(
    '${(await getApplicationSupportDirectory()).path}/motion_artwork',
  );

  String _key(MotionArtworkAlbum album) {
    String normalize(String value) =>
        value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([normalize(album.album), normalize(album.artist)]),
          ),
        )
        .toString();
  }

  Future<MotionArtwork?> find(MotionArtworkAlbum album) async {
    if (_clearing) return null;
    try {
      final root = await _directory();
      final key = _key(album);
      if (_invalid.contains(key)) return null;
      final file = File('${root.path}/$key.mp4');
      if (!await file.exists() || await file.length() == 0) return null;
      double? ratio;
      var version = 0;
      final info = File('${root.path}/$key.json');
      if (await info.exists()) {
        final data = jsonDecode(await info.readAsString());
        if (data is Map) {
          if (data['version'] is int) version = data['version'] as int;
          if (data['aspectRatio'] is num) {
            final value = (data['aspectRatio'] as num).toDouble();
            if (value.isFinite && value > 0) ratio = value;
          }
        }
      }
      // Older downloads could report success with corrupt HLS byte ranges.
      // Check those once per session; retain healthy covers for offline use.
      if (version != _cacheVersion &&
          !await _legacyChecks.putIfAbsent(key, () async {
            try {
              return await _validate(file.path);
            } catch (_) {
              return false;
            }
          })) {
        _invalid.add(key);
        _log.w('Saved motion artwork failed validation; repair required');
        return null;
      }
      return MotionArtwork(file.uri.toString(), aspectRatio: ratio);
    } catch (_) {
      return null;
    }
  }

  Future<MotionArtwork?> save(
    MotionArtworkAlbum album, {
    required Future<String?> Function() resolveSource,
  }) {
    if (_clearing ||
        album.album.trim().isEmpty ||
        album.artist.trim().isEmpty) {
      return Future.value();
    }
    final key = _key(album);
    return _pending.putIfAbsent(key, () async {
      try {
        return await _save(album, key, resolveSource);
      } finally {
        _pending.remove(key);
      }
    });
  }

  Future<void> clear() async {
    _clearing = true;
    try {
      await Future.wait(_pending.values.toList());
      await Future.wait(_legacyChecks.values.toList());
      final root = await _directory();
      if (await root.exists()) await root.delete(recursive: true);
      _legacyChecks.clear();
      _invalid.clear();
    } finally {
      _clearing = false;
    }
  }

  Future<MotionArtwork?> _save(
    MotionArtworkAlbum album,
    String key,
    Future<String?> Function() resolveSource,
  ) async {
    File? temporary;
    File? infoTemporary;
    try {
      final existing = await find(album);
      if (existing != null) return existing;
      final source = normalizeRemoteHttpUrl(await resolveSource());
      if (source == null) return null;
      final root = await _directory();
      await root.create(recursive: true);
      temporary = File('${root.path}/$key.partial.mp4');
      final ratio = await _download(source, temporary.path);
      if (ratio == null ||
          !ratio.isFinite ||
          ratio <= 0 ||
          !await temporary.exists() ||
          await temporary.length() == 0 ||
          !await _validate(temporary.path)) {
        return null;
      }
      infoTemporary = File('${root.path}/$key.partial.json');
      await infoTemporary.writeAsString(
        jsonEncode({'version': _cacheVersion, 'aspectRatio': ratio}),
        flush: true,
      );
      final file = await temporary.rename('${root.path}/$key.mp4');
      await infoTemporary.rename('${root.path}/$key.json');
      _invalid.remove(key);
      _legacyChecks.remove(key);
      return MotionArtwork(file.uri.toString(), aspectRatio: ratio);
    } catch (error) {
      _log.w('Could not save optional motion artwork: ${error.runtimeType}');
      return null;
    } finally {
      for (final file in [temporary, infoTemporary]) {
        if (file != null) await deleteFileQuietly(file);
      }
    }
  }

  static Future<double?> _downloadVideo(String source, String output) async {
    final original = await downloadMotionArtworkSource(
      source,
      '$output.source.mp4',
    );
    try {
      if (original != null) return await _remuxVideo(original.path, output);
      final proxy = await MotionArtworkProxy.start(Uri.parse(source));
      try {
        final hls = proxy.isHls;
        final ratio = await _remuxVideo(
          proxy.source.toString(),
          output,
          hlsInput: hls,
        );
        // Opaque or redirected URLs reveal HLS only after the first request.
        // Retry failed HLS input with its scoped demuxer options, without
        // passing HLS-only flags to ordinary MP4 inputs or buffering video.
        if (ratio == null && !hls && proxy.isHls && !proxy.isClosed) {
          return await _remuxVideo(
            proxy.source.toString(),
            output,
            hlsInput: true,
          );
        }
        return ratio;
      } finally {
        await proxy.close();
      }
    } finally {
      if (original != null && await original.exists()) await original.delete();
    }
  }

  static Future<double?> _remuxVideo(
    String source,
    String output, {
    bool hlsInput = false,
  }) async {
    // Remux public video/HLS into a self-contained, silent MP4. Bound both
    // transfer time and output size; never let optional artwork block audio.
    final success = await _run([
      '-y',
      '-protocol_whitelist',
      'file,http,https,tcp,tls,crypto',
      '-rw_timeout',
      '10000000',
      // HLS byte ranges can share one MP4 URL. Reusing/prefetching HTTP
      // connections can splice the next range into an unfinished segment.
      if (hlsInput) ...[
        // Tokenized URLs retain normal suffixes, but public HLS sources can
        // use opaque segment paths. Only discovered HTTP resources are served.
        '-extension_picky',
        '0',
        '-http_multiple',
        '0',
        '-http_persistent',
        '0',
      ],
      '-i',
      source,
      '-map',
      '0:v:0',
      '-an',
      '-sn',
      '-dn',
      '-c:v',
      'copy',
      '-t',
      '30',
      '-fs',
      '25165824',
      '-movflags',
      '+faststart',
      output,
    ], timeout: const Duration(seconds: 60));
    if (!success) return null;
    final dimensions = await FFmpegProbe.imageDimensions(output);
    return dimensions == null ? null : dimensions.width / dimensions.height;
  }

  static Future<bool> _validateVideo(String path) => _run([
    '-v',
    'error',
    '-xerror',
    '-err_detect',
    'explode',
    '-i',
    path,
    '-map',
    '0:v:0',
    '-an',
    '-sn',
    '-dn',
    '-f',
    'null',
    '-',
  ], timeout: const Duration(seconds: 20));

  static Future<bool> _run(
    List<String> arguments, {
    required Duration timeout,
  }) async {
    final session = await FFmpegExecution.start(arguments);
    final completed = session.completed.then((result) => result.success);
    return completed.timeout(
      timeout,
      onTimeout: () async {
        await FFmpegExecution.cancel(session.id);
        // Wait for this session to release its file before removing partials.
        await completed.timeout(
          const Duration(seconds: 5),
          onTimeout: () => false,
        );
        return false;
      },
    );
  }
}
