import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mornye/services/audio_analysis_models.dart';

const int audioSpectrogramWidth = 1600;
const int audioSpectrogramHeight = 800;
const int audioSpectralAnalysisWidth = 400;
const double audioSpectrogramDynamicRangeDb = 120;
// Keep splice boundaries well below the cutoff estimator's top temporal
// percentile. Too many short excerpts turn waveform discontinuities into a
// persistent broadband floor, which can make a real low-pass edge look like
// full-band content. Longer windows preserve the same whole-track coverage and
// memory bound while making the small number of seams statistical outliers.
const int audioSpectrogramSampleWindowCount = 16;
const int audioSpectrogramMaxSelectedChannelSamples = 8 * 1024 * 1024;

String formatAudioAnalysisSpectralCutoff(
  double? cutoffHz, {
  required String notDetectedLabel,
}) {
  if (cutoffHz == null || !cutoffHz.isFinite || cutoffHz <= 0) {
    return notDetectedLabel;
  }
  if (cutoffHz >= 1000) {
    return '${(cutoffHz / 1000).toStringAsFixed(1)} kHz';
  }
  return '${cutoffHz.round()} Hz';
}

final RegExp _ac4CodecTokenPattern = RegExp(
  r'(^|[^a-z0-9])ac[\s_-]?4($|[^a-z0-9])',
  caseSensitive: false,
);

/// Returns whether the bundled FFmpeg decoder can analyze this audio codec.
/// Container formats such as MP4 are intentionally not used here because the
/// same container may hold supported AAC/ALAC/E-AC-3 or unsupported AC-4.
bool isAudioAnalysisCodecSupported(String? codecName) {
  final value = codecName?.trim() ?? '';
  if (value.isEmpty) return true;
  return !_ac4CodecTokenPattern.hasMatch(value);
}

String? unsupportedAudioAnalysisCodecLabel(String? codecName) =>
    isAudioAnalysisCodecSupported(codecName) ? null : 'AC-4';

class UnsupportedAudioAnalysisCodecException implements Exception {
  final String codecLabel;

  const UnsupportedAudioAnalysisCodecException(this.codecLabel);
}

String _buildShowspectrumOptions({required int width, required String color}) {
  return 'showspectrumpic='
      's=${width}x$audioSpectrogramHeight:'
      'legend=0:mode=combined:color=$color:scale=log:fscale=lin:'
      'win_func=hann:drange=${audioSpectrogramDynamicRangeDb.toStringAsFixed(0)}:'
      'limit=0';
}

/// [inputLabel] names the audio to draw; another graph that ends in that
/// label (such as a null test residual) can precede this filter.
String buildAudioSpectrogramFilter({
  int channel = -1,
  bool includeCutoffPlane = false,
  double? durationSeconds,
  int? sampleRate,
  int? channels,
  String inputLabel = '[0:a:0]',
}) {
  final channelFilter = channel >= 0 ? 'pan=mono|c0=c$channel,' : '';
  final samplingFilter = _buildAudioSpectrogramSamplingFilter(
    channel: channel,
    durationSeconds: durationSeconds,
    sampleRate: sampleRate,
    channels: channels,
  );
  final input =
      '$inputLabel$channelFilter${samplingFilter}aformat=sample_fmts=fltp';
  final display = _buildShowspectrumOptions(
    width: audioSpectrogramWidth,
    color: 'intensity',
  );
  if (!includeCutoffPlane) {
    return '$input,$display,format=rgba[spectrum]';
  }

  // The display palette encodes quiet bins as saturated blue/purple pixels,
  // so RGB brightness is not a monotonic measure of spectral magnitude. Keep
  // the colorful UI output, but generate a small fixed-hue plane whose gray
  // values can be used safely for effective-bandwidth detection.
  final cutoff = _buildShowspectrumOptions(
    width: audioSpectralAnalysisWidth,
    color: 'green',
  );
  return '$input,asplit=2[display_input][cutoff_input];'
      '[display_input]$display,format=rgba[spectrum];'
      '[cutoff_input]$cutoff,format=gray[cutoff]';
}

List<String> buildAudioSpectrogramArguments({
  required String inputPath,
  required String outputPath,
  String? cutoffOutputPath,
  int channel = -1,
  double? durationSeconds,
  int? sampleRate,
  int? channels,
}) {
  final arguments = <String>[
    '-hide_banner',
    '-y',
    '-i',
    inputPath,
    '-filter_complex',
    buildAudioSpectrogramFilter(
      channel: channel,
      includeCutoffPlane: cutoffOutputPath != null,
      durationSeconds: durationSeconds,
      sampleRate: sampleRate,
      channels: channels,
    ),
    '-map',
    '[spectrum]',
    '-frames:v',
    '1',
    '-f',
    'rawvideo',
    '-pix_fmt',
    'rgba',
    outputPath,
  ];
  if (cutoffOutputPath != null) {
    arguments.addAll([
      '-map',
      '[cutoff]',
      '-frames:v',
      '1',
      '-f',
      'rawvideo',
      '-pix_fmt',
      'gray',
      cutoffOutputPath,
    ]);
  }
  return arguments;
}

String _buildAudioSpectrogramSamplingFilter({
  required int channel,
  required double? durationSeconds,
  required int? sampleRate,
  required int? channels,
}) {
  final duration = durationSeconds ?? 0;
  final rate = sampleRate ?? 0;
  if (!duration.isFinite || duration <= 0 || rate <= 0) return '';

  final selectedChannels = channel >= 0
      ? 1
      : ((channels ?? 0) > 0 ? channels! : 2);
  final maxSelectedDuration =
      audioSpectrogramMaxSelectedChannelSamples / (rate * selectedChannels);
  if (duration <= maxSelectedDuration) return '';

  // showspectrumpic retains its complete input until it can render the final
  // frame. Feed it equal windows spread across the whole track so memory is
  // bounded without biasing the image or cutoff estimate toward the intro.
  final interval = duration / audioSpectrogramSampleWindowCount;
  final window = maxSelectedDuration / audioSpectrogramSampleWindowCount;
  return "aselect='lt(mod(t,${interval.toStringAsFixed(9)}),"
      "${window.toStringAsFixed(9)})',asetpts=N/SR/TB,";
}

class AudioAstatsSummary {
  final double peakDb;
  final double rmsDb;

  const AudioAstatsSummary({required this.peakDb, required this.rmsDb});
}

class AudioAnalysisMetadataSummary extends AudioAstatsSummary {
  final double? integratedLufs;
  final double? truePeakDb;
  final List<ChannelAnalysisStats> channelStats;

  const AudioAnalysisMetadataSummary({
    required super.peakDb,
    required super.rmsDb,
    this.integratedLufs,
    this.truePeakDb,
    this.channelStats = const [],
  });
}

AudioAstatsSummary? parseAudioAstatsSummary(String logs) {
  final overallMatch = RegExp(r'Overall([\s\S]*)').firstMatch(logs);
  final section = overallMatch?.group(1) ?? logs;
  final peak = _parseLastAudioAstatsValue(section, 'Peak level dB');
  final rms = _parseLastAudioAstatsValue(section, 'RMS level dB');
  if (peak == null || rms == null) return null;
  return AudioAstatsSummary(peakDb: peak, rmsDb: rms);
}

double? _parseLastAudioAstatsValue(String text, String label) {
  final matches = RegExp(
    '${RegExp.escape(label)}:\\s*([-+]?\\d+(?:\\.\\d+)?)',
    caseSensitive: false,
  ).allMatches(text);
  double? value;
  for (final match in matches) {
    final parsed = double.tryParse(match.group(1) ?? '');
    if (parsed != null && parsed.isFinite) {
      value = parsed;
    }
  }
  return value;
}

List<ChannelAnalysisStats> parseChannelStats(String logs) {
  final stats = <ChannelAnalysisStats>[];
  final channelMatches = RegExp(
    r'Channel:\s*(\d+)([\s\S]*?)(?=Channel:\s*\d+|Overall|$)',
    caseSensitive: false,
  ).allMatches(logs);

  for (final match in channelMatches) {
    final channel = int.tryParse(match.group(1) ?? '') ?? 0;
    final section = match.group(2) ?? '';
    if (channel <= 0 || section.trim().isEmpty) continue;
    final peakDb = _parseLastAstatsValue(section, 'Peak level dB');
    final rmsDb = _parseLastAstatsValue(section, 'RMS level dB');
    stats.add(
      ChannelAnalysisStats(
        channel: channel,
        peakDb: peakDb,
        rmsDb: rmsDb,
        dynamicRangeDb: peakDb != null && rmsDb != null ? peakDb - rmsDb : null,
        peakCount:
            _parseLastAstatsInt(section, 'Peak count') ??
            _parseLastAstatsInt(section, 'Peak count ch') ??
            0,
      ),
    );
  }

  return stats;
}

double? _parseLastAstatsValue(String text, String label) {
  return _parseLastAudioAstatsValue(text, label);
}

int? _parseLastAstatsInt(String text, String label) {
  final matches = RegExp(
    '${RegExp.escape(label)}:\\s*(\\d+)',
    caseSensitive: false,
  ).allMatches(text);
  int? value;
  for (final match in matches) {
    value = int.tryParse(match.group(1) ?? '') ?? value;
  }
  return value;
}

/// Escapes a file path for a quoted filter option such as
/// `ametadata=print:file='...'`.
String escapeFFmpegFilterPath(String path) =>
    path.replaceAll(r'\', r'\\').replaceAll(':', r'\:').replaceAll("'", r"\'");

String buildAudioMetricsFilter({
  required double durationSeconds,
  required String metadataPath,
}) {
  final metadataStart = math.max(0.0, durationSeconds - 2.0);
  final escapedPath = escapeFFmpegFilterPath(metadataPath);
  return 'astats=metadata=1:reset=0:'
      'measure_perchannel=Peak_level+RMS_level+Peak_count:'
      'measure_overall=Peak_level+RMS_level,'
      'ebur128=peak=true:metadata=1:framelog=quiet,'
      "aselect='gte(t,${metadataStart.toStringAsFixed(3)})',"
      "ametadata=print:file='$escapedPath'";
}

List<String> buildAudioMetricsArguments({
  required String inputPath,
  required String metadataPath,
  required double durationSeconds,
}) {
  // FFmpegKit's log level is process-global. A native download finalizer can
  // run `-v error` concurrently, so analyzer results must come from this
  // session's metadata file rather than info-level log callbacks.
  return [
    '-hide_banner',
    '-nostats',
    '-i',
    inputPath,
    '-map',
    '0:a:0',
    '-vn',
    '-sn',
    '-dn',
    '-af',
    buildAudioMetricsFilter(
      durationSeconds: durationSeconds,
      metadataPath: metadataPath,
    ),
    '-f',
    'null',
    '-',
  ];
}

AudioAnalysisMetadataSummary? parseAudioAnalysisMetadata(String metadata) {
  final peak = _parseLastMetadataValue(
    metadata,
    'lavfi.astats.Overall.Peak_level',
  );
  final rms = _parseLastMetadataValue(
    metadata,
    'lavfi.astats.Overall.RMS_level',
  );
  if (peak == null || rms == null) return null;

  final channelNumbers = RegExp(
    r'^lavfi\.astats\.(\d+)\.',
    multiLine: true,
  ).allMatches(metadata).map((match) => int.parse(match.group(1)!)).toSet();
  final channelStats = channelNumbers.toList()..sort();

  final truePeakLinear = _parseLastMetadataValue(
    metadata,
    'lavfi.r128.true_peak',
  );
  return AudioAnalysisMetadataSummary(
    peakDb: peak,
    rmsDb: rms,
    integratedLufs: _parseLastMetadataValue(metadata, 'lavfi.r128.I'),
    truePeakDb: truePeakLinear != null && truePeakLinear > 0
        ? 20 * math.log(truePeakLinear) / math.ln10
        : null,
    channelStats: channelStats.map((channel) {
      final channelPeak = _parseLastMetadataValue(
        metadata,
        'lavfi.astats.$channel.Peak_level',
      );
      final channelRms = _parseLastMetadataValue(
        metadata,
        'lavfi.astats.$channel.RMS_level',
      );
      return ChannelAnalysisStats(
        channel: channel,
        peakDb: channelPeak,
        rmsDb: channelRms,
        dynamicRangeDb: channelPeak != null && channelRms != null
            ? channelPeak - channelRms
            : null,
        peakCount:
            _parseLastMetadataValue(
              metadata,
              'lavfi.astats.$channel.Peak_count',
            )?.round() ??
            0,
      );
    }).toList(),
  );
}

double? _parseLastMetadataValue(String metadata, String key) {
  final matches = RegExp(
    '^${RegExp.escape(key)}=([^\\r\\n]+)',
    multiLine: true,
  ).allMatches(metadata);
  double? value;
  for (final match in matches) {
    final parsed = double.tryParse(match.group(1)?.trim() ?? '');
    if (parsed != null && parsed.isFinite) value = parsed;
  }
  return value;
}

double? estimateEffectiveSpectralCutoffHz({
  required Uint8List intensity,
  required int width,
  required int height,
  required double maxFrequencyHz,
}) {
  if (width <= 0 ||
      height <= 0 ||
      maxFrequencyHz <= 0 ||
      intensity.length < width * height) {
    return null;
  }

  // Use a high temporal percentile so sustained musical bandwidth wins over
  // silence, while short ultrasonic transients do not define the cutoff.
  // These bytes come from FFmpeg's fixed-hue `color=green` output, where gray
  // value is monotonic with magnitude; display-palette RGB is deliberately not
  // accepted here because its blue noise floor has deceptively large channels.
  final profile = Float64List(height);
  final histogram = Uint32List(256);
  final percentileTarget = math.max(0, (width * 0.90).floor());
  for (var y = 0; y < height; y++) {
    histogram.fillRange(0, histogram.length, 0);
    final rowStart = y * width;
    for (var x = 0; x < width; x++) {
      histogram[intensity[rowStart + x]]++;
    }

    var cumulative = 0;
    for (var value = 0; value < histogram.length; value++) {
      cumulative += histogram[value];
      if (cumulative > percentileTarget) {
        // showspectrumpic stores Nyquist at the top. Reverse it here so array
        // indices increase with frequency, which makes edge detection clearer.
        profile[height - y - 1] = value.toDouble();
        break;
      }
    }
  }

  final hzPerRow = maxFrequencyHz / height;

  // Reject narrow horizontal lines before looking for a bandwidth edge. A
  // median over roughly 500 Hz preserves a broadband step while removing
  // pilots, tones, and isolated noisy bins that occupy only a small fraction
  // of the surrounding band.
  final lineRejectionRadius = math.max(1, (250 / hzPerRow).ceil());
  final broadbandProfile = Float64List(height);
  for (var index = 0; index < height; index++) {
    broadbandProfile[index] = _spectralMedian(
      profile,
      index - lineRejectionRadius,
      index + lineRejectionRadius + 1,
    );
  }

  // Apply only light smoothing after the robust frequency aggregation. This
  // reduces row quantization without letting a high-amplitude line smear into
  // enough adjacent bins to resemble broadband support.
  final smoothingRadius = math.max(1, (50 / hzPerRow).ceil());
  final smoothed = Float64List(height);
  var running = 0.0;
  var windowStart = 0;
  var windowEnd = -1;
  for (var index = 0; index < height; index++) {
    final desiredStart = math.max(0, index - smoothingRadius);
    final desiredEnd = math.min(height - 1, index + smoothingRadius);
    while (windowEnd < desiredEnd) {
      windowEnd++;
      running += broadbandProfile[windowEnd];
    }
    while (windowStart < desiredStart) {
      running -= broadbandProfile[windowStart];
      windowStart++;
    }
    smoothed[index] = running / (windowEnd - windowStart + 1);
  }

  final centralStart = math.max(0, (height * 0.05).floor());
  final centralEnd = math.min(height, (height * 0.95).ceil());
  final central = _sortedSpectralWindow(smoothed, centralStart, centralEnd);
  final lowLevel = _sortedSpectralPercentile(central, 0.10);
  final highLevel = _sortedSpectralPercentile(central, 0.95);
  final dynamicSpan = highLevel - lowLevel;
  if (highLevel < 24) return null;
  if (dynamicSpan < 1) return maxFrequencyHz;

  // Locate a sharp downward edge over roughly 200 Hz, then validate it using
  // wider bands on both sides. This detects codec/low-pass bandwidth edges but
  // rejects a gradual musical roll-off or a narrow ultrasonic pilot.
  final edgeSpanRows = math.max(2, (200 / hzPerRow).ceil());
  final topGuardRows = math.max(edgeSpanRows, (500 / hzPerRow).ceil());
  final minSearchHz = math.max(1000.0, math.min(4000.0, maxFrequencyHz * 0.20));
  final searchStart = math.max(edgeSpanRows, (minSearchHz / hzPerRow).floor());
  final searchEnd = height - edgeSpanRows - topGuardRows;
  final candidateStarts = <int>[];
  for (var start = searchStart; start < searchEnd; start++) {
    final drop = smoothed[start] - smoothed[start + edgeSpanRows];
    if (drop > 0) candidateStarts.add(start);
  }
  candidateStarts.sort((a, b) {
    final aDrop = smoothed[a] - smoothed[a + edgeSpanRows];
    final bDrop = smoothed[b] - smoothed[b + edgeSpanRows];
    return bDrop.compareTo(aDrop);
  });

  // A sharp, frequency-contiguous edge remains meaningful at lower contrast
  // than an arbitrary bright bin. Keep the threshold relative to the measured
  // spectral span, but do not require the old fixed 12-byte difference that
  // caused elevated noise floors to be classified as full-band.
  final minimumDrop = math.max(6.0, dynamicSpan * 0.18);
  final gapRows = math.max(1, (100 / hzPerRow).ceil());
  final supportRows = math.max(3, (1200 / hzPerRow).ceil());
  final stableTailSpread = math.max(4.0, dynamicSpan * 0.06);
  for (final bestStart in candidateStarts) {
    final bestLocalDrop =
        smoothed[bestStart] - smoothed[bestStart + edgeSpanRows];
    if (bestLocalDrop < minimumDrop * 0.60) break;
    final edgeIndex = (bestStart + edgeSpanRows / 2).round();
    final belowEnd = edgeIndex - gapRows;
    final belowStart = math.max(0, belowEnd - supportRows);
    final aboveStart = edgeIndex + gapRows;
    final aboveEnd = math.min(height, aboveStart + supportRows);
    if (belowEnd > belowStart && aboveEnd > aboveStart) {
      final belowLevel = _spectralMedian(smoothed, belowStart, belowEnd);
      final aboveLevel = _spectralMedian(smoothed, aboveStart, aboveEnd);
      if (belowLevel - aboveLevel < minimumDrop) continue;
      // All tail statistics share one sorted window. Rejected local edges do
      // not need to copy and sort the rest of the spectrum at all.
      final tail = _sortedSpectralWindow(smoothed, aboveStart, height);
      final tailLevel = _sortedSpectralPercentile(tail, 0.50);
      if (belowLevel - tailLevel < minimumDrop) continue;
      final tailSpread =
          _sortedSpectralPercentile(tail, 0.80) -
          _sortedSpectralPercentile(tail, 0.20);
      if (tailSpread > stableTailSpread) continue;
      final baseStart = math.max(0, edgeIndex - (3000 / hzPerRow).ceil());
      final baseLevel = _spectralMedian(smoothed, baseStart, belowEnd);
      if (baseLevel - tailLevel >= minimumDrop) {
        final cutoff = (edgeIndex + 0.5) * hzPerRow;
        return cutoff.clamp(0.0, maxFrequencyHz).toDouble();
      }
    }
  }

  // Some masters roll off over several kilohertz instead of ending at one
  // sharp edge. Find the highest sustained band that remains clearly above a
  // stable high-frequency floor so ordinary musical spectral tilt is not
  // mistaken for a low-pass cutoff.
  final tailReferenceLevel = _spectralMedian(
    smoothed,
    (height * 0.90).floor(),
    math.max(1, (height * 0.98).floor()),
  );
  // A gradual cutoff needs stronger contrast than a sharp, contiguous edge.
  // Otherwise an ordinary full-band spectral tilt can eventually cross the
  // high-frequency floor by a few grayscale steps and create an arbitrary
  // cutoff. Require a material transition into the stable tail instead.
  final activeMargin = math.max(12.0, dynamicSpan * 0.25);
  final activeThreshold = tailReferenceLevel + activeMargin;
  for (var edgeIndex = searchEnd - 1; edgeIndex >= searchStart; edgeIndex--) {
    final belowEnd = edgeIndex - gapRows;
    final belowStart = math.max(0, belowEnd - supportRows);
    final aboveStart = edgeIndex + gapRows;
    if (belowEnd <= belowStart || aboveStart >= height) continue;
    final belowLevel = _spectralMedian(smoothed, belowStart, belowEnd);
    if (belowLevel < activeThreshold) continue;
    final tail = _sortedSpectralWindow(smoothed, aboveStart, height);
    final tailLevel = _sortedSpectralPercentile(tail, 0.50);
    if (belowLevel - tailLevel < activeMargin) continue;
    final tailSpread =
        _sortedSpectralPercentile(tail, 0.80) -
        _sortedSpectralPercentile(tail, 0.20);
    if (tailSpread <= stableTailSpread) {
      final cutoffIndex = edgeIndex - supportRows / 2;
      final cutoff = (cutoffIndex + 0.5) * hzPerRow;
      return cutoff.clamp(0.0, maxFrequencyHz).toDouble();
    }
  }

  // A genuinely broadband signal with no stable tail plateau reaches the
  // analysis ceiling. Natural music may retain a pronounced spectral tilt,
  // so require populated baseband and top bands instead of similar levels.
  // Silence and isolated high-frequency lines still return null.
  final basebandLevel = _spectralMedian(
    smoothed,
    (height * 0.05).floor(),
    math.max(1, (height * 0.50).floor()),
  );
  final topBandLevel = _spectralMedian(
    smoothed,
    (height * 0.90).floor(),
    math.max(1, (height * 0.98).floor()),
  );
  final lowerTopBandLevel = _spectralMedian(
    smoothed,
    (height * 0.80).floor(),
    math.max(1, (height * 0.90).floor()),
  );
  final topBandNearPeak = topBandLevel >= highLevel - minimumDrop;
  // A real low-contrast full-band slope can change by less than the tail
  // stability tolerance. Preserve it when the upper octave still trends
  // downward by at least one grayscale step; a low-pass noise plateau remains
  // flat here and must already have passed the validated edge checks above.
  final upperBandSlope = lowerTopBandLevel - topBandLevel;
  final topBandStillSloping =
      upperBandSlope >= math.max(1.0, dynamicSpan * 0.05);
  if (basebandLevel >= 24 &&
      topBandLevel >= 24 &&
      (topBandNearPeak || topBandStillSloping)) {
    return maxFrequencyHz;
  }
  return null;
}

double _spectralMedian(Float64List values, int start, int end) {
  return _sortedSpectralPercentile(
    _sortedSpectralWindow(values, start, end),
    0.50,
  );
}

Float64List _sortedSpectralWindow(Float64List values, int start, int end) {
  final safeStart = start.clamp(0, values.length).toInt();
  final safeEnd = end.clamp(safeStart, values.length).toInt();
  return values.sublist(safeStart, safeEnd)..sort();
}

double _sortedSpectralPercentile(Float64List sorted, double percentile) {
  if (sorted.isEmpty) return 0;
  final index = ((sorted.length - 1) * percentile)
      .round()
      .clamp(0, sorted.length - 1)
      .toInt();
  return sorted[index];
}
