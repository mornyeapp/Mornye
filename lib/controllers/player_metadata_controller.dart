import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/playback_metadata.dart';
import 'package:mornye/services/player_lyrics_persistence.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/utils/int_utils.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/lyrics_parser.dart';

final _log = AppLogger('PlayerMetadata');

/// Returns LRC text from the configured lyrics providers, or empty.
typedef OnlineLyricsFetcher = Future<String> Function(MediaItem item);
typedef OnlineLyricsSaver = Future<void> Function(String source, String lyrics);

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
  }) : _readMetadata = readMetadata ?? readPlaybackFileMetadataWithRetry,
       _parseLyrics = parseLyrics ?? LyricsParser.parseAsyncNative,
       _fetchOnline = fetchOnlineLyrics ?? _fetchOnlineLyrics,
       _saveOnline = saveOnlineLyrics ?? persistPlayerLyrics,
       _metadataEvents = metadataEvents ?? SourceMetadataEvents.instance {
    _unsubscribeMetadata = _metadataEvents.subscribe((changed) async {
      if (_disposed ||
          changed != source ||
          _savingLyricsSources.contains(changed)) {
        return;
      }
      _requestKey = null;
      await load(_item);
    });
  }

  late final void Function() _unsubscribeMetadata;

  final PlaybackMetadataReader _readMetadata;
  final Future<ParsedLyrics> Function(String?) _parseLyrics;
  final OnlineLyricsFetcher _fetchOnline;
  final OnlineLyricsSaver _saveOnline;
  final SourceMetadataEvents _metadataEvents;
  final _savingLyricsSources = <String>{};
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

  /// The last online search for this track found nothing.
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
      _lyrics = parsed;
      _lyricsRaw = raw;
    }
    notifyListeners();
    if (parsed.isEmpty) return;

    _savingLyricsSources.add(source);
    try {
      await _saveOnline(source, raw);
      await _metadataEvents.publish(source);
      if (_disposed || generation != _generation) return;
      _metadata = Map.unmodifiable({...?_metadata, 'lyrics': raw});
      _lyrics = parsed;
      _lyricsRaw = raw;
    } catch (error) {
      _log.w('Could not embed online lyrics: $error');
      if (_disposed || generation != _generation) return;
      _onlineLyricsSaveFailed = true;
    } finally {
      _savingLyricsSources.remove(source);
    }
    if (!_disposed && generation == _generation) notifyListeners();
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
    try {
      final probed = await _readMetadata(path);
      if (_disposed || generation != _generation) return;
      _probePending = false;
      _loadedPath = path;
      final pending = _replaceMetadata(
        mergePlaybackFileMetadata(_fallback, probed),
      );
      if (pending != null) await pending;
    } catch (error) {
      if (_disposed || generation != _generation) return;
      _probePending = false;
      _log.w('Failed to read metadata: $error');
      final pending = _replaceMetadata(_fallback);
      if (pending != null) await pending;
    }
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
    _lyrics = parsed;
    _lyricsRaw = raw;
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
