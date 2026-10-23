import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('ApkDownloader');

typedef ProgressCallback = void Function(int received, int total);

Future<String> _hashApkInBackground(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

class ApkDownloader {
  static const _streamIdleTimeout = Duration(seconds: 60);
  static const _progressInterval = Duration(milliseconds: 500);

  static Future<String?> downloadApk({
    required String url,
    required String version,
    String? expectedSha256,
    ProgressCallback? onProgress,
    http.Client? client,
    Directory? downloadDirectory,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') {
      _log.e('Refusing to download from invalid or non-HTTPS URL');
      return null;
    }

    final ownedClient = client == null;
    final effectiveClient = client ?? http.Client();
    IOSink? sink;

    try {
      final dir = downloadDirectory ?? await getExternalStorageDirectory();
      if (dir == null) {
        _log.e('Could not get storage directory');
        return null;
      }
      await dir.create(recursive: true);

      final safeVersion = version.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final finalFile = File(
        '${dir.path}${Platform.pathSeparator}Mornye-$safeVersion.apk',
      );
      final partFile = File('${finalFile.path}.part');
      final metadataFile = File('${partFile.path}.json');
      final metadata = await _readResumeMetadata(metadataFile);

      var resumeOffset = 0;
      if (await partFile.exists() && metadata?['url'] == url) {
        resumeOffset = await partFile.length();
      } else {
        if (await partFile.exists()) await partFile.delete();
        if (await metadataFile.exists()) await metadataFile.delete();
      }

      final request = http.Request('GET', uri);
      if (resumeOffset > 0) {
        request.headers['Range'] = 'bytes=$resumeOffset-';
        final etag = metadata?['etag']?.toString() ?? '';
        if (etag.isNotEmpty) request.headers['If-Range'] = etag;
      }

      final response = await effectiveClient
          .send(request)
          .timeout(const Duration(seconds: 30));
      final isResume = resumeOffset > 0 && response.statusCode == 206;
      if (response.statusCode == 206 &&
          !_contentRangeStartsAt(response, resumeOffset)) {
        _log.w('Server returned an invalid Content-Range; clearing partial');
        await _discardPartial(partFile, metadataFile);
        return null;
      }
      if (response.statusCode == 416) {
        _log.w('Server rejected the saved download range; clearing partial');
        await _discardPartial(partFile, metadataFile);
        return null;
      }
      if (response.statusCode != 200 && response.statusCode != 206) {
        _log.e('Failed to download: ${response.statusCode}');
        return null;
      }

      if (!isResume) resumeOffset = 0;
      final total = _responseTotalBytes(response, resumeOffset);
      await metadataFile.writeAsString(
        jsonEncode({
          'url': url,
          'etag': response.headers['etag'] ?? '',
          'total': total,
        }),
        flush: true,
      );

      sink = partFile.openWrite(
        mode: isResume ? FileMode.append : FileMode.writeOnly,
      );
      var received = resumeOffset;
      var reported = received;
      final progressClock = Stopwatch()..start();
      onProgress?.call(received, total);
      await for (final chunk in response.stream.timeout(_streamIdleTimeout)) {
        sink.add(chunk);
        received += chunk.length;
        if (progressClock.elapsed >= _progressInterval) {
          onProgress?.call(received, total);
          reported = received;
          progressClock.reset();
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      // Always deliver the final byte count, including unknown-length streams,
      // without leaving a trailing timer that could outlive the download.
      if (received != reported) onProgress?.call(received, total);

      if (total > 0 && received != total) {
        _log.w('Incomplete APK download: $received/$total bytes');
        return null;
      }
      if (!await _looksLikeApk(partFile)) {
        _log.e('Downloaded update is not a valid APK/ZIP payload');
        await _discardPartial(partFile, metadataFile);
        return null;
      }

      final expected = expectedSha256?.trim().toLowerCase() ?? '';
      if (expected.isNotEmpty) {
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(expected)) {
          _log.e('Release supplied an invalid SHA-256 digest');
          await _discardPartial(partFile, metadataFile);
          return null;
        }
        final actual = await _hashApk(partFile);
        if (actual != expected) {
          _log.e('APK SHA-256 verification failed');
          await _discardPartial(partFile, metadataFile);
          return null;
        }
      }

      if (await finalFile.exists()) await finalFile.delete();
      await partFile.rename(finalFile.path);
      if (await metadataFile.exists()) await metadataFile.delete();
      _log.i(
        'Downloaded verified update to ${finalFile.path}'
        '${expected.isEmpty ? ' (release digest unavailable)' : ''}',
      );
      return finalFile.path;
    } catch (e) {
      _log.e('Update download paused after error: $e');
      return null;
    } finally {
      try {
        await sink?.close();
      } catch (error) {
        _log.w('Failed to close partial update file: $error');
      } finally {
        if (ownedClient) effectiveClient.close();
      }
    }
  }

  static Future<String> _hashApk(File file) async {
    try {
      final result = await PlatformBridge.runNativeDataJob({
        'operation': 'hash_file',
        'path': file.path,
      });
      final digest = result['sha256'];
      if (digest is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
        throw const FormatException('Invalid native APK digest');
      }
      return digest;
    } on MissingPluginException {
      return compute(_hashApkInBackground, file.path);
    }
  }

  static Future<Map<String, dynamic>?> _readResumeMetadata(File file) async {
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  static bool _contentRangeStartsAt(
    http.StreamedResponse response,
    int expected,
  ) {
    final value = response.headers['content-range'] ?? '';
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(value);
    return match != null && int.tryParse(match.group(1)!) == expected;
  }

  static int _responseTotalBytes(
    http.StreamedResponse response,
    int resumeOffset,
  ) {
    final range = response.headers['content-range'] ?? '';
    final match = RegExp(r'/([0-9]+)$').firstMatch(range);
    final rangeTotal = match == null ? null : int.tryParse(match.group(1)!);
    return rangeTotal ??
        ((response.contentLength ?? 0) > 0
            ? resumeOffset + response.contentLength!
            : 0);
  }

  static Future<bool> _looksLikeApk(File file) async {
    try {
      if (await file.length() < 4) return false;
      final header = await file
          .openRead(0, 4)
          .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));
      return header.length == 4 &&
          header[0] == 0x50 &&
          header[1] == 0x4b &&
          header[2] == 0x03 &&
          header[3] == 0x04;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _discardPartial(File part, File metadata) async {
    if (await part.exists()) await part.delete();
    if (await metadata.exists()) await metadata.delete();
  }

  static Future<void> installApk(String filePath) async {
    try {
      final result = await OpenFilex.open(filePath);
      _log.i('Open result: ${result.type} - ${result.message}');
    } catch (e) {
      _log.e('Install error: $e');
    }
  }
}
