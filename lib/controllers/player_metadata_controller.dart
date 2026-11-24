import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:mornye/services/lyrics_sidecar.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/playback_metadata.dart';
import 'package:mornye/services/player_lyrics_persistence.dart';
import 'package:mornye/services/saf_siblings.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/utils/int_utils.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/lyrics_draft.dart';
import 'package:mornye/utils/lyrics_metadata_helper.dart';
import 'package:mornye/utils/lyrics_parser.dart';

final _log = AppLogger('PlayerMetadata');

/// Returns LRC text from the configured lyrics providers, or empty.
typedef OnlineLyricsFetcher = Future<String> Function(MediaItem item);
typedef OnlineLyricsSaver = Future<void> Function(String source, String lyrics);

enum LyricsSaveTarget {
  /// Tags in the song's own LRC lyrics, or in its `.lrc` file when those are
  /// the lyrics shown.
  songFile,

  /// The `.mlrc` file next to the song.
  sidecar,
}

/// Neither the song's lyrics nor a `.mlrc` file next to it can take the
/// translations: TTML or plain lyrics of a song without a writable folder.
class LyricsSaveUnsupported implements Exception {
  const LyricsSaveUnsupported();

  @override
  String toString() => 'These lyrics cannot be saved for this song';
}

/// One editor's original track, writable source and draft input. The playing
/// controller may advance while a permission check or the editor is open.
@immutable
class PlayerLyricsEdit {
  const PlayerLyricsEdit._(
    this.item,
    this.source,
    this.rawLyrics, {
    required this.inLrcFile,
  });

  final MediaItem item;
  final String source;
  final String rawLyrics;

  /// The lyrics come from the `.lrc` file next to the song, which saving
  /// rewrites instead of the song's own file.
  final bool inLrcFile;
}

Future<String> _fetchOnlineLyrics(MediaItem item) async {
  final result = await PlatformBridge.getLyricsLRCWithSource(
    '',
    item.title,
    item.artist ?? '',
    durationMs: item.duration?.inMilliseconds ?? 0,
  ).timeout(const Duration(seconds: 30));
  return result['lyrics']?.toString() ?? '';
}

/// Owns file metadata and lyrics for the full player. Requests are scoped to
/// the current queue item so a late probe cannot replace another track's data.
class PlayerMetadataController extends ChangeNotifier {
  PlayerMetadataController({
    PlaybackMetadataReader? readMetadata,
    Future<ParsedLyrics> Function(String?)? parseLyrics,
    OnlineLyricsFetcher? fetchOnlineLyrics,
    OnlineLyricsSaver? saveOnlineLyrics,
    SourceMetadataEvents? metadataEvents,
    LyricsSidecarStore? sidecar,
    LyricsSidecarStore? lrcFile,
  }) : _readMetadata = readMetadata ?? readPlaybackFileMetadataWithRetry,
       _parseLyrics = parseLyrics ?? LyricsParser.parseAsyncNative,
       _fetchOnline = fetchOnlineLyrics ?? _fetchOnlineLyrics,
       _saveOnline = saveOnlineLyrics ?? persistPlayerLyrics,
       _metadataEvents = metadataEvents ?? SourceMetadataEvents.instance,
       _sidecar = sidecar ?? const LyricsSidecarStore(),
       _lrcFile = lrcFile ?? const LyricsSidecarStore(extension: lrcExtension) {
    _unsubscribeMetadata = _metadataEvents.subscribe((changed) async {
      if (_disposed ||
          changed != source ||
          _savingLyricsSources.contains(changed)) {
        return;
      }
      // A tag change can come with new sidecars beside the song.
      SafSiblings.instance.forget(changed);
      final item = _item;
      // Read again what was read before: a copy is probed on every load, an
      // unresolved document only when something asked for its tags.
      final readFile =
          _loadedPath != null ||
          _probePending ||
          _metadataPath(changed, _requestKey?.$3) != changed;
      _requestKey = null;
      if (item == null || !changed.startsWith('content://')) {
        await load(item);
        return;
      }
      // A document's playback copy keeps the tags it was made with, so the
      // changed document itself is read again rather than that copy.
      await load(
        item.copyWith(extras: {...?item.extras, 'resolvedSource': null}),
        inspectUnresolvedContentUri: readFile,
      );
    });
  }

  late final void Function() _unsubscribeMetadata;

  final PlaybackMetadataReader _readMetadata;
  final Future<ParsedLyrics> Function(String?) _parseLyrics;
  final OnlineLyricsFetcher _fetchOnline;
  final OnlineLyricsSaver _saveOnline;
  final SourceMetadataEvents _metadataEvents;
  final LyricsSidecarStore _sidecar;

  /// The `.lrc` file next to the song, read when its own file has no lyrics.
  final LyricsSidecarStore _lrcFile;
  final _savingLyricsSources = <String>{};

  /// The song's `.mlrc` lyrics, laid over [_fileLyrics] for [lyrics].
  ParsedLyrics? _saved;

  /// The song's `.lrc` lyrics, read because its own file has none.
  String? _lrcFileLyrics;

  /// The lyrics the song's own file holds, or else its `.lrc` file, as parsed
  /// from [_lyricsRaw].
  ParsedLyrics _fileLyrics = ParsedLyrics.empty;
  MediaItem? _item;
  bool _searchingOnline = false;
  bool _onlineSearchMissed = false;
  bool _onlineLyricsSaveFailed = false;
  (String, String, String?)? _requestKey;
  String? _loadedPath;
  Map<String, dynamic> _fallback = const {};
  int _generation = 0;
  int _metadataRevision = 0;
  String _lyricsRaw = '';
  bool _probePending = false;
  bool _disposed = false;

  String? get source => _requestKey?.$2;

  /// The queue item whose file this controller reads, or null for an item
  /// without one.
  MediaItem? get item => _item;

  /// The lyrics as stored: LRC, TTML or plain text, empty when none.
  String get rawLyrics => _lyricsRaw;

  /// The path the current metadata was probed from: the resolved copy of a
  /// document, or the source itself.
  String? get filePath => _loadedPath;
  Map<String, dynamic>? _metadata;
  ParsedLyrics _lyrics = ParsedLyrics.empty;
  bool _loading = false;
  Map<String, dynamic>? get metadata => _metadata;
  ParsedLyrics get lyrics => _lyrics;
  bool get loading => _loading;
  bool get searchingOnline => _searchingOnline;

  bool get onlineSearchMissed => _onlineSearchMissed;
  bool get onlineLyricsSaveFailed => _onlineLyricsSaveFailed;

  bool get canSearchOnline =>
      (_item?.title.trim().isNotEmpty ?? false) &&
      (_item?.artist?.trim().isNotEmpty ?? false);

  /// Displays fetched lyrics and embeds them in the original audio file.
  Future<void> searchOnline() async {
    final item = _item;
    if (_disposed ||
        item == null ||
        _searchingOnline ||
        _savingLyricsSources.contains(this.source) ||
        !canSearchOnline) {
      return;
    }
    final generation = _generation;
    final source = this.source!;
    _searchingOnline = true;
    _onlineSearchMissed = false;
    _onlineLyricsSaveFailed = false;
    notifyListeners();
    var parsed = ParsedLyrics.empty;
    var raw = '';
    try {
      raw = await _fetchOnline(item);
      if (_disposed || generation != _generation) return;
      if (raw.trim().isNotEmpty) parsed = await _parseLyrics(raw);
    } catch (error) {
      _log.w('Failed to search lyrics online: $error');
    }
    if (_disposed || generation != _generation) return;
    _searchingOnline = false;
    if (parsed.isEmpty) {
      _onlineSearchMissed = true;
    } else {
      _setFileLyrics(parsed, raw);
    }
    notifyListeners();
    if (parsed.isEmpty) return;

    _savingLyricsSources.add(source);
    try {
      await _saveOnline(source, raw);
      await _metadataEvents.publish(source);
      if (_disposed || generation != _generation) return;
      _metadata = Map.unmodifiable({...?_metadata, 'lyrics': raw});
      _setFileLyrics(parsed, raw);
    } catch (error) {
      _log.w('Could not embed online lyrics: $error');
      if (_disposed || generation != _generation) return;
      _onlineLyricsSaveFailed = true;
    } finally {
      _savingLyricsSources.remove(source);
    }
    if (!_disposed && generation == _generation) notifyListeners();
  }

  PlayerLyricsEdit? beginLyricsEdit() {
    final item = _item;
    final source = this.source;
    if (_disposed || _loading || item == null || source == null) return null;
    return PlayerLyricsEdit._(
      item,
      source,
      _lyricsRaw,
      inLrcFile: _lyricsInLrcFile,
    );
  }

  bool get _lyricsInLrcFile =>
      _lrcFileLyrics != null && _lyricsRaw == _lrcFileLyrics;

  /// Writes [raw] where the shown lyrics came from: the `.lrc` file next to
  /// the song, or the song's own file.
  Future<void> _saveSongLyrics(
    String source,
    String raw, {
    required bool inLrcFile,
  }) => inLrcFile ? _lrcFile.write(source, raw) : _saveOnline(source, raw);

  bool isCurrentLyricsEdit(PlayerLyricsEdit edit) =>
      !_disposed && _item?.id == edit.item.id && source == edit.source;

  /// Writes to the file captured when editing began, even if playback moved
  /// or stopped. Only updates the player when it still shows that same track.
  Future<void> saveEditedLyrics(
    String raw, {
    required PlayerLyricsEdit edit,
  }) async {
    if (_disposed) throw StateError('The lyrics editor is closed');
    final source = edit.source;
    final editingCurrentTrack = isCurrentLyricsEdit(edit);
    final generation = _generation;
    final parsed = raw.trim().isEmpty
        ? ParsedLyrics.empty
        : await _parseLyrics(raw);
    // A document plays from a copy, so reloading after the save would read
    // the old lyrics back; show what was written instead.
    _savingLyricsSources.add(source);
    try {
      await _saveSongLyrics(source, raw, inLrcFile: edit.inLrcFile);
      await _metadataEvents.publish(source);
    } finally {
      _savingLyricsSources.remove(source);
    }
    if (_disposed ||
        !editingCurrentTrack ||
        generation != _generation ||
        !isCurrentLyricsEdit(edit)) {
      return;
    }
    _metadata = Map.unmodifiable({...?_metadata, 'lyrics': raw});
    if (edit.inLrcFile) _lrcFileLyrics = raw;
    _setFileLyrics(parsed, raw);
    _onlineSearchMissed = false;
    _onlineLyricsSaveFailed = false;
    notifyListeners();
  }

  void _setFileLyrics(ParsedLyrics parsed, String raw) {
    _fileLyrics = parsed;
    _lyricsRaw = raw;
    _lyrics = mergeSavedLyrics(parsed, _saved);
  }

  /// Whether translations shown over these lyrics can be saved: into the
  /// song's own synced LRC lyrics, or a `.mlrc` file next to it.
  bool get canSaveTranslations {
    final source = this.source;
    if (_disposed || _loading || _item == null || source == null) return false;
    if (source.isEmpty ||
        const {'http', 'https'}.contains(Uri.tryParse(source)?.scheme)) {
      return false;
    }
    return _sidecar.canWrite(source) || _songFileTakesTranslations;
  }

  bool get _songFileTakesTranslations =>
      _fileLyrics.synced &&
      _lyricsRaw.trim().isNotEmpty &&
      LyricsDraft.canEdit(_lyricsRaw);

  /// Saves the translations and pronunciations [shown], these lyrics as the
  /// player displays them, adds. They go into the song's own LRC lyrics, or
  /// the `.lrc` file the shown lyrics come from, unless [preferSidecar] is
  /// set or those cannot carry them (TTML, lyrics without timing, none at
  /// all); then into a `.mlrc` file next to the song. An existing `.mlrc`
  /// file is kept in step with the song's file.
  /// Throws [LyricsSaveUnsupported] when neither can be written.
  Future<LyricsSaveTarget> saveShownLyrics(
    ParsedLyrics shown, {
    required bool preferSidecar,
  }) async {
    final source = this.source;
    if (_disposed || _item == null || source == null || source.isEmpty) {
      throw StateError('There is no song to save lyrics to');
    }
    final generation = _generation;
    final raw = _lyricsRaw;
    final inLrcFile = _lyricsInLrcFile;
    final embedded = _songFileTakesTranslations
        ? lyricsWithTranslations(raw, shown)
        : null;
    final sidecarWritable = _sidecar.canWrite(source);
    final LyricsSaveTarget target;
    if ((preferSidecar || embedded == null) && sidecarWritable) {
      target = LyricsSaveTarget.sidecar;
    } else if (embedded != null) {
      target = LyricsSaveTarget.songFile;
    } else {
      throw const LyricsSaveUnsupported();
    }
    _savingLyricsSources.add(source);
    try {
      String? mlrc;
      if (target == LyricsSaveTarget.songFile) {
        await _saveSongLyrics(source, embedded!, inLrcFile: inLrcFile);
        // An older .mlrc file would bring back what the song now replaces.
        if (_saved != null && sidecarWritable) {
          mlrc = buildMlrc(raw: embedded, shown: shown);
          await _sidecar.write(source, mlrc);
        }
      } else {
        mlrc = buildMlrc(raw: raw, shown: shown);
        await _sidecar.write(source, mlrc);
      }
      await _metadataEvents.publish(source);
      if (_disposed || generation != _generation || this.source != source) {
        return target;
      }
      final file = target == LyricsSaveTarget.songFile
          ? await _parseLyrics(embedded!)
          : _fileLyrics;
      final saved = mlrc == null ? _saved : await readMlrc(mlrc, _parseLyrics);
      if (_disposed || generation != _generation || this.source != source) {
        return target;
      }
      _saved = saved;
      if (target == LyricsSaveTarget.songFile) {
        _metadata = Map.unmodifiable({...?_metadata, 'lyrics': embedded});
        if (inLrcFile) _lrcFileLyrics = embedded;
        _setFileLyrics(file, embedded!);
      } else {
        _lyrics = mergeSavedLyrics(_fileLyrics, saved);
      }
      notifyListeners();
      return target;
    } finally {
      _savingLyricsSources.remove(source);
    }
  }

  /// The song's `.mlrc` lyrics, or null when it has none or they cannot be
  /// read.
  Future<ParsedLyrics?> _readSaved(String source) async {
    try {
      final raw = await _sidecar.read(source);
      if (raw == null || raw.trim().isEmpty) return null;
      final saved = await readMlrc(raw, _parseLyrics);
      return saved.isEmpty ? null : saved;
    } catch (error) {
      _log.w('Could not read the .mlrc lyrics: $error');
      return null;
    }
  }

  /// Reads deferred file tags when opening technical details. Already loaded
  /// metadata, including online lyrics, stays cached for the current item.
  Future<void> ensureFileMetadata() async {
    if (_disposed || _item == null || _loadedPath != null) return;
    await load(_item, inspectUnresolvedContentUri: true);
  }

  Future<void> load(
    MediaItem? item, {
    bool inspectUnresolvedContentUri = false,
  }) async {
    if (_disposed) return;
    final source = item?.extras?['source']?.toString() ?? '';
    if (item != null &&
        source.isEmpty &&
        item.extras?['displayMetadata'] is Map) {
      _generation++;
      _probePending = false;
      _resetOnlineSearch();
      _item = null;
      _requestKey = (item.id, source, null);
      _loadedPath = null;
      _fallback = Map.unmodifiable(playbackAudioMetadataFromMediaItem(item));
      final pending = _replaceMetadata(_fallback);
      if (pending != null) await pending;
      return;
    }
    if (item == null || source.isEmpty) {
      _item = null;
      if (_requestKey == null) return;
      _generation++;
      _probePending = false;
      _resetOnlineSearch();
      _requestKey = null;
      _loadedPath = null;
      final pending = _replaceMetadata(const {});
      if (pending != null) await pending;
      return;
    }
    final resolvedSource = item.extras?['resolvedSource']?.toString().trim();
    final key = (item.id, source, resolvedSource);
    final sameItem = key == _requestKey;
    _item = item;
    _fallback = Map.unmodifiable(playbackAudioMetadataFromMediaItem(item));
    if (!sameItem) {
      _generation++;
      _probePending = false;
      _resetOnlineSearch();
      _requestKey = key;
      _loadedPath = null;
      _saved = null;
      _lrcFileLyrics = null;
    }
    if (const {'http', 'https'}.contains(Uri.tryParse(source)?.scheme)) {
      _loadedPath = source;
      final pending = _replaceMetadata(_fallback);
      if (pending != null) await pending;
      return;
    }
    final path = _metadataPath(source, resolvedSource);
    final unresolved = path == source && source.startsWith('content://');
    if (sameItem) {
      if (metadata == null && _fallback.isNotEmpty) {
        _metadata = _fallback;
        notifyListeners();
      }
      if (loading || _loadedPath == path) return;
    } else {
      final pending = _replaceMetadata(_fallback);
      // A fallback parse must never postpone the file probe. Its revision
      // guard discards it as soon as richer metadata supersedes it.
      if (pending != null) unawaited(pending);
    }
    // Opening the player must not copy an unresolved SAF document. Lyrics
    // requests may inspect it until playback publishes its resolved source.
    if (unresolved && !inspectUnresolvedContentUri) return;
    _probePending = true;
    _loading = true;
    notifyListeners();
    final generation = _generation;
    // The .mlrc file sits next to the song itself, not a resolved copy. It
    // never holds up the song's own lyrics.
    unawaited(_loadSaved(source, generation));
    var probed = false;
    Map<String, dynamic> fileMetadata;
    try {
      final read = await _readMetadata(path);
      if (_disposed || generation != _generation) return;
      fileMetadata = mergePlaybackFileMetadata(_fallback, read);
      probed = true;
    } catch (error) {
      if (_disposed || generation != _generation) return;
      _log.w('Failed to read metadata: $error');
      fileMetadata = _fallback;
    }
    // A song without lyrics of its own shows the .lrc file next to it, read
    // beside the song itself rather than a resolved copy.
    final ownLyrics = fileMetadata['lyrics']?.toString() ?? '';
    final lrc = hasUsableLyricsContent(ownLyrics)
        ? null
        : await _readLrcFile(source);
    if (_disposed || generation != _generation) return;
    _probePending = false;
    if (probed) _loadedPath = path;
    _lrcFileLyrics = lrc;
    final pending = _replaceMetadata(
      lrc == null ? fileMetadata : {...fileMetadata, 'lyrics': lrc},
    );
    if (pending != null) await pending;
  }

  /// The `.lrc` file's lyrics, or null when the song has no such file, it
  /// holds no lyrics, or it cannot be read.
  Future<String?> _readLrcFile(String source) async {
    try {
      final raw = await _lrcFile.read(source);
      return raw != null && hasUsableLyricsContent(raw) ? raw : null;
    } catch (error) {
      _log.w('Could not read the .lrc lyrics: $error');
      return null;
    }
  }

  /// Lays the song's `.mlrc` lyrics over its own once they are read. While
  /// the song's lyrics still load, publishing them applies these.
  Future<void> _loadSaved(String source, int generation) async {
    final saved = await _readSaved(source);
    if (_disposed || generation != _generation || saved == null) return;
    _saved = saved;
    if (_loading) return;
    _lyrics = mergeSavedLyrics(_fileLyrics, saved);
    notifyListeners();
  }

  Future<void>? _replaceMetadata(Map<String, dynamic> value) {
    final revision = ++_metadataRevision;
    final raw = (value['lyrics'] ?? '').toString();
    // Empty fallback metadata stays synchronous, so file probes start at the
    // same point and changing tracks clears the previous lyrics immediately.
    if (raw.isEmpty) {
      _publishMetadata(value, ParsedLyrics.empty);
      return null;
    }
    _metadata = value.isEmpty ? null : Map.unmodifiable(value);
    if (raw != _lyricsRaw) _lyrics = ParsedLyrics.empty;
    _loading = true;
    notifyListeners();
    return _parseAndReplaceMetadata(value, raw, _generation, revision);
  }

  Future<void> _parseAndReplaceMetadata(
    Map<String, dynamic> value,
    String raw,
    int generation,
    int revision,
  ) async {
    try {
      final parsed = await _parseLyrics(raw);
      if (_disposed ||
          generation != _generation ||
          revision != _metadataRevision) {
        return;
      }
      _publishMetadata(value, parsed, raw: raw);
    } catch (error) {
      if (_disposed ||
          generation != _generation ||
          revision != _metadataRevision) {
        return;
      }
      _log.w('Failed to parse lyrics: $error');
      _publishMetadata(value, ParsedLyrics.empty);
    }
  }

  void _publishMetadata(
    Map<String, dynamic> value,
    ParsedLyrics parsed, {
    String raw = '',
  }) {
    _metadata = value.isEmpty ? null : Map.unmodifiable(value);
    _setFileLyrics(parsed, raw);
    _loading = _probePending;
    notifyListeners();
  }

  void _resetOnlineSearch() {
    _searchingOnline = false;
    _onlineSearchMissed = false;
    _onlineLyricsSaveFailed = false;
  }

  String _metadataPath(String source, String? resolved) =>
      resolved?.isNotEmpty == true &&
          (!source.startsWith('network://') ||
              !const {
                'http',
                'https',
                'network',
              }.contains(Uri.tryParse(resolved!)?.scheme))
      ? resolved!
      : source;

  Map<String, dynamic> detailsSnapshot(MediaItem? item) {
    if (item == null) return const {};
    final source = item.extras?['source']?.toString() ?? '';
    final resolved = item.extras?['resolvedSource']?.toString().trim();
    final sameItem = _requestKey == (item.id, source, resolved);
    return {
      'title': item.title,
      'artist': item.artist ?? '',
      'album': item.album ?? '',
      ...playbackAudioMetadataFromMediaItem(item),
      if (sameItem) ...?metadata,
    };
  }

  /// A details sheet owns this snapshot, independently of later track changes.
  /// Probing an unresolved document here does not alter the lyrics lifecycle.
  Future<Map<String, dynamic>> readDetails(MediaItem? item) async {
    final fallback = detailsSnapshot(item);
    final source = item?.extras?['source']?.toString() ?? '';
    final resolved = item?.extras?['resolvedSource']?.toString().trim();
    final path = _metadataPath(source, resolved);
    if (_disposed ||
        path.isEmpty ||
        const {'http', 'https'}.contains(Uri.tryParse(source)?.scheme) ||
        (_requestKey == (item?.id, source, resolved) && _loadedPath == path)) {
      return fallback;
    }
    try {
      return mergePlaybackFileMetadata(fallback, await _readMetadata(path));
    } catch (error) {
      _log.w('Failed to read details metadata: $error');
      return fallback;
    }
  }

  ({String? writers, String? provider}) get credits {
    String? field(String key) {
      final value = metadata?[key];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    return (
      writers: lyrics.writers ?? field('lyricist') ?? field('composer'),
      provider: lyrics.provider ?? field('lyrics_provider'),
    );
  }

  String? get qualityLabel {
    final meta = metadata;
    if (meta == null) return null;
    final parts = <String>[];
    final format = (meta['format'] ?? meta['audio_codec'] ?? '')
        .toString()
        .trim()
        .toUpperCase();
    if (format.isNotEmpty) parts.add(format);
    final bitDepth = readPositiveInt(meta['bit_depth']) ?? 0;
    if (bitDepth > 0) parts.add('$bitDepth-bit');
    final sampleRate = readPositiveInt(meta['sample_rate']) ?? 0;
    if (sampleRate > 0) {
      final khz = sampleRate / 1000;
      parts.add(
        '${khz.toStringAsFixed(khz == khz.roundToDouble() ? 0 : 1)} kHz',
      );
    }
    final bitrate = readPositiveInt(meta['bitrate']) ?? 0;
    if (bitDepth == 0 && bitrate > 0) parts.add('$bitrate kbps');
    return parts.isEmpty ? null : parts.join('  ·  ');
  }

  @override
  void dispose() {
    _disposed = true;
    _unsubscribeMetadata();
    _generation++;
    super.dispose();
  }
}
