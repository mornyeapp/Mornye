import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/history_row_mapper.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/utils/file_access.dart';

final musicPlayerRuntimeProvider = Provider<MusicPlayerRuntime>(
  (ref) => musicPlayerRuntime,
);

final currentMediaItemProvider =
    StreamNotifierProvider<CurrentMediaItemNotifier, MediaItem?>(
      CurrentMediaItemNotifier.new,
    );

class CurrentMediaItemNotifier extends StreamNotifier<MediaItem?> {
  @override
  Stream<MediaItem?> build() =>
      ref.watch(musicPlayerRuntimeProvider).mediaItemEvents();

  @override
  bool updateShouldNotify(
    AsyncValue<MediaItem?> previous,
    AsyncValue<MediaItem?> next,
  ) {
    // MediaItem equality compares IDs only. A new snapshot of the same track
    // can carry its late duration, artwork or metadata and must reach the UI.
    if (previous is AsyncData<MediaItem?> && next is AsyncData<MediaItem?>) {
      return !identical(previous.value, next.value);
    }
    return super.updateShouldNotify(previous, next);
  }
}

/// The download or Library record of the file a media item plays: by its
/// source path, then by its media id, then by title and artist with the same
/// path. Null when the file has no record.
Future<UnifiedLibraryItem?> _libraryItemForMedia(
  Ref ref, {
  required String id,
  required String source,
  required String title,
  required String artist,
}) async {
  if (source.isNotEmpty) {
    final history = await ref
        .read(downloadHistoryProvider.notifier)
        .getByFilePathAsync(source);
    if (history != null) return UnifiedLibraryItem.fromDownloadHistory(history);
  }
  final database = ref
      .watch(musicPlayerRuntimeProvider)
      .dependencies
      .libraryDatabase;
  final row = await database.getById(id);
  if (row != null) {
    return UnifiedLibraryItem.fromLocalLibrary(LocalLibraryItem.fromJson(row));
  }
  if (source.isNotEmpty) {
    final matches = await database.findByTrackAndArtist(title, artist);
    for (final row in matches) {
      final local = LocalLibraryItem.fromJson(row);
      if (local.filePath == source) {
        return UnifiedLibraryItem.fromLocalLibrary(local);
      }
    }
  }
  return null;
}

/// Use the Library's identity for favorites, including restored queues and
/// playback started from a file path rather than a Library row ID.
final playerCollectionTrackProvider = FutureProvider.autoDispose
    .family<Track, MediaItem>((ref, item) async {
      final match = await _libraryItemForMedia(
        ref,
        id: item.id,
        source: item.extras?['source']?.toString() ?? '',
        title: item.title,
        artist: item.artist ?? '',
      );
      if (match != null) return match.toTrack();
      return Track(
        id: item.id,
        name: item.title,
        artistName: item.artist ?? '',
        albumName: item.album ?? '',
        coverUrl: item.artUri?.toString(),
        duration: item.duration?.inSeconds ?? 0,
        source: 'local',
      );
    });

final playbackStateProvider = StreamProvider<PlaybackState>((ref) {
  return ref.watch(musicPlayerRuntimeProvider).playbackStateEvents();
});

/// Small derived providers keep position ticks from rebuilding widgets that
/// only care about transport state (and vice versa).
final playbackPositionProvider = Provider<Duration>((ref) {
  return ref.watch(
    playbackStateProvider.select(
      (state) => state.value?.position ?? Duration.zero,
    ),
  );
});

final playbackPlayingProvider = Provider<bool>((ref) {
  return ref.watch(
    playbackStateProvider.select((state) => state.value?.playing ?? false),
  );
});

final playbackLoadingProvider = Provider<bool>((ref) {
  return ref.watch(
    playbackStateProvider.select((state) {
      final processingState = state.value?.processingState;
      return processingState == AudioProcessingState.loading ||
          processingState == AudioProcessingState.buffering;
    }),
  );
});

/// Whether a list row is the current track, and if so whether it plays or
/// loads.
typedef MediaPlaybackUi = ({bool isCurrent, bool isPlaying, bool isLoading});

const MediaPlaybackUi _notCurrent = (
  isCurrent: false,
  isPlaying: false,
  isLoading: false,
);

/// The transport state of a row once it is known to be current. Only the
/// current row follows play and loading.
MediaPlaybackUi _currentPlaybackUi(Ref ref) => (
  isCurrent: true,
  isPlaying: ref.watch(playbackPlayingProvider),
  isLoading: ref.watch(playbackLoadingProvider),
);

/// What a list row plays: its media [id] (a download or Library row id) and
/// the [path] of its file, either of which may be empty.
typedef PlaybackRowKey = ({String id, String path});

String _cleanMediaPath(String path) =>
    path.startsWith('EXISTS:') ? path.substring(7) : path;

/// Whether [item] plays the row [row].
///
/// Every queued item carries its file in `extras['source']`, but its id
/// depends on where the queue started: a download or Library row id, or the
/// path itself when a playlist or a single file started it. So when both
/// sides know a path only the paths are compared, and an id that another
/// source happens to share never marks the row. Rows without a path fall
/// back to the media id.
bool mediaItemPlaysRow(MediaItem? item, PlaybackRowKey row) {
  if (item == null) return false;
  final source = _cleanMediaPath(item.extras?['source']?.toString() ?? '');
  final path = _cleanMediaPath(row.path);
  if (source.isNotEmpty && path.isNotEmpty) return source == path;
  return (row.id.isNotEmpty && item.id == row.id) ||
      (path.isNotEmpty && item.id == path);
}

/// Transport state for one list row. Non-current Library cells only watch
/// whether the current item plays them; the active cell additionally follows
/// play/loading so a transport toggle does not rebuild the entire Library
/// grid. Release each cell's subscription when it scrolls out of the Library.
final mediaItemPlaybackUiProvider = Provider.autoDispose
    .family<MediaPlaybackUi, PlaybackRowKey>((ref, row) {
      final isCurrent = ref.watch(
        currentMediaItemProvider.select(
          (state) => mediaItemPlaysRow(state.value, row),
        ),
      );
      return isCurrent ? _currentPlaybackUi(ref) : _notCurrent;
    });

/// A catalog track row (an online album, a playlist, a Library folder) by
/// the values its downloaded file can be matched on: its catalog [id], its
/// normalized [isrc] and its title and artist [matchKey].
typedef CatalogTrackKey = ({String id, String isrc, String matchKey});

CatalogTrackKey catalogTrackKey(Track track) => (
  id: track.id.trim(),
  isrc: HistoryDatabase.normalizeIsrc(track.isrc),
  matchKey: HistoryDatabase.matchKeyFor(track.name, track.artistName),
);

/// The records behind the current media item, for marking catalog rows,
/// which carry no media id or file path of their own.
@immutable
class CurrentTrackIdentity {
  const CurrentTrackIdentity({
    this.recordIds = const {},
    this.catalogIds = const {},
    this.isrc = '',
    this.matchKey = '',
  });

  factory CurrentTrackIdentity.of({
    required String mediaId,
    UnifiedLibraryItem? record,
  }) {
    final history = record?.historyItem;
    final local = record?.localItem;
    return CurrentTrackIdentity(
      recordIds: {mediaId, ?history?.id, ?local?.id},
      catalogIds: {
        for (final id in HistoryDatabase.spotifyLookupCandidates(
          history?.spotifyId,
        ))
          HistoryRowMapper.normalizeSpotifyId(id),
      },
      isrc: HistoryDatabase.normalizeIsrc(history?.isrc ?? local?.isrc),
      matchKey: record == null
          ? ''
          : HistoryDatabase.matchKeyFor(record.trackName, record.artistName),
    );
  }

  /// Ids that name this one file: the media id and its download and Library
  /// rows. Library playlists store these for downloaded and local tracks.
  final Set<String> recordIds;

  /// The catalog ids the file was downloaded as, normalized.
  final Set<String> catalogIds;
  final String isrc;
  final String matchKey;

  /// Whether [row] is this track. A record id is exact. Otherwise two ISRCs
  /// decide, and without one on both sides the catalog id must match along
  /// with the title and artist: providers number their catalogs
  /// independently, so an id alone can name another song. A title and artist
  /// alone never match.
  bool matches(CatalogTrackKey row) {
    if (row.id.isNotEmpty && recordIds.contains(row.id)) return true;
    if (isrc.isNotEmpty && row.isrc.isNotEmpty) return isrc == row.isrc;
    return row.id.isNotEmpty &&
        catalogIds.contains(HistoryRowMapper.normalizeSpotifyId(row.id)) &&
        matchKey.isNotEmpty &&
        matchKey == row.matchKey;
  }

  @override
  bool operator ==(Object other) =>
      other is CurrentTrackIdentity &&
      setEquals(other.recordIds, recordIds) &&
      setEquals(other.catalogIds, catalogIds) &&
      other.isrc == isrc &&
      other.matchKey == matchKey;

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(recordIds),
    Object.hashAllUnordered(catalogIds),
    isrc,
    matchKey,
  );
}

/// The identity of the current media item, resolved once per track change.
final currentTrackIdentityProvider =
    FutureProvider.autoDispose<CurrentTrackIdentity?>((ref) async {
      final current = ref.watch(
        currentMediaItemProvider.select((state) {
          final item = state.value;
          if (item == null) return null;
          return (
            id: item.id,
            source: item.extras?['source']?.toString() ?? '',
            title: item.title,
            artist: item.artist ?? '',
          );
        }),
      );
      if (current == null) return null;
      final record = await _libraryItemForMedia(
        ref,
        id: current.id,
        source: current.source,
        title: current.title,
        artist: current.artist,
      );
      return CurrentTrackIdentity.of(mediaId: current.id, record: record);
    });

/// Transport state for one catalog track row. Rows stay unmarked while the
/// current item's identity resolves, so a track change never marks the row
/// of the previous track.
final catalogTrackPlaybackUiProvider = Provider.autoDispose
    .family<MediaPlaybackUi, CatalogTrackKey>((ref, row) {
      final isCurrent = ref.watch(
        currentTrackIdentityProvider.select(
          (state) => !state.isLoading && (state.value?.matches(row) ?? false),
        ),
      );
      return isCurrent ? _currentPlaybackUi(ref) : _notCurrent;
    });

final playQueueProvider = StreamProvider<List<MediaItem>>((ref) {
  return ref.watch(musicPlayerRuntimeProvider).queueEvents();
});

/// Prefers the reported queue index while it still names the current item.
final currentQueueIndexProvider = Provider<int>((ref) {
  final queue = ref.watch(playQueueProvider).value ?? const <MediaItem>[];
  final id = ref.watch(currentMediaItemProvider.select((s) => s.value?.id));
  final index = ref.watch(
    playbackStateProvider.select((state) => state.value?.queueIndex),
  );
  return index != null &&
          index >= 0 &&
          index < queue.length &&
          queue[index].id == id
      ? index
      : queue.indexWhere((item) => item.id == id);
});

class MusicPlayerController {
  MusicPlayerController({MusicPlayerRuntime? runtime})
    : _runtime = runtime ?? musicPlayerRuntime;

  final MusicPlayerRuntime _runtime;

  MusicPlayerHandler? get _handler => _runtime.handler;

  DateTime? get sleepTimerEndsAt => _handler?.sleepTimerEndsAt;

  Future<MusicPlayerHandler?> ensureInitialized() async {
    try {
      return await _runtime.initialize();
    } catch (_) {
      return null;
    }
  }

  Future<void> playAll(
    List<PlayableMedia> items, {
    int initialIndex = 0,
  }) async {
    final handler = await ensureInitialized();
    await handler?.setQueueAndPlay(items, initialIndex: initialIndex);
  }

  Future<void> playSingle(PlayableMedia item) => playAll([item]);

  Future<({LocalLibraryItem item, List<LocalLibraryItem> tracks})?>
  localAlbumFor(String mediaId) async {
    final database = _runtime.dependencies.libraryDatabase;
    final row = await database.getById(mediaId);
    if (row == null) return null;
    final item = LocalLibraryItem.fromJson(row);
    final rows = await database.getQueueLocalAlbumTracksByKey(item.albumKey);
    final tracks = rows.map(LocalLibraryItem.fromJson).toList(growable: false);
    return tracks.isEmpty ? null : (item: item, tracks: tracks);
  }

  /// Plays every Library song, downloads and enabled scanned sources alike,
  /// from a random one with shuffle on. The queue keeps the Library order
  /// underneath, so turning shuffle off returns to that order.
  Future<bool> shuffleLibrary() async {
    const pageSize = 1000;
    final database = _runtime.dependencies.libraryDatabase;
    final includeLocal = _runtime.settings.localLibraryEnabled;
    final media = <PlayableMedia>[];
    QueueLibraryDbCursor? cursor;
    for (var offset = 0; ; offset += pageSize) {
      final page = await database.getQueueTrackPageResult(
        QueueLibraryDbQuery(
          includeLocal: includeLocal,
          limit: pageSize,
          offset: offset,
          cursor: cursor,
        ),
      );
      for (final row in page.rows) {
        final item = Map<String, dynamic>.from(row['item'] as Map);
        final playable = switch (row['source']) {
          'local' => playableFromLocal(LocalLibraryItem.fromJson(item)),
          'downloaded' => playableFromHistory(
            DownloadHistoryItem.fromJson(item),
          ),
          _ => null,
        };
        if (playable != null && playable.source.trim().isNotEmpty) {
          media.add(playable);
        }
      }
      if (page.rows.length < pageSize) break;
      cursor = page.nextCursor;
    }
    if (media.isEmpty) return false;
    final handler = await _runtime.initialize();
    await handler.setShuffleMode(AudioServiceShuffleMode.all);
    await handler.setQueueAndPlay(
      media,
      initialIndex: Random().nextInt(media.length),
    );
    return true;
  }

  Future<void> seek(Duration position) async => _handler?.seek(position);
  Future<void> next() async => _handler?.skipToNext();
  Future<void> previous() async => _handler?.skipToPrevious();

  void setSleepTimer(Duration duration) => _handler?.setSleepTimer(duration);

  void cancelSleepTimer() => _handler?.cancelSleepTimer();

  Future<void> togglePlayPause(bool isPlaying) async {
    final handler = _handler;
    if (handler == null) return;
    final processingState = handler.playbackState.value.processingState;
    if (processingState == AudioProcessingState.loading ||
        processingState == AudioProcessingState.buffering) {
      return;
    }
    if (isPlaying) {
      await handler.pause();
    } else {
      await handler.play();
    }
  }

  Future<void> setShuffle(bool enabled) async {
    await _handler?.setShuffleMode(
      enabled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
    );
  }

  Future<void> setRepeatMode(AudioServiceRepeatMode mode) async =>
      _handler?.setRepeatMode(mode);

  Future<void> playNext(PlayableMedia item) async =>
      (await ensureInitialized())?.enqueue(item, playNext: true);

  Future<void> addToQueue(PlayableMedia item) async =>
      (await ensureInitialized())?.enqueue(item);

  Future<void> enqueueLibraryItems(
    List<UnifiedLibraryItem> items, {
    bool playNext = false,
  }) async {
    final media = [
      for (final item in items)
        if (item.localItem != null)
          playableFromLocal(item.localItem!)
        else if (item.historyItem != null)
          playableFromHistory(item.historyItem!),
    ];
    await (await ensureInitialized())?.enqueueAll(media, playNext: playNext);
  }

  Future<void> playNextHistory(DownloadHistoryItem item) async =>
      playNext(playableFromHistory(item));

  Future<void> addToQueueHistory(DownloadHistoryItem item) async =>
      addToQueue(playableFromHistory(item));

  Future<void> playNextLocal(LocalLibraryItem item) async =>
      playNext(playableFromLocal(item));

  Future<void> addToQueueLocal(LocalLibraryItem item) async =>
      addToQueue(playableFromLocal(item));

  Future<void> jumpTo(int index) async => _handler?.skipToQueueItem(index);

  void moveQueueItem(int oldIndex, int newIndex) {
    _handler?.moveQueueItem(oldIndex, newIndex);
  }

  void removeQueuedItem(MediaItem item) => _handler?.removeQueuedItem(item);
}

final musicPlayerControllerProvider = Provider<MusicPlayerController>(
  (ref) =>
      MusicPlayerController(runtime: ref.watch(musicPlayerRuntimeProvider)),
);

PlayableMedia playableFromHistory(DownloadHistoryItem item) {
  return PlayableMedia(
    id: item.id,
    source: item.filePath,
    title: item.trackName,
    artist: item.artistName,
    album: item.albumName,
    artUri: (item.coverUrl != null && item.coverUrl!.trim().isNotEmpty)
        ? item.coverUrl
        : null,
    duration: (item.duration != null && item.duration! > 0)
        ? Duration(seconds: item.duration!)
        : null,
    bitDepth: item.bitDepth,
    sampleRate: item.sampleRate,
    bitrate: item.bitrate,
    format: item.format,
    explicit: item.explicit,
    genre: item.genre,
  );
}

PlayableMedia playableFromLocal(LocalLibraryItem item) {
  String? art;
  final cover = item.coverPath;
  if (cover != null && cover.trim().isNotEmpty) {
    art = cover.startsWith('http') || isContentUri(cover)
        ? cover
        : Uri.file(cover).toString();
  }
  return PlayableMedia(
    id: item.id,
    source: item.filePath,
    title: item.trackName,
    artist: item.artistName,
    album: item.albumName,
    artUri: art,
    duration: (item.duration != null && item.duration! > 0)
        ? Duration(seconds: item.duration!)
        : null,
    bitDepth: item.bitDepth,
    sampleRate: item.sampleRate,
    bitrate: item.bitrate,
    format: item.format,
    explicit: item.explicit,
    genre: item.genre,
  );
}
