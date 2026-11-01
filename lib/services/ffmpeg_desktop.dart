import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/media_information.dart';
import 'package:flutter/foundation.dart';
import 'package:mornye/models/ffmpeg_models.dart';
import 'package:mornye/utils/logger.dart';
import 'package:path/path.dart' as p;

final _log = AppLogger('FFmpeg');

/// Raised when a desktop FFmpeg tool is missing; its message is shown to
/// users as the reason a feature failed.
class FFmpegUnavailableException implements Exception {
  const FFmpegUnavailableException(this.tool);

  /// `ffmpeg` or `ffprobe`.
  final String tool;

  String get message =>
      '$tool is not available. Reinstall Mornye, or set '
      '${DesktopFFmpegTools.directoryVariable} to a folder that contains '
      'ffmpeg and ffprobe.';

  @override
  String toString() => message;
}

/// Locations of the standalone FFmpeg executables shipped with desktop builds.
///
/// Lookup order for each tool:
/// 1. the folder named by `MORNYE_FFMPEG_DIR`;
/// 2. the app bundle: `Contents/Resources/ffmpeg/` then `Contents/MacOS/` on
///    macOS, `ffmpeg\` next to the executable on Windows, and `lib/ffmpeg/`
///    next to the executable on Linux (see scripts/fetch_desktop_ffmpeg.sh);
/// 3. `PATH`, a developer fallback.
@immutable
class DesktopFFmpegTools {
  const DesktopFFmpegTools({this.ffmpegPath, this.ffprobePath});

  static const directoryVariable = 'MORNYE_FFMPEG_DIR';

  final String? ffmpegPath;
  final String? ffprobePath;

  static Future<DesktopFFmpegTools>? _shared;

  /// The tools of this process, located once.
  static Future<DesktopFFmpegTools> get shared => _shared ??= locate();

  /// Folders searched for the tools, in order.
  static List<String> searchDirectories({
    required String operatingSystem,
    required String executablePath,
    required Map<String, String> environment,
  }) {
    final windows = operatingSystem == 'windows';
    final path = windows ? p.windows : p.posix;
    final executableDir = path.dirname(executablePath);
    final override = environment[directoryVariable]?.trim() ?? '';
    final searchPath =
        environment[windows ? 'Path' : 'PATH'] ?? environment['PATH'] ?? '';
    return [
      if (override.isNotEmpty) override,
      ...switch (operatingSystem) {
        'macos' => [
          path.normalize(path.join(executableDir, '..', 'Resources', 'ffmpeg')),
          executableDir,
        ],
        'windows' => [path.join(executableDir, 'ffmpeg')],
        _ => [path.join(executableDir, 'lib', 'ffmpeg')],
      },
      ...searchPath
          .split(windows ? ';' : ':')
          .map((entry) => entry.trim())
          .where((entry) => entry.isNotEmpty),
    ];
  }

  /// Resolves both tools; a missing tool stays null.
  static Future<DesktopFFmpegTools> locate({
    String? operatingSystem,
    String? executablePath,
    Map<String, String>? environment,
    Future<bool> Function(String path)? isFile,
  }) async {
    final os = operatingSystem ?? Platform.operatingSystem;
    final exists = isFile ?? FileSystemEntity.isFile;
    final directories = searchDirectories(
      operatingSystem: os,
      executablePath: executablePath ?? Platform.resolvedExecutable,
      environment: environment ?? Platform.environment,
    );
    final path = os == 'windows' ? p.windows : p.posix;
    final suffix = os == 'windows' ? '.exe' : '';

    Future<String?> find(String tool) async {
      for (final directory in directories) {
        final candidate = path.join(directory, '$tool$suffix');
        try {
          if (await exists(candidate)) return candidate;
        } catch (_) {
          // Unreadable PATH entries are skipped.
        }
      }
      return null;
    }

    final tools = DesktopFFmpegTools(
      ffmpegPath: await find('ffmpeg'),
      ffprobePath: await find('ffprobe'),
    );
    if (tools.ffmpegPath == null || tools.ffprobePath == null) {
      _log.w(
        'Desktop FFmpeg tools missing (ffmpeg: ${tools.ffmpegPath}, '
        'ffprobe: ${tools.ffprobePath})',
      );
    }
    return tools;
  }
}

/// Starts a tool process; injected by tests.
typedef FFmpegProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

/// Builds the probe model FFprobeKit returns from `ffprobe -print_format
/// json` output. Returns null when ffprobe recognized nothing.
MediaInformation? parseFFprobeJson(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return null;
  }
  if (decoded is! Map || decoded.isEmpty) return null;
  return MediaInformation(decoded);
}

/// Runs the standalone `ffmpeg`/`ffprobe` executables, mirroring the FFmpegKit
/// session semantics the app relies on: an id per session, its return code
/// and log output on completion, and cancellation by id.
class DesktopFFmpegRunner {
  DesktopFFmpegRunner({
    Future<DesktopFFmpegTools> Function()? tools,
    FFmpegProcessStarter? startProcess,
    this.killGrace = const Duration(seconds: 2),
  }) : _tools = tools ?? (() => DesktopFFmpegTools.shared),
       _startProcess = startProcess ?? _defaultStart;

  static DesktopFFmpegRunner? _shared;

  static DesktopFFmpegRunner get shared => _shared ??= DesktopFFmpegRunner();

  @visibleForTesting
  static set debugShared(DesktopFFmpegRunner? runner) => _shared = runner;

  /// How long a cancelled process may run after SIGTERM before it is killed.
  final Duration killGrace;
  final Future<DesktopFFmpegTools> Function() _tools;
  final FFmpegProcessStarter _startProcess;
  final _processes = <int, Process>{};
  int _nextId = 1;

  static Future<Process> _defaultStart(
    String executable,
    List<String> arguments,
  ) => Process.start(executable, arguments);

  static const _decoder = Utf8Decoder(allowMalformed: true);

  Future<String> _tool(String name) async {
    final tools = await _tools();
    final path = name == 'ffprobe' ? tools.ffprobePath : tools.ffmpegPath;
    if (path == null) throw FFmpegUnavailableException(name);
    return path;
  }

  /// Starts `ffmpeg` with [arguments]. Throws [FFmpegUnavailableException]
  /// when the executable is missing.
  Future<({int id, Future<FFmpegSessionResult> completed})> start(
    List<String> arguments,
  ) async {
    final executable = await _tool('ffmpeg');
    // The CLI polls stdin for interactive keys; FFmpegKit never reads it.
    final process = await _startProcess(executable, [
      if (!arguments.contains('-nostdin')) '-nostdin',
      ...arguments,
    ]);
    final id = _nextId++;
    _processes[id] = process;
    unawaited(process.stdin.close().catchError((Object _) {}));
    // FFmpegKit reports FFmpeg's log, which the CLI writes to stderr.
    final logs = process.stderr.transform(_decoder).join();
    final stdout = process.stdout.drain<void>();
    final completed = () async {
      try {
        final code = await process.exitCode;
        final output = await logs;
        await stdout;
        return FFmpegSessionResult(returnCode: code, logs: () async => output);
      } finally {
        _processes.remove(id);
      }
    }();
    return (id: id, completed: completed);
  }

  /// Runs `ffmpeg` to completion; failures, including a missing executable,
  /// are reported in the result.
  Future<FFmpegResult> run(List<String> arguments) async {
    try {
      final session = await start(arguments);
      final result = await session.completed;
      return FFmpegResult(
        success: result.success,
        returnCode: result.returnCode ?? -1,
        output: await result.logs(),
      );
    } catch (e) {
      _log.e('FFmpeg process error: $e');
      return FFmpegResult(success: false, returnCode: -1, output: '$e');
    }
  }

  /// Stops the session with [id]. FFmpeg finalizes on SIGTERM; a process that
  /// does not exit within [killGrace] is killed. Unknown ids are ignored.
  Future<void> cancel(int id) async {
    final process = _processes[id];
    if (process == null) return;
    process.kill();
    if (Platform.isWindows) return;
    unawaited(
      process.exitCode.timeout(
        killGrace,
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      ),
    );
  }

  /// Probes [path] with `ffprobe`. Throws [FFmpegUnavailableException] when
  /// the executable is missing; returns null when the probe fails.
  Future<MediaInformation?> probe(String path) async {
    final executable = await _tool('ffprobe');
    final process = await _startProcess(executable, [
      '-v',
      'quiet',
      '-print_format',
      'json',
      '-show_format',
      '-show_streams',
      '-show_chapters',
      '-i',
      path,
    ]);
    unawaited(process.stdin.close().catchError((Object _) {}));
    final stdout = process.stdout.transform(_decoder).join();
    final stderr = process.stderr.drain<void>();
    final code = await process.exitCode;
    final json = await stdout;
    await stderr;
    if (code != 0) return null;
    return parseFFprobeJson(json);
  }
}
