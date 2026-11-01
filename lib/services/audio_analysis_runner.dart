import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/audio_analysis_ffmpeg.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/audio_analysis_models.dart';
import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/services/ffmpeg_support.dart';
import 'package:mornye/services/network_audio_analysis_input.dart';
import 'package:mornye/services/platform_bridge.dart';

class GeneratedSpectrogram {
  final ui.Image image;
  final double? cutoffFrequencyHz;

  const GeneratedSpectrogram({required this.image, this.cutoffFrequencyHz});
}

class AudioAnalysisRunResult {
  final AudioAnalysisData data;
  final ui.Image spectrogramImage;

  const AudioAnalysisRunResult({
    required this.data,
    required this.spectrogramImage,
  });
}

class _SpectralCutoffFileParams {
  final String path;
  final int width;
  final int height;
  final double maxFrequencyHz;

  const _SpectralCutoffFileParams({
    required this.path,
    required this.width,
    required this.height,
    required this.maxFrequencyHz,
  });
}

double? _estimateEffectiveSpectralCutoffFileInIsolate(
  _SpectralCutoffFileParams params,
) {
  final expected = params.width * params.height;
  final file = File(params.path);
  if (file.lengthSync() != expected) {
    throw const FormatException('Incomplete spectral cutoff output');
  }
  return estimateEffectiveSpectralCutoffHz(
    intensity: file.readAsBytesSync(),
    width: params.width,
    height: params.height,
    maxFrequencyHz: params.maxFrequencyHz,
  );
}

class _MediaInfo {
  final int fileSize;
  final String codecName;
  final String codec;
  final String container;
  final String decodedSampleFormat;
  final int sampleRate;
  final int channels;
  final String channelLayout;
  final int bitsPerSample;
  final double duration;
  final int bitrate;
  final int totalSamples;

  const _MediaInfo({
    required this.fileSize,
    required this.codecName,
    required this.codec,
    required this.container,
    required this.decodedSampleFormat,
    required this.sampleRate,
    required this.channels,
    required this.channelLayout,
    required this.bitsPerSample,
    required this.duration,
    required this.bitrate,
    required this.totalSamples,
  });
}

class _LevelMetrics {
  final double peakDb;
  final double rmsDb;
  final double? integratedLufs;
  final double? truePeakDb;
  final int clippingSamples;
  final List<ChannelAnalysisStats> channelStats;

  const _LevelMetrics({
    required this.peakDb,
    required this.rmsDb,
    this.integratedLufs,
    this.truePeakDb,
    this.clippingSamples = 0,
    this.channelStats = const [],
  });
}

/// FFmpeg/ffprobe pipeline for one analysis card. The card owns request ids
/// and passes `isCancelled`, which the runner polls between awaited steps
/// and answers by throwing [AudioAnalysisCancelled].
class AudioAnalysisRunner {
  final networkInput = NetworkAudioAnalysisInput();
  final _analysisJobs = AudioAnalysisJobs<FFmpegSessionResult>(
    start: FFmpegExecution.start,
    cancel: FFmpegExecution.cancel,
  );

  void _checkCancelled(bool Function() isCancelled) {
    if (isCancelled()) {
      throw const AudioAnalysisCancelled();
    }
  }

  final _nativeAnalysisRequests = <String>{};

  /// Stops the owned FFmpeg session, network download and native data jobs.
  void cancel() {
    _analysisJobs.invalidate();
    networkInput.cancel();
    _cancelNativeAnalysis();
  }

  void dispose() {
    _analysisJobs.dispose();
    networkInput.cancel();
    _cancelNativeAnalysis();
  }

  void _cancelNativeAnalysis() {
    for (final request in _nativeAnalysisRequests) {
      unawaited(_cancelNativeAnalysisRequest(request));
    }
  }

  Future<void> _cancelNativeAnalysisRequest(String request) async {
    try {
      await PlatformBridge.cancelNativeDataJob(request);
    } catch (_) {
      // Await the owned worker before temp cleanup even if cancellation fails.
    }
  }

  Future<AudioAnalysisRunResult> runAnalysis(
    String filePath,
    bool Function() isCancelled, {
    String? sourcePath,
  }) async {
    _checkCancelled(isCancelled);
    if (NetworkAudioAnalysisInput.isNetwork(filePath)) {
      return networkInput.withFile(
        filePath,
        (path) => runAnalysis(path, isCancelled, sourcePath: filePath),
      );
    }
    String workingPath = filePath;
    String? tempCopy;
    if (filePath.startsWith('content://')) {
      tempCopy = await PlatformBridge.copyContentUriToTemp(filePath);
      if (tempCopy == null) {
        throw Exception('Failed to copy SAF file for analysis');
      }
      workingPath = tempCopy;
    }

    try {
      _checkCancelled(isCancelled);
      final info = await _getMediaInfo(workingPath);
      _checkCancelled(isCancelled);
      final unsupported = unsupportedAudioAnalysisCodecLabel(info.codecName);
      if (unsupported != null) {
        throw UnsupportedAudioAnalysisCodecException(unsupported);
      }
      GeneratedSpectrogram? spectrogram;
      try {
        final effectiveDuration = info.totalSamples > 0 && info.sampleRate > 0
            ? info.totalSamples / info.sampleRate
            : info.duration;
        spectrogram = await _generateSpectrogram(
          workingPath,
          isCancelled: isCancelled,
          channel: -1,
          includeCutoffPlane: true,
          durationSeconds: effectiveDuration,
          sampleRate: info.sampleRate,
          channels: info.channels,
        );
        _checkCancelled(isCancelled);
        final spectralCutoffHz = spectrogram.cutoffFrequencyHz;
        final levelMetrics = await _runFullStreamLevelAnalysis(
          workingPath,
          isCancelled: isCancelled,
          durationSeconds: effectiveDuration,
        );
        if (levelMetrics == null) {
          throw Exception('FFmpeg level analysis returned no usable metrics');
        }
        final peakAmplitude = levelMetrics.peakDb;
        final rmsLevel = levelMetrics.rmsDb;
        final dynamicRange = peakAmplitude - rmsLevel;

        return AudioAnalysisRunResult(
          data: AudioAnalysisData(
            filePath: sourcePath ?? filePath,
            fileSize: info.fileSize,
            codec: info.codec,
            container: info.container,
            decodedSampleFormat: info.decodedSampleFormat,
            sampleRate: info.sampleRate,
            channels: info.channels,
            channelLayout: info.channelLayout,
            bitsPerSample: info.bitsPerSample,
            duration: info.duration,
            bitrate: info.bitrate,
            bitDepth: info.bitsPerSample > 0
                ? '${info.bitsPerSample}-bit'
                : 'N/A',
            dynamicRange: dynamicRange,
            peakAmplitude: peakAmplitude,
            rmsLevel: rmsLevel,
            integratedLufs: levelMetrics.integratedLufs,
            truePeakDb: levelMetrics.truePeakDb,
            clippingSamples: levelMetrics.clippingSamples,
            spectralCutoffHz: spectralCutoffHz,
            channelStats: levelMetrics.channelStats,
            totalSamples: info.totalSamples,
          ),
          spectrogramImage: spectrogram.image,
        );
      } catch (_) {
        spectrogram?.image.dispose();
        rethrow;
      }
    } finally {
      if (tempCopy != null) {
        try {
          await File(tempCopy).delete();
        } catch (_) {}
      }
    }
  }

  Future<GeneratedSpectrogram> generateSpectrogramForFile(
    String filePath, {
    required bool Function() isCancelled,
    required int channel,
    double? durationSeconds,
    int? sampleRate,
    int? channels,
  }) async {
    _checkCancelled(isCancelled);
    if (NetworkAudioAnalysisInput.isNetwork(filePath)) {
      return networkInput.withFile(
        filePath,
        (path) => generateSpectrogramForFile(
          path,
          isCancelled: isCancelled,
          channel: channel,
          durationSeconds: durationSeconds,
          sampleRate: sampleRate,
          channels: channels,
        ),
      );
    }
    String workingPath = filePath;
    String? tempCopy;
    if (filePath.startsWith('content://')) {
      tempCopy = await PlatformBridge.copyContentUriToTemp(filePath);
      if (tempCopy == null) {
        throw Exception('Failed to copy SAF file for spectrogram');
      }
      workingPath = tempCopy;
    }

    try {
      return await _generateSpectrogram(
        workingPath,
        isCancelled: isCancelled,
        channel: channel,
        durationSeconds: durationSeconds,
        sampleRate: sampleRate,
        channels: channels,
      );
    } finally {
      if (tempCopy != null) {
        try {
          await File(tempCopy).delete();
        } catch (_) {}
      }
    }
  }

  Future<GeneratedSpectrogram> _generateSpectrogram(
    String inputPath, {
    required bool Function() isCancelled,
    required int channel,
    bool includeCutoffPlane = false,
    double? durationSeconds,
    int? sampleRate,
    int? channels,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final rawPath =
        '${tempDir.path}/analysis_spectrum_'
        '${DateTime.now().microsecondsSinceEpoch}_${channel + 1}.rgba';
    final cutoffPath = includeCutoffPlane ? '$rawPath.cutoff.gray' : null;

    try {
      _checkCancelled(isCancelled);
      final session = await _analysisJobs.run(
        buildAudioSpectrogramArguments(
          inputPath: inputPath,
          outputPath: rawPath,
          cutoffOutputPath: cutoffPath,
          channel: channel,
          durationSeconds: durationSeconds,
          sampleRate: sampleRate,
          channels: channels,
        ),
      );

      if (!session.success) {
        final logs = await session.logs();
        throw Exception('FFmpeg spectrogram failed: $logs');
      }

      final expectedLength = audioSpectrogramWidth * audioSpectrogramHeight * 4;
      final rawBytes = await File(rawPath).readAsBytes();
      if (rawBytes.length < expectedLength) {
        throw Exception(
          'Incomplete spectrogram output '
          '(${rawBytes.length}/$expectedLength bytes)',
        );
      }
      final rgba = rawBytes.length == expectedLength
          ? rawBytes
          : Uint8List.sublistView(rawBytes, 0, expectedLength);
      double? cutoffFrequencyHz;
      if (cutoffPath != null) {
        final expectedCutoffLength =
            audioSpectralAnalysisWidth * audioSpectrogramHeight;
        final cutoffLength = await File(cutoffPath).length();
        if (cutoffLength != expectedCutoffLength) {
          throw Exception(
            'Incomplete spectral cutoff output '
            '($cutoffLength/$expectedCutoffLength bytes)',
          );
        }
        _checkCancelled(isCancelled);
        final nativeRequest = 'spectral-$rawPath';
        _nativeAnalysisRequests.add(nativeRequest);
        try {
          try {
            final result = await PlatformBridge.runNativeDataJob({
              'operation': 'spectral_cutoff',
              'path': cutoffPath,
              'width': audioSpectralAnalysisWidth,
              'height': audioSpectrogramHeight,
              'max_frequency': (sampleRate ?? 0) / 2,
            }, requestId: nativeRequest);
            cutoffFrequencyHz = (result['cutoff'] as num?)?.toDouble();
          } on MissingPluginException {
            cutoffFrequencyHz = await compute(
              _estimateEffectiveSpectralCutoffFileInIsolate,
              _SpectralCutoffFileParams(
                path: cutoffPath,
                width: audioSpectralAnalysisWidth,
                height: audioSpectrogramHeight,
                maxFrequencyHz: (sampleRate ?? 0) / 2,
              ),
            );
          }
        } finally {
          _nativeAnalysisRequests.remove(nativeRequest);
        }
        _checkCancelled(isCancelled);
      }
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        rgba,
        audioSpectrogramWidth,
        audioSpectrogramHeight,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      return GeneratedSpectrogram(
        image: await completer.future,
        cutoffFrequencyHz: cutoffFrequencyHz,
      );
    } finally {
      try {
        await File(rawPath).delete();
      } catch (_) {}
      if (cutoffPath != null) {
        try {
          await File(cutoffPath).delete();
        } catch (_) {}
      }
    }
  }

  Future<_MediaInfo> _getMediaInfo(String filePath) async {
    final info = await FFmpegExecution.mediaInformation(filePath);

    if (info == null) {
      throw Exception('Failed to get media information');
    }

    int fileSize = 0;
    try {
      fileSize = await File(filePath).length();
    } catch (_) {}

    final streams = info.getStreams();
    final audioStream = streams.firstWhere(
      (s) => s.getAllProperties()?['codec_type'] == 'audio',
      orElse: () => throw Exception('No audio stream found'),
    );

    final props = audioStream.getAllProperties() ?? {};
    final infoProps = info.getAllProperties() ?? {};
    final codecName = props['codec_name']?.toString().toLowerCase() ?? '';
    final codecLongName = props['codec_long_name']?.toString() ?? '';
    final decodedSampleFormat = props['sample_fmt']?.toString() ?? '';
    final formatName = infoProps['format_name']?.toString() ?? '';
    final formatLongName = infoProps['format_long_name']?.toString() ?? '';
    final sampleRate =
        int.tryParse(props['sample_rate']?.toString() ?? '') ?? 0;
    final channels = int.tryParse(props['channels']?.toString() ?? '') ?? 0;
    final channelLayout =
        props['channel_layout']?.toString() ??
        props['ch_layout']?.toString() ??
        '';
    final streamDuration = double.tryParse(props['duration']?.toString() ?? '');
    final containerDuration = double.tryParse(info.getDuration() ?? '');
    final duration =
        (streamDuration != null && streamDuration > 0
            ? streamDuration
            : containerDuration) ??
        0;
    final streamBitrate = int.tryParse(props['bit_rate']?.toString() ?? '');
    final containerBitrate = int.tryParse(info.getBitrate() ?? '');
    final bitrate =
        streamBitrate ??
        containerBitrate ??
        (duration > 0 && fileSize > 0 ? (fileSize * 8 / duration).round() : 0);

    final canReportStoredBitDepth = _codecHasStoredBitDepth(codecName);

    int bitsPerSample = 0;
    if (canReportStoredBitDepth) {
      bitsPerSample =
          int.tryParse(props['bits_per_raw_sample']?.toString() ?? '') ?? 0;
      if (bitsPerSample == 0) {
        bitsPerSample =
            int.tryParse(props['bits_per_sample']?.toString() ?? '') ?? 0;
      }
    }

    if (bitsPerSample == 0 && canReportStoredBitDepth) {
      final sampleFmt = props['sample_fmt']?.toString() ?? '';
      if (sampleFmt.contains('16') ||
          sampleFmt == 's16' ||
          sampleFmt == 's16p') {
        bitsPerSample = 16;
      } else if (sampleFmt.contains('32') ||
          sampleFmt == 'flt' ||
          sampleFmt == 'fltp') {
        bitsPerSample = 32;
      } else if (sampleFmt.contains('24') || sampleFmt == 's24') {
        bitsPerSample = 24;
      }
    }

    return _MediaInfo(
      fileSize: fileSize,
      codecName: codecName,
      codec: _formatCodecLabel(codecName, codecLongName),
      container: _formatContainerLabel(formatName, formatLongName),
      decodedSampleFormat: decodedSampleFormat,
      sampleRate: sampleRate,
      channels: channels,
      channelLayout: channelLayout,
      bitsPerSample: bitsPerSample,
      duration: duration,
      bitrate: bitrate,
      totalSamples: _estimateTotalSamples(
        props: props,
        duration: duration,
        sampleRate: sampleRate,
        channels: channels,
      ),
    );
  }

  String _formatCodecLabel(String codecName, String codecLongName) {
    final name = codecName.trim();
    final longName = _normalizeAnalysisLabel(codecLongName);
    if (name.isEmpty) return longName;
    if (longName.isEmpty || longName.toLowerCase() == name.toLowerCase()) {
      return name.toUpperCase();
    }
    return '${name.toUpperCase()} ($longName)';
  }

  String _formatContainerLabel(String formatName, String formatLongName) {
    final longName = _normalizeAnalysisLabel(formatLongName);
    if (longName.isNotEmpty) return longName;
    final name = formatName.trim();
    return name.isEmpty ? '' : name.toUpperCase();
  }

  String _normalizeAnalysisLabel(String value) {
    final trimmed = value.trim();
    final lower = trimmed.toLowerCase();
    if (lower.isEmpty || lower == 'unknown' || lower == 'n/a') return '';
    return trimmed;
  }

  int _estimateTotalSamples({
    required Map<dynamic, dynamic> props,
    required double duration,
    required int sampleRate,
    required int channels,
  }) {
    final nbSamples = int.tryParse(props['nb_samples']?.toString() ?? '');
    if (nbSamples != null && nbSamples > 0) {
      return nbSamples;
    }

    final durationTs = int.tryParse(props['duration_ts']?.toString() ?? '');
    final timeBase = props['time_base']?.toString() ?? '';
    if (durationTs != null && durationTs > 0 && timeBase.contains('/')) {
      final parts = timeBase.split('/');
      final numerator = double.tryParse(parts[0]);
      final denominator = double.tryParse(parts[1]);
      if (numerator != null &&
          numerator > 0 &&
          denominator != null &&
          denominator > 0 &&
          sampleRate > 0) {
        final seconds = durationTs * numerator / denominator;
        return (seconds * sampleRate).round();
      }
    }

    if (duration > 0 && sampleRate > 0) {
      return (duration * sampleRate).round();
    }
    return 0;
  }

  bool _codecHasStoredBitDepth(String codecName) {
    if (codecName.isEmpty) return false;
    return codecName == 'flac' ||
        codecName == 'alac' ||
        codecName == 'wavpack' ||
        codecName == 'ape' ||
        codecName == 'tta' ||
        codecName.startsWith('pcm_');
  }

  Future<_LevelMetrics?> _runFullStreamLevelAnalysis(
    String inputPath, {
    required bool Function() isCancelled,
    required double durationSeconds,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final metadataFile = File(
      '${tempDir.path}/analysis_metrics_'
      '${DateTime.now().microsecondsSinceEpoch}.txt',
    );
    try {
      _checkCancelled(isCancelled);
      final session = await _analysisJobs.run(
        buildAudioMetricsArguments(
          inputPath: inputPath,
          metadataPath: metadataFile.path,
          durationSeconds: durationSeconds,
        ),
      );

      if (!session.success) {
        return null;
      }

      final metadata = await metadataFile.exists()
          ? await metadataFile.readAsString()
          : '';
      final metadataSummary = parseAudioAnalysisMetadata(metadata);
      final logs = metadataSummary == null ? await session.logs() : '';
      final summary = metadataSummary ?? parseAudioAstatsSummary(logs);
      if (summary == null) return null;
      final channelStats = metadataSummary?.channelStats.isNotEmpty == true
          ? metadataSummary!.channelStats
          : parseChannelStats(logs);
      final clippingSamples = channelStats.fold<int>(0, (sum, stats) {
        if (stats.peakDb == null || stats.peakDb! < -0.1) return sum;
        return sum + stats.peakCount;
      });
      return _LevelMetrics(
        peakDb: summary.peakDb,
        rmsDb: summary.rmsDb,
        integratedLufs: metadataSummary?.integratedLufs,
        truePeakDb: metadataSummary?.truePeakDb,
        clippingSamples: clippingSamples,
        channelStats: channelStats,
      );
    } finally {
      try {
        if (await metadataFile.exists()) await metadataFile.delete();
      } catch (_) {}
    }
  }
}
