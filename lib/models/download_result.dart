import 'dart:collection';

import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/ffmpeg_models.dart';
import 'package:mornye/utils/audio_format_utils.dart';
import 'package:mornye/utils/download_error_type.dart';
import 'package:mornye/utils/int_utils.dart';

/// Typed access to the download protocol, retaining extension-specific fields.
/// Wraps the original map so metadata helpers and native reconciliation observe
/// the same finalization updates without translating or dropping unknown keys.
class DownloadResult extends MapBase<String, dynamic> {
  factory DownloadResult.fromMap(Map<String, dynamic> values) =>
      values is DownloadResult ? values : DownloadResult._(values);

  DownloadResult._(this._values);
  final Map<String, dynamic> _values;

  bool get success => _values['success'] == true;
  bool get alreadyExists => _values['already_exists'] == true;
  bool get nativeFinalized => _values['native_finalized'] == true;
  bool get deferredSafPublish => _values['saf_deferred_publish'] == true;
  String? get filePath => _values['file_path'] as String?;
  set filePath(String? value) => _values['file_path'] = value;
  String? get fileName => _values['file_name'] as String?;
  set fileName(String? value) => _values['file_name'] = value;
  String? get service => _values['service'] as String?;
  String? get resolvedSafDirectory {
    final directory = _values['saf_relative_dir'];
    return directory is String ? directory : null;
  }

  int? get actualBitDepth => readPositiveInt(_values['actual_bit_depth']);
  int? get actualSampleRate => readPositiveInt(_values['actual_sample_rate']);
  int? get bitrateKbps =>
      readPositiveBitrateKbps(_values['bitrate'] ?? _values['actual_bitrate']);
  String? get audioCodec =>
      (_values['audio_codec'] ?? _values['actual_audio_codec'])?.toString();
  String? get reportedFormat => audioCodec ?? _values['format']?.toString();
  bool get requiresContainerConversion =>
      _values['requires_container_conversion'] == true ||
      _values['requiresContainerConversion'] == true;
  DownloadDecryptionDescriptor? get decryption =>
      DownloadDecryptionDescriptor.fromDownloadResult(this);
  DownloadFailure? get failure => success ? null : DownloadFailure(this);

  void markConvertedAudio({
    required String path,
    required String? name,
    required String format,
    required int? bitrateKbps,
    int? bitDepth,
    int? sampleRate,
  }) {
    filePath = path;
    fileName = name;
    _values['audio_codec'] = format;
    _values['format'] = format;
    _values.remove('actual_bitrate');
    for (final entry in {
      'bitrate': bitrateKbps,
      'actual_bit_depth': bitDepth,
      'actual_sample_rate': sampleRate,
    }.entries) {
      if (entry.value == null) {
        _values.remove(entry.key);
      } else {
        _values[entry.key] = entry.value;
      }
    }
    if (format == 'flac') markFlacContainer();
  }

  void markFlacContainer({String? path, String? name}) {
    if (path != null) filePath = path;
    if (name != null) fileName = name;
    _values['audio_codec'] = 'flac';
    _values['format'] = 'flac';
    _values['actual_container'] = 'flac';
    if (_values.containsKey('container')) _values['container'] = 'flac';
    _values['actual_extension'] = '.flac';
    _values['output_extension'] = '.flac';
    _values['requires_container_conversion'] = false;
    _values.remove('requiresContainerConversion');
  }

  String? outputExtension({String? path}) {
    const extensions = {
      '.flac',
      '.m4a',
      '.mp4',
      '.mp3',
      '.opus',
      '.ogg',
      '.aac',
    };
    for (final key in [
      'actual_extension',
      'output_extension',
      'actual_container',
      'container',
    ]) {
      final value = _values[key]?.toString().trim().toLowerCase();
      if (value == null || value.isEmpty) continue;
      final extension = value.startsWith('.') ? value : '.$value';
      if (extensions.contains(extension)) return extension;
    }
    for (final candidate in [fileName, path, filePath]) {
      if (candidate == null) continue;
      final lower = candidate.trim().toLowerCase();
      for (final extension in extensions) {
        if (lower.endsWith(extension)) return extension;
      }
    }
    // SAF URIs may hide the suffix. Prefer actual codec over requested format.
    return switch (normalizeAudioFormatValue(reportedFormat)) {
      'opus' => '.opus',
      'mp3' => '.mp3',
      'aac' || 'alac' || 'm4a' => '.m4a',
      'flac' => '.flac',
      _ => null,
    };
  }

  @override
  dynamic operator [](Object? key) => _values[key];
  @override
  void operator []=(String key, dynamic value) => _values[key] = value;
  @override
  Iterable<String> get keys => _values.keys;
  @override
  dynamic remove(Object? key) => _values.remove(key);
  @override
  void clear() => _values.clear();
}

class DownloadFailure {
  DownloadFailure(DownloadResult result)
    : message = result['error'] as String? ?? 'Download failed',
      backendType = result['error_type'] as String? ?? 'unknown',
      retryAfterSeconds = readPositiveInt(result['retry_after_seconds']),
      service = result.service;

  final String message;
  final String backendType;
  final int? retryAfterSeconds;
  final String? service;
  bool get cancelled => backendType == 'cancelled';
  DownloadErrorType? get type => downloadErrorTypeFromBackend(backendType);
  String get retryMessage => retryAfterSeconds == null
      ? message
      : '$message retry-after: $retryAfterSeconds';
}
