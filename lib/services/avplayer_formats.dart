import 'dart:async';
import 'dart:io';

import 'package:mornye/services/content_uri_playback_cache.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('AVPlayerFormats');

/// A file type AVPlayer, the iOS and macOS playback engine, cannot always
/// open. [label] names it to the user. [never]: no tested system version
/// opens it, so it plays from a FLAC copy up front; otherwise it gets the
/// copy only after AVPlayer fails, as Ogg Opus plays on iOS 27 while Ogg
/// Vorbis does not. [lossy] copies use 16-bit samples.
typedef AvPlayerFormat = ({String label, bool never, bool lossy});

const _formats = <String, AvPlayerFormat>{
  'ape': (label: 'APE', never: true, lossy: false),
  'wv': (label: 'WavPack', never: true, lossy: false),
  'wavpack': (label: 'WavPack', never: true, lossy: false),
  'dsf': (label: 'DSF', never: true, lossy: false),
  'dff': (label: 'DFF', never: true, lossy: false),
  'dsd': (label: 'DSD', never: true, lossy: false),
  'tta': (label: 'TTA', never: true, lossy: false),
  'tak': (label: 'TAK', never: true, lossy: false),
  'shn': (label: 'Shorten', never: true, lossy: false),
  'shorten': (label: 'Shorten', never: true, lossy: false),
  'mpc': (label: 'Musepack', never: true, lossy: true),
  'musepack': (label: 'Musepack', never: true, lossy: true),
  'musepack7': (label: 'Musepack', never: true, lossy: true),
  'musepack8': (label: 'Musepack', never: true, lossy: true),
  'wma': (label: 'WMA', never: true, lossy: false),
  'asf': (label: 'WMA', never: true, lossy: false),
  'wmav1': (label: 'WMA', never: true, lossy: true),
  'wmav2': (label: 'WMA', never: true, lossy: true),
  'wmapro': (label: 'WMA', never: true, lossy: true),
  'wmalossless': (label: 'WMA Lossless', never: true, lossy: false),
  'mka': (label: 'Matroska', never: true, lossy: false),
  'webm': (label: 'WebM', never: true, lossy: true),
  'dts': (label: 'DTS', never: true, lossy: true),
  'dca': (label: 'DTS', never: true, lossy: true),
  'spx': (label: 'Speex', never: true, lossy: true),
  'speex': (label: 'Speex', never: true, lossy: true),
  'vorbis': (label: 'Ogg Vorbis', never: true, lossy: true),
  'ogg': (label: 'Ogg', never: false, lossy: true),
  'oga': (label: 'Ogg', never: false, lossy: true),
  'opus': (label: 'Opus', never: false, lossy: true),
};

/// The format of a song AVPlayer may not open, from its [codec] (the
/// Library's format) and the extension of its file [name]; null when
/// AVPlayer opens both.
AvPlayerFormat? avPlayerFormat({String? name, String? codec}) {
  var key = codec?.trim().toLowerCase() ?? '';
  // FFmpeg names DSD decoders by bit order, such as dsd_lsbf_planar.
  if (key.startsWith('dsd_')) key = 'dsd';
  final byCodec = _formats[key];
  if (byCodec != null) return byCodec;
  return _formats[fileExtension(name)];
}

/// The lowercase extension of the last path segment of [name], or ''.
String fileExtension(String? name) {
  if (name == null) return '';
  final segment = name.split(RegExp(r'[/\\]')).last;
  final dot = segment.lastIndexOf('.');
  return dot <= 0 ? '' : segment.substring(dot + 1).toLowerCase();
}

/// The sample rate a FLAC copy uses instead of [rate], or null to keep it.
/// DSD decodes at 1/8 of its bit rate (352.8 kHz for DSD64), far above the
/// audible band, so its copy uses 176.4 kHz; others stay at most 384 kHz.
int? avPlayerCopyRate(int? rate, {required bool dsd}) {
  if (dsd) return 176400;
  if (rate == null || rate <= 384000) return null;
  return rate % 44100 == 0 ? 352800 : 384000;
}

/// FFmpeg arguments that copy the first audio stream of [input] to the
/// FLAC file [output]. Tags stay, so normalization reads the copy.
List<String> avPlayerCopyArguments(
  String input,
  String output, {
  AvPlayerFormat? format,
  int? sampleRate,
  bool dsd = false,
}) {
  final rate = avPlayerCopyRate(sampleRate, dsd: dsd);
  return [
    '-v',
    'error',
    '-hide_banner',
    if (const {'http', 'https'}.contains(Uri.tryParse(input)?.scheme)) ...[
      '-rw_timeout',
      '30000000',
    ],
    '-i',
    input,
    '-map',
    '0:a:0',
    '-vn',
    '-sn',
    '-dn',
    '-c:a',
    'flac',
    // The copy is temporary: favor speed over size.
    '-compression_level',
    '0',
    // FFmpeg keeps a decoder's frame length, such as TTA's 50155 samples,
    // and Apple's FLAC decoder rejects blocks that large.
    '-frame_size',
    '4096',
    if (dsd) ...[
      '-sample_fmt',
      's32',
    ] else if (format?.lossy ?? false) ...[
      '-sample_fmt',
      's16',
    ],
    if (rate != null) ...['-ar', '$rate'],
    '-f',
    'flac',
    output,
    '-y',
  ];
}

class _CopyJob {
  _CopyJob(this.input, this.format, this.sampleRate, this.dsd);

  final String input;
  final AvPlayerFormat? format;
  final int? sampleRate;
  final bool dsd;
}

/// FLAC copies of songs AVPlayer cannot open, keyed by song source and
/// bounded like SAF playback copies. Pinned copies (the playing song, a
/// prepared next one) are deleted once released.
class AvPlayerCopies {
  AvPlayerCopies({
    required Future<bool> Function(List<String> arguments) run,
    required bool Function() isDisposed,
    required bool Function(String) isPinned,
    Directory? directory,
    int maxEntries = 3,
    int maxBytes = 1024 * 1024 * 1024,
  }) : _run = run,
       _directory = directory {
    _cache = ContentUriPlaybackCache(
      copy: _copy,
      isDisposed: isDisposed,
      isPinned: isPinned,
      onResolveError: (error) => _log.w('Playback copy failed: $error'),
      onDeleteError: (error) => _log.w('Playback copy not deleted: $error'),
      maxEntries: maxEntries,
      maxBytes: maxBytes,
    );
  }

  final Future<bool> Function(List<String> arguments) _run;
  final Directory? _directory;
  late final ContentUriPlaybackCache _cache;
  final _jobs = <String, _CopyJob>{};
  Future<Directory>? _folder;
  int _counter = 0;

  bool ownsPath(String path) => _cache.ownsPath(path);

  /// Whether a copy was made for the song [source].
  bool has(String source) => _cache.cachedPath(source) != null;

  /// A FLAC copy of [input] for the song [source], or null when FFmpeg
  /// cannot make one.
  Future<String?> resolve(
    String source,
    String input, {
    AvPlayerFormat? format,
    int? sampleRate,
    bool dsd = false,
  }) async {
    await _cache.releaseUnpinned();
    final job = _CopyJob(input, format, sampleRate, dsd);
    _jobs[source] = job;
    try {
      return await _cache.resolve(source);
    } finally {
      if (identical(_jobs[source], job)) _jobs.remove(source);
    }
  }

  Future<void> invalidate(String source) => _cache.invalidate(source);

  Future<void> dispose() => _cache.dispose();

  Future<String?> _copy(String source) async {
    final job = _jobs[source];
    if (job == null) return null;
    final Directory folder;
    try {
      folder = await _prepareFolder();
    } catch (_) {
      _folder = null;
      if (_directory == null) _defaultFolder = null;
      rethrow;
    }
    final output =
        '${folder.path}${Platform.pathSeparator}'
        '${DateTime.now().microsecondsSinceEpoch}-${_counter++}.flac';
    var done = false;
    try {
      done = await _run(
        avPlayerCopyArguments(
          job.input,
          output,
          format: job.format,
          sampleRate: job.sampleRate,
          dsd: job.dsd,
        ),
      );
      if (done && await File(output).exists()) return output;
      done = false;
      return null;
    } finally {
      if (!done) {
        try {
          await File(output).delete();
        } on FileSystemException {
          // FFmpeg may not have created it.
        }
      }
    }
  }

  /// The app's copies folder, emptied once per process.
  static Future<Directory>? _defaultFolder;

  Future<Directory> _prepareFolder() {
    final directory = _directory;
    if (directory != null) return _folder ??= _emptied(directory);
    return _defaultFolder ??= _emptied(
      Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'mornye-playback-copies',
      ),
    );
  }

  /// Copies left by an earlier run are never reused; start empty.
  static Future<Directory> _emptied(Directory folder) async {
    try {
      if (await folder.exists()) await folder.delete(recursive: true);
    } on FileSystemException catch (error) {
      _log.w('Old playback copies not deleted: $error');
    }
    return folder.create(recursive: true);
  }
}
