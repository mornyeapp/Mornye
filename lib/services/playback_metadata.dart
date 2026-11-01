import 'package:audio_service/audio_service.dart';
import 'package:mornye/services/network_metadata_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/int_utils.dart';
import 'package:mornye/utils/string_utils.dart';

/// Bounded display tags. Transport and filesystem fields never belong here.
Map<String, dynamic> playbackDisplayMetadata(Object? value) {
  if (value is! Map) return {};
  const keys = {
    'title',
    'artist',
    'album',
    'album_artist',
    'genre',
    'date',
    'year',
    'release_date',
    'track',
    'disc',
    'track_number',
    'disc_number',
    'label',
    'copyright',
    'composer',
    'isrc',
    'duration',
    'channels',
    'format',
    'bit_depth',
    'sample_rate',
    'bitrate',
    'replaygain_track_gain',
    'replaygain_track_peak',
    'replaygain_album_gain',
    'replaygain_album_peak',
    'lyrics',
  };
  return {
    for (final key in keys)
      if (value[key] case final Object field
          when (field is String &&
                  field.length <= (key == 'lyrics' ? 256 * 1024 : 4096)) ||
              (field is num && field.isFinite) ||
              field is bool)
        key: field,
  };
}

/// Display tags and audio quality carried with a queue item. This is available
/// immediately when tracks change, before a fresh file probe completes.
Map<String, dynamic> playbackAudioMetadataFromMediaItem(MediaItem item) {
  final extras = item.extras;
  if (extras == null || extras.isEmpty) return const {};

  final metadata = playbackDisplayMetadata(extras['displayMetadata']);
  final bitDepth = readPositiveInt(extras['bit_depth']);
  final sampleRate = readPositiveInt(extras['sample_rate']);
  final bitrate = readPositiveInt(extras['bitrate']);
  final format = extras['format']?.toString().trim();
  final explicit = parseExplicitFlag(extras['explicit']);
  if (bitDepth != null) metadata['bit_depth'] = bitDepth;
  if (sampleRate != null) metadata['sample_rate'] = sampleRate;
  if (bitrate != null) metadata['bitrate'] = bitrate;
  if (format != null && format.isNotEmpty) metadata['format'] = format;
  if (explicit != null) metadata['explicit'] = explicit;
  return metadata;
}

/// Combines the immediate queue metadata with the richer file probe while
/// retaining known quality fields when a decoder omits or reports them as 0.
Map<String, dynamic> mergePlaybackFileMetadata(
  Map<String, dynamic> fallback,
  Map<String, dynamic> probed,
) {
  final merged = <String, dynamic>{...fallback, ...probed};
  for (final key in const ['bit_depth', 'sample_rate', 'bitrate']) {
    if (readPositiveInt(probed[key]) == null &&
        readPositiveInt(fallback[key]) != null) {
      merged[key] = fallback[key];
    }
  }
  final probedFormat = probed['format']?.toString().trim();
  final fallbackFormat = fallback['format']?.toString().trim();
  if ((probedFormat == null || probedFormat.isEmpty) &&
      fallbackFormat != null &&
      fallbackFormat.isNotEmpty) {
    merged['format'] = fallbackFormat;
  }
  return merged;
}

typedef PlaybackMetadataReader =
    Future<Map<String, dynamic>> Function(String path);

/// Reads playback metadata with a small bounded retry window for transient
/// cold-start/native bridge failures.
///
/// The native bridge reports some read failures as an `error` field instead
/// of throwing. Treat both forms identically so Now Playing does not cache an
/// empty Lyrics view until the route is reopened. A successful response with
/// no lyrics is still final and is never retried.
Future<Map<String, dynamic>> readPlaybackFileMetadataWithRetry(
  String path, {
  PlaybackMetadataReader? reader,
  List<Duration> retryDelays = const [
    Duration.zero,
    Duration(milliseconds: 250),
    Duration(milliseconds: 750),
  ],
}) async {
  if (reader == null && path.startsWith('network://')) {
    return NetworkMetadataService.instance.read(path);
  }
  final read = reader ?? PlatformBridge.readFileMetadata;
  final delays = retryDelays.isEmpty ? const [Duration.zero] : retryDelays;
  Object? lastError;
  var lastStack = StackTrace.current;

  for (final delay in delays) {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    try {
      final metadata = await read(path);
      final reportedError = metadata['error']?.toString().trim() ?? '';
      if (reportedError.isEmpty) return metadata;
      lastError = StateError(reportedError);
      lastStack = StackTrace.current;
    } catch (error, stack) {
      lastError = error;
      lastStack = stack;
    }
  }

  Error.throwWithStackTrace(
    lastError ?? StateError('Metadata reader returned no result'),
    lastStack,
  );
}
