import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart'
    show musicPlayerRuntimeProvider;
import 'package:mornye/services/autoplay_personalization.dart'
    show AutoplayFeedbackKind, AutoplayLearningTrack;
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/library_collections_hydration.dart';
import 'package:mornye/services/collection_track_batch.dart';
import 'package:mornye/services/playlist_cover_store.dart';
import 'package:mornye/utils/logger.dart';

export 'package:mornye/models/library_collections.dart';

final _log = AppLogger('LibraryCollections');

class LibraryCollectionsNotifier extends Notifier<LibraryCollectionsState> {
  LibraryCollectionsNotifier({LibraryCollectionsDatabase? database})
    : _db = database ?? LibraryCollectionsDatabase.instance;

  final LibraryCollectionsDatabase _db;
  final PlaylistCoverStore _coverStore = const PlaylistCoverStore();
  Future<void>? _loadFuture;
  final Map<String, Future<void>> _playlistLoadFutures = {};
  Future<void> _mutationTail = Future<void>.value();

  /// Evaluate membership against the preceding completed write, then publish
  /// only after persistence succeeds. A failed write does not block the next.
  Future<T> _mutate<T>(Future<T> Function() mutation) {
    final operation = _mutationTail.then((_) async {
      await _ensureLoaded();
      if (!ref.mounted) {
        throw StateError('Library collections provider was disposed');
      }
      return mutation();
    });
    _mutationTail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }

  void _invalidatePlaylistPickerSummaries() {
    if (!ref.mounted) return;
    ref.invalidate(libraryPlaylistPickerSummariesProvider);
  }

  @override
  LibraryCollectionsState build() {
    _loadFuture = _load();
    return LibraryCollectionsState();
  }

  Future<void> _load() async {
    try {
      await _db.migrateFromSharedPreferences();
      if (!ref.mounted) return;
      final snapshot = await _db.loadSnapshot();
      try {
        if (!ref.mounted) return;
        final loaded = await hydrateLibraryCollectionsSnapshot(snapshot);
        if (ref.mounted) state = loaded;
      } finally {
        await cleanupCollectionRows(
          nativeRowsPath: snapshot.nativeRowsPath,
          nativeRowsDirectory: snapshot.nativeRowsDirectory,
        );
      }
    } catch (error, stack) {
      _log.e('Failed to load library collections', error, stack);
      if (ref.mounted) state = state.copyWith(isLoaded: true);
    }
  }

  Future<void> _ensureLoaded() async {
    if (!ref.mounted) return;
    if (state.isLoaded) return;
    await (_loadFuture ?? _load());
  }

  Future<void> ensurePlaylistLoaded(String playlistId) async {
    await _ensureLoaded();
    if (!ref.mounted) return;
    final playlist = state.playlistById(playlistId);
    if (playlist == null || playlist.tracksLoaded) return;

    final pending = _playlistLoadFutures[playlistId];
    if (pending != null) return pending;
    final load = () async {
      while (ref.mounted) {
        final loading = state.playlistById(playlistId);
        if (loading == null || loading.tracksLoaded) return;
        final snapshot = await _db.loadPlaylistTracksSnapshot(playlistId);
        late HydratedPlaylistTracks hydrated;
        try {
          if (!ref.mounted) return;
          hydrated = await hydratePlaylistTracksSnapshot(
            snapshot,
            knownKeys: loading.trackKeys,
          );
        } finally {
          await cleanupCollectionRows(
            nativeRowsPath: snapshot.nativeRowsPath,
            nativeRowsDirectory: snapshot.nativeRowsDirectory,
          );
        }
        if (!ref.mounted) return;
        final current = state.playlistById(playlistId);
        if (current == null || current.tracksLoaded) return;
        // Metadata-only edits share the index. A restore/reload can replace it
        // while the worker is running; retry rather than publish stale tracks.
        if (!current.sharesMembershipIndexWith(loading)) continue;
        _replacePlaylistById(
          playlistId,
          (current) => current.withHydratedTracks(
            tracks: hydrated.tracks,
            trackKeys: hydrated.trackKeys,
            membershipUnchanged: hydrated.membershipUnchanged,
          ),
        );
        return;
      }
    }();
    _playlistLoadFutures[playlistId] = load;
    try {
      await load;
    } finally {
      if (identical(_playlistLoadFutures[playlistId], load)) {
        _playlistLoadFutures.remove(playlistId);
      }
    }
  }

  Future<void> ensurePlaylistsLoaded(Iterable<String> playlistIds) async {
    await Future.wait(playlistIds.toSet().map(ensurePlaylistLoaded));
  }

  bool _replacePlaylistById(
    String playlistId,
    UserPlaylistCollection Function(UserPlaylistCollection playlist) update,
  ) {
    if (!ref.mounted) return false;
    final playlist = state.playlistById(playlistId);
    if (playlist == null) return false;

    final playlistIndex = state.playlists.indexWhere((p) => p.id == playlistId);
    if (playlistIndex < 0) return false;

    final nextPlaylist = update(playlist);
    if (identical(nextPlaylist, playlist)) return false;

    final updatedPlaylists = [...state.playlists];
    updatedPlaylists[playlistIndex] = nextPlaylist;
    state = state.copyWith(playlists: updatedPlaylists);
    return true;
  }

  Future<bool> _toggleTrackEntry(
    Track track, {
    required bool Function(String key) contains,
    required List<CollectionTrackEntry> Function(LibraryCollectionsState state)
    select,
    required LibraryCollectionsState Function(List<CollectionTrackEntry> list)
    withList,
    required Future<void> Function(String key) dbDelete,
    required Future<void> Function({
      required String trackKey,
      required String trackJson,
      required String addedAt,
    })
    dbUpsert,
  }) => _mutate(() async {
    final key = trackCollectionKey(track);
    if (contains(key)) {
      await dbDelete(key);
      if (!ref.mounted) return false;
      state = withList(
        select(
          state,
        ).where((entry) => entry.key != key).toList(growable: false),
      );
      return false;
    }

    final entry = CollectionTrackEntry(
      key: key,
      track: track,
      addedAt: DateTime.now(),
    );
    await dbUpsert(
      trackKey: key,
      trackJson: jsonEncode(track.toJson()),
      addedAt: entry.addedAt.toIso8601String(),
    );
    if (ref.mounted) state = withList([entry, ...select(state)]);
    return true;
  });

  Future<bool> toggleWishlist(Track track) => _toggleTrackEntry(
    track,
    contains: (key) => state.containsWishlistKey(key),
    select: (state) => state.wishlist,
    withList: (list) => state.copyWith(wishlist: list),
    dbDelete: _db.deleteWishlistEntry,
    dbUpsert: _db.upsertWishlistEntry,
  );

  Future<bool> toggleLoved(Track track) async {
    final loved = await _toggleTrackEntry(
      track,
      contains: (key) => state.containsLovedKey(key),
      select: (state) => state.loved,
      withList: (list) => state.copyWith(loved: list),
      dbDelete: _db.deleteLovedEntry,
      dbUpsert: _db.upsertLovedEntry,
    );
    if (loved) _endorse([track], AutoplayFeedbackKind.loved);
    return loved;
  }

  /// Tells autoplay learning the listener chose these songs outright. Large
  /// selections, such as a whole album, organize more than they rate.
  void _endorse(List<Track> tracks, AutoplayFeedbackKind kind) {
    if (!ref.mounted || tracks.length > 3) return;
    final learning = ref.read(musicPlayerRuntimeProvider).personalization;
    for (final track in tracks) {
      learning.endorse(
        AutoplayLearningTrack(
          source: track.id,
          title: track.name,
          artist: track.artistName,
          album: track.albumName,
          genre: track.genre ?? '',
          duration: track.duration > 0
              ? Duration(seconds: track.duration)
              : null,
        ),
        kind,
      );
    }
  }

  /// One selection is one mutation: mixed selections add only missing tracks,
  /// fully loved selections remove them, and observers see one committed state.
  Future<({bool removed, int count})> toggleLovedTracks(
    Iterable<Track> tracks,
  ) => _mutate(() async {
    final selected = tracks.toList(growable: false);
    if (selected.isEmpty) return (removed: false, count: 0);
    if (selected.every(state.isLoved)) {
      final keys = selected.map(trackCollectionKey).toSet();
      await _db.deleteLovedTracks(keys.toList(growable: false));
      if (ref.mounted) {
        state = state.copyWith(
          loved: state.loved
              .where((entry) => !keys.contains(entry.key))
              .toList(growable: false),
        );
      }
      return (removed: true, count: keys.length);
    }

    final now = DateTime.now();
    final prepared = await prepareCollectionTrackBatch(
      tracks: selected,
      existingKeys: state.loved.map((entry) => entry.key).toSet(),
      addedAt: now,
    );
    try {
      if (!ref.mounted || prepared.entries.isEmpty) {
        return (removed: false, count: 0);
      }
      final rowsPath = prepared.rowsPath;
      if (rowsPath != null) {
        await _db.upsertLovedTracksFile(
          addedAt: now.toIso8601String(),
          rowsPath: rowsPath,
          expectedCount: prepared.entries.length,
        );
      } else {
        await _db.upsertLovedTracksBatch(prepared.rows);
      }
      if (ref.mounted) {
        // The latest added track appears first, matching the original
        // per-track inserts and the database's DESC rowid tie-breaker.
        state = state.copyWith(
          loved: [...prepared.entries.reversed, ...state.loved],
        );
      }
      return (removed: false, count: prepared.entries.length);
    } finally {
      await prepared.dispose();
    }
  });

  Future<bool> toggleFavoriteArtist({
    required String artistId,
    required String? providerId,
    required String name,
    String? imageUrl,
  }) => _mutate(() async {
    final key = artistCollectionKey(artistId: artistId, providerId: providerId);
    final sourceSeparator = key.indexOf(':');
    final source = sourceSeparator > 0 ? key.substring(0, sourceSeparator) : '';
    final trimmedProviderId = providerId?.trim();
    final effectiveProviderId =
        trimmedProviderId != null && trimmedProviderId.isNotEmpty
        ? trimmedProviderId
        : (source.isNotEmpty && source != 'builtin' ? source : null);
    if (state.containsFavoriteArtistKey(key)) {
      await _db.deleteFavoriteArtistEntry(key);
      if (!ref.mounted) return false;
      state = state.copyWith(
        favoriteArtists: state.favoriteArtists
            .where((entry) => entry.key != key)
            .toList(growable: false),
      );
      return false;
    }

    final entry = CollectionArtistEntry(
      key: key,
      artistId: collectionArtistId(artistId),
      providerId: effectiveProviderId,
      name: name,
      imageUrl: imageUrl,
      addedAt: DateTime.now(),
    );
    await _db.upsertFavoriteArtistEntry(
      artistKey: key,
      artistJson: jsonEncode(entry.toJson()),
      addedAt: entry.addedAt.toIso8601String(),
    );
    if (ref.mounted) {
      state = state.copyWith(
        favoriteArtists: [entry, ...state.favoriteArtists],
      );
    }
    return true;
  });

  Future<void> _removeEntry<T>(
    String key, {
    required bool Function(String key) contains,
    required List<T> Function(LibraryCollectionsState state) select,
    required String Function(T entry) keyOf,
    required LibraryCollectionsState Function(List<T> list) withList,
    required Future<void> Function(String key) dbDelete,
  }) => _mutate(() async {
    if (!contains(key)) return;

    await dbDelete(key);
    if (!ref.mounted) return;
    state = withList(
      select(
        state,
      ).where((entry) => keyOf(entry) != key).toList(growable: false),
    );
  });

  Future<void> removeFavoriteArtist(String artistKey) => _removeEntry(
    artistKey,
    contains: (key) => state.containsFavoriteArtistKey(key),
    select: (state) => state.favoriteArtists,
    keyOf: (entry) => entry.key,
    withList: (list) => state.copyWith(favoriteArtists: list),
    dbDelete: _db.deleteFavoriteArtistEntry,
  );

  Future<int> _removeTrackEntries(
    Iterable<String> trackKeys, {
    required bool Function(String key) contains,
    required List<CollectionTrackEntry> Function() select,
    required LibraryCollectionsState Function(List<CollectionTrackEntry>)
    withList,
    required Future<void> Function(List<String>) dbDelete,
  }) {
    final selected = trackKeys.toSet();
    return _mutate(() async {
      final keys = selected.where(contains).toSet();
      if (keys.isEmpty) return 0;
      await dbDelete(keys.toList(growable: false));
      if (ref.mounted) {
        state = withList(
          select()
              .where((entry) => !keys.contains(entry.key))
              .toList(growable: false),
        );
      }
      return keys.length;
    });
  }

  Future<int> removeWishlistTracks(Iterable<String> trackKeys) =>
      _removeTrackEntries(
        trackKeys,
        contains: (key) => state.containsWishlistKey(key),
        select: () => state.wishlist,
        withList: (list) => state.copyWith(wishlist: list),
        dbDelete: _db.deleteWishlistTracks,
      );

  Future<int> removeLovedTracks(Iterable<String> trackKeys) =>
      _removeTrackEntries(
        trackKeys,
        contains: (key) => state.containsLovedKey(key),
        select: () => state.loved,
        withList: (list) => state.copyWith(loved: list),
        dbDelete: _db.deleteLovedTracks,
      );

  Future<String> createPlaylist(String name) => _mutate(() async {
    final now = DateTime.now();
    final id = 'pl_${now.microsecondsSinceEpoch}';
    final trimmedName = name.trim();

    final playlist = UserPlaylistCollection(
      id: id,
      name: trimmedName,
      createdAt: now,
      updatedAt: now,
      tracks: const [],
    );

    await _db.upsertPlaylist(
      id: id,
      name: trimmedName,
      coverImagePath: null,
      createdAt: now.toIso8601String(),
      updatedAt: now.toIso8601String(),
    );
    if (!ref.mounted) return id;
    state = state.copyWith(playlists: [playlist, ...state.playlists]);
    _invalidatePlaylistPickerSummaries();
    return id;
  });

  Future<void> renamePlaylist(String playlistId, String newName) =>
      _mutate(() async {
        final trimmed = newName.trim();
        if (trimmed.isEmpty) return;
        final playlist = state.playlistById(playlistId);
        if (playlist == null || playlist.name == trimmed) return;

        final now = DateTime.now();
        await _db.renamePlaylist(
          playlistId: playlistId,
          name: trimmed,
          updatedAt: now.toIso8601String(),
        );
        _replacePlaylistById(playlistId, (playlist) {
          return playlist.copyWith(name: trimmed, updatedAt: now);
        });
        _invalidatePlaylistPickerSummaries();
      });

  Future<int> deletePlaylists(Iterable<String> playlistIds) {
    final selected = playlistIds.toSet();
    return _mutate(() async {
      final ids = selected
          .where((id) => state.playlistById(id) != null)
          .toSet();
      if (ids.isEmpty) return 0;
      await _db.deletePlaylists(ids.toList(growable: false));
      if (ref.mounted) {
        state = state.copyWith(
          playlists: state.playlists
              .where((playlist) => !ids.contains(playlist.id))
              .toList(growable: false),
        );
        _invalidatePlaylistPickerSummaries();
      }
      return ids.length;
    });
  }

  Future<bool> addTrackToPlaylist(String playlistId, Track track) => _mutate(
    () async {
      var playlist = state.playlistById(playlistId);
      if (playlist == null) return false;

      final key = trackCollectionKey(track);
      if (playlist.containsTrackKey(key)) return false;
      await ensurePlaylistLoaded(playlistId);
      if (!ref.mounted) return false;
      playlist = state.playlistById(playlistId);
      if (playlist == null) return false;

      final now = DateTime.now();
      final entry = CollectionTrackEntry(key: key, track: track, addedAt: now);
      await _db.upsertPlaylistTrack(
        playlistId: playlistId,
        trackKey: key,
        trackJson: jsonEncode(track.toJson()),
        addedAt: entry.addedAt.toIso8601String(),
        playlistUpdatedAt: now.toIso8601String(),
      );
      final changed = _replacePlaylistById(playlistId, (playlist) {
        if (playlist.containsTrackKey(key)) return playlist;
        return playlist.copyWith(
          tracks: [...playlist.tracks, entry],
          updatedAt: now,
        );
      });
      if (!changed) return false;
      _invalidatePlaylistPickerSummaries();
      _endorse([track], AutoplayFeedbackKind.playlisted);
      return true;
    },
  );

  Future<PlaylistAddBatchResult> addTracksToPlaylist(
    String playlistId,
    Iterable<Track> tracks, {
    bool preserveOccurrences = false,
  }) => _mutate(() async {
    await ensurePlaylistLoaded(playlistId);
    if (!ref.mounted) {
      return const PlaylistAddBatchResult(
        addedCount: 0,
        alreadyInPlaylistCount: 0,
      );
    }
    final playlist = state.playlistById(playlistId);
    if (playlist == null) {
      return const PlaylistAddBatchResult(
        addedCount: 0,
        alreadyInPlaylistCount: 0,
      );
    }

    final now = DateTime.now();
    final prepared = await prepareCollectionTrackBatch(
      tracks: tracks,
      existingKeys: playlist.trackKeys,
      addedAt: now,
      preserveOccurrences: preserveOccurrences,
    );
    try {
      if (!ref.mounted || prepared.entries.isEmpty) {
        return PlaylistAddBatchResult(
          addedCount: 0,
          alreadyInPlaylistCount: prepared.duplicates,
        );
      }
      final rowsPath = prepared.rowsPath;
      if (rowsPath != null) {
        await _db.upsertPlaylistTracksFile(
          playlistId: playlistId,
          playlistUpdatedAt: now.toIso8601String(),
          rowsPath: rowsPath,
          expectedCount: prepared.entries.length,
        );
      } else {
        await _db.upsertPlaylistTracksBatch(
          playlistId: playlistId,
          playlistUpdatedAt: now.toIso8601String(),
          tracks: prepared.rows,
        );
      }
      final changed = _replacePlaylistById(playlistId, (current) {
        return current.copyWith(
          // Append in playlist order, matching the ASC snapshot ordering.
          tracks: [...current.tracks, ...prepared.entries],
          updatedAt: now,
        );
      });
      if (changed) {
        _invalidatePlaylistPickerSummaries();
        _endorse([
          for (final entry in prepared.entries) entry.track,
        ], AutoplayFeedbackKind.playlisted);
      }
      return PlaylistAddBatchResult(
        addedCount: changed ? prepared.entries.length : 0,
        alreadyInPlaylistCount: prepared.duplicates,
      );
    } finally {
      await prepared.dispose();
    }
  });

  Future<int> removeTracksFromPlaylist(
    String playlistId,
    Iterable<String> trackKeys,
  ) {
    final selected = trackKeys.toSet();
    return _mutate(() async {
      var playlist = state.playlistById(playlistId);
      if (playlist == null || !selected.any(playlist.containsTrackKey)) {
        return 0;
      }
      await ensurePlaylistLoaded(playlistId);
      if (!ref.mounted) return 0;
      playlist = state.playlistById(playlistId);
      if (playlist == null) return 0;
      final keys = selected.where(playlist.containsTrackKey).toSet();
      if (keys.isEmpty) return 0;

      final now = DateTime.now();
      await _db.deletePlaylistTracks(
        playlistId: playlistId,
        trackKeys: keys.toList(growable: false),
        playlistUpdatedAt: now.toIso8601String(),
      );
      _replacePlaylistById(
        playlistId,
        (current) => current.copyWith(
          tracks: current.tracks
              .where((entry) => !keys.contains(entry.key))
              .toList(growable: false),
          updatedAt: now,
        ),
      );
      _invalidatePlaylistPickerSummaries();
      return keys.length;
    });
  }

  /// Puts the playlist in [orderedKeys] order, which must name every track
  /// once. Tracks are restamped one millisecond apart from the earliest
  /// stamp, kept before now so later additions still append.
  Future<bool> reorderPlaylistTracks(
    String playlistId,
    List<String> orderedKeys,
  ) => _mutate(() async {
    await ensurePlaylistLoaded(playlistId);
    if (!ref.mounted) return false;
    final playlist = state.playlistById(playlistId);
    if (playlist == null) return false;
    final byKey = {for (final entry in playlist.tracks) entry.key: entry};
    if (orderedKeys.length != byKey.length ||
        orderedKeys.toSet().length != orderedKeys.length ||
        !orderedKeys.every(byKey.containsKey)) {
      return false;
    }
    var unchanged = true;
    for (var i = 0; i < orderedKeys.length; i++) {
      if (playlist.tracks[i].key != orderedKeys[i]) {
        unchanged = false;
        break;
      }
    }
    if (unchanged) return false;

    final now = DateTime.now();
    final earliest = playlist.tracks
        .map((entry) => entry.addedAt.toLocal())
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final latestStart = now.subtract(
      Duration(milliseconds: orderedKeys.length),
    );
    final start = earliest.isBefore(latestStart) ? earliest : latestStart;
    final reordered = [
      for (var i = 0; i < orderedKeys.length; i++)
        CollectionTrackEntry(
          key: orderedKeys[i],
          track: byKey[orderedKeys[i]]!.track,
          addedAt: start.add(Duration(milliseconds: i)),
        ),
    ];
    await _db.reorderPlaylistTracks(
      playlistId: playlistId,
      addedAtByKey: {
        for (final entry in reordered)
          entry.key: entry.addedAt.toIso8601String(),
      },
      playlistUpdatedAt: now.toIso8601String(),
    );
    final changed = _replacePlaylistById(
      playlistId,
      (current) => current.copyWith(tracks: reordered, updatedAt: now),
    );
    if (changed) _invalidatePlaylistPickerSummaries();
    return changed;
  });

  /// Built-in collections use descending added-at order. Keep the same
  /// ordering contract in storage, backups and Link, with new likes first.
  Future<bool> reorderSavedTracks(
    LibraryTracksFolderMode mode,
    List<String> orderedKeys,
  ) => _mutate(() async {
    if (mode == LibraryTracksFolderMode.playlist) return false;
    final entries = mode == LibraryTracksFolderMode.loved
        ? state.loved
        : state.wishlist;
    final byKey = {for (final entry in entries) entry.key: entry};
    if (orderedKeys.length != byKey.length ||
        orderedKeys.toSet().length != orderedKeys.length ||
        !orderedKeys.every(byKey.containsKey)) {
      return false;
    }
    if (orderedKeys.indexed.every((item) => entries[item.$1].key == item.$2)) {
      return false;
    }
    final now = DateTime.now();
    final latest = entries
        .map((entry) => entry.addedAt.toLocal())
        .reduce((a, b) => a.isAfter(b) ? a : b);
    final end = latest.isAfter(now) ? now : latest;
    final reordered = [
      for (final (i, key) in orderedKeys.indexed)
        CollectionTrackEntry(
          key: key,
          track: byKey[key]!.track,
          addedAt: end.subtract(Duration(milliseconds: i)),
        ),
    ];
    await _db.reorderSavedTracks(
      mode: mode,
      addedAtByKey: {
        for (final entry in reordered)
          entry.key: entry.addedAt.toIso8601String(),
      },
    );
    if (!ref.mounted) return false;
    state = mode == LibraryTracksFolderMode.loved
        ? state.copyWith(loved: reordered)
        : state.copyWith(wishlist: reordered);
    return true;
  });

  Future<void> setPlaylistCover(
    String playlistId,
    String sourceFilePath,
  ) => _mutate(() async {
    final playlist = state.playlistById(playlistId);
    if (playlist == null) return;

    final previousCoverPath = playlist.coverImagePath;
    final destPath = await _coverStore.normalize(playlistId, sourceFilePath);

    final now = DateTime.now();
    await _db.updatePlaylistCover(
      playlistId: playlistId,
      coverImagePath: destPath,
      updatedAt: now.toIso8601String(),
    );
    _replacePlaylistById(playlistId, (playlist) {
      if (playlist.coverImagePath == destPath) return playlist;
      return playlist.copyWith(coverImagePath: () => destPath, updatedAt: now);
    });
    _invalidatePlaylistPickerSummaries();
    if (previousCoverPath != null && previousCoverPath != destPath) {
      await _coverStore.deleteQuietly(previousCoverPath);
    }
  });

  Future<void> removePlaylistCover(String playlistId) => _mutate(() async {
    final playlist = state.playlistById(playlistId);
    if (playlist == null || playlist.coverImagePath == null) return;

    final path = playlist.coverImagePath;
    if (path != null) {
      await _coverStore.delete(path);
    }

    final now = DateTime.now();
    await _db.updatePlaylistCover(
      playlistId: playlistId,
      coverImagePath: null,
      updatedAt: now.toIso8601String(),
    );
    _replacePlaylistById(playlistId, (playlist) {
      if (playlist.coverImagePath == null) return playlist;
      return playlist.copyWith(coverImagePath: () => null, updatedAt: now);
    });
    _invalidatePlaylistPickerSummaries();
  });

  Future<String> exportCollectionsJson() async {
    await _ensureLoaded();
    await ensurePlaylistsLoaded(state.playlists.map((playlist) => playlist.id));
    return exportLibraryCollectionsJson(state);
  }

  /// Returns cover file references for the streaming ZIP backup format. The
  /// backup writer reads each file directly instead of materializing every
  /// image as base64 in memory.
  Future<Map<String, Map<String, String>>> exportPlaylistCoverFiles() async {
    await _ensureLoaded();
    final covers = <String, Map<String, String>>{};
    final playlists = List<UserPlaylistCollection>.of(state.playlists);
    for (final playlist in playlists) {
      var path = playlist.coverImagePath;
      if (path == null || path.isEmpty) continue;
      try {
        if (await _coverStore.needsNormalization(path)) {
          await setPlaylistCover(playlist.id, path);
          path = state.playlistById(playlist.id)?.coverImagePath ?? path;
        }
        if (!await _coverStore.hasContent(path)) continue;
        covers[playlist.id] = {
          'ext': p.extension(path).toLowerCase(),
          'path': path,
        };
      } catch (_) {
        // Skip unreadable cover; the rest of the backup still succeeds.
      }
    }
    return covers;
  }

  /// Replaces all collections (wishlist, loved, playlists, favorite artists)
  /// with the contents of a backup. [collectionsJson] uses the
  /// [LibraryCollectionsState.toJson] shape; [coverImages] is the backup's
  /// playlist cover map: `ext` plus either a `path` to an extracted file or
  /// legacy base64 `data`. Cover images are rewritten into this device's
  /// covers directory and their paths fixed up before persisting.
  Future<void> restoreFromBackup(
    Map<String, dynamic> collectionsJson, {
    Map<String, dynamic>? coverImages,
  }) => _mutate(() async {
    final normalized = Map<String, dynamic>.from(collectionsJson);
    final coversDir = await _coverStore.coversDirectory();

    final playlistsRaw = normalized['playlists'];
    if (playlistsRaw is List) {
      final rewritten = <Map<String, dynamic>>[];
      for (final entry in playlistsRaw.whereType<Map<Object?, Object?>>()) {
        final playlist = Map<String, dynamic>.from(entry);
        final id = playlist['id'] as String?;
        String? newCoverPath;
        final coverEntry = (id != null && coverImages != null)
            ? coverImages[id]
            : null;
        if (id != null && coverEntry is Map) {
          final data = coverEntry['data'] as String?;
          final restoredPath = coverEntry['path'] as String?;
          final ext = (coverEntry['ext'] as String?) ?? '.jpg';
          if ((data != null && data.isNotEmpty) ||
              (restoredPath != null && restoredPath.isNotEmpty)) {
            newCoverPath = await _coverStore.restoreFromBackup(
              coversDir: coversDir,
              id: id,
              ext: ext,
              restoredPath: restoredPath,
              data: data,
            );
          }
        }
        // Always replace the backup's device-specific path: either with the
        // freshly written local cover, or drop it so a stale path is not kept.
        if (newCoverPath != null) {
          playlist['coverImagePath'] = newCoverPath;
        } else {
          playlist.remove('coverImagePath');
        }
        rewritten.add(playlist);
      }
      normalized['playlists'] = rewritten;
    }

    await _db.replaceAllFromBackup(normalized);
    await _load();
    _invalidatePlaylistPickerSummaries();
  });

  /// Reloads every collection after another writer (Mornye Link sync)
  /// changed the database. Queued behind pending mutations.
  Future<void> reloadFromDatabase() => _mutate(() async {
    await _load();
    _invalidatePlaylistPickerSummaries();
  });
}

final libraryCollectionsProvider =
    NotifierProvider<LibraryCollectionsNotifier, LibraryCollectionsState>(
      LibraryCollectionsNotifier.new,
    );

final libraryPlaylistPickerSummariesProvider = FutureProvider.autoDispose
    .family<List<PlaylistPickerSummary>, PlaylistPickerSummaryRequest>((
      ref,
      request,
    ) async {
      final db = LibraryCollectionsDatabase.instance;
      await db.migrateFromSharedPreferences();
      return db.loadPlaylistPickerSummaries(request.trackKeys);
    });
