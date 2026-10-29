import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('FFmpeg');

/// Keeps large global tags out of a single-output FFmpeg command line.
/// Scoped stream tags and existing input indices keep their original meaning.
class FFmpegMetadataInput {
  FFmpegMetadataInput._(this.arguments, [this._directory]);

  final List<String> arguments;
  final Directory? _directory;
  static const _inlineLimit = 8 * 1024;
  static final _specialCharacters = RegExp(r'[\\=;#\r\n]');

  static bool _globalMetadata(String argument) =>
      argument == '-metadata' || argument == '-metadata:g';

  static String _escape(String value) =>
      value.replaceAllMapped(_specialCharacters, (match) => '\\${match[0]}');

  static Future<FFmpegMetadataInput> prepare(List<String> arguments) async {
    var size = 0;
    for (var i = 0; i + 1 < arguments.length; i++) {
      if (_globalMetadata(arguments[i])) size += arguments[++i].length;
    }
    if (size < _inlineLimit) return FFmpegMetadataInput._(arguments);

    final tags = <String, MapEntry<String, String>>{};
    final remaining = <String>[];
    for (var i = 0; i < arguments.length; i++) {
      if (_globalMetadata(arguments[i]) && i + 1 < arguments.length) {
        final assignment = arguments[i + 1];
        final equals = assignment.indexOf('=');
        if (equals > 0) {
          final key = assignment.substring(0, equals);
          final value = assignment.substring(equals + 1);
          // FFmpeg applies the last assignment to a key, ignoring its case.
          tags[key.toLowerCase()] = MapEntry(key, value);
          i++;
          continue;
        }
      }
      remaining.add(arguments[i]);
    }
    var inputs = 0;
    var insertAt = 0;
    for (var i = 0; i + 1 < remaining.length; i++) {
      if (remaining[i] == '-i') {
        inputs++;
        insertAt = i + 2;
        i++;
      }
    }
    if (inputs == 0 || tags.isEmpty) return FFmpegMetadataInput._(arguments);

    final directory = await (await getTemporaryDirectory()).createTemp(
      'ffmpeg-metadata-',
    );
    try {
      final file = File.fromUri(directory.uri.resolve('tags.ffmetadata'));
      final contents = StringBuffer(';FFMETADATA1\n');
      final deletions = <String>[];
      for (final entry in tags.values) {
        if (entry.value.isEmpty) {
          // An explicit empty option removes a tag, including a preserved one.
          deletions.addAll(['-metadata', '${entry.key}=']);
        } else {
          contents
            ..write(_escape(entry.key))
            ..write('=')
            ..writeln(_escape(entry.value));
        }
      }
      await file.writeAsString(contents.toString(), flush: true);
      final hasGlobalMapping = remaining.any(
        (argument) =>
            argument == '-map_metadata' || argument == '-map_metadata:g',
      );
      return FFmpegMetadataInput._([
        ...remaining.take(insertAt),
        '-f',
        'ffmetadata',
        '-i',
        file.path,
        // Selected tags take precedence over preserved input metadata.
        '-map_metadata',
        inputs.toString(),
        // An explicit mapping disables FFmpeg's default global metadata copy.
        if (!hasGlobalMapping) ...['-map_metadata', '0'],
        ...deletions,
        ...remaining.skip(insertAt),
      ], directory);
    } catch (_) {
      await _delete(directory);
      rethrow;
    }
  }

  Future<void> dispose() async {
    if (_directory case final directory?) await _delete(directory);
  }

  static Future<void> _delete(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (error) {
      _log.w('Failed to clean FFmpeg metadata input: $error');
    }
  }
}
