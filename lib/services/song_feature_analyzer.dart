import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit_config.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/ffmpeg_support.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/song_features.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/file_access.dart' show isContentUri;
import 'package:mornye/utils/logger.dart';

/// What analyzing one song found.
class SongAnalysisResult {
  const SongAnalysisResult.described(Float32List this.features) : retry = false;

  /// The song cannot be described: it does not decode, or it is silent.
  const SongAnalysisResult.failed() : features = null, retry = false;

  /// Nothing was learned about the song, such as after a cancellation or
  /// without a decoder here, so it is tried again later.
  const SongAnalysisResult.unavailable() : features = null, retry = true;

  final Float32List? features;
  final bool retry;
}

/// Decodes two short mono windows of a song, at about 30% and 60% of it to
/// skip intros, on one decoder thread, and describes them natively. The raw
/// PCM is deleted at once and never reaches the user's Library.
class SongFeatureAnalyzer {
  static const windowSeconds = 24.0;
  static const sampleRate = 22050;
  static const _maxWindowBytes = sampleRate * 2 * 25;

  final _log = AppLogger('SongAnalysis');
  final _jobs = AudioAnalysisJobs<bool>(
    start: _start,
    cancel: FFmpegExecution.cancel,
  );
  final _nativeRequests = <String>{};
  int _generation = 0;

  static Future<({int id, Future<bool> completed})> _start(
    List<String> arguments,
  ) async {
    final inputIndex = arguments.indexOf('-i') + 1;
    if (!isDesktopPlatform &&
        inputIndex > 0 &&
        isContentUri(arguments[inputIndex])) {
      // As haptics does: FFmpegKit opens and closes its own descriptor of the
      // document, so a Library sweep never copies the file.
      final input = await FFmpegKitConfig.getSafParameterForRead(
        arguments[inputIndex],
      );
      if (input == null || input.isEmpty) {
        throw StateError('Unable to open the song for analysis');
      }
      arguments = List.of(arguments)..[inputIndex] = input;
    }
    final session = await FFmpegExecution.start(arguments);
    final timeout = Timer(const Duration(seconds: 30), () {
      unawaited(FFmpegExecution.cancel(session.id));
    });
    return (
      id: session.id,
      completed: session.completed
          .then((result) => result.success)
          .whenComplete(timeout.cancel),
    );
  }

  /// Where the windows start, in seconds. Unknown durations start past most
  /// intros; a short song gets one window from its middle.
  static List<double> windowOffsets(Duration? duration) {
    final seconds = (duration?.inMilliseconds ?? 0) / 1000;
    if (seconds <= 0) return const [30, 90];
    if (seconds < 2 * windowSeconds + 6) {
      return [max(0, (seconds - windowSeconds) / 2)];
    }
    return [
      for (final share in const [0.3, 0.6])
        min(seconds * share, seconds - windowSeconds),
    ];
  }

  /// Stops the running analysis; it reports [SongAnalysisResult.unavailable].
  void cancel() {
    _generation++;
    _jobs.invalidate();
    for (final request in _nativeRequests) {
      unawaited(_cancelNative(request));
    }
  }

  Future<void> _cancelNative(String request) async {
    try {
      await PlatformBridge.cancelNativeDataJob(request);
    } catch (_) {
      // Completion still owns temp cleanup; unsupported hosts have no lease.
    }
  }

  void dispose() {
    cancel();
    _jobs.dispose();
  }

  Future<SongAnalysisResult> analyze(String path, {Duration? duration}) async {
    final generation = _generation;
    Directory? work;
    try {
      work = await (await getTemporaryDirectory()).createTemp('song-analysis-');
      final windows = <String>[];
      for (final (index, offset) in windowOffsets(duration).indexed) {
        final output = File('${work.path}/window$index.pcm');
        final decoded = await _jobs.run([
          '-hide_banner',
          '-loglevel',
          'error',
          '-nostdin',
          '-y',
          '-threads',
          '1',
          '-filter_threads',
          '1',
          '-ss',
          offset.toStringAsFixed(3),
          '-i',
          path,
          '-t',
          '$windowSeconds',
          '-vn',
          '-sn',
          '-dn',
          '-ac',
          '1',
          '-ar',
          '$sampleRate',
          '-c:a',
          'pcm_s16le',
          '-f',
          's16le',
          output.path,
        ]);
        if (generation != _generation) {
          return const SongAnalysisResult.unavailable();
        }
        if (!decoded) {
          // A later window may only have started past the end.
          if (windows.isEmpty) return const SongAnalysisResult.failed();
          break;
        }
        if (!await output.exists()) continue;
        final size = await output.length();
        if (size > _maxWindowBytes) return const SongAnalysisResult.failed();
        // A window past the end of a song of unknown length stays empty.
        if (size >= sampleRate * 2) windows.add(output.path);
      }
      if (windows.isEmpty) return const SongAnalysisResult.failed();
      final request = 'song-analysis-${work.path}';
      _nativeRequests.add(request);
      final Map<String, dynamic> result;
      try {
        result = await PlatformBridge.runNativeDataJob({
          'operation': 'audio_features',
          'paths': windows,
        }, requestId: request);
      } finally {
        _nativeRequests.remove(request);
      }
      if (generation != _generation ||
          result['version'] != SongFeatures.version) {
        return const SongAnalysisResult.unavailable();
      }
      final values = result['features'];
      // Too little audible audio to describe.
      if (values == null) return const SongAnalysisResult.failed();
      if (values is! List || values.length != SongFeatures.length) {
        throw StateError('Invalid song features');
      }
      final features = Float32List(SongFeatures.length);
      for (var i = 0; i < features.length; i++) {
        final value = (values[i] as num).toDouble();
        if (!value.isFinite) throw StateError('Invalid song features');
        features[i] = value;
      }
      return SongAnalysisResult.described(features);
    } on AudioAnalysisCancelled {
      return const SongAnalysisResult.unavailable();
    } on MissingPluginException {
      // No decoder or native analysis on this host.
      return const SongAnalysisResult.unavailable();
    } on Object catch (error) {
      if (generation == _generation) {
        _log.w('Song analysis unavailable (${error.runtimeType})');
      }
      return const SongAnalysisResult.unavailable();
    } finally {
      try {
        if (work != null && await work.exists()) {
          await work.delete(recursive: true);
        }
      } on FileSystemException {
        // The OS clears the temporary directory.
      }
    }
  }
}
