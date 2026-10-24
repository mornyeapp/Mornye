import 'dart:io';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/file_access.dart';

/// A song file on the phone that the desktop can receive.
class LinkPhoneFile {
  const LinkPhoneFile({
    required this.fileId,
    required this.source,
    this.extension,
  });

  /// The [TrackRef.fileId] the desktop knows it by.
  final String fileId;

  /// A path or a content URI.
  final String source;

  /// The lowercase extension of a path; null for a content URI, whose copy
  /// names it.
  final String? extension;
}

/// The lowercase extension of [path] when the desktop accepts it.
String? _uploadExtension(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return null;
  final extension = name.substring(dot + 1).toLowerCase();
  return linkUploadExtensions.contains(extension) ? extension : null;
}

/// Sends the phone's own song files to the paired desktop, so it can play
/// songs only the phone has.
class LinkPhoneFiles {
  LinkPhoneFiles({Future<String?> Function(String uri)? copyContentUri})
    : _copyContentUri = copyContentUri ?? PlatformBridge.copyContentUriToTemp;

  final Future<String?> Function(String uri) _copyContentUri;
  int _run = 0;

  /// Starts sending another queue; the uploads of the one before stop.
  int begin() => ++_run;

  /// Whether [run] is still the queue being sent.
  bool isCurrent(int run) => run == _run;

  /// The phone's file behind [item], or null when it streams or the desktop
  /// does not take its format.
  Future<LinkPhoneFile?> fileFor(MediaItem item) async {
    final source = item.extras?['source']?.toString() ?? '';
    if (isContentUri(source)) {
      return LinkPhoneFile(fileId: linkFileIdFor(source, 0), source: source);
    }
    if (!source.startsWith('/')) return null;
    final extension = _uploadExtension(source);
    if (extension == null) return null;
    try {
      final size = await File(source).length();
      return LinkPhoneFile(
        fileId: linkFileIdFor(source, size),
        source: source,
        extension: extension,
      );
    } on FileSystemException {
      return null;
    }
  }

  /// Uploads [file] through [client]; [onProgress] gets the bytes sent and
  /// the file's size. A content URI is copied to a temporary file first.
  Future<void> upload(
    LinkClientApi client,
    LinkPhoneFile file, {
    void Function(int sent, int total)? onProgress,
  }) async {
    if (file.extension case final extension?) {
      await _send(
        client,
        file.fileId,
        extension,
        File(file.source),
        onProgress,
      );
      return;
    }
    final copy = await _copyContentUri(file.source);
    if (copy == null) {
      throw const LinkException('unavailable', 'The song file is unreadable');
    }
    final temporary = File(copy);
    try {
      final extension = _uploadExtension(copy);
      if (extension == null) {
        throw const LinkException('invalid', 'The computer cannot play it');
      }
      await _send(client, file.fileId, extension, temporary, onProgress);
    } finally {
      await deleteFileQuietly(temporary);
    }
  }

  Future<void> _send(
    LinkClientApi client,
    String fileId,
    String extension,
    File local,
    void Function(int sent, int total)? onProgress,
  ) async {
    final total = await local.length();
    await client.upload(
      '$fileId.$extension',
      local,
      onProgress: onProgress == null ? null : (sent) => onProgress(sent, total),
    );
  }
}
