// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'track_metadata_screen.dart';

extension _TrackMetadataDisplay on _TrackMetadataScreenState {
  bool _isBitrateFormatValue(String? value) {
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

  String? _usableStoredQuality(String? quality) {
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
    return normalized;
  }

  String? _displayQualityForValues({
    required String? format,
    int? bitDepth,
    int? sampleRate,
    int? bitrateKbps,
    String? storedQuality,
  }) {
    final normalizedFormat = normalizeAudioFormatValue(format);
    final formatLabel = normalizedFormat == null
        ? normalizeOptionalString(format)?.toUpperCase()
        : _formatLabelForRaw(normalizedFormat);
    if (_isBitrateFormatValue(normalizedFormat)) {
      return buildDisplayAudioQuality(
            bitrateKbps: bitrateKbps,
            format: formatLabel,
          ) ??
          _usableStoredQuality(storedQuality) ??
          formatLabel;
    }
    return buildDisplayAudioQuality(
      bitDepth: bitDepth,
      sampleRate: sampleRate,
      storedQuality: _usableStoredQuality(storedQuality),
    );
  }

  String _displayServiceTrackId(String value) => displayServiceTrackId(value);

  String _serviceForTrackId(String value, {required String fallbackService}) =>
      serviceForTrackId(value, fallbackService: fallbackService);

  String? get _displayAudioQuality {
    final fileName = _extractFileNameFromPathOrUri(cleanFilePath);
    final fileExt = fileName.contains('.')
        ? fileName.split('.').last.toUpperCase()
        : null;

    return _displayQualityForValues(
      format: _storedAudioFormat ?? fileExt,
      bitDepth: bitDepth,
      sampleRate: sampleRate,
      bitrateKbps: _audioBitrate,
      storedQuality: _quality,
    );
  }

  /// The raw file path, with EXISTS: prefix stripped but #trackNN preserved.
  /// Use this when you need the full virtual path (e.g. for display or DB lookups).
  String get rawFilePath {
    final path = _filePath;
    return path.startsWith('EXISTS:') ? path.substring(7) : path;
  }

  /// The clean file path with both EXISTS: prefix and #trackNN suffix stripped.
  /// Use this for actual filesystem/SAF operations.
  String get cleanFilePath {
    var path = _filePath;
    if (path.startsWith('EXISTS:')) path = path.substring(7);
    if (isCueVirtualPath(path)) path = stripCueTrackSuffix(path);
    return path;
  }

  bool get _isCueVirtualTrack => isCueVirtualPath(rawFilePath);

  String _cueVirtualTrackGuidance(BuildContext context) {
    return 'This CUE track is virtual. Use ${context.l10n.cueSplitButton} first.';
  }

  void _showCueVirtualTrackSnackBar(BuildContext context) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(_cueVirtualTrackGuidance(context))));
  }

  void _showSnackBarMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showLongSnackBarMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 60)),
    );
  }

  String _formatPathForDisplay(String pathOrUri) {
    if (_isLocalItem || !pathOrUri.startsWith('content://')) {
      return formatSafUriForDisplay(pathOrUri);
    }

    final item = _downloadItem!;
    final settings = ref.read(settingsProvider);
    final sameSelectedTree =
        item.downloadTreeUri != null &&
        item.downloadTreeUri!.isNotEmpty &&
        item.downloadTreeUri == settings.downloadTreeUri;
    return buildSafFileDisplayPath(
      pathOrUri: pathOrUri,
      treeUri: item.downloadTreeUri,
      treeDisplayPath: sameSelectedTree ? settings.downloadDirectory : null,
      relativeDir: item.safRelativeDir,
      fileName: item.safFileName,
    );
  }
}
