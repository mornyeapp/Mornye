part of 'music_player_service.dart';

/// Songs AVPlayer, the iOS and macOS engine, cannot open. A format it never
/// opens plays from a FLAC copy FFmpeg makes; another song gets the copy
/// after AVPlayer fails on it. A song that still fails names its format and
/// gives way to the next one, for up to [_skipLimit] songs in a row and one
/// pass over the queue.
class _MusicFormats {
  _MusicFormats(this.handler)
    : _copies = AvPlayerCopies(
        run: handler._dependencies.convertAudio,
        isDisposed: () => handler._disposed,
        directory: handler._dependencies.playbackCopies,
        isPinned: (path) =>
            path == handler._activeResolvedPath ||
            handler._autoMix.pinnedPaths.contains(path) ||
            handler._gapless.pinnedPaths.contains(path),
      );

  static const _skipLimit = 10;

  final MusicPlayerHandler handler;
  final AvPlayerCopies _copies;

  bool owns(String? path) => path != null && _copies.ownsPath(path);

  /// AVPlayer plays the main and prepared decks: not a cast device, nor
  /// macOS exclusive output, which libmpv plays.
  bool get _avPlayer =>
      (handler._dependencies.isIOS || handler._dependencies.isMacOS) &&
      playbackEngine == PlaybackEngine.audioplayers &&
      !handler._cast.active &&
      !playbackExclusiveOutput.value;

  static AvPlayerFormat? _format(PlayableMedia media) =>
      avPlayerFormat(name: media.source, codec: media.format) ??
      (MusicPlayerHandler._requiresDsd(media)
          ? avPlayerFormat(codec: 'dsd')
          : null);

  static bool _isUrl(String path) =>
      const {'http', 'https'}.contains(Uri.tryParse(path)?.scheme);

  /// What plays for [media]: a FLAC copy of a format AVPlayer never opens,
  /// or of a song it failed to open before, else its resolved source.
  Future<String?> resolve(PlayableMedia media) async {
    final path = await handler._resolveSource(media);
    if (path == null || !_avPlayer) return path;
    final format = _format(media);
    if (!(format?.never ?? false) && !_copies.has(media.source)) return path;
    return await _copy(media, path, format) ?? path;
  }

  /// A FLAC copy to try after AVPlayer could not open [path] for [media]:
  /// a local file, or a stream of a format some system versions open.
  /// Null when there is none to try.
  Future<String?> afterFailure(PlayableMedia media, String path) async {
    if (!_avPlayer || owns(path)) return null;
    final format = _format(media);
    // A format AVPlayer never opens already had its copy attempt.
    if (format != null && format.never) return null;
    if (_isUrl(path) ? format == null : !await fileExists(path)) return null;
    return _copy(media, path, format);
  }

  Future<String?> _copy(
    PlayableMedia media,
    String path,
    AvPlayerFormat? format,
  ) async {
    final copy = await _copies.resolve(
      media.source,
      path,
      format: format,
      sampleRate: media.sampleRate,
      dsd: MusicPlayerHandler._requiresDsd(media),
    );
    if (copy != null) {
      _log.i('Playing ${format?.label ?? 'a song'} from a FLAC copy');
    }
    return copy;
  }

  Future<void> invalidate(String source) => _copies.invalidate(source);

  /// Reports that AVPlayer could not play the current [media], resolved to
  /// [path], by its format, and plays the next song in its place unless it
  /// is the last, repeats alone, starts paused or ends a run of failures.
  /// False leaves the failure to the caller to report.
  Future<bool> skipUnplayable(
    PlayableMedia media,
    String? path,
    int generation, {
    required bool startPaused,
  }) async {
    if (!_avPlayer || path == null) return false;
    final format = _format(media);
    // A missing file, or a stream of a format AVPlayer opens, failed for
    // another reason.
    if (_isUrl(path) ? format == null : !await fileExists(path)) return false;
    if (!handler._isCurrentPlayRequest(generation, media)) return true;
    final extension = fileExtension(media.source).toUpperCase();
    final codec = media.format?.trim().toUpperCase() ?? '';
    final label =
        format?.label ??
        (codec.isNotEmpty ? codec : (extension.isNotEmpty ? extension : null));
    if (label == null) return false;
    final skip = handler._failures.canSkip(
      generation,
      startPaused: startPaused,
      limit: _skipLimit,
    );
    handler._runtime.notifyUnplayableSong(label, skipped: skip);
    _log.w('AVPlayer cannot play ${media.title} ($label)');
    if (!skip) return false;
    handler._failures.playNext();
    return true;
  }

  Future<void> dispose() => _copies.dispose();
}
