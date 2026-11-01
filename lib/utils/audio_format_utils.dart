import 'package:mornye/utils/hash_utils.dart';
import 'package:mornye/utils/int_utils.dart';
import 'package:mornye/utils/string_utils.dart';

/// Audio format/quality helpers shared by the download queue and history
/// providers.
Map<String, dynamic> normalizeScannedAudioMetadata(
  Map<String, dynamic> metadata,
) {
  dynamic firstValue(String snakeCase, String camelCase) {
    final snakeValue = metadata[snakeCase];
    return snakeValue ?? metadata[camelCase];
  }

  final normalized = <String, dynamic>{...metadata};
  final metadataFromFilename = metadata['metadataFromFilename'] == true;

  // readAudioMetadata uses the LibraryScanResult contract. Automatic metadata
  // probes use the same snake_case keys as readFileMetadata so callers can use
  // the cheaper SAF file-descriptor path without knowing which backend result
  // shape was returned.
  if (!metadataFromFilename) {
    normalized['title'] = firstValue('title', 'trackName');
    normalized['artist'] = firstValue('artist', 'artistName');
    normalized['album'] = firstValue('album', 'albumName');
  }
  normalized['album_artist'] = firstValue('album_artist', 'albumArtist');
  normalized['date'] = firstValue('date', 'releaseDate');
  normalized['track_number'] = firstValue('track_number', 'trackNumber');
  normalized['total_tracks'] = firstValue('total_tracks', 'totalTracks');
  normalized['disc_number'] = firstValue('disc_number', 'discNumber');
  normalized['total_discs'] = firstValue('total_discs', 'totalDiscs');
  normalized['bit_depth'] = firstValue('bit_depth', 'bitDepth');
  normalized['sample_rate'] = firstValue('sample_rate', 'sampleRate');
  normalized['album_type'] = firstValue('album_type', 'albumType');
  normalized['upc'] = firstValue('upc', 'barcode');
  normalized['comment'] = metadata['comment'];
  normalized['explicit'] = metadata['explicit'];
  normalized['audio_codec'] =
      firstValue('audio_codec', 'audioCodec') ?? metadata['format'];
  return normalized;
}

/// Whether scanned or probed tags carry a usable ReplayGain value. Library scans
/// and readFileMetadata both use the snake_case `replaygain_*` keys; persisted
/// rows round-trip through `hasReplayGain`.
bool metadataHasReplayGain(Map<String, dynamic> metadata) {
  final stored = metadata['hasReplayGain'];
  if (stored == true || stored == 1) return true;
  for (final key in const ['replaygain_track_gain', 'replaygain_album_gain']) {
    final value = metadata[key];
    final gain = double.tryParse(
      (value?.toString() ?? '')
          .replaceFirst(RegExp(r'\s*dB\s*$', caseSensitive: false), '')
          .trim(),
    );
    if (gain != null && gain.isFinite) return true;
  }
  return false;
}

bool replayGainMetadataWasRead(Map<String, dynamic> metadata) =>
    metadata['error'] == null &&
    metadata['metadataFromFilename'] != true &&
    (metadata['audio_codec'] != null ||
        metadata['format'] != null ||
        metadata.containsKey('replaygain_track_gain') ||
        metadata.containsKey('replaygain_album_gain'));

int? readPositiveBitrateKbps(dynamic value) {
  final parsed = readPositiveInt(value);
  if (parsed == null) return null;
  final kbps = parsed >= 10000 ? (parsed / 1000).round() : parsed;
  return kbps >= 16 ? kbps : null;
}

/// Estimates average stream bitrate without decoding audio. Older SAF-backed
/// Library rows can therefore be updated with a cheap size query instead of
/// copying the complete audio file into app cache.
int? estimateAverageBitrateKbps({
  required int? fileSizeBytes,
  required int? durationSeconds,
}) {
  if (fileSizeBytes == null ||
      fileSizeBytes <= 0 ||
      durationSeconds == null ||
      durationSeconds <= 0) {
    return null;
  }
  return readPositiveBitrateKbps(
    (fileSizeBytes * 8 / durationSeconds / 1000).round(),
  );
}

String? audioFormatForPath(String? filePath, {String? fileName}) {
  final candidates = <String>[?filePath, ?fileName];
  for (final candidate in candidates) {
    final lower = candidate.trim().toLowerCase();
    if (lower.endsWith('.flac')) return 'FLAC';
    if (lower.endsWith('.alac')) return 'ALAC';
    if (lower.endsWith('.wav')) return 'WAV';
    if (lower.endsWith('.aiff') || lower.endsWith('.aif')) return 'AIFF';
    if (lower.endsWith('.opus') || lower.endsWith('.ogg')) return 'OPUS';
    if (lower.endsWith('.mp3')) return 'MP3';
    if (lower.endsWith('.aac')) return 'AAC';
    if (lower.endsWith('.m4a') || lower.endsWith('.mp4')) return 'M4A';
  }
  return null;
}

String? nonPlaceholderQuality(String? quality) {
  final normalized = normalizeOptionalString(quality);
  if (normalized == null || isPlaceholderQualityLabel(normalized)) {
    return null;
  }
  final bitrateMatch = RegExp(
    r'\b(\d+)\s*kbps\b',
    caseSensitive: false,
  ).firstMatch(normalized);
  if (bitrateMatch != null) {
    final bitrate = int.tryParse(bitrateMatch.group(1) ?? '');
    if (bitrate != null && bitrate < 16) return null;
  }
  final lower = normalized.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  const requestedLosslessLabels = {
    'hi_res_lossless',
    'hires_lossless',
    'hi_res',
    'hires',
    'flac_best_available',
  };
  if (requestedLosslessLabels.contains(lower)) return null;
  return normalized;
}

String? normalizeAudioFormatValue(String? value) {
  final normalized = normalizeOptionalString(
    value,
  )?.toLowerCase().replaceAll('-', '_');
  return switch (normalized) {
    'flac' => 'flac',
    'alac' => 'alac',
    'wav' || 'wave' => 'wav',
    'aiff' || 'aif' || 'aifc' => 'aiff',
    'aac' || 'mp4a' => 'aac',
    'eac3' || 'ec_3' => 'eac3',
    'ac3' || 'ac_3' => 'ac3',
    'ac4' || 'ac_4' => 'ac4',
    'mp3' => 'mp3',
    'opus' || 'ogg' => 'opus',
    'm4a' || 'mp4' => 'm4a',
    _ => null,
  };
}

/// Chooses the user-facing extension for an audio-only ISO-BMFF container.
/// AC-4 stays `.mp4` because its compatibility repair and passthrough path
/// depend on that container identity; other audio codecs use the conventional
/// `.m4a` extension, including Opus and E-AC-3 streams carried inside MP4.
String isoBmffAudioExtensionForCodec(String? codec) {
  return normalizeAudioFormatValue(codec) == 'ac4' ? '.mp4' : '.m4a';
}

/// Uses the finalized local container after conversion, before publishing to
/// SAF. Provider output fields still describe the original download here.
String finalizedAudioFileName({
  required String fileName,
  required String localPath,
  required String fallbackExtension,
}) {
  final extension =
      RegExp(
        r'\.(flac|m4a|mp4|mp3|opus|ogg|aac|wav|aiff)$',
        caseSensitive: false,
      ).firstMatch(localPath)?.group(0)?.toLowerCase() ??
      fallbackExtension;
  final stem = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
  return '$stem$extension';
}

/// Resolves the actual audio codec reported by native metadata probing, while
/// falling back to the container format when the codec is absent or generic.
///
/// This distinction matters for MP4/M4A files: the same container may hold
/// AAC, ALAC, Dolby, or other codecs.
String? detectedAudioFormatFromMetadata(Map<String, dynamic> metadata) {
  final codec = normalizeAudioFormatValue(metadata['audio_codec']?.toString());
  if (codec != null) return codec;
  return normalizeAudioFormatValue(metadata['format']?.toString());
}

bool isLossyAudioFormat(String? value) {
  return const {
    'aac',
    'eac3',
    'ac3',
    'ac4',
    'mp3',
    'opus',
    'm4a',
  }.contains(normalizeAudioFormatValue(value));
}

/// Whether a reported codec value only identifies the ISO-BMFF container.
/// `m4a`/`mp4` cannot tell callers whether the audio stream is AAC, ALAC,
/// FLAC, or another codec, so an explicit conversion request must probe or
/// attempt conversion instead of classifying it as known-lossy audio.
bool isInconclusiveAudioCodec(String? value) {
  final raw = normalizeOptionalString(value);
  if (raw == null) return true;
  final normalized = raw.toLowerCase().replaceAll('-', '_');
  return normalized == 'm4a' || normalized == 'mp4';
}

bool isLosslessAudioCodec(String? codec) {
  final normalized = codec?.trim().toLowerCase().replaceAll('-', '_') ?? '';
  return normalized.startsWith('pcm_') ||
      const {
        'alac',
        'flac',
        'wavpack',
        'ape',
        'tta',
        'mlp',
        'truehd',
        'shorten',
      }.contains(normalized);
}

/// A generic container needs an explicit conversion request; known lossy
/// audio stays in its native container even when that request is present.
bool shouldAttemptLosslessContainerConversion({
  required bool forceConversion,
  required String? probedCodec,
}) =>
    isLosslessAudioCodec(probedCodec) ||
    (forceConversion && isInconclusiveAudioCodec(probedCodec));

/// Returns a provider-independent quality label suitable for a filename.
///
/// Requested labels such as LOSSLESS and HI_RES are intentionally ignored:
/// they describe provider intent, not the audio that was actually written.
String? buildQualityVariantFilenameLabel({
  String? detectedFormat,
  int? bitDepth,
  int? sampleRate,
  int? bitrateKbps,
  String? measuredQuality,
}) {
  if (isLossyAudioFormat(detectedFormat)) {
    final effectiveBitrate =
        bitrateKbps ?? _bitrateFromQuality(measuredQuality);
    return effectiveBitrate != null && effectiveBitrate >= 16
        ? '${effectiveBitrate}kbps'
        : null;
  }

  final measured = _losslessSpecsFromQuality(measuredQuality);
  final effectiveBitDepth = bitDepth ?? measured?.$1;
  final effectiveSampleRate = sampleRate ?? measured?.$2;
  if (effectiveBitDepth == null ||
      effectiveBitDepth <= 0 ||
      effectiveSampleRate == null ||
      effectiveSampleRate <= 0) {
    return null;
  }
  return '${effectiveBitDepth}bit-${formatSampleRateKHz(effectiveSampleRate)}';
}

int? _bitrateFromQuality(String? quality) {
  final match = RegExp(
    r'\b(\d+)\s*kbps\b',
    caseSensitive: false,
  ).firstMatch(quality ?? '');
  final value = int.tryParse(match?.group(1) ?? '');
  return value != null && value >= 16 ? value : null;
}

(int, int)? _losslessSpecsFromQuality(String? quality) {
  final match = RegExp(
    r'\b(\d+)\s*(?:-|\s)?bit\s*[/_-]\s*(\d+(?:\.\d+)?)\s*k?hz\b',
    caseSensitive: false,
  ).firstMatch(quality ?? '');
  final bitDepth = int.tryParse(match?.group(1) ?? '');
  final rate = double.tryParse(match?.group(2) ?? '');
  if (bitDepth == null || bitDepth <= 0 || rate == null || rate <= 0) {
    return null;
  }
  final sampleRate = rate < 1000 ? (rate * 1000).round() : rate.round();
  return (bitDepth, sampleRate);
}

String qualityVariantStagingLabel(String itemId) {
  final hash = fnv1a32(itemId.codeUnits);
  return 'qv_${hash.toRadixString(16).padLeft(8, '0')}';
}

String applyQualityVariantFilenameLabel({
  required String fileName,
  required String stagingLabel,
  required String qualityLabel,
}) {
  if (stagingLabel.isNotEmpty && fileName.contains(stagingLabel)) {
    return fileName.replaceAll(stagingLabel, qualityLabel);
  }
  if (fileName.contains(qualityLabel)) {
    return fileName;
  }
  final dotIndex = fileName.lastIndexOf('.');
  final hasExtension = dotIndex > 0;
  final stem = hasExtension ? fileName.substring(0, dotIndex) : fileName;
  final extension = hasExtension ? fileName.substring(dotIndex) : '';
  return '$stem - $qualityLabel$extension';
}

String removeQualityVariantStagingLabel({
  required String fileName,
  required String stagingLabel,
}) {
  if (stagingLabel.isEmpty || !fileName.contains(stagingLabel)) {
    return fileName;
  }
  final dotIndex = fileName.lastIndexOf('.');
  final hasExtension = dotIndex > 0;
  final stem = hasExtension ? fileName.substring(0, dotIndex) : fileName;
  final extension = hasExtension ? fileName.substring(dotIndex) : '';
  final cleanedStem = stem
      .replaceAll(stagingLabel, '')
      .replaceFirst(RegExp(r'[\s_-]+$'), '')
      .trim();
  return '${cleanedStem.isEmpty ? 'track' : cleanedStem}$extension';
}

String resolveQualityVariantFilename({
  required String fileName,
  required String stagingLabel,
  required String qualityLabel,
  required bool collisionOnly,
  required bool cleanNameExists,
}) {
  if (!collisionOnly || cleanNameExists) {
    return applyQualityVariantFilenameLabel(
      fileName: fileName,
      stagingLabel: stagingLabel,
      qualityLabel: qualityLabel,
    );
  }
  return removeQualityVariantStagingLabel(
    fileName: fileName,
    stagingLabel: stagingLabel,
  );
}

String metadataFormatForLossyFormat(String format) {
  return format == 'aac' ? 'm4a' : format;
}

String displayFormatForLossyFormat(String format) {
  return format == 'aac' ? 'AAC' : format.toUpperCase();
}

const List<String> autoConvertFormats = ['mp3', 'aac', 'opus', 'flac'];
const List<String> autoConvertBitrates = [
  '128k',
  '160k',
  '192k',
  '256k',
  '320k',
];

String normalizeAutoConvertFormat(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized == 'm4a') return 'aac';
  return autoConvertFormats.contains(normalized) ? normalized : 'mp3';
}

String normalizeAutoConvertBitrate(String value) {
  final match = RegExp(r'(\d+)').firstMatch(value);
  final normalized = match == null ? '' : '${match.group(1)}k';
  return autoConvertBitrates.contains(normalized) ? normalized : '320k';
}

int autoConvertBitrateKbps(String value) {
  return int.parse(normalizeAutoConvertBitrate(value).replaceAll('k', ''));
}

String autoConvertFormatLabel(String format) {
  return switch (normalizeAutoConvertFormat(format)) {
    'aac' => 'M4A (AAC)',
    'opus' => 'Opus',
    'flac' => 'FLAC',
    _ => 'MP3',
  };
}

bool autoConversionAlreadySatisfied({
  required String? filePath,
  String? fileName,
  required String targetFormat,
  required String targetBitrate,
  String? quality,
  int? bitrateKbps,
  int? bitDepth,
  int? sampleRate,
  int? maxBitDepth,
  int? maxSampleRate,
}) {
  final sourceFormat = audioFormatForPath(filePath, fileName: fileName);
  final normalizedTarget = normalizeAutoConvertFormat(targetFormat);
  if (normalizedTarget == 'flac') {
    return sourceFormat == 'FLAC' &&
        (maxBitDepth == null ||
            (bitDepth != null && bitDepth > 0 && bitDepth <= maxBitDepth)) &&
        (maxSampleRate == null ||
            (sampleRate != null &&
                sampleRate > 0 &&
                sampleRate <= maxSampleRate));
  }
  final matchesFormat = switch (normalizedTarget) {
    'aac' => sourceFormat == 'AAC' || sourceFormat == 'M4A',
    'opus' => sourceFormat == 'OPUS',
    _ => sourceFormat == 'MP3',
  };
  if (!matchesFormat) return false;

  final targetKbps = autoConvertBitrateKbps(targetBitrate);
  if (bitrateKbps != null && bitrateKbps > 0) {
    return bitrateKbps == targetKbps;
  }
  return RegExp(
    '\\b$targetKbps\\s*kbps\\b',
    caseSensitive: false,
  ).hasMatch(quality ?? '');
}

String? resolveDisplayQuality({
  required String? filePath,
  String? fileName,
  String? detectedFormat,
  int? bitDepth,
  int? sampleRate,
  int? bitrateKbps,
  String? storedQuality,
}) {
  final format =
      displayFormatForCodec(detectedFormat) ??
      audioFormatForPath(filePath, fileName: fileName);
  if (format == 'OPUS' ||
      format == 'MP3' ||
      format == 'AAC' ||
      format == 'EAC3' ||
      format == 'AC3' ||
      format == 'AC4' ||
      (format == 'M4A' && (bitDepth == null || bitDepth <= 0))) {
    return buildDisplayAudioQuality(bitrateKbps: bitrateKbps, format: format) ??
        nonPlaceholderQuality(storedQuality) ??
        format;
  }
  return buildDisplayAudioQuality(
    bitDepth: bitDepth,
    sampleRate: sampleRate,
    storedQuality: nonPlaceholderQuality(storedQuality) ?? storedQuality,
  );
}

String? displayFormatForCodec(String? value) {
  final normalized = normalizeOptionalString(
    value,
  )?.toLowerCase().replaceAll('-', '_');
  return switch (normalized) {
    'flac' => 'FLAC',
    'alac' => 'ALAC',
    'aac' || 'mp4a' => 'AAC',
    'eac3' || 'ec_3' => 'EAC3',
    'ac3' || 'ac_3' => 'AC3',
    'ac4' || 'ac_4' => 'AC4',
    'mp3' => 'MP3',
    'opus' => 'OPUS',
    _ => null,
  };
}
