import 'package:mornye/l10n/app_localizations.dart';

const List<String> audioConversionTargetFormats = [
  'ALAC',
  'FLAC',
  'WAV',
  'AIFF',
  'AAC',
  'MP3',
  'Opus',
];

const List<int> losslessConversionSampleRateOptions = [
  192000,
  96000,
  48000,
  44100,
];

const List<int> losslessConversionBitDepthOptions = [16, 24];

const List<String> losslessDitherOptions = [
  'none',
  'triangular',
  'triangular_hp',
];

const List<String> losslessResamplerOptions = ['swr', 'soxr'];

const int soxrVhqPrecisionBits = 28;
const double soxrPassbandEndRatio = 0.95;

class LosslessConversionProcessing {
  final String dither;
  final String resampler;

  const LosslessConversionProcessing({
    this.dither = 'none',
    this.resampler = 'swr',
  });

  String get normalizedDither {
    final normalized = dither.trim().toLowerCase();
    return losslessDitherOptions.contains(normalized) ? normalized : 'none';
  }

  String get normalizedResampler {
    final normalized = resampler.trim().toLowerCase();
    return losslessResamplerOptions.contains(normalized) ? normalized : 'swr';
  }

  bool get hasDither => normalizedDither != 'none';
}

List<String> losslessResamplerFilterOptions(
  LosslessConversionProcessing processing,
) {
  final resampler = processing.normalizedResampler;
  return [
    'resampler=$resampler',
    if (resampler == 'soxr') ...[
      'precision=$soxrVhqPrecisionBits',
      'cutoff=$soxrPassbandEndRatio',
    ],
  ];
}

List<int> availableLosslessBitDepthOptions(int? sourceBitDepth) {
  if (sourceBitDepth == null || sourceBitDepth <= 0) {
    return losslessConversionBitDepthOptions;
  }
  return losslessConversionBitDepthOptions
      .where((depth) => depth < sourceBitDepth)
      .toList();
}

List<int> availableLosslessSampleRateOptions(int? sourceSampleRate) {
  if (sourceSampleRate == null || sourceSampleRate <= 0) {
    return losslessConversionSampleRateOptions;
  }
  return losslessConversionSampleRateOptions
      .where((rate) => rate < sourceSampleRate)
      .toList();
}

/// Offer every cap that can reduce a file in the batch. Unknown sources leave
/// the options open; the converter inspects each file before applying a cap.
int? conversionSourceMaximum(Iterable<int?> values) {
  int? highest;
  for (final value in values) {
    if (value == null || value <= 0) return null;
    if (highest == null || value > highest) {
      highest = value;
    }
  }
  return highest;
}

int normalizeAutoConvertBitDepth(int value) =>
    value == 0 || losslessConversionBitDepthOptions.contains(value)
    ? value
    : 16;

int normalizeAutoConvertSampleRate(int value) =>
    value == 0 || losslessConversionSampleRateOptions.contains(value)
    ? value
    : 48000;

class LosslessConversionQuality {
  final int? maxBitDepth;
  final int? maxSampleRate;

  const LosslessConversionQuality({this.maxBitDepth, this.maxSampleRate});

  bool get hasCaps => maxBitDepth != null || maxSampleRate != null;

  int? effectiveBitDepth(int? sourceBitDepth) {
    if (maxBitDepth == null) return sourceBitDepth;
    if (sourceBitDepth == null || sourceBitDepth <= 0) return maxBitDepth;
    return sourceBitDepth > maxBitDepth! ? maxBitDepth : sourceBitDepth;
  }

  int? effectiveSampleRate(int? sourceSampleRate) {
    if (maxSampleRate == null) return sourceSampleRate;
    if (sourceSampleRate == null || sourceSampleRate <= 0) {
      return maxSampleRate;
    }
    return sourceSampleRate > maxSampleRate! ? maxSampleRate : sourceSampleRate;
  }
}

bool isLosslessConversionTarget(String targetFormat) {
  final normalized = targetFormat.trim().toLowerCase();
  return normalized == 'alac' ||
      normalized == 'flac' ||
      normalized == 'wav' ||
      normalized == 'aiff' ||
      normalized == 'aif';
}

bool isLosslessConversionSource(String sourceFormat) =>
    switch (sourceFormat.trim().toUpperCase()) {
      'FLAC' || 'ALAC' || 'M4A' || 'WAV' || 'AIFF' || 'AIF' => true,
      _ => false,
    };

bool canConvertAudioFormat({
  required String sourceFormat,
  required String targetFormat,
}) {
  final normalizedSource = sourceFormat.trim().toUpperCase();
  final normalizedTarget = targetFormat.trim().toUpperCase();
  if (normalizedSource == normalizedTarget) {
    // Same-format lossless re-encoding is useful for reducing bit depth or
    // sample rate while selecting the dither and resampler implementation.
    return isLosslessConversionSource(normalizedSource) &&
        isLosslessConversionTarget(normalizedTarget);
  }
  if (isLosslessConversionTarget(targetFormat) &&
      !isLosslessConversionSource(sourceFormat)) {
    return false;
  }
  return true;
}

String? convertibleAudioSourceFormat({
  String? storedFormat,
  String? filePath,
  String? fileName,
}) {
  final fromStored = _convertibleAudioFormatLabel(storedFormat);
  if (fromStored != null) return fromStored;

  final name = (fileName != null && fileName.trim().isNotEmpty)
      ? fileName
      : filePath;
  if (name == null || name.trim().isEmpty) return null;

  final normalizedName = name.trim().toLowerCase();
  final dotIndex = normalizedName.lastIndexOf('.');
  if (dotIndex < 0 || dotIndex == normalizedName.length - 1) {
    return null;
  }
  return _convertibleAudioFormatLabel(normalizedName.substring(dotIndex + 1));
}

String? _convertibleAudioFormatLabel(String? rawFormat) {
  final format = rawFormat?.trim().toLowerCase();
  if (format == null || format.isEmpty) return null;

  return switch (format) {
    'flac' => 'FLAC',
    'alac' => 'ALAC',
    'wav' || 'wave' => 'WAV',
    'aiff' || 'aif' || 'aifc' => 'AIFF',
    'm4a' || 'mp4' => 'M4A',
    'aac' || 'mp4a' => 'AAC',
    'mp3' => 'MP3',
    'opus' || 'ogg' => 'Opus',
    'eac3' || 'ec-3' => 'EAC3',
    'ac3' || 'ac-3' => 'AC3',
    'ac4' || 'ac-4' => 'AC4',
    _ => null,
  };
}

class LosslessConversionLabels {
  final String original;
  final String originalQuality;
  final String lossless;

  const LosslessConversionLabels({
    required this.original,
    required this.originalQuality,
    required this.lossless,
  });
}

extension LosslessConversionLabelsL10n on AppLocalizations {
  LosslessConversionLabels get losslessConversionLabels =>
      LosslessConversionLabels(
        original: trackConvertOriginal,
        originalQuality: trackConvertOriginalQuality,
        lossless: trackConvertLosslessSuffix,
      );

  String losslessDitherOptionLabel(String dither) =>
      switch (dither.trim().toLowerCase()) {
        'triangular' => trackConvertDitherTriangular,
        'triangular_hp' => trackConvertDitherTriangularHp,
        _ => trackConvertDitherNone,
      };

  String losslessResamplerOptionLabel(String resampler) =>
      switch (resampler.trim().toLowerCase()) {
        'soxr' => trackConvertResamplerSoxr,
        _ => trackConvertResamplerSwr,
      };
}

String losslessBitDepthLabel(int? bitDepth, {required String originalLabel}) {
  return bitDepth == null ? originalLabel : '$bitDepth-bit';
}

String losslessSampleRateLabel(
  int? sampleRate, {
  required String originalLabel,
}) {
  if (sampleRate == null) return originalLabel;
  final khz = sampleRate / 1000;
  final precision = sampleRate % 1000 == 0 ? 0 : 1;
  return '${khz.toStringAsFixed(precision)} kHz';
}

String losslessQualityLabel(
  LosslessConversionQuality quality, {
  required String originalLabel,
  required String originalQualityLabel,
}) {
  final parts = <String>[];
  if (quality.maxBitDepth != null) {
    parts.add(
      losslessBitDepthLabel(quality.maxBitDepth, originalLabel: originalLabel),
    );
  }
  if (quality.maxSampleRate != null) {
    parts.add(
      losslessSampleRateLabel(
        quality.maxSampleRate,
        originalLabel: originalLabel,
      ),
    );
  }
  return parts.isEmpty ? originalQualityLabel : parts.join(' / ');
}

String convertedAudioQualityLabel({
  required String targetFormat,
  required String bitrate,
  required LosslessConversionLabels labels,
  LosslessConversionQuality losslessQuality = const LosslessConversionQuality(),
  int? actualBitDepth,
  int? actualSampleRate,
}) {
  final upper = targetFormat.toUpperCase();
  if (isLosslessConversionTarget(targetFormat)) {
    if (actualBitDepth != null &&
        actualBitDepth > 0 &&
        actualSampleRate != null &&
        actualSampleRate > 0) {
      return '$upper ${losslessBitDepthLabel(actualBitDepth, originalLabel: labels.original)}/${losslessSampleRateLabel(actualSampleRate, originalLabel: labels.original)}';
    }
    if (losslessQuality.hasCaps) {
      return '$upper ${losslessQualityLabel(losslessQuality, originalLabel: labels.original, originalQualityLabel: labels.originalQuality)}';
    }
    return '$upper ${labels.lossless}';
  }
  return '$upper ${bitrate.trim().toLowerCase()}';
}

String normalizedConvertedAudioFormat(String targetFormat) {
  return targetFormat.trim().toLowerCase();
}

/// Returns the output file extension (with dot) and MIME type for a conversion
/// target format. Used when creating the converted file via SAF so WAV/AIFF and
/// the other formats get the correct extension + MIME.
({String ext, String mime}) convertTargetExtAndMime(String targetFormat) =>
    switch (targetFormat.trim().toLowerCase()) {
      'opus' => (ext: '.opus', mime: 'audio/opus'),
      'alac' || 'aac' => (ext: '.m4a', mime: 'audio/mp4'),
      'flac' => (ext: '.flac', mime: 'audio/flac'),
      'wav' => (ext: '.wav', mime: 'audio/wav'),
      'aiff' || 'aif' => (ext: '.aiff', mime: 'audio/aiff'),
      _ => (ext: '.mp3', mime: 'audio/mpeg'),
    };

String convertedOutputFileName({
  required String originalFileName,
  required String targetFormat,
}) {
  final dotIndex = originalFileName.lastIndexOf('.');
  final baseName = dotIndex > 0
      ? originalFileName.substring(0, dotIndex)
      : originalFileName;
  return '$baseName${convertTargetExtAndMime(targetFormat).ext}';
}

String convertedLibraryItemId(String sourceId, String filePath) {
  var hash = 5381;
  for (final codeUnit in filePath.codeUnits) {
    hash = (((hash << 5) + hash) ^ codeUnit) & 0x7fffffff;
  }
  return '$sourceId:converted:${hash.toRadixString(16)}';
}

int? convertedAudioBitrateKbps({
  required String targetFormat,
  required String bitrate,
}) {
  if (isLosslessConversionTarget(targetFormat)) return null;
  final match = RegExp(r'(\d+)').firstMatch(bitrate);
  return match != null ? int.tryParse(match.group(1)!) : null;
}
