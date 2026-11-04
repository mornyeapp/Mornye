import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/source_deletion_events.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/ios_container_paths.dart';
import 'package:mornye/utils/mime_utils.dart';

/// Whether the queue should run its iOS output-directory path-shape check
/// (which can replace [outputDir] with the default Documents folder when the
/// path looks like iCloud Drive or an invalid container path).
///
/// A security-scoped bookmark is the source of truth for a folder picked
/// from Files: its persisted path may legitimately contain substrings that
/// look like iCloud Drive, or fail the structural writable-path check, even
/// though the bookmark itself grants real write access. Running the
/// path-shape check anyway would reset - and via setDownloadDirectory,
/// permanently drop - a perfectly valid bookmarked folder. When a bookmark
/// is present, the queue's later bookmark-resolution step is authoritative
/// instead.
bool shouldValidateIosOutputDir({
  required bool isIOS,
  required bool isSafMode,
  required String outputDir,
  required String downloadDirectoryBookmark,
}) {
  return isIOS &&
      !isSafMode &&
      outputDir.isNotEmpty &&
      downloadDirectoryBookmark.isEmpty;
}

/// Regular expression to detect iOS app container paths.
/// Matches paths like /var/mobile/Containers/Data/Application/{UUID}
/// or /private/var/mobile/Containers/Data/Application/{UUID}
final _iosContainerRootPattern = RegExp(
  r'^(/private)?/var/mobile/Containers/Data/Application/[A-F0-9\-]+/?$',
  caseSensitive: false,
);
final _iosContainerPathWithoutLeadingSlashPattern = RegExp(
  r'^(private/)?var/mobile/Containers/Data/Application/[A-F0-9\-]+/.+',
  caseSensitive: false,
);
final _iosLegacyRelativeDocumentsPattern = RegExp(
  r'^Data/Application/[A-F0-9\-]+/Documents(?:/(.*))?$',
  caseSensitive: false,
);
final _iosNestedLegacyDocumentsPattern = RegExp(
  r'/Documents/Data/Application/[A-F0-9\-]+/Documents(?:/(.*))?$',
  caseSensitive: false,
);

String _normalizeRecoveredIosSuffix(String suffix) {
  final trimmed = suffix.trim();
  if (trimmed.isEmpty) return '';
  return trimmed.startsWith('/') ? trimmed.substring(1) : trimmed;
}

String _joinRecoveredIosPath(String documentsPath, String suffix) {
  final normalizedSuffix = _normalizeRecoveredIosSuffix(suffix);
  if (normalizedSuffix.isEmpty) return documentsPath;
  return '$documentsPath/$normalizedSuffix';
}

/// Checks if a path is a valid writable directory on iOS.
/// Returns false if:
/// - The path is the app container root (not writable)
/// - The path is an iCloud Drive path (not accessible by the backend)
/// - The path is outside the app sandbox
bool isValidIosWritablePath(String path) {
  if (!Platform.isIOS) return true;
  if (path.isEmpty) return false;
  if (!path.startsWith('/')) return false;

  if (_iosContainerRootPattern.hasMatch(path)) {
    return false;
  }

  if (path.contains('Mobile Documents') ||
      path.contains('CloudDocs') ||
      path.contains('com~apple~CloudDocs')) {
    return false;
  }

  if (_iosNestedLegacyDocumentsPattern.hasMatch(path)) {
    return false;
  }

  final containerPattern = RegExp(
    r'/var/mobile/Containers/Data/Application/[A-F0-9\-]+',
    caseSensitive: false,
  );
  final match = containerPattern.firstMatch(path);
  if (match != null) {
    final remainingPath = path.substring(match.end);
    if (remainingPath.isEmpty || remainingPath == '/') {
      return false;
    }
  }

  return true;
}

/// Validates and potentially corrects an iOS path.
/// Returns a valid Documents subdirectory path if the input is invalid.
Future<String> validateOrFixIosPath(
  String path, {
  String subfolder = 'Mornye',
}) async {
  if (!Platform.isIOS) return path;

  final docDir = await getApplicationDocumentsDirectory();
  final trimmed = rebaseIosSandboxPath(path.trim(), docDir.path);

  final nestedLegacyMatch = _iosNestedLegacyDocumentsPattern.firstMatch(
    trimmed,
  );
  if (nestedLegacyMatch != null) {
    return _joinRecoveredIosPath(docDir.path, nestedLegacyMatch.group(1) ?? '');
  }

  if (isValidIosWritablePath(trimmed)) {
    return trimmed;
  }

  final candidates = <String>[];

  if (trimmed.isNotEmpty) {
    candidates.add(trimmed);
  }

  if (_iosContainerPathWithoutLeadingSlashPattern.hasMatch(trimmed)) {
    candidates.add('/$trimmed');
  }

  final legacyRelativeMatch = _iosLegacyRelativeDocumentsPattern.firstMatch(
    trimmed,
  );
  if (legacyRelativeMatch != null) {
    candidates.add(
      _joinRecoveredIosPath(docDir.path, legacyRelativeMatch.group(1) ?? ''),
    );
  }

  if (!trimmed.startsWith('/')) {
    final documentsMarker = 'Documents/';
    final index = trimmed.indexOf(documentsMarker);
    if (index >= 0) {
      final suffix = trimmed.substring(index + documentsMarker.length).trim();
      candidates.add(_joinRecoveredIosPath(docDir.path, suffix));
    }
  }

  for (final candidate in candidates) {
    if (isValidIosWritablePath(candidate)) {
      return candidate;
    }
  }

  final musicDir = Directory('${docDir.path}/$subfolder');
  if (!await musicDir.exists()) {
    await musicDir.create(recursive: true);
  }
  return musicDir.path;
}

/// Detailed result for iOS path validation
class IosPathValidationResult {
  final bool isValid;
  final String? errorReason;

  const IosPathValidationResult({required this.isValid, this.errorReason});
}

/// Validates an iOS path and returns detailed information about the result.
/// A bookmark supplied by the native picker grants access independently of
/// the folder's path shape. Actual access is checked when resolving that grant.
IosPathValidationResult validateIosPath(String path, {String bookmark = ''}) {
  if (path.isEmpty) {
    return const IosPathValidationResult(
      isValid: false,
      errorReason: 'Path is empty',
    );
  }

  if (!path.startsWith('/')) {
    return const IosPathValidationResult(
      isValid: false,
      errorReason:
          'Invalid path format. Please choose a local folder from Files.',
    );
  }

  if (bookmark.trim().isNotEmpty) {
    return const IosPathValidationResult(isValid: true);
  }

  if (_iosContainerRootPattern.hasMatch(path)) {
    return const IosPathValidationResult(
      isValid: false,
      errorReason:
          'Cannot write to app container root. Please choose a subfolder like Documents.',
    );
  }

  if (path.contains('Mobile Documents') ||
      path.contains('CloudDocs') ||
      path.contains('com~apple~CloudDocs')) {
    return const IosPathValidationResult(
      isValid: false,
      errorReason:
          'iCloud Drive is not supported. Please choose a local folder.',
    );
  }

  if (_iosNestedLegacyDocumentsPattern.hasMatch(path)) {
    return const IosPathValidationResult(
      isValid: false,
      errorReason:
          'Invalid iOS app folder path. Please choose App Documents or another local folder.',
    );
  }

  final containerPattern = RegExp(
    r'/var/mobile/Containers/Data/Application/[A-F0-9\-]+',
    caseSensitive: false,
  );
  final match = containerPattern.firstMatch(path);
  if (match != null) {
    final remainingPath = path.substring(match.end);
    if (remainingPath.isEmpty || remainingPath == '/') {
      return const IosPathValidationResult(
        isValid: false,
        errorReason:
            'Cannot write to app container root. Please use the default folder or choose a different location.',
      );
    }
  }

  return const IosPathValidationResult(isValid: true);
}

class FileAccessStat {
  final int? size;
  final DateTime? modified;

  const FileAccessStat({this.size, this.modified});
}

/// Deletes [file] when it exists and swallows any error.
Future<void> deleteFileQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {}
}

bool isContentUri(String? path) {
  return path != null && path.startsWith('content://');
}

bool isSameContentUri(String? first, String? second) {
  if (first == null || second == null) return false;
  if (first == second) return true;
  if (!isContentUri(first) || !isContentUri(second)) return false;

  String decode(String value) {
    try {
      return Uri.decodeFull(value);
    } catch (_) {
      return value;
    }
  }

  return decode(first) == decode(second);
}

/// Pattern matching CUE virtual path suffixes like #track01, #track12, etc.
final _cueTrackSuffix = RegExp(r'#track\d+$');

const cueVirtualTrackRequiresSplitMessage =
    'This CUE track is virtual. Use Split into Tracks first.';

/// Whether the path is a CUE virtual path (contains #trackNN suffix).
bool isCueVirtualPath(String? path) {
  return path != null && _cueTrackSuffix.hasMatch(path);
}

/// Strip the #trackNN suffix from a CUE virtual path to get the base .cue path.
/// Returns the path unchanged if it's not a CUE virtual path.
String stripCueTrackSuffix(String path) {
  return path.replaceFirst(_cueTrackSuffix, '');
}

Future<bool> fileExists(String? path) async {
  if (path == null || path.isEmpty) return false;
  // Network identities are resolved by the built-in player, not File.exists.
  if (path.startsWith('network://')) return true;
  final realPath = isCueVirtualPath(path) ? stripCueTrackSuffix(path) : path;
  if (isContentUri(realPath)) {
    // A phone's content URI can arrive with synced statistics; a computer has
    // no way to open one.
    if (isDesktopPlatform) return false;
    return PlatformBridge.safExists(realPath);
  }
  return File(realPath).exists();
}

/// Bounded, tri-state checks for destructive library cleanup. Unknown results
/// retain their database rows. CUE tracks are checked against the backing file.
Future<Map<String, bool?>> fileExistenceByPath(List<String> paths) async {
  final realPaths = {for (final path in paths) path: stripCueTrackSuffix(path)};
  final results = <String, bool?>{};
  final unique = realPaths.values.toSet();
  final saf = unique.where(isContentUri).toList(growable: false);
  const batchSize = 64;
  for (var start = 0; start < saf.length; start += batchSize) {
    final end = start + batchSize < saf.length ? start + batchSize : saf.length;
    final batch = saf.sublist(start, end);
    try {
      results.addAll(await PlatformBridge.safExistsBatch(batch));
    } catch (_) {
      // Missing native method on an older build is also inconclusive.
    }
  }
  // Offline network paths remain inconclusive during destructive cleanup.
  final local = unique
      .where((path) => !isContentUri(path) && !path.startsWith('network://'))
      .toList();
  const concurrency = 16;
  for (var start = 0; start < local.length; start += concurrency) {
    final end = start + concurrency < local.length
        ? start + concurrency
        : local.length;
    await Future.wait(
      local.sublist(start, end).map((path) async {
        if (path.isEmpty) return;
        try {
          final stat = await File(path).stat();
          if (stat.type != FileSystemEntityType.notFound) {
            results[path] = true;
          } else {
            // Dart's stat also returns notFound for permission errors. Opening
            // exposes the OS error without reading the audio file's contents.
            final handle = await File(path).open();
            await handle.close();
            results[path] = true;
          }
        } on FileSystemException catch (error) {
          final code = error.osError?.errorCode;
          final absent = code == 2 || code == (Platform.isWindows ? 3 : 20);
          results[path] = absent ? false : null;
        } catch (_) {
          results[path] = null;
        }
      }),
    );
  }
  return {for (final item in realPaths.entries) item.key: results[item.value]};
}

/// Deletes [path] and reports whether the file is confirmed absent afterward.
///
/// SAF providers are allowed to reject a delete request by returning `false`.
/// Callers that also remove a Library row must only do so when this returns
/// `true`, otherwise the app would hide a file that still exists on storage.
Future<bool> deleteFile(
  String? path, {
  SourceDeletionEvents? deletionEvents,
  NetworkStorageService? networkStorage,
}) async {
  if (path == null || path.isEmpty) return false;
  if (path.startsWith('EXISTS:')) {
    path = path.substring(7).trim();
    if (path.isEmpty) return false;
  }
  // CUE virtual paths should NOT be deleted through this function —
  // deleting album.cue would remove ALL tracks. Callers should handle
  // CUE deletion specially (e.g. only delete when all tracks are removed).
  if (isCueVirtualPath(path)) return false;
  bool confirmedAbsent;
  try {
    if (path.startsWith('network://')) {
      confirmedAbsent = await (networkStorage ?? NetworkStorageService.instance)
          .deleteFile(path);
    } else if (isContentUri(path)) {
      final deleted = await PlatformBridge.safDelete(path);
      confirmedAbsent = deleted || !await PlatformBridge.safExists(path);
    } else {
      final source = path;
      return await (deletionEvents ?? SourceDeletionEvents.instance).delete(
        source,
        () async {
          final file = File(source);
          if (await file.exists()) await file.delete();
          return !await file.exists();
        },
      );
    }
  } catch (_) {
    return false;
  }
  if (confirmedAbsent) {
    await (deletionEvents ?? SourceDeletionEvents.instance).publish(path);
  }
  return confirmedAbsent;
}

Future<FileAccessStat?> fileStat(String? path) async {
  if (path == null || path.isEmpty) return null;
  if (path.startsWith('network://')) return const FileAccessStat();
  final realPath = isCueVirtualPath(path) ? stripCueTrackSuffix(path) : path;
  if (isContentUri(realPath)) {
    final stat = await PlatformBridge.safStat(realPath);
    final exists = stat['exists'] as bool? ?? true;
    if (!exists) return null;
    return FileAccessStat(
      size: stat['size'] as int?,
      modified: stat['modified'] != null
          ? DateTime.fromMillisecondsSinceEpoch(stat['modified'] as int)
          : null,
    );
  }

  final stat = await FileStat.stat(realPath);
  if (stat.type == FileSystemEntityType.notFound) {
    // Dart stat hides every OS error behind notFound. A metadata-only lookup
    // exposes the errno without opening or copying audio on the normal path.
    try {
      return FileAccessStat(size: await File(realPath).length());
    } on FileSystemException catch (error) {
      final code = error.osError?.errorCode;
      if (code == 2 || code == (Platform.isWindows ? 3 : 20)) return null;
      rethrow;
    }
  }
  return FileAccessStat(size: stat.size, modified: stat.modified);
}

Future<void> openFile(String path) async {
  if (isCueVirtualPath(path)) {
    throw Exception(cueVirtualTrackRequiresSplitMessage);
  }

  final realPath = path;
  if (isContentUri(realPath)) {
    await PlatformBridge.openContentUri(realPath, mimeType: '');
    return;
  }
  if (isDesktopPlatform) {
    // open_filex has no desktop implementation; the OS opens file URIs with
    // the user's default application.
    if (!await launchUrl(Uri.file(realPath))) {
      throw Exception('No application can open $realPath');
    }
    return;
  }
  final mimeType = audioMimeTypeForPath(realPath);
  final result = await OpenFilex.open(realPath, type: mimeType);
  if (result.type != ResultType.done) {
    throw Exception(result.message);
  }
}
