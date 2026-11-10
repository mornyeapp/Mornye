import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:mornye/models/automix_options.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/ffmpeg_support.dart';

/// Keep the beginning dry for the live deck handover, then ease in the FX.
String autoMixEffectFilters(
  AutoMixOptions options,
  Duration duration, {
  bool bassHandoff = false,
}) {
  final seconds = duration.inMicroseconds / 1e6;
  final pitchRatio = pow(2, options.effectivePitch / 12).toDouble();
  final ramp = bassHandoff
      ? max(0.1, seconds * 0.5 - 0.24)
      : min(1.5, seconds / 3);
  final progress = 'clip((t-0.24)/${ramp.toStringAsFixed(6)},0,1)';
  final wet = '($progress*$progress*(3-2*$progress))';
  final bounds =
      'apad=whole_dur=${seconds.toStringAsFixed(6)},'
      'atrim=duration=${seconds.toStringAsFixed(6)}';
  final effects = [
    if (bassHandoff) 'highpass=f=260',
    if (options.effectivePitch != 0) ...[
      'asetrate=${(48000 * pitchRatio).toStringAsFixed(6)}',
      'aresample=48000',
    ],
    if (options.effectiveSpeed != 1 || options.effectivePitch != 0)
      'atempo=${(options.effectiveSpeed / pitchRatio).toStringAsFixed(6)}',
    if (options.useLowPass) 'lowpass=f=1200',
    if (options.useEcho) 'aecho=0.6:0.75:180|360:0.3|0.15',
    if (options.effect == AutoMixEffect.vinylBrake) ...[
      'asetrate=48000*max(0.05,1-pow(clip(t/${seconds.toStringAsFixed(6)},0,1),2))',
      'aresample=48000',
    ],
    bounds,
    "volume='$wet':eval=frame",
  ].join(',');
  // Complementary gains preserve the dry signal's level while the two
  // branches are still correlated. The limiter bounds combined FX peaks.
  return 'aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,'
      'asplit=2[dry][wet];'
      '[dry]$bounds,volume=\'1-$wet\':eval=frame[clean];'
      '[wet]$effects[effect];'
      '[clean][effect]amix=inputs=2:normalize=0,'
      'alimiter=limit=0.98:level=false:latency=true';
}

class RenderedMixTail {
  RenderedMixTail(this.directory, this.path);
  final Directory directory;
  final String path;

  Future<void> dispose() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// Renders at most one 60-second outgoing tail, never a complete song.
class AutoMixEffectRenderer {
  AutoMixEffectRenderer({
    AudioAnalysisJobs<bool>? jobs,
    Future<Directory> Function()? temporaryDirectory,
  }) : _jobs =
           jobs ??
           AudioAnalysisJobs<bool>(
             start: _start,
             cancel: FFmpegExecution.cancel,
           ),
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final AudioAnalysisJobs<bool> _jobs;
  final Future<Directory> Function() _temporaryDirectory;
  int _generation = 0;

  static Future<({int id, Future<bool> completed})> _start(
    List<String> arguments,
  ) async {
    final session = await FFmpegExecution.start(arguments);
    final id = session.id;
    final timeout = Timer(
      const Duration(seconds: 30),
      () => unawaited(FFmpegExecution.cancel(id)),
    );
    return (
      id: id,
      completed: session.completed
          .then((result) => result.success)
          .whenComplete(timeout.cancel),
    );
  }

  void cancel() {
    _generation++;
    _jobs.invalidate();
  }

  void dispose() {
    _generation++;
    _jobs.dispose();
  }

  Future<RenderedMixTail?> render(
    String path, {
    required Duration start,
    required Duration duration,
    required AutoMixOptions options,
    bool bassHandoff = false,
  }) async {
    if ((!options.hasEffects && !bassHandoff) ||
        duration <= Duration.zero ||
        duration > const Duration(seconds: 60)) {
      return null;
    }
    final generation = _generation;
    Directory? work;
    try {
      work = await (await _temporaryDirectory()).createTemp('automix-effect-');
      if (generation != _generation) return null;
      final output = File('${work.path}/tail.wav');
      final seconds = duration.inMicroseconds / 1e6;
      // Faster playback consumes more source than the overlap lasts. Reading
      // only the overlap's length ended the effect early and padded the rest
      // with silence. The song's end still bounds the read, then padding
      // keeps the exact overlap length.
      final source = seconds * max(1.0, options.effectiveSpeed);
      final success = await _jobs.run([
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
        (max(0, start.inMicroseconds) / 1e6).toStringAsFixed(6),
        '-t',
        source.toStringAsFixed(6),
        '-i',
        path,
        '-vn',
        '-sn',
        '-dn',
        '-af',
        autoMixEffectFilters(options, duration, bassHandoff: bassHandoff),
        '-t',
        seconds.toStringAsFixed(6),
        '-ac',
        '2',
        '-ar',
        '48000',
        '-c:a',
        'pcm_s16le',
        '-f',
        'wav',
        output.path,
      ]);
      if (!success || generation != _generation || !await output.exists()) {
        return null;
      }
      final size = await output.length();
      if (size < 44 || size > 48000 * 4 * 61) return null;
      final header = await output.open();
      final bytes = await header.read(12);
      await header.close();
      if (String.fromCharCodes(bytes.take(4)) != 'RIFF' ||
          String.fromCharCodes(bytes.skip(8)) != 'WAVE') {
        return null;
      }
      final result = RenderedMixTail(work, output.path);
      work = null;
      return result;
    } on Object {
      return null;
    } finally {
      if (work != null && await work.exists()) {
        await work.delete(recursive: true);
      }
    }
  }
}
