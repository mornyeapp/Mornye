import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffmpeg_kit_flutter_new_audio/media_information.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/audio_analysis_ffmpeg.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/audio_analysis_runner.dart';
import 'package:mornye/services/audio_compare_dsp.dart';
import 'package:mornye/services/audio_compare_ffmpeg.dart';
import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/services/ffmpeg_support.dart';
import 'package:mornye/services/network_audio_analysis_input.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('AudioCompare');

/// Shorter files cannot be lined up reliably.
const double audioCompareMinSeconds = 2;

/// The step a running comparison is on, in order.
enum AudioCompareStage { preparing, aligning, measuring, spectrogram }

enum AudioCompareFailure { unreadable, tooShort, decodeFailed }

class AudioCompareException implements Exception {
  const AudioCompareException(this.failure, {this.fileName, this.detail});

  final AudioCompareFailure failure;

  /// The file that could not be read, for [AudioCompareFailure.unreadable].
  final String? fileName;

  /// FFmpeg's log or another technical reason, for the app log.
  final String? detail;

  @override
  String toString() =>
      'AudioCompareException($failure${fileName == null ? '' : ', $fileName'})';
}

class AudioCompareFileInfo {
  const AudioCompareFileInfo({
    required this.name,
    required this.codec,
    required this.sampleRate,
    required this.bitsPerSample,
    required this.channels,
    required this.durationSeconds,
  });

  factory AudioCompareFileInfo.fromMedia(
    String name,
    AudioAnalysisMediaInfo media,
  ) => AudioCompareFileInfo(
    name: name,
    codec: media.codecName.toUpperCase(),
    sampleRate: media.sampleRate,
    bitsPerSample: media.bitsPerSample,
    channels: media.channels,
    durationSeconds: media.totalSamples > 0 && media.sampleRate > 0
        ? media.totalSamples / media.sampleRate
        : media.duration,
  );

  final String name;

  /// Short codec name, such as FLAC or MP3.
  final String codec;
  final int sampleRate;

  /// Stored bit depth of lossless files; 0 for lossy codecs.
  final int bitsPerSample;
  final int channels;
  final double durationSeconds;
}

/// Everything the result view shows. Owns [spectrogram].
class AudioCompareResult {
  AudioCompareResult({
    required this.reference,
    required this.other,
    required this.sampleRate,
    required this.channels,
    required this.offsetFrames,
    required this.gain,
    required this.correlation,
    required this.excerptResidualDb,
    required this.windows,
    this.driftMs,
    this.spectrogram,
  }) : overallDb = audioCompareOverallDb(windows),
       medianDb = audioCompareMedianDb(windows),
       peak = audioComparePeakFor(windows),
       band = audioCompareBandFor(windows) {
    level = audioCompareLevelFor(overallDb);
    notices = audioCompareNoticesFor(
      correlation: correlation,
      overallDb: overallDb,
      medianDb: medianDb,
      driftCoarse: driftMs == null
          ? null
          : (driftMs! * audioCompareCoarseRate / 1000).round(),
      referenceSeconds: reference.durationSeconds,
      otherSeconds: other.durationSeconds,
      offsetSeconds: offsetFrames / sampleRate,
    );
  }

  final AudioCompareFileInfo reference;
  final AudioCompareFileInfo other;

  /// The rate and channel count both files were compared at.
  final int sampleRate;
  final int channels;

  /// Other-file frame minus reference frame of the same sound: positive
  /// when the other file starts later.
  final int offsetFrames;

  /// Applied to the other file before subtracting.
  final double gain;

  /// Normalized correlation peak of the full-rate alignment, 0 to 1.
  final double correlation;
  final double excerptResidualDb;

  /// Change of the offset between the start and the end of the song.
  final double? driftMs;
  final List<AudioCompareWindow> windows;
  final double overallDb;
  final double medianDb;
  final AudioComparePeak? peak;
  final AudioCompareBand band;
  late final AudioCompareLevel level;
  late final Set<AudioCompareNotice> notices;
  ui.Image? spectrogram;

  double get offsetMs => offsetFrames * 1000 / sampleRate;

  /// The gain in dB; positive when the other file was quieter.
  double get gainDb =>
      gain == 0 ? audioCompareFloorDb : 20 * math.log(gain.abs()) / math.ln10;
  bool get polarityInverted => gain < 0;

  bool get meaningful => notices.isEmpty;

  /// One of the files was converted to [sampleRate].
  bool get resampled =>
      reference.sampleRate != sampleRate || other.sampleRate != sampleRate;

  /// The channel layouts differ, or a surround file was folded to stereo.
  bool get channelsConverted =>
      reference.channels != other.channels || reference.channels > 2;

  double get durationSeconds => reference.durationSeconds;

  void dispose() {
    spectrogram?.dispose();
    spectrogram = null;
  }
}

/// The file name shown for [path], also for content and network URIs.
String audioCompareDisplayName(String path) {
  var name = path;
  final uri = Uri.tryParse(path);
  // One-letter schemes are Windows drive letters, not URIs.
  if (uri != null && uri.scheme.length > 1) {
    name = uri.pathSegments.isEmpty ? path : uri.pathSegments.last;
  }
  final last = name.split(RegExp(r'[/\\:]')).last;
  return last.isEmpty ? name : last;
}

typedef AudioCompareStart =
    Future<({int id, Future<FFmpegSessionResult> completed})> Function(
      List<String> arguments,
    );

typedef AudioCompareImageDecoder =
    Future<ui.Image> Function(Uint8List rgba, int width, int height);

Future<ui.Image> _decodeRgba(Uint8List rgba, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

Future<List<AudioCompareCoarseMatch>> _coarseAlignInIsolate(
  List<AudioCompareCoarseInput> inputs,
) => Isolate.run(
  () => [for (final input in inputs) audioCompareCoarseAlign(input)],
);

Future<AudioCompareFineMatch> _fineAlignInIsolate(
  AudioCompareFineInput input,
) => Isolate.run(() => audioCompareFineAlign(input));

/// Runs the null test of one file against a reference. Each FFmpeg session
/// is owned and cancellable; every temporary file lives in one directory
/// that is removed when [compare] finishes, fails or is cancelled.
class AudioCompareEngine {
  AudioCompareEngine({
    AudioCompareStart? start,
    Future<void> Function(int id)? cancel,
    Future<MediaInformation?> Function(String path)? probe,
    Future<Directory> Function()? temporaryDirectory,
    Future<String?> Function(String uri)? copyContentUri,
    NetworkAudioAnalysisInput? networkInput,
    AudioCompareImageDecoder? decodeImage,
  }) : _jobs = AudioAnalysisJobs<FFmpegSessionResult>(
         start: start ?? FFmpegExecution.start,
         cancel: cancel ?? FFmpegExecution.cancel,
       ),
       _probe = probe ?? FFmpegExecution.mediaInformation,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _copyContentUri = copyContentUri ?? PlatformBridge.copyContentUriToTemp,
       networkInput = networkInput ?? NetworkAudioAnalysisInput(),
       _decodeImage = decodeImage ?? _decodeRgba;

  final AudioAnalysisJobs<FFmpegSessionResult> _jobs;
  final Future<MediaInformation?> Function(String path) _probe;
  final Future<Directory> Function() _temporaryDirectory;
  final Future<String?> Function(String uri) _copyContentUri;
  final NetworkAudioAnalysisInput networkInput;
  final AudioCompareImageDecoder _decodeImage;
  int _generation = 0;
  bool _disposed = false;

  /// Stops the running comparison; it ends with [AudioAnalysisCancelled].
  void cancel() {
    _generation++;
    _jobs.invalidate();
    networkInput.cancel();
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _jobs.dispose();
    networkInput.cancel();
  }

  /// Compares [otherPath] (a local file) with [referencePath], which may
  /// also be an Android content URI or a network source. [onStage] reports
  /// each step. Throws [AudioCompareException],
  /// [UnsupportedAudioAnalysisCodecException] or [AudioAnalysisCancelled].
  Future<AudioCompareResult> compare({
    required String referencePath,
    required String otherPath,
    void Function(AudioCompareStage stage)? onStage,
    bool includeSpectrogram = true,
  }) async {
    final generation = _generation;
    bool isCancelled() => _disposed || generation != _generation;
    void check() {
      if (isCancelled()) throw const AudioAnalysisCancelled();
    }

    check();
    final referenceName = audioCompareDisplayName(referencePath);
    final otherName = audioCompareDisplayName(otherPath);
    Future<AudioCompareResult> run(String path) => _compareFiles(
      referencePath: path,
      otherPath: otherPath,
      referenceName: referenceName,
      otherName: otherName,
      check: check,
      onStage: onStage,
      includeSpectrogram: includeSpectrogram,
    );

    if (NetworkAudioAnalysisInput.isNetwork(referencePath)) {
      onStage?.call(AudioCompareStage.preparing);
      AudioCompareResult? produced;
      try {
        return await networkInput.withFile(
          referencePath,
          (path) async => produced = await run(path),
        );
      } catch (_) {
        produced?.dispose();
        rethrow;
      }
    }
    if (referencePath.startsWith('content://')) {
      onStage?.call(AudioCompareStage.preparing);
      final copy = await _copyContentUri(referencePath);
      if (copy == null) {
        throw AudioCompareException(
          AudioCompareFailure.unreadable,
          fileName: referenceName,
        );
      }
      try {
        check();
        return await run(copy);
      } finally {
        try {
          await File(copy).delete();
        } catch (_) {}
      }
    }
    return run(referencePath);
  }

  Future<AudioCompareFileInfo> _probeFile(String path, String name) async {
    MediaInformation? info;
    try {
      info = await _probe(path);
    } on FFmpegUnavailableException {
      rethrow;
    } catch (e) {
      _log.w('Probe failed for $name: $e');
    }
    if (info == null) {
      throw AudioCompareException(
        AudioCompareFailure.unreadable,
        fileName: name,
      );
    }
    final AudioAnalysisMediaInfo media;
    try {
      media = AudioAnalysisRunner.parseMediaInfo(info);
    } catch (e) {
      throw AudioCompareException(
        AudioCompareFailure.unreadable,
        fileName: name,
        detail: '$e',
      );
    }
    final unsupported = unsupportedAudioAnalysisCodecLabel(media.codecName);
    if (unsupported != null) {
      throw UnsupportedAudioAnalysisCodecException(unsupported);
    }
    return AudioCompareFileInfo.fromMedia(name, media);
  }

  Future<void> _runFFmpeg(List<String> arguments) async {
    final session = await _jobs.run(arguments);
    if (!session.success) {
      final logs = await session.logs();
      final tail = logs.length > 2000
          ? logs.substring(logs.length - 2000)
          : logs;
      _log.w('FFmpeg failed (${session.returnCode}): $tail');
      throw AudioCompareException(
        AudioCompareFailure.decodeFailed,
        detail: tail,
      );
    }
  }

  static Future<Float32List> _readFloats(String path) async {
    final file = File(path);
    if (!await file.exists()) return Float32List(0);
    final bytes = await file.readAsBytes();
    final count = bytes.length ~/ 4;
    if (Endian.host == Endian.little && bytes.offsetInBytes % 4 == 0) {
      return bytes.buffer.asFloat32List(bytes.offsetInBytes, count);
    }
    final data = ByteData.sublistView(bytes);
    return Float32List.fromList([
      for (var i = 0; i < count; i++) data.getFloat32(i * 4, Endian.little),
    ]);
  }

  Future<AudioCompareResult> _compareFiles({
    required String referencePath,
    required String otherPath,
    required String referenceName,
    required String otherName,
    required void Function() check,
    required void Function(AudioCompareStage stage)? onStage,
    required bool includeSpectrogram,
  }) async {
    onStage?.call(AudioCompareStage.preparing);
    final infos = await Future.wait([
      _probeFile(referencePath, referenceName),
      _probeFile(otherPath, otherName),
    ]);
    check();
    final reference = infos[0];
    final other = infos[1];
    if (reference.durationSeconds < audioCompareMinSeconds ||
        other.durationSeconds < audioCompareMinSeconds) {
      throw const AudioCompareException(AudioCompareFailure.tooShort);
    }
    final rate = reference.sampleRate > 0
        ? math.min(reference.sampleRate, audioCompareMaxSampleRate)
        : 48000;
    final channels = reference.channels == 1 ? 1 : 2;

    final root = await _temporaryDirectory();
    final directory = await root.createTemp('audio-compare-');
    try {
      check();
      onStage?.call(AudioCompareStage.aligning);
      final alignment = await _align(
        directory: directory,
        referencePath: referencePath,
        otherPath: otherPath,
        durationSeconds: reference.durationSeconds,
        rate: rate,
        channels: channels,
        check: check,
      );

      onStage?.call(AudioCompareStage.measuring);
      final totalFrames = (reference.durationSeconds * rate).round();
      final windowFrames = audioCompareWindowFrames(totalFrames, rate);
      final metadataPath =
          '${directory.path}${Platform.pathSeparator}levels.txt';
      await _runFFmpeg(
        buildAudioCompareStatsArguments(
          referencePath: referencePath,
          otherPath: otherPath,
          sampleRate: rate,
          channels: channels,
          offsetFrames: alignment.fine.lag,
          gain: alignment.fine.gain,
          windowFrames: windowFrames,
          metadataPath: metadataPath,
        ),
      );
      check();
      final metadataFile = File(metadataPath);
      final metadata = await metadataFile.exists()
          ? await metadataFile.readAsString()
          : '';
      final windows = audioCompareWindowsFromMetadata(
        parseAudioCompareMetadata(metadata, channels: channels * 4),
        channels: channels,
        sampleRate: rate,
        windowFrames: windowFrames,
        totalFrames: totalFrames,
      );
      if (windows.isEmpty) {
        throw const AudioCompareException(
          AudioCompareFailure.decodeFailed,
          detail: 'The level pass wrote no windows',
        );
      }

      final result = AudioCompareResult(
        reference: reference,
        other: other,
        sampleRate: rate,
        channels: channels,
        offsetFrames: alignment.fine.lag,
        gain: alignment.fine.gain,
        correlation: alignment.fine.correlation.abs(),
        excerptResidualDb: alignment.fine.excerptResidualDb,
        windows: windows,
        driftMs: alignment.driftMs,
      );
      if (!includeSpectrogram) return result;

      onStage?.call(AudioCompareStage.spectrogram);
      try {
        result.spectrogram = await _residualSpectrogram(
          directory: directory,
          referencePath: referencePath,
          otherPath: otherPath,
          rate: rate,
          channels: channels,
          offsetFrames: alignment.fine.lag,
          gain: alignment.fine.gain,
          durationSeconds: reference.durationSeconds,
        );
        check();
      } on AudioAnalysisCancelled {
        result.dispose();
        rethrow;
      } catch (e) {
        // The timeline and summary stand on their own without the picture.
        _log.w('Residual spectrogram failed: $e');
      }
      return result;
    } finally {
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<
    ({
      AudioCompareCoarseMatch coarse,
      AudioCompareFineMatch fine,
      double? driftMs,
    })
  >
  _align({
    required Directory directory,
    required String referencePath,
    required String otherPath,
    required double durationSeconds,
    required int rate,
    required int channels,
    required void Function() check,
  }) async {
    const coarseRate = audioCompareCoarseRate;
    final separator = Platform.pathSeparator;
    final scan = math.min(audioCompareScanSeconds, durationSeconds);
    double scanStart(double fraction) => math.max(
      math.min(audioCompareSearchSeconds, durationSeconds - scan),
      math.min(durationSeconds * fraction, durationSeconds - scan),
    );
    final starts = [scanStart(0.25)];
    // A second excerpt near the end shows whether the offset drifts.
    final lateStart = scanStart(0.7);
    if (lateStart >= starts.first + scan) starts.add(lateStart);

    final excerpts = <AudioCompareExcerpt>[];
    final inputs = <({int referenceStart, int otherStart})>[];
    for (final (index, start) in starts.indexed) {
      final referenceStart = (start * coarseRate).round();
      final referenceEnd = ((start + scan) * coarseRate).round();
      final otherStart = math.max(
        0,
        ((start - audioCompareSearchSeconds) * coarseRate).round(),
      );
      final otherEnd = ((start + scan + audioCompareSearchSeconds) * coarseRate)
          .round();
      excerpts
        ..add(
          AudioCompareExcerpt(
            input: 0,
            startSample: referenceStart,
            endSample: referenceEnd,
            outputPath: '${directory.path}${separator}coarse_ref_$index.f32',
          ),
        )
        ..add(
          AudioCompareExcerpt(
            input: 1,
            startSample: otherStart,
            endSample: otherEnd,
            outputPath: '${directory.path}${separator}coarse_other_$index.f32',
          ),
        );
      inputs.add((referenceStart: referenceStart, otherStart: otherStart));
    }
    await _runFFmpeg(
      buildAudioCompareExcerptArguments(
        referencePath: referencePath,
        otherPath: otherPath,
        sampleRate: rate,
        channels: channels,
        decimatedRate: coarseRate,
        excerpts: excerpts,
      ),
    );
    check();
    final coarseInputs = <AudioCompareCoarseInput>[];
    for (final (index, input) in inputs.indexed) {
      coarseInputs.add(
        AudioCompareCoarseInput(
          reference: await _readFloats(excerpts[index * 2].outputPath),
          referenceStart: input.referenceStart,
          other: await _readFloats(excerpts[index * 2 + 1].outputPath),
          otherStart: input.otherStart,
        ),
      );
    }
    check();
    final coarse = await _coarseAlignInIsolate(coarseInputs);
    check();
    final first = coarse.first;

    // Each strong coarse peak gets a short full-rate excerpt of the other
    // file around it; the best full-rate match wins.
    final ratio = rate / coarseRate;
    final radius = 4 * ratio.ceil() + 64;
    final fineFrames = (audioCompareFineSeconds * rate).round();
    final totalFrames = (durationSeconds * rate).round();
    final referenceStart =
        ((first.fineCenter * ratio).round() - fineFrames ~/ 2)
            .clamp(0, math.max(0, totalFrames - fineFrames))
            .toInt();
    final predictions = [
      for (final candidate in first.candidates) (candidate.lag * ratio).round(),
    ];
    if (predictions.isEmpty) predictions.add(0);
    final fineExcerpts = [
      AudioCompareExcerpt(
        input: 0,
        startSample: referenceStart,
        endSample: referenceStart + fineFrames,
        outputPath: '${directory.path}${separator}fine_ref.f32',
      ),
      for (final (index, predicted) in predictions.indexed)
        AudioCompareExcerpt(
          input: 1,
          startSample: math.max(0, referenceStart + predicted - radius),
          endSample: math.max(
            1,
            referenceStart + fineFrames + predicted + radius,
          ),
          outputPath: '${directory.path}${separator}fine_other_$index.f32',
        ),
    ];
    await _runFFmpeg(
      buildAudioCompareExcerptArguments(
        referencePath: referencePath,
        otherPath: otherPath,
        sampleRate: rate,
        channels: channels,
        excerpts: fineExcerpts,
      ),
    );
    check();
    final candidates = <AudioCompareFineCandidate>[];
    for (final (index, predicted) in predictions.indexed) {
      final excerpt = fineExcerpts[index + 1];
      candidates.add(
        AudioCompareFineCandidate(
          other: await _readFloats(excerpt.outputPath),
          otherStart: excerpt.startSample,
          predictedLag: predicted,
        ),
      );
    }
    final fine = await _fineAlignInIsolate(
      AudioCompareFineInput(
        reference: await _readFloats(fineExcerpts.first.outputPath),
        referenceStart: referenceStart,
        candidates: candidates,
        channels: channels,
        sampleRate: rate,
        radius: radius,
      ),
    );
    check();

    double? driftMs;
    if (coarse.length > 1 &&
        fine.correlation.abs() >= audioCompareMinCorrelation &&
        coarse[1].correlation.abs() >= audioCompareMinCorrelation) {
      final startLag = fine.lag / ratio;
      final endLag = coarse[1].lagNearest(startLag.round());
      driftMs = (endLag - startLag) * 1000 / coarseRate;
    }
    return (coarse: first, fine: fine, driftMs: driftMs);
  }

  Future<ui.Image?> _residualSpectrogram({
    required Directory directory,
    required String referencePath,
    required String otherPath,
    required int rate,
    required int channels,
    required int offsetFrames,
    required double gain,
    required double durationSeconds,
  }) async {
    final outputPath =
        '${directory.path}${Platform.pathSeparator}residual_spectrum.rgba';
    await _runFFmpeg(
      buildAudioCompareSpectrogramArguments(
        referencePath: referencePath,
        otherPath: otherPath,
        sampleRate: rate,
        channels: channels,
        offsetFrames: offsetFrames,
        gain: gain,
        durationSeconds: durationSeconds,
        outputPath: outputPath,
      ),
    );
    const expected = audioSpectrogramWidth * audioSpectrogramHeight * 4;
    final bytes = await File(outputPath).readAsBytes();
    if (bytes.length < expected) {
      throw AudioCompareException(
        AudioCompareFailure.decodeFailed,
        detail: 'Incomplete residual spectrogram (${bytes.length}/$expected)',
      );
    }
    return _decodeImage(
      bytes.length == expected
          ? bytes
          : Uint8List.sublistView(bytes, 0, expected),
      audioSpectrogramWidth,
      audioSpectrogramHeight,
    );
  }
}
