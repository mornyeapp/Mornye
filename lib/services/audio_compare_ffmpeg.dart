// FFmpeg commands of the null test. Input 0 is the reference, input 1 the
// other file. Every pass decodes both from their first sample through the
// same chain, so a sample index means the same thing in each pass.
import 'dart:typed_data';

import 'package:mornye/services/audio_analysis_ffmpeg.dart';
import 'package:mornye/services/audio_compare_dsp.dart';

/// Decodes one input to float PCM at [sampleRate] with [channels] (1 or 2).
String audioCompareDecodeChain({
  required int sampleRate,
  required int channels,
}) =>
    'aresample=$sampleRate,'
    'aformat=sample_fmts=flt:channel_layouts=${channels == 1 ? 'mono' : 'stereo'}';

/// One excerpt to write as raw little-endian float PCM.
class AudioCompareExcerpt {
  const AudioCompareExcerpt({
    required this.input,
    required this.startSample,
    required this.endSample,
    required this.outputPath,
  });

  /// 0 for the reference, 1 for the other file.
  final int input;

  /// First sample kept and first sample dropped, at the excerpt's rate.
  final int startSample;
  final int endSample;
  final String outputPath;
}

/// Writes [excerpts] in one decode of both files. With [decimatedRate] the
/// excerpts are mono at that rate (the wide search); otherwise they keep
/// [channels] at [sampleRate].
List<String> buildAudioCompareExcerptArguments({
  required String referencePath,
  required String otherPath,
  required int sampleRate,
  required int channels,
  int? decimatedRate,
  required List<AudioCompareExcerpt> excerpts,
}) {
  final chain = decimatedRate == null
      ? audioCompareDecodeChain(sampleRate: sampleRate, channels: channels)
      : '${audioCompareDecodeChain(sampleRate: sampleRate, channels: 1)},'
            'aresample=$decimatedRate';
  final parts = <String>[];
  for (final input in const [0, 1]) {
    final indexes = [
      for (var i = 0; i < excerpts.length; i++)
        if (excerpts[i].input == input) i,
    ];
    if (indexes.isEmpty) continue;
    String trim(int index) {
      final excerpt = excerpts[index];
      return 'atrim=start_sample=${excerpt.startSample}:'
          'end_sample=${excerpt.endSample}[cmp_x$index]';
    }

    if (indexes.length == 1) {
      parts.add('[$input:a:0]$chain,${trim(indexes.single)}');
      continue;
    }
    final splits = [for (final index in indexes) '[cmp_s$index]'].join();
    parts.add('[$input:a:0]$chain,asplit=${indexes.length}$splits');
    for (final index in indexes) {
      parts.add('[cmp_s$index]${trim(index)}');
    }
  }
  return [
    '-hide_banner',
    '-nostats',
    '-y',
    '-i',
    referencePath,
    '-i',
    otherPath,
    '-filter_complex',
    parts.join(';'),
    for (var i = 0; i < excerpts.length; i++) ...[
      '-map',
      '[cmp_x$i]',
      '-f',
      'f32le',
      '-c:a',
      'pcm_f32le',
      excerpts[i].outputPath,
    ],
  ];
}

String _formatGain(double gain) => gain.toStringAsFixed(9);

/// `c<out>=c<a>-gain*c<b>`, written so a negative gain stays parseable.
String _subtract(int out, int a, int b, double gain) => gain >= 0
    ? 'c$out=c$a-${_formatGain(gain)}*c$b'
    : 'c$out=c$a+${_formatGain(-gain)}*c$b';

/// Lines both decoded files up and merges them into one stream whose first
/// [channels] channels are the reference and the next [channels] the other
/// file, shifted by [offsetFrames] (other-file frame minus reference frame)
/// and padded with silence after its end. The graph ends unlabeled, so the
/// caller appends filters to it.
String buildAudioCompareMergeGraph({
  required int sampleRate,
  required int channels,
  required int offsetFrames,
}) {
  final chain = audioCompareDecodeChain(
    sampleRate: sampleRate,
    channels: channels,
  );
  final offset = offsetFrames > 0
      ? 'atrim=start_sample=$offsetFrames,'
      : offsetFrames < 0
      ? 'adelay=delays=${-offsetFrames}S:all=1,'
      : '';
  return '[0:a:0]$chain,asetpts=N/SR/TB[cmp_ref];'
      '[1:a:0]$chain,${offset}asetpts=N/SR/TB,apad[cmp_oth];'
      '[cmp_ref][cmp_oth]amerge=inputs=2';
}

/// The residual `reference - gain * other`, appended to the merge graph.
String _residualPan(int channels, double gain) => channels == 1
    ? 'pan=mono|${_subtract(0, 0, 1, gain)}'
    : 'pan=stereo|${_subtract(0, 0, 2, gain)}|${_subtract(1, 1, 3, gain)}';

/// Per-window levels of the whole song. The metadata file lists, for each
/// window of [windowFrames] frames, the RMS level of the residual channels,
/// then the reference channels, then both again above [bandSplitHz].
List<String> buildAudioCompareStatsArguments({
  required String referencePath,
  required String otherPath,
  required int sampleRate,
  required int channels,
  required int offsetFrames,
  required double gain,
  required int windowFrames,
  required String metadataPath,
  double bandSplitHz = audioCompareBandSplitHz,
}) {
  final merge = buildAudioCompareMergeGraph(
    sampleRate: sampleRate,
    channels: channels,
    offsetFrames: offsetFrames,
  );
  final split = bandSplitHz.clamp(1.0, sampleRate * 0.45).round();
  final pan = channels == 1
      ? 'pan=2c|${_subtract(0, 0, 1, gain)}|c1=c0'
      : 'pan=4c|${_subtract(0, 0, 2, gain)}|${_subtract(1, 1, 3, gain)}|'
            'c2=c0|c3=c1';
  final graph =
      '$merge,$pan,asplit=2[cmp_full][cmp_hp];'
      '[cmp_hp]highpass=f=$split:poles=2,highpass=f=$split:poles=2[cmp_high];'
      '[cmp_full][cmp_high]amerge=inputs=2,'
      'asetnsamples=n=$windowFrames:p=0,'
      'astats=metadata=1:reset=1:measure_perchannel=RMS_level:'
      'measure_overall=none,'
      "ametadata=print:file='${escapeFFmpegFilterPath(metadataPath)}'"
      '[cmp_stats]';
  return [
    '-hide_banner',
    '-nostats',
    '-i',
    referencePath,
    '-i',
    otherPath,
    '-filter_complex',
    graph,
    '-map',
    '[cmp_stats]',
    '-f',
    'null',
    '-',
  ];
}

/// The existing spectrogram picture, drawn from the residual instead of a
/// file.
List<String> buildAudioCompareSpectrogramArguments({
  required String referencePath,
  required String otherPath,
  required int sampleRate,
  required int channels,
  required int offsetFrames,
  required double gain,
  required double durationSeconds,
  required String outputPath,
}) {
  final merge = buildAudioCompareMergeGraph(
    sampleRate: sampleRate,
    channels: channels,
    offsetFrames: offsetFrames,
  );
  final spectrogram = buildAudioSpectrogramFilter(
    durationSeconds: durationSeconds,
    sampleRate: sampleRate,
    channels: channels,
    inputLabel: '[cmp_residual]',
  );
  return [
    '-hide_banner',
    '-nostats',
    '-y',
    '-i',
    referencePath,
    '-i',
    otherPath,
    '-filter_complex',
    '$merge,${_residualPan(channels, gain)}[cmp_residual];$spectrogram',
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
}

final RegExp _frameLine = RegExp(r'^frame:\s*(\d+)', multiLine: false);
final RegExp _levelLine = RegExp(
  r'^lavfi\.astats\.(\d+)\.RMS_level=(.+)$',
  multiLine: false,
);

double _parseLevel(String value) {
  final text = value.trim().toLowerCase();
  if (text == '-inf') return double.negativeInfinity;
  if (text == 'inf' || text == '+inf') return double.infinity;
  return double.tryParse(text) ?? double.nan;
}

/// RMS levels in dBFS per window from the stats pass's metadata file, each
/// list holding [channels] values in channel order.
List<Float64List> parseAudioCompareMetadata(
  String metadata, {
  required int channels,
}) {
  final windows = <Float64List>[];
  Float64List? current;
  for (final line in metadata.split('\n')) {
    final trimmed = line.trim();
    if (_frameLine.hasMatch(trimmed)) {
      current = Float64List(channels)..fillRange(0, channels, double.nan);
      windows.add(current);
      continue;
    }
    final match = _levelLine.firstMatch(trimmed);
    if (match == null || current == null) continue;
    final channel = int.parse(match.group(1)!) - 1;
    if (channel < 0 || channel >= channels) continue;
    current[channel] = _parseLevel(match.group(2)!);
  }
  return windows;
}

/// Timeline windows from the stats pass, for [channels] audio channels (the
/// metadata holds four times as many). [totalFrames], when known, sizes the
/// final partial window.
List<AudioCompareWindow> audioCompareWindowsFromMetadata(
  List<Float64List> levels, {
  required int channels,
  required int sampleRate,
  required int windowFrames,
  int? totalFrames,
}) {
  Float64List powers(Float64List values, int from) => Float64List.fromList([
    for (var c = 0; c < channels; c++)
      audioCompareDbToPower(
        from + c < values.length ? values[from + c] : double.nan,
      ),
  ]);

  return [
    for (var i = 0; i < levels.length; i++)
      AudioCompareWindow(
        startSeconds: i * windowFrames / sampleRate,
        frames: i == levels.length - 1 && totalFrames != null
            ? (totalFrames - i * windowFrames).clamp(1, windowFrames).toInt()
            : windowFrames,
        residual: powers(levels[i], 0),
        reference: powers(levels[i], channels),
        residualHigh: powers(levels[i], channels * 2),
        referenceHigh: powers(levels[i], channels * 3),
      ),
  ];
}
