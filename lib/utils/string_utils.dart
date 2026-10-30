String? normalizeOptionalString(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.toLowerCase() == 'null') return null;
  return trimmed;
}

/// Parses the parental-advisory flag from backend/extension payloads, which
/// may arrive as a bool, a 0/1 number, or a "true"/"1" string.
bool? parseExplicitFlag(dynamic value) {
  if (value == null) return null;
  if (value is bool) return value;
  if (value is num) return value == 1;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty || normalized == 'null') return null;
    return normalized == 'true' || normalized == '1';
  }
  return null;
}

final RegExp _windowsAbsolutePathPattern = RegExp(r'^[A-Za-z]:[\\/]');

bool _looksLikeLocalReference(String value) {
  return value.startsWith('/') ||
      value.startsWith('content://') ||
      value.startsWith('file://') ||
      _windowsAbsolutePathPattern.hasMatch(value);
}

String? normalizeCoverReference(String? value) {
  final normalized = normalizeOptionalString(value);
  if (normalized == null) return null;

  if (normalized.startsWith('//')) {
    return 'https:$normalized';
  }

  if (normalized.startsWith('http://') ||
      normalized.startsWith('https://') ||
      _looksLikeLocalReference(normalized)) {
    return normalized;
  }

  return null;
}

/// [normalizeCoverReference] that also keeps a `network://` cover source,
/// for stores whose readers resolve one, such as listening statistics.
String? normalizeStoredCoverReference(String? value) {
  final normalized = normalizeOptionalString(value);
  if (normalized != null && normalized.startsWith('network://')) {
    return normalized;
  }
  return normalizeCoverReference(normalized);
}

String? normalizeRemoteHttpUrl(String? value) {
  final normalized = normalizeCoverReference(value);
  if (normalized == null) return null;
  if (normalized.startsWith('http://') || normalized.startsWith('https://')) {
    return normalized;
  }
  return null;
}

/// Byte count expressed as a plain megabyte number with 1 decimal, e.g. "3.4".
String formatMegabytes(num bytes) {
  return (bytes / (1024 * 1024)).toStringAsFixed(1);
}

/// Human-readable byte size: "512 B", "3.4 KB", "12.0 MB", "1.25 GB".
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// English month abbreviations indexed by `DateTime.month - 1`.
const List<String> shortMonthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "m:ss" clock formatting for track durations.
String formatClock(num seconds) {
  final total = seconds.round();
  final minutes = total ~/ 60;
  final secs = total % 60;
  return '$minutes:${secs.toString().padLeft(2, '0')}';
}

String formatSampleRateKHz(int sampleRate) {
  final khz = sampleRate / 1000;
  final precision = sampleRate % 1000 == 0 ? 0 : 1;
  return '${khz.toStringAsFixed(precision)}kHz';
}

String? buildDisplayAudioQuality({
  int? bitDepth,
  int? sampleRate,
  int? bitrateKbps,
  String? format,
  String? storedQuality,
}) {
  if (bitrateKbps != null && bitrateKbps > 0) {
    final normalizedFormat = normalizeOptionalString(format)?.toUpperCase();
    return normalizedFormat != null
        ? '$normalizedFormat ${bitrateKbps}kbps'
        : '${bitrateKbps}kbps';
  }

  if (bitDepth != null &&
      bitDepth > 0 &&
      sampleRate != null &&
      sampleRate > 0) {
    return '$bitDepth-bit/${formatSampleRateKHz(sampleRate)}';
  }

  return normalizeOptionalString(storedQuality);
}

bool isPlaceholderQualityLabel(String? quality) {
  final normalized = normalizeOptionalString(quality)?.toLowerCase();
  if (normalized == null) return false;

  return const {
    'best',
    'lossless',
    'hi-res',
    'hi-res-max',
    'high',
    'cd',
  }.contains(normalized);
}
