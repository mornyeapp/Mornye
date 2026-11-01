import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/audio_analysis_models.dart';
import 'package:mornye/services/network_audio_analysis_input.dart';
import 'package:mornye/services/platform_bridge.dart';

/// On-disk analysis bundles: `{key}.json`, `{key}.png` and `{key}_ch{n}.png`
/// in `audio_analysis_cache` under the application support directory. The
/// directory name, key derivation and file names are persisted on devices.
abstract final class AudioAnalysisDiskCache {
  /// The one place that names the cache directory; it does not create it.
  static Directory directoryIn(String appSupportPath) =>
      Directory('$appSupportPath/audio_analysis_cache');

  static Future<void> clearCache(String filePath) async {
    try {
      final dir = await cacheDir();
      final key = cacheKey(filePath);
      final jsonFile = File('${dir.path}/$key.json');
      if (await jsonFile.exists()) {
        await jsonFile.delete();
      }
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.path.replaceAll('\\', '/').split('/').last;
        final isCombined = name == '$key.png';
        final isChannel = name.startsWith('${key}_ch') && name.endsWith('.png');
        if (isCombined || isChannel) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }

  static String cacheKey(String filePath) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(filePath)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16);
  }

  static Future<Directory> cacheDir() async {
    final appSupport = await getApplicationSupportDirectory();
    final dir = directoryIn(appSupport.path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static final cacheBudget = AudioAnalysisCache();

  static Future<void> trimCache() async {
    try {
      await cacheBudget.trim(await cacheDir());
    } catch (_) {
      // Cache maintenance must not interrupt the selected track's analysis.
    }
  }

  static Future<AudioAnalysisData?> loadFromCache(
    String filePath,
    NetworkAudioAnalysisInput networkInput,
  ) async {
    try {
      final dir = await cacheDir();
      final key = cacheKey(filePath);
      final file = File('${dir.path}/$key.json');
      if (!await file.exists()) return null;

      final json = Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map,
      );
      if (json['cacheVersion'] != AudioAnalysisData.cacheVersion) {
        return null;
      }
      final cachedSize = json['fileSize'] as int;

      if (NetworkAudioAnalysisInput.isNetwork(filePath)) {
        final currentSize = await networkInput.length(filePath);
        if (currentSize <= 0 || currentSize != cachedSize) return null;
      } else if (!filePath.startsWith('content://')) {
        final currentSize = await File(filePath).length();
        if (currentSize != cachedSize) return null;
      } else {
        final stat = await PlatformBridge.safStat(filePath);
        final currentSize = (stat['size'] as num?)?.toInt() ?? 0;
        if (currentSize > 0 && currentSize != cachedSize) return null;
      }

      final data = AudioAnalysisData.fromJson(json);
      await file.setLastModified(DateTime.now());
      return data;
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveToCache(
    String filePath,
    AudioAnalysisData data,
  ) async {
    try {
      final dir = await cacheDir();
      final key = cacheKey(filePath);
      final file = File('${dir.path}/$key.json');
      await file.writeAsString(jsonEncode(data.toJson()));
    } catch (_) {}
  }

  static Future<void> saveSpectrogramToCache(
    String filePath,
    ui.Image image, {
    required int channel,
  }) async {
    try {
      final dir = await cacheDir();
      final key = cacheKey(filePath);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData != null) {
        final file = File(
          '${dir.path}/${_spectrogramCacheFileName(key, channel)}',
        );
        await file.writeAsBytes(byteData.buffer.asUint8List());
        await cacheBudget.trim(dir);
      }
    } catch (_) {}
  }

  static String _spectrogramCacheFileName(String key, int channel) =>
      channel < 0 ? '$key.png' : '${key}_ch$channel.png';

  static Future<ui.Image?> loadSpectrogramFromCache(
    String filePath, {
    required int channel,
  }) async {
    try {
      final dir = await cacheDir();
      final key = cacheKey(filePath);
      final file = File(
        '${dir.path}/${_spectrogramCacheFileName(key, channel)}',
      );
      if (!await file.exists()) return null;

      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        return (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    } catch (_) {
      return null;
    }
  }
}

/// Evicts complete analysis bundles (metadata, combined image and channels).
/// Leases protect cache reads/writes while a card changes tracks or channels.
class AudioAnalysisCache {
  final Map<String, int> _active = {};
  Future<void> _sweep = Future<void>.value();
  static final _filename = RegExp(r'^([a-f0-9]+)(?:_ch\d+)?\.(json|png)$');

  void Function() retain(String key) {
    _active.update(key, (count) => count + 1, ifAbsent: () => 1);
    var released = false;
    return () {
      if (released) return;
      released = true;
      final count = _active[key]! - 1;
      if (count == 0) {
        _active.remove(key);
      } else {
        _active[key] = count;
      }
    };
  }

  Future<void> trim(
    Directory directory, {
    int maxBytes = 64 * 1024 * 1024,
    int targetBytes = 48 * 1024 * 1024,
  }) {
    assert(targetBytes >= 0 && targetBytes <= maxBytes);
    _sweep = _sweep.then((_) async {
      try {
        if (!await directory.exists()) return;
        final bundles = <String, _AnalysisBundle>{};
        var total = 0;
        await for (final file in directory.list(followLinks: false)) {
          if (file is! File) continue;
          final match = _filename.firstMatch(file.uri.pathSegments.last);
          if (match == null) continue;
          final stat = await file.stat();
          if (stat.type != FileSystemEntityType.file) continue;
          final bundle = bundles.putIfAbsent(match[1]!, _AnalysisBundle.new);
          bundle.files.add(file);
          if (bundle.modified.isBefore(stat.modified)) {
            bundle.modified = stat.modified;
          }
          total += stat.size;
        }
        if (total <= maxBytes) return;
        final oldest = bundles.entries.toList()
          ..sort((a, b) => a.value.modified.compareTo(b.value.modified));
        for (final entry in oldest) {
          if (total <= targetBytes) break;
          if (_active.containsKey(entry.key)) continue;
          for (final file in entry.value.files) {
            // A cache reader can acquire a lease during the asynchronous scan.
            if (_active.containsKey(entry.key)) break;
            try {
              final size = await file.length();
              if (_active.containsKey(entry.key)) break;
              await file.delete();
              total -= size;
            } on FileSystemException {
              // Cache cleanup or a metadata refresh can race with this sweep.
            }
          }
        }
      } on FileSystemException {
        // Optional cache maintenance must not fail audio analysis.
      }
    });
    return _sweep;
  }
}

class _AnalysisBundle {
  final List<File> files = [];
  DateTime modified = DateTime.fromMillisecondsSinceEpoch(0);
}
