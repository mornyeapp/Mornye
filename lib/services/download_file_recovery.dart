import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('DownloadFileRecovery');

/// Finds a moved download in the selected destination without moving files or
/// changing a valid old path. Folder structure and the complete filename must
/// match; an unrelated same-name file elsewhere in the tree is not a match.
class DownloadFileRecovery {
  DownloadFileRecovery({
    HistoryDatabase? history,
    Future<SharedPreferences> Function()? preferences,
    Future<bool> Function(String)? exists,
    Future<List<Map<String, dynamic>>> Function(List<Map<String, dynamic>>)?
    inspect,
  }) : _history = history ?? HistoryDatabase.instance,
       _preferences = preferences ?? SharedPreferences.getInstance,
       _exists = exists ?? fileExists,
       _inspect = inspect ?? PlatformBridge.inspectSafFiles;

  static final instance = DownloadFileRecovery();
  static const previousDirectoriesKey = 'download_previous_directories_v1';
  final HistoryDatabase _history;
  final Future<SharedPreferences> Function() _preferences;
  final Future<bool> Function(String) _exists;
  final Future<List<Map<String, dynamic>>> Function(List<Map<String, dynamic>>)
  _inspect;
  final _pending = <String, Future<String?>>{};
  static final _listeners = <void Function()>{};

  static void Function() subscribe(void Function() listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  static Future<void> rememberDirectories(
    SharedPreferences preferences,
    Iterable<String> directories,
  ) async {
    final roots = <String>{
      ...directories.where((path) => path.startsWith('/')).toList().reversed,
      ...?preferences.getStringList(previousDirectoriesKey),
    };
    await preferences.setStringList(
      previousDirectoriesKey,
      roots.take(32).toList(),
    );
  }

  Future<String?> recover(
    String source, {
    String? historyId,
    AppSettings? settings,
    bool knownMissing = false,
  }) {
    if (!source.startsWith('/') && !source.startsWith('content://')) {
      return Future.value(null);
    }
    final key = '$historyId\n$source';
    return _pending.putIfAbsent(key, () async {
      try {
        return await _recover(
          source,
          historyId: historyId,
          settings: settings,
          knownMissing: knownMissing,
        );
      } finally {
        _pending.remove(key);
      }
    });
  }

  Future<String?> _recover(
    String source, {
    String? historyId,
    AppSettings? settings,
    required bool knownMissing,
  }) async {
    if (!knownMissing && await _exists(source)) return null;
    final row = historyId == null ? null : await _history.getById(historyId);
    final json = row ?? await _history.findByFilePath(source);
    if (json == null) return null;
    final item = DownloadHistoryItem.fromJson(json);
    if (item.filePath != source) {
      return await _exists(item.filePath) ? item.filePath : null;
    }
    final preferences = await _preferences();
    if (settings == null) {
      final raw = preferences.getString('app_settings');
      if (raw == null) return null;
      settings = AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    }
    if (settings.networkDownloadFolder.isNotEmpty) return null;
    final relativePaths = <String>{};
    final name = item.safFileName;
    if (name != null && name.isNotEmpty && !name.contains('/')) {
      relativePaths.add(p.posix.join(item.safRelativeDir ?? '', name));
    }
    if (source.startsWith('/')) {
      final roots = [
        settings.downloadDirectory,
        ...?preferences.getStringList(previousDirectoriesKey),
      ]..sort((first, second) => second.length.compareTo(first.length));
      for (final root in roots) {
        if (root.startsWith('/') && p.posix.isWithin(root, source)) {
          relativePaths.add(p.posix.relative(source, from: root));
        }
      }
    }
    relativePaths.removeWhere(
      (path) =>
          p.posix.isAbsolute(path) ||
          p.posix
              .split(path)
              .any((part) => part == '..' || part.contains('\u0000')),
    );
    if (relativePaths.isEmpty) return null;

    final saf =
        settings.storageMode == 'saf' && settings.downloadTreeUri.isNotEmpty;
    if (saf &&
        isContentUri(source) &&
        item.downloadTreeUri == settings.downloadTreeUri) {
      // The existing SAF repair already searches the original tree. This
      // fallback concerns a changed destination, not deleted original files.
      return null;
    }
    for (final relative in relativePaths) {
      final directory = p.posix.dirname(relative) == '.'
          ? ''
          : p.posix.dirname(relative);
      final filename = p.posix.basename(relative);
      String? replacement;
      if (saf) {
        final results = await _inspect([
          {
            'key': item.id,
            'tree_uri': settings.downloadTreeUri,
            'relative_dir': directory,
            'current_uri': '',
            'file_names': [filename],
            'exact_relative_dir': true,
          },
        ]);
        final found = results
            .where((result) => result['key'] == item.id)
            .firstOrNull;
        if (found == null || found['status'] == 'unknown') {
          throw StateError(
            'The selected download folder could not be inspected',
          );
        }
        if (found['status'] == 'found' &&
            found['relative_dir'] == directory &&
            found['file_name'] == filename) {
          replacement = found['uri'] as String?;
        }
      } else if (settings.downloadDirectory.startsWith('/')) {
        replacement = p.posix.join(settings.downloadDirectory, relative);
      }
      if (replacement == null ||
          replacement == source ||
          !await _exists(replacement)) {
        continue;
      }
      if (saf && !isContentUri(replacement)) {
        throw StateError(
          'The selected download folder returned an invalid document URI',
        );
      }
      if (await _exists(source)) return null;
      final updated = await _history.updateFilePath(
        item.id,
        replacement,
        newStorageMode: saf ? 'saf' : 'app',
        newDownloadTreeUri: saf ? settings.downloadTreeUri : '',
        newSafRelativeDir: directory,
        newSafFileName: filename,
        expectedFilePath: source,
        expectedDownloadedAt: json['downloadedAt'] as String,
      );
      if (!updated) {
        throw StateError('The download changed while recovering its path');
      }
      for (final listener in List.of(_listeners)) {
        try {
          listener();
        } catch (error) {
          _log.w('Could not refresh recovered download history: $error');
        }
      }
      _log.i('Recovered a moved download in the selected folder');
      return replacement;
    }
    return null;
  }
}
