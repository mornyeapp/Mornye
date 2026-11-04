// Analysis result models. `AudioAnalysisData` is the persisted cache JSON.

class AudioAnalysisBitrate {
  const AudioAnalysisBitrate(this.bitsPerSecond, {this.fileAverage = false});

  factory AudioAnalysisBitrate.fromProbe({
    int? streamBitrate,
    int? containerBitrate,
    required int fileSize,
    required double duration,
  }) {
    if (streamBitrate != null && streamBitrate > 0) {
      return AudioAnalysisBitrate(streamBitrate);
    }
    if (containerBitrate != null && containerBitrate > 0) {
      return AudioAnalysisBitrate(containerBitrate, fileAverage: true);
    }
    if (fileSize > 0 && duration.isFinite && duration > 0) {
      return AudioAnalysisBitrate(
        (fileSize * 8 / duration).round(),
        fileAverage: true,
      );
    }
    return const AudioAnalysisBitrate(0);
  }

  final int bitsPerSecond;

  /// Includes container overhead and tags, not just the encoded audio stream.
  final bool fileAverage;
}

class AudioAnalysisData {
  static const cacheVersion = 14;

  final String filePath;
  final int fileSize;
  final String codec;
  final String container;
  final String decodedSampleFormat;
  final int sampleRate;
  final int channels;
  final String channelLayout;
  final int bitsPerSample;
  final double duration;
  final int bitrate;
  final bool bitrateIsFileAverage;
  final String bitDepth;
  final double dynamicRange;
  final double peakAmplitude;
  final double rmsLevel;
  final double? integratedLufs;
  final double? truePeakDb;
  final int clippingSamples;
  final double? spectralCutoffHz;
  final List<ChannelAnalysisStats> channelStats;
  final int totalSamples;

  const AudioAnalysisData({
    required this.filePath,
    required this.fileSize,
    this.codec = '',
    this.container = '',
    this.decodedSampleFormat = '',
    required this.sampleRate,
    required this.channels,
    this.channelLayout = '',
    required this.bitsPerSample,
    required this.duration,
    required this.bitrate,
    this.bitrateIsFileAverage = false,
    required this.bitDepth,
    required this.dynamicRange,
    required this.peakAmplitude,
    required this.rmsLevel,
    this.integratedLufs,
    this.truePeakDb,
    this.clippingSamples = 0,
    this.spectralCutoffHz,
    this.channelStats = const [],
    required this.totalSamples,
  });

  Map<String, dynamic> toJson() => {
    'filePath': filePath,
    'cacheVersion': cacheVersion,
    'fileSize': fileSize,
    'codec': codec,
    'container': container,
    'decodedSampleFormat': decodedSampleFormat,
    'sampleRate': sampleRate,
    'channels': channels,
    'channelLayout': channelLayout,
    'bitsPerSample': bitsPerSample,
    'duration': duration,
    'bitrate': bitrate,
    'bitrateIsFileAverage': bitrateIsFileAverage,
    'bitDepth': bitDepth,
    'dynamicRange': dynamicRange,
    'peakAmplitude': peakAmplitude,
    'rmsLevel': rmsLevel,
    'integratedLufs': integratedLufs,
    'truePeakDb': truePeakDb,
    'clippingSamples': clippingSamples,
    'spectralCutoffHz': spectralCutoffHz,
    'channelStats': channelStats.map((stats) => stats.toJson()).toList(),
    'totalSamples': totalSamples,
  };

  factory AudioAnalysisData.fromJson(Map<String, dynamic> json) {
    return AudioAnalysisData(
      filePath: json['filePath'] as String,
      fileSize: json['fileSize'] as int,
      codec: json['codec']?.toString() ?? '',
      container: json['container']?.toString() ?? '',
      decodedSampleFormat: json['decodedSampleFormat']?.toString() ?? '',
      sampleRate: json['sampleRate'] as int,
      channels: json['channels'] as int,
      channelLayout: json['channelLayout']?.toString() ?? '',
      bitsPerSample: json['bitsPerSample'] as int,
      duration: (json['duration'] as num).toDouble(),
      bitrate: json['bitrate'] as int,
      bitrateIsFileAverage: json['bitrateIsFileAverage'] == true,
      bitDepth: json['bitDepth'] as String,
      dynamicRange: (json['dynamicRange'] as num).toDouble(),
      peakAmplitude: (json['peakAmplitude'] as num).toDouble(),
      rmsLevel: (json['rmsLevel'] as num).toDouble(),
      integratedLufs: (json['integratedLufs'] as num?)?.toDouble(),
      truePeakDb: (json['truePeakDb'] as num?)?.toDouble(),
      clippingSamples: (json['clippingSamples'] as num?)?.toInt() ?? 0,
      spectralCutoffHz: (json['spectralCutoffHz'] as num?)?.toDouble(),
      channelStats:
          (json['channelStats'] as List?)
              ?.whereType<Map<dynamic, dynamic>>()
              .map((item) => ChannelAnalysisStats.fromJson(item))
              .toList() ??
          const [],
      totalSamples: json['totalSamples'] as int,
    );
  }
}

class ChannelAnalysisStats {
  final int channel;
  final double? peakDb;
  final double? rmsDb;
  final double? dynamicRangeDb;
  final int peakCount;

  const ChannelAnalysisStats({
    required this.channel,
    this.peakDb,
    this.rmsDb,
    this.dynamicRangeDb,
    this.peakCount = 0,
  });

  Map<String, dynamic> toJson() => {
    'channel': channel,
    'peakDb': peakDb,
    'rmsDb': rmsDb,
    'dynamicRangeDb': dynamicRangeDb,
    'peakCount': peakCount,
  };

  factory ChannelAnalysisStats.fromJson(Map<dynamic, dynamic> json) {
    return ChannelAnalysisStats(
      channel: (json['channel'] as num?)?.toInt() ?? 0,
      peakDb: (json['peakDb'] as num?)?.toDouble(),
      rmsDb: (json['rmsDb'] as num?)?.toDouble(),
      dynamicRangeDb: (json['dynamicRangeDb'] as num?)?.toDouble(),
      peakCount: (json['peakCount'] as num?)?.toInt() ?? 0,
    );
  }
}
