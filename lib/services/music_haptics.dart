import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart' show AppLogger;

const musicHapticsSampleRate = 4000;
const _hop = 40; // 10 ms frames.
const _maxSeconds = 1200;
const _minimumGapMilliseconds = 150; // At most about six pulses per second.
const _minimumScore = 0.5; // The most sensitive setting halves the threshold.

/// The threshold multiple a hit must clear at [sensitivity] (0 to 1).
///
/// The middle setting keeps the tuned threshold; the ends make it 1.6 times
/// stricter or twice as permissive.
double musicHapticsScoreFor(double sensitivity) {
  final value = sensitivity.clamp(0.0, 1.0);
  return value < 0.5 ? 1.6 - 1.2 * value : 1.5 - value;
}

/// One pulse per detected hit, stored compactly for a whole song.
class HapticTrack {
  HapticTrack(this.times, this.intensity, this.sharpness, [this.scores]);

  /// Pulse starts in milliseconds, ascending.
  final Int32List times;
  final Uint8List intensity;
  final Uint8List sharpness;

  /// How many times each candidate clears the tuned threshold. Null when the
  /// pulses are already selected and play as given.
  final Float32List? scores;

  int get length => times.length;

  /// The pulses that clear [sensitivity], spaced as the analysis would have.
  ///
  /// Candidates are kept for the whole range, so a new sensitivity applies
  /// without decoding the song again.
  HapticTrack select(double sensitivity) {
    final scores = this.scores;
    if (scores == null) return this;
    final required = musicHapticsScoreFor(sensitivity);
    final kept = <int>[];
    var last = -_minimumGapMilliseconds;
    for (var n = 0; n < times.length; n++) {
      if (scores[n] <= required || times[n] - last < _minimumGapMilliseconds) {
        continue;
      }
      kept.add(n);
      last = times[n];
    }
    return HapticTrack(
      Int32List.fromList([for (final n in kept) times[n]]),
      Uint8List.fromList([for (final n in kept) intensity[n]]),
      Uint8List.fromList([for (final n in kept) sharpness[n]]),
    );
  }

  /// The first pulse at or after [milliseconds].
  int indexAt(int milliseconds) {
    var low = 0;
    var high = times.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (times[middle] < milliseconds) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }
}

/// Finds hits in mono s16le PCM at [musicHapticsSampleRate].
///
/// Energy is split into bass (below about 150 Hz) and treble (above about
/// 400 Hz). Rises in either band are onsets; kick and bass hits weigh more,
/// as they are what a phone's motor renders well. An adaptive threshold
/// follows the song's own density, so busy and sparse passages both produce
/// a readable pattern instead of a constant buzz.
///
/// The result holds every candidate down to the most sensitive setting; use
/// [HapticTrack.select] to pick the pulses for one setting.
HapticTrack analyzeHapticPcm(Uint8List pcm) {
  final samples = ByteData.sublistView(pcm);
  final frames = pcm.length ~/ (2 * _hop);
  final empty = HapticTrack(
    Int32List(0),
    Uint8List(0),
    Uint8List(0),
    Float32List(0),
  );
  if (frames < 8) return empty;
  final low = Float64List(frames);
  final high = Float64List(frames);
  final lowAlpha = exp(-2 * pi * 150 / musicHapticsSampleRate);
  final highAlpha = exp(-2 * pi * 400 / musicHapticsSampleRate);
  var low1 = 0.0, low2 = 0.0, smooth1 = 0.0, smooth2 = 0.0;
  for (var frame = 0; frame < frames; frame++) {
    var lowSum = 0.0;
    var highSum = 0.0;
    for (var i = 0; i < _hop; i++) {
      final x = samples.getInt16((frame * _hop + i) * 2, Endian.little) / 32768;
      low1 = (1 - lowAlpha) * x + lowAlpha * low1;
      low2 = (1 - lowAlpha) * low1 + lowAlpha * low2;
      // Two one-pole high-passes keep a kick's fundamental out of treble.
      smooth1 = (1 - highAlpha) * x + highAlpha * smooth1;
      final high1 = x - smooth1;
      smooth2 = (1 - highAlpha) * high1 + highAlpha * smooth2;
      final high2 = high1 - smooth2;
      lowSum += low2 * low2;
      highSum += high2 * high2;
    }
    low[frame] = sqrt(lowSum / _hop);
    high[frame] = sqrt(highSum / _hop);
  }
  final loudness = Float64List(frames);
  for (var i = 0; i < frames; i++) {
    loudness[i] = low[i] + high[i];
  }
  final sorted = Float64List.fromList(loudness)..sort();
  final gate = max(0.002, sorted[(frames * 0.9).floor()] * 0.1);

  double loud(Float64List band) {
    final ranked = Float64List.fromList(band)..sort();
    return max(1e-4, ranked[(frames * 0.9).floor()]);
  }

  // Rises are measured against each band's typical loud level, not in log
  // terms: every quiet sound starting is a large log rise, but only loud hits
  // such as kicks and snares should become pulses.
  final lowReference = loud(low);
  final highReference = loud(high);
  final onset = Float64List(frames);
  for (var i = 2; i < frames; i++) {
    onset[i] =
        max(0.0, low[i] - low[i - 2]) / lowReference +
        max(0.0, high[i] - high[i - 2]) / highReference * 0.3;
  }
  final prefix = Float64List(frames + 1);
  for (var i = 0; i < frames; i++) {
    prefix[i + 1] = prefix[i] + onset[i];
  }

  const radius = 40; // ±0.4 s of context for the threshold.
  const peak = 3; // A hit must be the largest rise within ±30 ms.
  final found = <int>[];
  final excess = <double>[];
  final score = <double>[];
  for (var i = 2; i < frames; i++) {
    if (loudness[i] < gate) continue;
    final value = onset[i];
    final from = max(0, i - radius);
    final to = min(frames, i + radius + 1);
    final threshold = max(
      0.15,
      (prefix[to] - prefix[from]) / (to - from) * 2.4,
    );
    if (value <= threshold * _minimumScore) continue;
    var largest = true;
    for (var j = max(0, i - peak); j <= min(frames - 1, i + peak); j++) {
      if (onset[j] > value) {
        largest = false;
        break;
      }
    }
    if (!largest) continue;
    found.add(i);
    excess.add(value - threshold);
    score.add(value / threshold);
  }
  if (found.isEmpty) return empty;
  // Scale accents against the hits the tuned threshold keeps, so the default
  // setting feels the same and extra hits from higher sensitivity stay soft.
  final ranked = [
    for (final value in excess)
      if (value > 0) value,
  ]..sort();
  final reference = ranked.isEmpty
      ? 1e-6
      : max(1e-6, ranked[(ranked.length * 0.95).floor()]);
  final times = Int32List(found.length);
  final intensity = Uint8List(found.length);
  final sharpness = Uint8List(found.length);
  final scores = Float32List.fromList(score);
  for (var n = 0; n < found.length; n++) {
    final i = found[n];
    // Log rises ignore level, so compare the bands' linear rises instead.
    final lowRise = max(0.0, low[i] - low[i - 2]);
    final highRise = max(0.0, high[i] - high[i - 2]);
    final bass = lowRise / (lowRise + highRise + 1e-9);
    final strength = sqrt((excess[n] / reference).clamp(0.0, 1.0));
    times[n] = i * _hop * 1000 ~/ musicHapticsSampleRate;
    intensity[n] = (255 * (0.3 + 0.7 * strength) * (0.65 + 0.35 * bass))
        .round()
        .clamp(1, 255);
    sharpness[n] = (255 * (1 - bass)).round().clamp(0, 255);
  }
  return HapticTrack(times, intensity, sharpness, scores);
}

/// Decodes a low-rate mono copy of a local song once and caches its pulses.
class MusicHapticsAnalyzer {
  MusicHapticsAnalyzer({
    AudioAnalysisJobs<bool>? jobs,
    Future<Directory> Function()? temporaryDirectory,
  }) : _jobs =
           jobs ??
           AudioAnalysisJobs<bool>(start: _start, cancel: FFmpegKit.cancel),
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final _log = AppLogger('MusicHaptics');
  final AudioAnalysisJobs<bool> _jobs;
  final Future<Directory> Function() _temporaryDirectory;
  final _cache = <String, HapticTrack>{};
  int _generation = 0;

  static Future<({int id, Future<bool> completed})> _start(
    List<String> arguments,
  ) async {
    final inputIndex = arguments.indexOf('-i') + 1;
    if (inputIndex > 0 && isContentUri(arguments[inputIndex])) {
      // Resolve only when this owned job starts. FFmpegKit opens and closes
      // its own SAF descriptor, independently of the player's short lease.
      final input = await FFmpegKitConfig.getSafParameterForRead(
        arguments[inputIndex],
      );
      if (input == null || input.isEmpty) {
        throw StateError('Unable to open haptics audio source');
      }
      arguments = List.of(arguments)..[inputIndex] = input;
    }
    final done = Completer<bool>();
    final session = await FFmpegKit.executeWithArgumentsAsync(arguments, (
      session,
    ) async {
      if (!done.isCompleted) {
        done.complete(ReturnCode.isSuccess(await session.getReturnCode()));
      }
    });
    final id = session.getSessionId();
    if (id == null) throw StateError('Haptics session has no ID');
    final timeout = Timer(
      const Duration(seconds: 60),
      () => unawaited(FFmpegKit.cancel(id)),
    );
    return (id: id, completed: done.future.whenComplete(timeout.cancel));
  }

  void cancel() {
    _generation++;
    _jobs.invalidate();
  }

  void dispose() {
    cancel();
    _jobs.dispose();
    _cache.clear();
  }

  Future<HapticTrack?> analyze(String path) async {
    final generation = _generation;
    Directory? work;
    try {
      String? key;
      if (isContentUri(path)) {
        // A document URI is not a filesystem path. Unknown modification times
        // still allow analysis, but cannot safely identify a cached revision.
        try {
          final modified = (await PlatformBridge.getSafFileModTimes([
            path,
          ]))[path];
          if (modified != null && modified > 0) key = '$path:$modified';
        } catch (_) {
          // Some document providers cannot report a modification timestamp.
        }
      } else {
        final stat = await File(path).stat();
        if (stat.type != FileSystemEntityType.file) return null;
        key = '$path:${stat.size}:${stat.modified.microsecondsSinceEpoch}';
      }
      if (generation != _generation) return null;
      if (key != null) {
        final cached = _cache.remove(key);
        if (cached != null) return _cache[key] = cached;
      }
      work = await (await _temporaryDirectory()).createTemp('haptics-');
      if (generation != _generation) return null;
      final output = File('${work.path}/song.pcm');
      final success = await _jobs.run([
        '-hide_banner',
        '-loglevel',
        'error',
        '-nostdin',
        '-y',
        '-threads',
        '1',
        '-i',
        path,
        '-t',
        '$_maxSeconds',
        '-vn',
        '-sn',
        '-dn',
        '-ac',
        '1',
        '-ar',
        '$musicHapticsSampleRate',
        '-c:a',
        'pcm_s16le',
        '-f',
        's16le',
        output.path,
      ]);
      if (!success || generation != _generation || !await output.exists()) {
        return null;
      }
      if (await output.length() >
          musicHapticsSampleRate * 2 * (_maxSeconds + 1)) {
        return null;
      }
      final track = await compute(analyzeHapticPcm, await output.readAsBytes());
      if (generation != _generation) return null;
      if (key != null) _cache[key] = track;
      while (_cache.length > 8) {
        _cache.remove(_cache.keys.first);
      }
      return track;
    } on AudioAnalysisCancelled {
      return null;
    } on Object catch (error) {
      if (generation == _generation) {
        _log.w('Music haptics unavailable (${error.runtimeType})');
      }
      return null;
    } finally {
      if (work != null && await work.exists()) {
        await work.delete(recursive: true);
      }
    }
  }
}

typedef HapticPulse = Future<void> Function(double intensity, double sharpness);

const _channel = MethodChannel('com.zarz.mornye/haptics');

/// Which system setting a pulse answers to on Android. Music pulses follow
/// media vibration; UI feedback follows touch feedback. iOS ignores it.
enum HapticPulseUsage { media, touch }

Future<void> nativeHapticPulse(
  double intensity,
  double sharpness, {
  HapticPulseUsage usage = HapticPulseUsage.media,
}) => _channel.invokeMethod<void>('pulse', {
  'intensity': intensity,
  'sharpness': sharpness,
  // Absent means media, which older callers rely on.
  if (usage == HapticPulseUsage.touch) 'usage': 'touch',
});

/// A pulse for UI feedback, such as a swipe crossing its threshold.
Future<void> nativeTouchHapticPulse(double intensity, double sharpness) =>
    nativeHapticPulse(intensity, sharpness, usage: HapticPulseUsage.touch);

/// Plays a song's pulses against the live playback position.
///
/// Only the next pulse is scheduled. Each one re-reads the extrapolated
/// position, so seeks, pauses, AutoMix rate changes and position updates
/// correct the timing within a beat.
class MusicHaptics {
  MusicHaptics({
    required this.state,
    MusicHapticsAnalyzer? analyzer,
    HapticPulse? pulse,
    this.lead = const Duration(milliseconds: 12),
  }) : _analyzer = analyzer ?? MusicHapticsAnalyzer(),
       _pulse = pulse ?? nativeHapticPulse;

  final PlaybackState Function() state;
  final MusicHapticsAnalyzer _analyzer;
  final HapticPulse _pulse;

  /// Motors need a moment to spin up; fire slightly early.
  final Duration lead;

  String? _path;
  HapticTrack? _analyzed;
  HapticTrack? _track;
  Timer? _timer;
  int _generation = 0;
  bool _unsupported = false;
  double _sensitivity = 0.5;
  double _gain = 1;

  @visibleForTesting
  HapticTrack? get track => _track;

  /// Applies the user's [sensitivity] and [strength], both 0 to 1 with the
  /// tuned behaviour at 0.5. A loaded song is reselected without decoding.
  void configure({required double sensitivity, required double strength}) {
    _gain = 0.4 + 1.2 * strength.clamp(0.0, 1.0);
    if (sensitivity == _sensitivity) return;
    _sensitivity = sensitivity;
    final analyzed = _analyzed;
    if (analyzed == null) return;
    _track = analyzed.select(sensitivity);
    _schedule();
  }

  /// [path] is null when haptics are off or the song is not a local file.
  void update(String? path) {
    if (path != _path) {
      _path = path;
      _analyzed = null;
      _track = null;
      _timer?.cancel();
      _generation++;
      _analyzer.cancel();
      if (path != null && !_unsupported) unawaited(_load(path, _generation));
      return;
    }
    _schedule();
  }

  Future<void> _load(String path, int generation) async {
    final track = await _analyzer.analyze(path);
    if (generation != _generation) return;
    _analyzed = track;
    _track = track?.select(_sensitivity);
    _schedule();
  }

  int? _position() {
    final current = state();
    if (!current.playing ||
        current.processingState != AudioProcessingState.ready) {
      return null;
    }
    return current.position.inMilliseconds;
  }

  void _schedule([int from = 0]) {
    _timer?.cancel();
    final track = _track;
    final position = _position();
    if (track == null || position == null || _unsupported) return;
    final index = max(from, track.indexAt(position + lead.inMilliseconds));
    if (index >= track.length) return;
    final speed = state().speed > 0 ? state().speed : 1.0;
    final wait = ((track.times[index] - position) / speed).round();
    final generation = _generation;
    _timer = Timer(
      Duration(milliseconds: max(0, wait - lead.inMilliseconds)),
      () => _fire(index, generation),
    );
  }

  void _fire(int index, int generation) {
    if (generation != _generation) return;
    final track = _track;
    final position = _position();
    if (track != null && position != null) {
      // A late timer or a position correction makes the pulse stale.
      final offset = track.times[index] - position - lead.inMilliseconds;
      if (offset > 40) return _schedule();
      if (offset >= -40) {
        unawaited(
          _pulse(
            (track.intensity[index] / 255 * _gain).clamp(0.0, 1.0),
            track.sharpness[index] / 255,
          ).catchError((Object error) {
            if (error is MissingPluginException) {
              _unsupported = true;
              _timer?.cancel();
            }
          }),
        );
      }
    }
    _schedule(index + 1);
  }

  void dispose() {
    _generation++;
    _timer?.cancel();
    _analyzer.dispose();
  }
}
