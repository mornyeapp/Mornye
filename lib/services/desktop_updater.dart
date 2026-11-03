import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/native_file_hash.dart';
import 'package:mornye/services/update_checker.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('DesktopUpdater');

class DesktopUpdateException implements Exception {
  final String message;
  const DesktopUpdateException(this.message);

  @override
  String toString() => 'DesktopUpdateException: $message';
}

/// Downloads a desktop release package, checks it against the release's
/// SHA256SUMS.txt (and GitHub's digest when present), and applies it the way
/// the running build was installed (see [UpdateInstallKind]).
class DesktopUpdater {
  static const _streamIdleTimeout = Duration(seconds: 60);
  static final _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');
  static final _safeName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

  final http.Client? _client;
  final Directory? _downloadDirectory;

  DesktopUpdater({http.Client? client, Directory? downloadDirectory})
    : _client = client,
      _downloadDirectory = downloadDirectory;

  /// The digest the package must have. SHA256SUMS.txt is preferred; GitHub's
  /// asset digest is used when the release has no SHA256SUMS.txt, and both
  /// must agree when both exist. A package with neither is refused.
  Future<String> expectedSha256(UpdateInfo info, http.Client client) async {
    final assetName = info.assetName;
    if (assetName == null) {
      throw const DesktopUpdateException('The update has no package');
    }
    final fromDigest = info.assetSha256?.toLowerCase();
    String? fromChecksums;
    final checksumsUrl = info.checksumsUrl;
    if (checksumsUrl != null) {
      final uri = Uri.tryParse(checksumsUrl);
      if (uri == null || uri.scheme != 'https') {
        throw const DesktopUpdateException('SHA256SUMS.txt is not HTTPS');
      }
      final response = await client
          .get(uri)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw DesktopUpdateException(
          'SHA256SUMS.txt returned ${response.statusCode}',
        );
      }
      fromChecksums = UpdateChecker.sha256FromChecksums(
        response.body,
        assetName,
      );
      if (fromChecksums == null) {
        throw DesktopUpdateException('SHA256SUMS.txt does not list $assetName');
      }
    }

    if (fromChecksums != null &&
        fromDigest != null &&
        fromChecksums != fromDigest) {
      throw const DesktopUpdateException(
        'SHA256SUMS.txt and the GitHub digest disagree',
      );
    }
    final expected = fromChecksums ?? fromDigest;
    if (expected == null || !_sha256Pattern.hasMatch(expected)) {
      throw const DesktopUpdateException('The release publishes no SHA-256');
    }
    return expected;
  }

  /// Downloads the package of [info] into a temporary folder and returns it
  /// once its SHA-256 matches.
  Future<File> download(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
  }) async {
    final assetName = info.assetName ?? '';
    final uri = Uri.tryParse(info.assetUrl ?? '');
    if (!info.hasDesktopPackage || uri == null || uri.scheme != 'https') {
      throw const DesktopUpdateException('No HTTPS package to download');
    }
    if (!_safeName.hasMatch(assetName) || p.basename(assetName) != assetName) {
      throw DesktopUpdateException('Unsafe package name: $assetName');
    }

    final ownedClient = _client == null;
    final client = _client ?? http.Client();
    IOSink? sink;
    File? partFile;
    try {
      final expected = await expectedSha256(info, client);
      final directory =
          _downloadDirectory ??
          Directory(
            p.join((await getTemporaryDirectory()).path, 'mornye-update'),
          );
      await directory.create(recursive: true);
      final target = File(p.join(directory.path, assetName));
      partFile = File('${target.path}.part');

      final response = await client
          .send(http.Request('GET', uri))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw DesktopUpdateException(
          'Download returned ${response.statusCode}',
        );
      }
      final total = response.contentLength ?? 0;
      sink = partFile.openWrite();
      var received = 0;
      onProgress?.call(received, total);
      await for (final chunk in response.stream.timeout(_streamIdleTimeout)) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (total > 0 && received != total) {
        throw DesktopUpdateException('Incomplete download: $received/$total');
      }

      final actual = await hashFileSha256(partFile.path);
      if (actual != expected) {
        throw const DesktopUpdateException('SHA-256 verification failed');
      }
      if (await target.exists()) await target.delete();
      final verified = await partFile.rename(target.path);
      _log.i('Downloaded verified update to ${verified.path}');
      return verified;
    } catch (error) {
      try {
        await sink?.close();
      } catch (_) {}
      if (partFile != null && await partFile.exists()) {
        await partFile.delete();
      }
      _log.e('Desktop update download failed: $error');
      rethrow;
    } finally {
      if (ownedClient) client.close();
    }
  }

  /// Windows: starts the Inno Setup installer silently; it closes this app,
  /// installs over it and relaunches it (/RELAUNCH=1). The caller quits.
  Future<void> startWindowsInstaller(File installer) async {
    await Process.start(installer.path, const [
      '/SILENT',
      '/SP-',
      '/SUPPRESSMSGBOXES',
      '/NORESTART',
      '/CLOSEAPPLICATIONS',
      '/RELAUNCH=1',
    ], mode: ProcessStartMode.detached);
  }

  /// macOS: mounts the disk image and shows it in Finder. The app is not
  /// replaced in place while releases are unsigned.
  Future<void> openDiskImage(File diskImage) async {
    final result = await Process.run('open', [diskImage.path]);
    if (result.exitCode != 0) {
      throw DesktopUpdateException('open failed: ${result.stderr}');
    }
  }

  /// Linux AppImage: moves [downloaded] over [appImagePath] with an atomic
  /// rename in the same folder. The running instance keeps its mounted
  /// image until it exits.
  Future<void> replaceAppImage(File downloaded, String appImagePath) async {
    final target = File(appImagePath);
    if (!p.isAbsolute(appImagePath) || !await target.exists()) {
      throw DesktopUpdateException('AppImage not found: $appImagePath');
    }
    final staging = File(
      p.join(target.parent.path, '.${p.basename(appImagePath)}.update'),
    );
    try {
      await downloaded.copy(staging.path);
      final chmod = await Process.run('chmod', ['755', staging.path]);
      if (chmod.exitCode != 0) {
        throw DesktopUpdateException('chmod failed: ${chmod.stderr}');
      }
      await staging.rename(target.path);
    } catch (_) {
      if (await staging.exists()) await staging.delete();
      rethrow;
    }
    try {
      await downloaded.delete();
    } catch (error) {
      _log.w('Could not remove the downloaded AppImage: $error');
    }
    _log.i('Replaced $appImagePath');
  }

  /// Starts [appImagePath] once this process has had a moment to exit, so a
  /// single-instance check does not hand the launch back to it. The caller
  /// quits.
  Future<void> restartAppImage(String appImagePath) async {
    await Process.start('/bin/sh', [
      '-c',
      r'sleep 1; exec "$0"',
      appImagePath,
    ], mode: ProcessStartMode.detached);
  }
}
