import 'dart:convert';
import 'dart:io';

import 'package:mornye/utils/windows_path_identity.dart';

const _androidStoragePathAliases = <String>[
  '/storage/emulated/0',
  '/storage/emulated/legacy',
  '/storage/self/primary',
  '/sdcard',
  '/mnt/sdcard',
];

/// Audio file extensions that the app commonly produces or converts between.
/// Used to generate extension-stripped match keys so that a file converted from
/// one format to another (e.g. .flac → .opus) is still recognised as the same
/// track.
const _audioExtensions = <String>[
  '.flac',
  '.m4a',
  '.mp3',
  '.opus',
  '.ogg',
  '.wav',
  '.aiff',
  '.aif',
  '.aac',
];

const _maxPathMatchKeyCacheSize = 6000;
final Map<String, Set<String>> _pathMatchKeyCache = <String, Set<String>>{};

String? _stripAudioExtension(String path) {
  final lower = path.toLowerCase();
  for (final ext in _audioExtensions) {
    if (lower.endsWith(ext)) {
      return path.substring(0, path.length - ext.length);
    }
  }
  return null;
}

/// Path aliases that refer to the same physical file.
///
/// Unlike [buildPathMatchKeys], this deliberately keeps the audio extension.
/// A converted `.flac` and `.opus` can coexist on disk and must not be treated
/// as the same physical file by destructive operations.
Set<String> buildPhysicalPathMatchKeys(String? filePath) =>
    _buildPathMatchKeys(filePath, includeExtensionless: false);

Set<String> buildPathMatchKeys(String? filePath) =>
    _buildPathMatchKeys(filePath, includeExtensionless: true);

bool physicalFilePathsMatch(String? first, String? second) {
  final firstKeys = buildPhysicalPathMatchKeys(first);
  if (firstKeys.isEmpty) return false;
  return buildPhysicalPathMatchKeys(
    second,
  ).any((key) => firstKeys.contains(key));
}

bool isPhysicalFileRetained(
  String? candidatePath,
  Iterable<String?> retainedPaths,
) => retainedPaths.any(
  (retainedPath) => physicalFilePathsMatch(candidatePath, retainedPath),
);

Set<String> _buildPathMatchKeys(
  String? filePath, {
  required bool includeExtensionless,
}) {
  final raw = filePath?.trim() ?? '';
  if (raw.isEmpty) return const {};

  final cleaned = raw.startsWith('EXISTS:') ? raw.substring(7).trim() : raw;
  if (cleaned.isEmpty) return const {};
  final cacheKey =
      '${includeExtensionless ? 'track' : 'physical'}\u0000$cleaned';
  final cached = _pathMatchKeyCache.remove(cacheKey);
  if (cached != null) {
    _pathMatchKeyCache[cacheKey] = cached;
    return cached;
  }

  final keys = <String>{};
  final visited = <String>{};
  final windowsPath = windowsPathIdentity(cleaned);
  if (windowsPath != null) keys.add('windows-file:$windowsPath');

  // A DocumentsProvider document can be reached through an album tree, its
  // parent tree, or a direct document URI. Keep that identity independent of
  // the selected tree, without guessing from a filename or lowercasing the
  // provider's opaque document ID. Parse only the original URI: decoding it
  // repeatedly would change IDs containing literal percent escapes.
  final documentKey = _androidDocumentMatchKey(Uri.tryParse(cleaned));
  if (documentKey != null) keys.add(documentKey);

  void addNormalized(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    if (!visited.add(trimmed)) return;

    keys.add(trimmed);
    keys.add(trimmed.toLowerCase());

    if (trimmed.contains('\\')) {
      final slash = trimmed.replaceAll('\\', '/');
      if (slash != trimmed) {
        addNormalized(slash);
      }
    }

    // Windows resolves paths to the verbatim form (`\\?\C:\…`,
    // `\\?\UNC\server\…`), which the desktop scanner stores, while
    // downloads keep the plain form. Both name the same file.
    final plain = withoutWindowsVerbatimPrefix(trimmed);
    if (plain != null) addNormalized(plain);

    if (trimmed.contains('%')) {
      try {
        final decoded = Uri.decodeFull(trimmed);
        if (decoded != trimmed) {
          addNormalized(decoded);
        }
      } catch (_) {}
    }

    Uri? parsed;
    try {
      parsed = Uri.parse(trimmed);
    } catch (_) {}

    if (parsed != null && parsed.hasScheme) {
      final withoutQueryOrFragment = parsed.replace(
        query: null,
        fragment: null,
      );
      final uriString = withoutQueryOrFragment.toString();
      keys.add(uriString);
      keys.add(uriString.toLowerCase());

      if (parsed.scheme == 'file') {
        try {
          addNormalized(parsed.toFilePath());
        } catch (_) {}
      }

      for (final alias in _androidExternalStorageDocumentPaths(parsed)) {
        addNormalized(alias);
      }
    } else if (trimmed.startsWith('/')) {
      try {
        final asFileUri = Uri.file(trimmed).toString();
        keys.add(asFileUri);
        keys.add(asFileUri.toLowerCase());
      } catch (_) {}
    }

    if (Platform.isAndroid) {
      for (final alias in _androidEquivalentPaths(trimmed)) {
        if (alias != trimmed) {
          addNormalized(alias);
        }
      }
    }
  }

  addNormalized(cleaned);
  if (windowsPath != null) addNormalized(windowsPath);

  if (includeExtensionless) {
    final extensionStrippedKeys = <String>{};
    for (final key in keys) {
      if (key.startsWith('windows-file:')) continue;
      final stripped = _stripAudioExtension(key);
      if (stripped != null && stripped.isNotEmpty) {
        extensionStrippedKeys.add(stripped);
      }
    }
    keys.addAll(extensionStrippedKeys);
  }

  final result = Set<String>.unmodifiable(keys);
  _pathMatchKeyCache[cacheKey] = result;
  while (_pathMatchKeyCache.length > _maxPathMatchKeyCacheSize) {
    _pathMatchKeyCache.remove(_pathMatchKeyCache.keys.first);
  }
  return result;
}

/// [path] without its Windows verbatim prefix, in either separator:
/// `\\?\C:\a` → `C:\a` and `\\?\UNC\server\share\a` →
/// `\\server\share\a`. Null when [path] has no such prefix, or names a
/// device or volume GUID that has no plain spelling.
String? withoutWindowsVerbatimPrefix(String path) {
  if (path.length < 6) return null;
  final separator = path[0];
  if ((separator != r'\' && separator != '/') ||
      path[1] != separator ||
      path[2] != '?' ||
      path[3] != separator) {
    return null;
  }
  final rest = path.substring(4);
  if (rest.length > 4 &&
      rest.substring(0, 3).toUpperCase() == 'UNC' &&
      rest[3] == separator) {
    return '$separator$separator${rest.substring(4)}';
  }
  final drive = rest.codeUnitAt(0) | 0x20;
  if (drive >= 0x61 && drive <= 0x7a && rest[1] == ':') return rest;
  return null;
}

String? _androidDocumentMatchKey(Uri? uri) {
  if (uri == null || uri.scheme != 'content' || uri.authority.isEmpty) {
    return null;
  }
  final segments = uri.pathSegments;
  final isDirect = segments.length == 2 && segments[0] == 'document';
  final isTreeDocument =
      segments.length == 4 &&
      segments[0] == 'tree' &&
      segments[1].isNotEmpty &&
      segments[2] == 'document';
  if ((!isDirect && !isTreeDocument) || segments.last.isEmpty) return null;
  // Encode only the authority so the separator cannot be ambiguous. The ID
  // stays verbatim and keeps its extension for track/conversion match keys.
  final authority = base64Url.encode(utf8.encode(uri.authority.toLowerCase()));
  return 'saf-document:$authority:${segments.last}';
}

Iterable<String> _androidExternalStorageDocumentPaths(Uri uri) {
  if (uri.scheme.toLowerCase() != 'content' ||
      uri.host.toLowerCase() != 'com.android.externalstorage.documents') {
    return const [];
  }

  final segments = uri.pathSegments;
  final documentIndex = segments.lastIndexOf('document');
  final treeIndex = segments.lastIndexOf('tree');
  final idIndex = documentIndex >= 0 ? documentIndex + 1 : treeIndex + 1;
  if (idIndex <= 0 || idIndex >= segments.length) return const [];

  var documentId = segments.sublist(idIndex).join('/');
  try {
    documentId = Uri.decodeComponent(documentId);
  } catch (_) {}
  final separator = documentId.indexOf(':');
  if (separator < 0 ||
      documentId.substring(0, separator).toLowerCase() != 'primary') {
    return const [];
  }

  final relativePath = documentId
      .substring(separator + 1)
      .replaceAll('\\', '/')
      .replaceFirst(RegExp(r'^/+'), '');
  final suffix = relativePath.isEmpty ? '' : '/$relativePath';
  return _androidStoragePathAliases.map((prefix) => '$prefix$suffix');
}

Iterable<String> _androidEquivalentPaths(String path) {
  final normalized = path.replaceAll('\\', '/');
  final lower = normalized.toLowerCase();
  String? suffix;

  for (final prefix in _androidStoragePathAliases) {
    if (lower == prefix) {
      suffix = '';
      break;
    }
    final withSlash = '$prefix/';
    if (lower.startsWith(withSlash)) {
      suffix = normalized.substring(prefix.length);
      break;
    }
  }

  if (suffix == null) return const [];
  return _androidStoragePathAliases.map((prefix) => '$prefix$suffix');
}
