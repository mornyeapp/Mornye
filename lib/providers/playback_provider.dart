import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('PlaybackProvider');

class PlaybackState {
  const PlaybackState();
}

class PlaybackController extends Notifier<PlaybackState> {
  PlaybackController({LibraryDatabase? library, HistoryDatabase? history})
    : _library = library ?? LibraryDatabase.instance,
      _history = history ?? HistoryDatabase.instance;

  final LibraryDatabase _library;
  final HistoryDatabase _history;

  @override
  PlaybackState build() => const PlaybackState();

  Future<bool> _useInternalPlayer({String? source}) async {
    final mode = ref.read(settingsProvider).playerMode;
    if (mode != 'internal' && source?.startsWith('network://') != true) {
      return false;
    }
    return await ref.read(musicPlayerControllerProvider).ensureInitialized() !=
        null;
  }

  String? _normalizeArtUri(String cover) {
    final value = cover.trim();
    if (value.isEmpty) return null;
    if (value.startsWith('http') ||
        isContentUri(value) ||
        value.startsWith('file://')) {
      return value;
    }
    return Uri.file(value).toString();
  }

  Future<void> playLocalPath({
    required String path,
    required String title,
    required String artist,
    String album = '',
    String coverUrl = '',
    Duration? duration,
    int? bitDepth,
    int? sampleRate,
    int? bitrate,
    String? format,
    bool? explicit,
  }) async {
    if (isCueVirtualPath(path)) {
      throw Exception(cueVirtualTrackRequiresSplitMessage);
    }

    if (await _useInternalPlayer(source: path)) {
      _log.d('Playing "$title" in the internal player: $path');
      await ref
          .read(musicPlayerControllerProvider)
          .playSingle(
            PlayableMedia(
              id: path,
              source: path,
              title: title,
              artist: artist,
              album: album,
              artUri: _normalizeArtUri(coverUrl),
              duration: duration,
              bitDepth: bitDepth,
              sampleRate: sampleRate,
              bitrate: bitrate,
              format: format,
              explicit: explicit ?? false,
            ),
          );
      return;
    }

    _log.d('Opening external player for "$title" by $artist: $path');
    await openFile(path);
  }

  /// Plays a local-library album/list starting at [startItem], queuing the rest
  /// so playback continues to the next track automatically. Honors player mode.
  Future<void> playLocalLibraryQueue(
    List<LocalLibraryItem> items, {
    required LocalLibraryItem startItem,
  }) => _playQueue(
    items,
    (i) => i.id == startItem.id,
    (i) => i.filePath,
    playableFromLocal,
  );

  /// Plays a downloaded-history album/list starting at [startItem], queuing the
  /// rest. Honors player mode.
  Future<void> playHistoryQueue(
    List<DownloadHistoryItem> items, {
    required DownloadHistoryItem startItem,
  }) => _playQueue(
    items,
    (i) => i.id == startItem.id,
    (i) => i.filePath,
    playableFromHistory,
  );

  Future<void> _playQueue<T>(
    List<T> items,
    bool Function(T item) isStart,
    String Function(T item) path,
    PlayableMedia Function(T item) toMedia,
  ) async {
    final playable = items
        .where((i) => path(i).trim().isNotEmpty && !isCueVirtualPath(path(i)))
        .toList();
    if (playable.isEmpty) return;
    var startIndex = playable.indexWhere(isStart);
    if (startIndex < 0) startIndex = 0;
    await playMediaQueue(
      playable.map(toMedia),
      startIndex: startIndex,
      externalPath: path(playable[startIndex]),
    );
  }

  /// Plays a prebuilt media queue starting at [startIndex]. Honors player mode
  /// ([externalPath] is opened externally when the built-in player is off).
  Future<void> playMediaQueue(
    Iterable<PlayableMedia> queue, {
    required int startIndex,
    required String externalPath,
  }) async {
    if (await _useInternalPlayer(source: externalPath)) {
      final items = queue.toList(growable: false);
      if (items.isEmpty) return;
      final i = startIndex.clamp(0, items.length - 1);
      await ref
          .read(musicPlayerControllerProvider)
          .playAll(items, initialIndex: i);
    } else {
      await openFile(externalPath);
    }
  }

  Future<void> playTrackList(List<Track> tracks, {int startIndex = 0}) async {
    if (tracks.isEmpty) return;

    final safeStart = startIndex.clamp(0, tracks.length - 1);
    List<String?>? resolvedPaths;
    String? networkSource;
    if (ref.read(settingsProvider).playerMode != 'internal') {
      var skippedCueVirtualTrack = false;
      // External playback opens one file. Resolve only candidates actually
      // visited, preserving the original forward/wrap fallback order.
      for (var offset = 0; offset < tracks.length; offset++) {
        final index = (safeStart + offset) % tracks.length;
        final path = (await resolveTrackFilePaths([tracks[index]])).single;
        if (path == null) continue;
        if (isCueVirtualPath(path)) {
          skippedCueVirtualTrack = true;
          continue;
        }
        if (path.startsWith('network://')) {
          // Network identities require the internal proxy-aware player.
          networkSource = path;
          resolvedPaths = await resolveTrackFilePaths(tracks);
          break;
        }
        await openFile(path);
        return;
      }
      if (resolvedPaths == null) {
        throw Exception(
          skippedCueVirtualTrack
              ? cueVirtualTrackRequiresSplitMessage
              : 'No local audio file is available to open. Download the track first.',
        );
      }
    }
    resolvedPaths ??= await resolveTrackFilePaths(tracks);

    if (await _useInternalPlayer(
      source: networkSource ?? resolvedPaths[safeStart],
    )) {
      final queue = <PlayableMedia>[];
      int? initialIndex;
      var skippedCueVirtualTrack = false;
      for (var index = 0; index < tracks.length; index++) {
        final track = tracks[index];
        final resolvedPath = resolvedPaths[index];
        if (resolvedPath == null) continue;
        if (isCueVirtualPath(resolvedPath)) {
          skippedCueVirtualTrack = true;
          continue;
        }
        // Keep the playlist's original order so Previous can reach earlier
        // tracks and reaching its end still respects the player's repeat mode.
        if (index >= safeStart) initialIndex ??= queue.length;
        queue.add(
          PlayableMedia(
            id: resolvedPath,
            source: resolvedPath,
            title: track.name,
            artist: track.artistName,
            album: track.albumName,
            artUri: _normalizeArtUri(track.coverUrl ?? ''),
            duration: track.duration > 0
                ? Duration(seconds: track.duration)
                : null,
            explicit: track.isExplicit,
          ),
        );
      }

      if (queue.isNotEmpty) {
        _log.d('Playing ${queue.length} tracks in the internal player');
        await ref
            .read(musicPlayerControllerProvider)
            .playAll(queue, initialIndex: initialIndex ?? 0);
        return;
      }
      if (skippedCueVirtualTrack) {
        throw Exception(cueVirtualTrackRequiresSplitMessage);
      }
      throw Exception(
        'No local audio file is available to play. Download the track first.',
      );
    }

    var skippedCueVirtualTrack = false;
    for (var offset = 0; offset < tracks.length; offset++) {
      final index = (safeStart + offset) % tracks.length;
      final track = tracks[index];
      final resolvedPath = resolvedPaths[index];
      if (resolvedPath == null) {
        continue;
      }
      if (isCueVirtualPath(resolvedPath)) {
        skippedCueVirtualTrack = true;
        continue;
      }

      _log.d(
        'Opening first available external track for list playback: '
        '"${track.name}" by ${track.artistName} -> $resolvedPath',
      );
      await openFile(resolvedPath);
      return;
    }

    if (skippedCueVirtualTrack) {
      throw Exception(cueVirtualTrackRequiresSplitMessage);
    }

    throw Exception(
      'No local audio file is available to open. Download the track first.',
    );
  }

  /// Public wrapper so non-playback features (e.g. M3U export) reuse the
  /// same library+history file resolution.
  Future<List<String?>> resolveTrackFilePaths(List<Track> tracks) =>
      _resolveTrackPaths(tracks);

  Future<List<String?>> _resolveTrackPaths(List<Track> tracks) async {
    if (tracks.isEmpty) return const [];
    final localFuture = _library.findExistingBatch([
      for (final track in tracks)
        LocalLibraryBatchLookupRequest(
          id: (track.source ?? '').toLowerCase() == 'local' ? track.id : null,
          isrc: track.isrc,
          trackName: track.name,
          artistName: track.artistName,
        ),
    ]);
    final historyFuture = _history.findExistingTracks([
      for (final track in tracks)
        HistoryLookupRequest(
          spotifyId: track.id,
          isrc: track.isrc,
          trackName: track.name,
          artistName: track.artistName,
        ),
    ]);
    final localMatches = await localFuture;
    final historyMatches = await historyFuture;

    final results = List<String?>.filled(tracks.length, null);
    final existsChecks = <String, Future<bool>>{};
    final unknownSafPaths = <String>{};
    final safPaths = <String>{
      for (final row in [...localMatches, ...historyMatches])
        if (isContentUri(
          stripCueTrackSuffix(row?['filePath']?.toString() ?? ''),
        ))
          stripCueTrackSuffix(row!['filePath'].toString()),
    }.toList(growable: false);
    for (var start = 0; start < safPaths.length; start += 64) {
      final batch = safPaths.sublist(
        start,
        (start + 64).clamp(0, safPaths.length),
      );
      try {
        final checks = await PlatformBridge.safExistsBatch(batch);
        for (final path in batch) {
          final exists = checks[path];
          if (exists != null) {
            existsChecks[path] = Future.value(exists);
          } else {
            unknownSafPaths.add(path);
          }
        }
      } catch (_) {
        // Older bindings may lack the batch API; retain per-file fallback.
        unknownSafPaths.addAll(batch);
      }
    }
    final invalidHistoryIds = <String>{};
    var next = 0;
    final workerCount = tracks.length < 8 ? tracks.length : 8;

    Future<bool> pathExists(String path) {
      final realPath = stripCueTrackSuffix(path);
      return existsChecks.putIfAbsent(realPath, () => fileExists(path));
    }

    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= tracks.length) return;
        final localPath = localMatches[index]?['filePath']?.toString() ?? '';
        if (localPath.isNotEmpty && await pathExists(localPath)) {
          results[index] = localPath;
          continue;
        }

        final historyMatch = historyMatches[index];
        final historyPath = historyMatch?['filePath']?.toString() ?? '';
        if (historyPath.isNotEmpty && await pathExists(historyPath)) {
          results[index] = historyPath;
          continue;
        }
        final historyId = historyMatch?['id']?.toString() ?? '';
        if (historyId.isNotEmpty &&
            !unknownSafPaths.contains(stripCueTrackSuffix(historyPath))) {
          invalidHistoryIds.add(historyId);
        }
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
    final historyNotifier = ref.read(downloadHistoryProvider.notifier);
    await historyNotifier.removeManyFromHistory(invalidHistoryIds);
    return results;
  }
}

final playbackProvider = NotifierProvider<PlaybackController, PlaybackState>(
  PlaybackController.new,
);
