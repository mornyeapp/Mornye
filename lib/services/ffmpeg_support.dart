import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/media_information.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/ffmpeg_desktop.dart';
import 'package:mornye/services/ffmpeg_metadata_input.dart';
import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/logger.dart';

export 'package:mornye/services/ffmpeg_desktop.dart'
    show FFmpegUnavailableException;

final _log = AppLogger('FFmpeg');

/// Shared native execution boundary; feature modules supply their own commands.
/// Mobile runs FFmpegKit in process; desktop runs the bundled `ffmpeg` and
/// `ffprobe` executables through [DesktopFFmpegRunner].
abstract final class FFmpegExecution {
  static Future<FFmpegResult> command(String command) async {
    if (isDesktopPlatform) {
      // FFmpegKit's own quoting rules, so commands behave as on mobile.
      return DesktopFFmpegRunner.shared.run(
        FFmpegKitConfig.parseArguments(command),
      );
    }
    try {
      final session = await FFmpegKit.execute(command);
      final code = await session.getReturnCode();
      return FFmpegResult(
        success: ReturnCode.isSuccess(code),
        returnCode: code?.getValue() ?? -1,
        output: await session.getOutput() ?? '',
      );
    } catch (e) {
      _log.e('FFmpeg execute error: $e');
      return FFmpegResult(success: false, returnCode: -1, output: e.toString());
    }
  }

  static Future<FFmpegResult> arguments(
    List<String> arguments, {
    Future<FFmpegResult> Function(List<String>)? execute,
  }) async {
    final FFmpegMetadataInput prepared;
    try {
      prepared = await FFmpegMetadataInput.prepare(arguments);
    } catch (error) {
      _log.e('Failed to prepare FFmpeg metadata input: $error');
      return FFmpegResult(
        success: false,
        returnCode: -1,
        output: error.toString(),
      );
    }
    try {
      return await (execute ?? _executeArguments)(prepared.arguments);
    } finally {
      await prepared.dispose();
    }
  }

  static Future<FFmpegResult> _executeArguments(List<String> arguments) async {
    if (isDesktopPlatform) return DesktopFFmpegRunner.shared.run(arguments);
    try {
      final session = await FFmpegKit.executeWithArguments(arguments);
      final code = await session.getReturnCode();
      return FFmpegResult(
        success: ReturnCode.isSuccess(code),
        returnCode: code?.getValue() ?? -1,
        output: await session.getOutput() ?? '',
      );
    } catch (e) {
      _log.e('FFmpeg executeWithArguments error: $e');
      return FFmpegResult(success: false, returnCode: -1, output: e.toString());
    }
  }

  /// Starts a cancellable session; [cancel] takes its id. Throws when the
  /// session cannot start, including [FFmpegUnavailableException] on desktop.
  static Future<({int id, Future<FFmpegSessionResult> completed})> start(
    List<String> arguments,
  ) async {
    if (isDesktopPlatform) return DesktopFFmpegRunner.shared.start(arguments);
    final completed = Completer<FFmpegSessionResult>();
    final session = await FFmpegKit.executeWithArgumentsAsync(arguments, (
      session,
    ) async {
      int? code;
      try {
        code = (await session.getReturnCode())?.getValue();
      } catch (e) {
        _log.w('FFmpeg return code unavailable: $e');
      }
      if (completed.isCompleted) return;
      completed.complete(
        FFmpegSessionResult(
          returnCode: code,
          logs: () async => await session.getAllLogsAsString() ?? '',
        ),
      );
    });
    final id = session.getSessionId();
    if (id == null) {
      // Never pass null to cancel: FFmpegKit interprets it as cancel-all.
      await completed.future;
      throw StateError('FFmpeg session has no ID');
    }
    return (id: id, completed: completed.future);
  }

  static Future<void> cancel(int id) => isDesktopPlatform
      ? DesktopFFmpegRunner.shared.cancel(id)
      : FFmpegKit.cancel(id);

  /// FFprobe media information, or null when the file cannot be probed.
  /// Throws [FFmpegUnavailableException] when desktop ffprobe is missing.
  static Future<MediaInformation?> mediaInformation(String path) async {
    if (isDesktopPlatform) return DesktopFFmpegRunner.shared.probe(path);
    return (await FFprobeKit.getMediaInformation(path)).getMediaInformation();
  }

  static String preview(String command) {
    final redacted = command
        .replaceAll(
          RegExp(r'-metadata\s+lyrics="[^"]*"', caseSensitive: false),
          '-metadata lyrics="<redacted>"',
        )
        .replaceAll(
          RegExp(r'-metadata\s+unsyncedlyrics="[^"]*"', caseSensitive: false),
          '-metadata unsyncedlyrics="<redacted>"',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return redacted.length <= 300
        ? redacted
        : '${redacted.substring(0, 300)}...';
  }
}

class FFmpegOutputPlan {
  final String workingPath;
  final String finalPath;

  const FFmpegOutputPlan({required this.workingPath, required this.finalPath});
}

/// Owns output reservation, cleanup and publication after successful execution.
abstract final class FFmpegOutput {
  static int _tempCounter = 0;

  static bool samePath(String first, String second) {
    final firstPath = File(first).absolute.path;
    final secondPath = File(second).absolute.path;
    return Platform.isWindows
        ? firstPath.toLowerCase() == secondPath.toLowerCase()
        : firstPath == secondPath;
  }

  // Exclusive creation keeps simultaneous conversions from choosing one name.
  static Future<String> reserve(String requestedPath) async {
    final file = File(requestedPath);
    final name = file.uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var index = 1; ; index++) {
      final candidate = index == 1
          ? requestedPath
          : '${file.parent.path}${Platform.pathSeparator}$base ($index)$extension';
      try {
        await File(candidate).create(exclusive: true);
        return candidate;
      } on FileSystemException {
        if (await FileSystemEntity.type(candidate, followLinks: false) ==
            FileSystemEntityType.notFound) {
          rethrow;
        }
      }
    }
  }

  static Future<FFmpegOutputPlan> plan(
    String inputPath,
    String extension, {
    required bool deleteOriginal,
  }) async {
    final ext = extension.startsWith('.') ? extension : '.$extension';
    final file = File(inputPath);
    final name = file.uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final requested = '${file.parent.path}${Platform.pathSeparator}$base$ext';
    if (samePath(requested, inputPath) && deleteOriginal) {
      return FFmpegOutputPlan(
        workingPath: await reserve(
          '${file.parent.path}${Platform.pathSeparator}.$base.mornye-${DateTime.now().microsecondsSinceEpoch}$ext',
        ),
        finalPath: inputPath,
      );
    }
    final finalPath = await reserve(requested);
    return FFmpegOutputPlan(workingPath: finalPath, finalPath: finalPath);
  }

  static Future<String> tempPath(String extension) async {
    final directory = await getTemporaryDirectory();
    final ext = extension.startsWith('.') ? extension : '.$extension';
    _tempCounter = (_tempCounter + 1) & 0x7fffffff;
    return '${directory.path}${Platform.pathSeparator}temp_embed_${DateTime.now().microsecondsSinceEpoch}_${pid}_$_tempCounter$ext';
  }

  static Future<void> cleanup(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      _log.w('Failed to clean FFmpeg output: $e');
    }
  }

  static Future<String?> finalize({
    required FFmpegOutputPlan plan,
    required String inputPath,
    required bool deleteOriginal,
    void Function(Object e)? onError,
  }) async {
    final working = File(plan.workingPath);
    if (!await working.exists() || await working.length() == 0) {
      _log.e('Converted output is missing or empty: ${plan.workingPath}');
      await cleanup(plan.workingPath);
      return null;
    }
    if (plan.workingPath != plan.finalPath) {
      final source = File(inputPath);
      final backupPath =
          '$inputPath.mornye-backup-${DateTime.now().microsecondsSinceEpoch}';
      final backup = File(backupPath);
      var backedUp = false;
      try {
        if (await source.exists()) {
          await source.rename(backupPath);
          backedUp = true;
        }
        await working.rename(plan.finalPath);
      } catch (e) {
        _log.e('Failed to replace original after conversion: $e');
        try {
          if (backedUp && !await source.exists() && await backup.exists()) {
            await backup.rename(inputPath);
          }
        } catch (restoreError) {
          _log.e('Failed to restore original conversion backup: $restoreError');
        }
        await cleanup(plan.workingPath);
        onError?.call(e);
        return null;
      }
      await cleanup(backupPath);
    } else if (deleteOriginal && !samePath(inputPath, plan.finalPath)) {
      try {
        final source = File(inputPath);
        if (await source.exists()) await source.delete();
      } catch (e) {
        _log.w('Failed to delete original after conversion: $e');
      }
    }
    FFmpegProbe.invalidate(inputPath);
    FFmpegProbe.invalidate(plan.finalPath);
    return plan.finalPath;
  }

  /// Copies across filesystems before moving the original aside. A failed copy
  /// or publication leaves the original available and cleans staging output.
  static Future<bool> promote(
    String tempOutput,
    String targetPath, {
    void Function()? onMissing,
    required void Function(Object e) onError,
  }) async {
    String? staging;
    try {
      final temp = File(tempOutput);
      if (!await temp.exists()) {
        onMissing?.call();
        return false;
      }
      staging = await reserve(
        '$targetPath.mornye-staging-${DateTime.now().microsecondsSinceEpoch}',
      );
      await temp.copy(staging);
      return await finalize(
            plan: FFmpegOutputPlan(workingPath: staging, finalPath: targetPath),
            inputPath: targetPath,
            deleteOriginal: true,
            onError: onError,
          ) !=
          null;
    } catch (e) {
      onError(e);
      return false;
    } finally {
      if (staging != null) await cleanup(staging);
      await cleanup(tempOutput);
    }
  }
}
