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

/// An upload as it starts: the name the desktop stores it under, its size,
/// and whether a player can start it before all of it arrives.
typedef LinkUploadStart = ({String name, int size, bool streamable});

/// Whether a player can start [file] before all of it arrives. MP4 files
/// keep their index (`moov`) at either end; one after the audio (`mdat`)
/// arrives last.
Future<bool> _startsBeforeWhole(File file, String extension) async {
  if (!const {'m4a', 'mp4'}.contains(extension)) return true;
  final input = await file.open();
  try {
    final length = await input.length();
    var offset = 0;
    for (var boxes = 0; boxes < 64 && offset + 8 <= length; boxes++) {
      await input.setPosition(offset);
      final header = await input.read(16);
      if (header.length < 8) return false;
      final type = String.fromCharCodes(header.sublist(4, 8));
      if (type == 'moov') return true;
      if (type == 'mdat') return false;
      var size = header.take(4).fold(0, (value, byte) => value << 8 | byte);
      if (size == 1 && header.length == 16) {
        size = header.skip(8).fold(0, (value, byte) => value << 8 | byte);
      }
      if (size < 8) return false;
      offset += size;
    }
    return false;
  } finally {
    await input.close();
  }
}

/// The lowercase extension of [path] when the desktop accepts it.
String? linkUploadExtensionOf(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return null;
  final extension = name.substring(dot + 1).toLowerCase();
  return linkUploadExtensions.contains(extension) ? extension : null;
}

/// Sends the phone's own song files to the paired desktop, so it can play
/// songs only the phone has.
class LinkPhoneFiles {
  LinkPhoneFiles({
    Future<String?> Function(String uri)? copyContentUri,
    Future<Future<void> Function()> Function(String desktopName)?
    acquireTransfer,
  }) : _copyContentUri = copyContentUri ?? PlatformBridge.copyContentUriToTemp,
       _acquireTransfer = acquireTransfer;

  final Future<String?> Function(String uri) _copyContentUri;
  final Future<Future<void> Function()> Function(String)? _acquireTransfer;
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
    final extension = linkUploadExtensionOf(source);
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

  /// Uploads [file] through [client]. [onStart] learns its name and size
  /// before the first byte goes; [onProgress] gets the bytes sent and the
  /// file's size. A content URI is copied to a temporary file first.
  Future<void> upload(
    LinkClientApi client,
    LinkPhoneFile file, {
    void Function(LinkUploadStart start)? onStart,
    void Function(int sent, int total)? onProgress,
  }) async {
    final release = await _acquireTransfer?.call(client.server.name);
    try {
      await _upload(client, file, onStart: onStart, onProgress: onProgress);
    } finally {
      await release?.call();
    }
  }

  Future<void> _upload(
    LinkClientApi client,
    LinkPhoneFile file, {
    void Function(LinkUploadStart start)? onStart,
    void Function(int sent, int total)? onProgress,
  }) async {
    if (file.extension case final extension?) {
      await _send(
        client,
        file.fileId,
        extension,
        File(file.source),
        onStart,
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
      final extension = linkUploadExtensionOf(copy);
      if (extension == null) {
        throw const LinkException('invalid', 'The computer cannot play it');
      }
      await _send(
        client,
        file.fileId,
        extension,
        temporary,
        onStart,
        onProgress,
      );
    } finally {
      await deleteFileQuietly(temporary);
    }
  }

  Future<void> _send(
    LinkClientApi client,
    String fileId,
    String extension,
    File local,
    void Function(LinkUploadStart start)? onStart,
    void Function(int sent, int total)? onProgress,
  ) async {
    final total = await local.length();
    final name = '$fileId.$extension';
    onStart?.call((
      name: name,
      size: total,
      streamable: await _startsBeforeWhole(local, extension),
    ));
    await client.upload(
      name,
      local,
      onProgress: onProgress == null ? null : (sent) => onProgress(sent, total),
    );
  }
}
