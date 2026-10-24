import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/sync/link_collection_sync_store.dart';
import 'package:mornye/services/link/sync/link_history_sync_store.dart';
import 'package:mornye/services/link/sync/link_sync_protocol.dart';
import 'package:mornye/services/link/sync/link_sync_runner.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkSyncHandlers');

/// Forwarded Subsonic ops this unit answers (contract section 6.2).
abstract final class LinkSyncSubsonicOps {
  static const getPlaylists = '${LinkOps.subsonicPrefix}getPlaylists';
  static const getPlaylist = '${LinkOps.subsonicPrefix}getPlaylist';
  static const createPlaylist = '${LinkOps.subsonicPrefix}createPlaylist';
  static const updatePlaylist = '${LinkOps.subsonicPrefix}updatePlaylist';
  static const deletePlaylist = '${LinkOps.subsonicPrefix}deletePlaylist';
  static const star = '${LinkOps.subsonicPrefix}star';
  static const unstar = '${LinkOps.subsonicPrefix}unstar';
  static const getStarred = '${LinkOps.subsonicPrefix}getStarred';
  static const scrobble = '${LinkOps.subsonicPrefix}scrobble';
}

/// Tells connected phones to sync. The desktop calls it after a phone or a
/// Subsonic app changed collections, and after local collection edits
/// (debounced). The integrator connects it to `linkSend` with
/// `{"type": "collections.changed"}` and no `deviceId` (every phone).
class LinkCollectionsChangedHook extends Notifier<void Function()?> {
  @override
  void Function()? build() => null;

  void set(void Function()? callback) => state = callback;
}

final linkCollectionsChangedHookProvider =
    NotifierProvider<LinkCollectionsChangedHook, void Function()?>(
      LinkCollectionsChangedHook.new,
    );

/// Turns a catalog song into the app [Track] the Library would collect for
/// it, so starring from a Subsonic app and loving in the app share one key.
typedef LinkSongTrackResolver = Future<Track> Function(LinkSongInfo song);

final linkSongTrackResolverProvider = Provider<LinkSongTrackResolver>(
  (ref) => resolveLinkSongTrack,
);

/// Looks the song up in download history (`d:`) or the local library
/// (`l:`), else builds a [Track] from the forwarded fields.
Future<Track> resolveLinkSongTrack(LinkSongInfo song) async {
  try {
    if (song.id.startsWith('d:')) {
      final row = await HistoryDatabase.instance.getById(song.id.substring(2));
      if (row != null) {
        return UnifiedLibraryItem.fromDownloadHistory(
          DownloadHistoryItem.fromJson(row),
        ).toTrack();
      }
    } else if (song.id.startsWith('l:')) {
      final row = await LibraryDatabase.instance.getById(song.id.substring(2));
      if (row != null) {
        return UnifiedLibraryItem.fromLocalLibrary(
          LocalLibraryItem.fromJson(row),
        ).toTrack();
      }
    }
  } on Object catch (error) {
    _log.w('Could not resolve ${song.id}: $error');
  }
  return linkTrackFromSongInfo(song);
}

/// A [Track] from the forwarded song fields alone.
Track linkTrackFromSongInfo(LinkSongInfo song) {
  final separator = song.id.indexOf(':');
  final prefix = separator > 0 ? song.id.substring(0, separator) : '';
  return Track(
    id: separator > 0 ? song.id.substring(separator + 1) : song.id,
    name: song.title,
    artistName: song.artist,
    albumName: song.album ?? '',
    albumArtist: song.albumArtist,
    isrc: song.isrc,
    duration: ((song.durationMs ?? 0) / 1000).round(),
    source: prefix == 'l' ? 'local' : null,
  );
}

final _registered = Expando<bool>('linkSyncHandlers');

/// Registers the collections and history sync endpoints and the Subsonic
/// playlist, star and scrobble ops on the desktop's [router]. Handlers read
/// providers through [ref] per request. Also watches local collection edits
/// and calls [linkCollectionsChangedHookProvider] (debounced) when this
/// desktop authored new changes. Safe to call again on server restart.
void registerLinkSyncHandlers(LinkHostRouter router, Ref ref) {
  final handlers = _LinkSyncHandlers(ref);
  router
    ..register(LinkOps.collections, handlers.collections)
    ..register(LinkOps.history, handlers.history)
    ..register(LinkSyncSubsonicOps.getPlaylists, handlers.getPlaylists)
    ..register(LinkSyncSubsonicOps.getPlaylist, handlers.getPlaylist)
    ..register(LinkSyncSubsonicOps.createPlaylist, handlers.createPlaylist)
    ..register(LinkSyncSubsonicOps.updatePlaylist, handlers.updatePlaylist)
    ..register(LinkSyncSubsonicOps.deletePlaylist, handlers.deletePlaylist)
    ..register(LinkSyncSubsonicOps.star, (request) => handlers.star(request))
    ..register(
      LinkSyncSubsonicOps.unstar,
      (request) => handlers.star(request, starred: false),
    )
    ..register(LinkSyncSubsonicOps.getStarred, handlers.getStarred)
    ..register(LinkSyncSubsonicOps.scrobble, handlers.scrobble);
  if (_registered[ref] != true) {
    _registered[ref] = true;
    handlers.watchLocalChanges();
  }
}

String? _string(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

Track? _decodeTrack(Object? json) {
  if (json is! String) return null;
  try {
    final decoded = jsonDecode(json);
    return decoded is Map
        ? Track.fromJson(Map<String, dynamic>.from(decoded))
        : null;
  } on Object {
    return null;
  }
}

/// A playlist member in playlist order and its catalog song, if any.
typedef _Member = ({String key, String? songId});

class _LinkSyncHandlers {
  _LinkSyncHandlers(this.ref);

  final Ref ref;

  LinkCollectionSyncStore get _store =>
      ref.read(linkCollectionSyncStoreProvider);
  LibraryCollectionsNotifier get _collections =>
      ref.read(libraryCollectionsProvider.notifier);

  /// The catalog song id for [track] when the catalog still serves it.
  String? _songId(LinkCatalogIndex? index, Track? track) {
    if (index == null || track == null) return null;
    final id = index.songIdForTrack(track);
    return id != null && index.songById(id) != null ? id : null;
  }

  void _notifyPhones() => ref.read(linkCollectionsChangedHookProvider)?.call();

  /// The database changed underneath the collections provider.
  void _collectionsChangedByPeer() {
    unawaited(
      _collections.reloadFromDatabase().catchError((Object error) {
        _log.w('Could not reload collections after sync: $error');
      }),
    );
    _notifyPhones();
  }

  void watchLocalChanges() {
    Timer? timer;
    int? notified;
    unawaited(
      _store.latestLocalSeq().then(
        (seq) => notified ??= seq,
        onError: (Object _) => notified ??= 0,
      ),
    );
    final subscription = ref.listen(libraryCollectionsProvider, (_, _) {
      timer?.cancel();
      timer = Timer(ref.read(linkSyncSettingsProvider).localDebounce, () async {
        try {
          final seq = await _store.latestLocalSeq();
          if (seq > (notified ?? 0)) {
            notified = seq;
            _notifyPhones();
          }
        } on Object catch (error) {
          _log.w('Could not check local collection changes: $error');
        }
      });
    });
    ref.onDispose(() {
      timer?.cancel();
      subscription.close();
      // A rebuilt host registers again and watches anew.
      _registered[ref] = null;
    });
  }

  Future<Object?> collections(LinkRequest request) async {
    final args = request.args;
    if (request.method == 'GET') {
      final page = await _store.changesSince(
        linkSyncInt(args['since']) ?? 0,
        excludeOrigin: _string(args['device']),
        limit: linkSyncInt(args['limit']) ?? linkSyncPageSize,
      );
      return page.toJson('changes', (change) => change.toJson());
    }
    final raw = args['changes'];
    if (raw is! List) {
      throw const LinkException('invalid', 'changes must be a list');
    }
    if (raw.length > linkSyncPageSize * 4) {
      throw const LinkException('invalid', 'Too many changes in one request');
    }
    final device = _string(args['device']);
    final result = await _store.apply([
      for (final item in raw)
        ?LinkSyncChange.fromJson(item, fallbackOrigin: device),
    ]);
    if (result.applied > 0) _collectionsChangedByPeer();
    return {'applied': result.applied, 'cursor': result.latest};
  }

  Future<Object?> history(LinkRequest request) async {
    final args = request.args;
    final store = ref.read(linkHistorySyncStoreProvider);
    if (request.method == 'GET') {
      final page = await store.eventsSince(
        linkSyncInt(args['since']) ?? 0,
        excludeOrigin: _string(args['device']),
        limit: linkSyncInt(args['limit']) ?? linkSyncPageSize,
      );
      return page.toJson('events', (event) => event.toJson());
    }
    final raw = args['events'];
    if (raw is! List) {
      throw const LinkException('invalid', 'events must be a list');
    }
    if (raw.length > linkSyncPageSize * 4) {
      throw const LinkException('invalid', 'Too many events in one request');
    }
    final device = _string(args['device']);
    final result = await store.apply([
      for (final item in raw)
        ?LinkHistoryEvent.fromJson(item, fallbackOrigin: device),
    ]);
    if (result.applied > 0) refreshLinkListeningProviders(ref);
    return {'applied': result.applied, 'cursor': result.latest};
  }

  Future<List<_Member>> _members(
    DatabaseExecutor db,
    String playlistId,
    LinkCatalogIndex? index,
  ) async {
    final rows = await db.rawQuery(
      'SELECT track_key, track_json FROM playlist_tracks '
      'WHERE playlist_id = ? ORDER BY added_at ASC, rowid ASC',
      [playlistId],
    );
    return [
      for (final row in rows)
        (
          key: row['track_key']! as String,
          songId: _songId(index, _decodeTrack(row['track_json'])),
        ),
    ];
  }

  Map<String, dynamic> _playlistJson(
    Map<String, Object?> row,
    List<_Member> members,
  ) => {
    'id': row['id'],
    'name': row['name'] as String? ?? '',
    'songIds': [
      for (final member in members)
        if (member.songId != null) member.songId,
    ],
    'createdMs': linkSyncIsoToMs(row['created_at']) ?? 0,
    'changedMs': linkSyncIsoToMs(row['updated_at']) ?? 0,
  };

  Future<Map<String, Object?>?> _playlistRow(
    DatabaseExecutor db,
    String id,
  ) async {
    final rows = await db.rawQuery(
      'SELECT id, name, created_at, updated_at FROM playlists WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, dynamic>> _playlistReply(String id) async {
    final db = await _store.database;
    final row = await _playlistRow(db, id);
    if (row == null) {
      throw LinkException('not_found', 'No playlist $id');
    }
    final index = ref.read(linkCatalogIndexProvider);
    return {'playlist': _playlistJson(row, await _members(db, id, index))};
  }

  String _requiredId(LinkRequest request, String name) {
    final id = _string(request.args[name]);
    if (id == null) throw LinkException('invalid', '$name is required');
    return id;
  }

  Future<List<Track>> _tracks(Object? songs) async {
    final resolve = ref.read(linkSongTrackResolverProvider);
    return [
      for (final song in LinkSongInfo.listFromJson(songs)) await resolve(song),
    ];
  }

  Future<Object?> getPlaylists(LinkRequest request) async {
    final db = await _store.database;
    final index = ref.read(linkCatalogIndexProvider);
    final rows = await db.rawQuery(
      'SELECT id, name, created_at, updated_at FROM playlists '
      'ORDER BY created_at DESC, rowid DESC',
    );
    return {
      'playlists': [
        for (final row in rows)
          _playlistJson(row, await _members(db, row['id']! as String, index)),
      ],
    };
  }

  Future<Object?> getPlaylist(LinkRequest request) =>
      _playlistReply(_requiredId(request, 'id'));

  /// Subsonic `createPlaylist`: a new playlist, or with `playlistId` the
  /// existing playlist's songs replaced (and renamed when `name` is set).
  Future<Object?> createPlaylist(LinkRequest request) async {
    final existingId = _string(request.args['playlistId']);
    final name = _string(request.args['name']);
    final tracks = await _tracks(request.args['songs']);
    final collections = _collections;
    final String id;
    if (existingId != null) {
      final db = await _store.database;
      if (await _playlistRow(db, existingId) == null) {
        throw LinkException('not_found', 'No playlist $existingId');
      }
      id = existingId;
      final members = await _members(db, id, null);
      await collections.removeTracksFromPlaylist(
        id,
        members.map((member) => member.key),
      );
      if (name != null) await collections.renamePlaylist(id, name);
    } else if (name == null) {
      throw const LinkException('invalid', 'name is required');
    } else {
      id = await collections.createPlaylist(name);
    }
    if (tracks.isNotEmpty) await collections.addTracksToPlaylist(id, tracks);
    return _playlistReply(id);
  }

  /// Subsonic `updatePlaylist`: rename, remove by index into the song list
  /// `getPlaylist` returned, then append. `comment` has no app field.
  Future<Object?> updatePlaylist(LinkRequest request) async {
    final id = _requiredId(request, 'playlistId');
    final db = await _store.database;
    if (await _playlistRow(db, id) == null) {
      throw LinkException('not_found', 'No playlist $id');
    }
    final collections = _collections;
    final name = _string(request.args['name']);
    if (name != null) await collections.renamePlaylist(id, name);
    final rawIndexes = request.args['songIndexesToRemove'];
    final indexes = {
      if (rawIndexes is List)
        for (final value in rawIndexes) ?linkSyncInt(value),
    };
    if (indexes.isNotEmpty) {
      final listed = [
        for (final member in await _members(
          db,
          id,
          ref.read(linkCatalogIndexProvider),
        ))
          if (member.songId != null) member.key,
      ];
      await collections.removeTracksFromPlaylist(id, [
        for (final index in indexes)
          if (index >= 0 && index < listed.length) listed[index],
      ]);
    }
    final tracks = await _tracks(request.args['songsToAdd']);
    if (tracks.isNotEmpty) await collections.addTracksToPlaylist(id, tracks);
    return const <String, dynamic>{};
  }

  Future<Object?> deletePlaylist(LinkRequest request) async {
    final id = _requiredId(request, 'id');
    final db = await _store.database;
    if (await _playlistRow(db, id) == null) {
      throw LinkException('not_found', 'No playlist $id');
    }
    await _collections.deletePlaylists([id]);
    return const <String, dynamic>{};
  }

  /// Subsonic `star` and `unstar`: songs are loved tracks, artists favorite
  /// artists (matched by name). Album stars have no app collection and are
  /// ignored.
  Future<Object?> star(LinkRequest request, {bool starred = true}) async {
    final db = await _store.database;
    final collections = _collections;
    final index = ref.read(linkCatalogIndexProvider);
    final songs = LinkSongInfo.listFromJson(request.args['songs']);
    if (songs.isNotEmpty) {
      final loved = await db.rawQuery(
        'SELECT track_key, track_json FROM loved_tracks',
      );
      final keysBySong = <String, List<String>>{};
      final lovedKeys = <String>{};
      for (final row in loved) {
        final key = row['track_key']! as String;
        lovedKeys.add(key);
        final songId = _songId(index, _decodeTrack(row['track_json']));
        if (songId != null) keysBySong.putIfAbsent(songId, () => []).add(key);
      }
      final resolve = ref.read(linkSongTrackResolverProvider);
      if (starred) {
        final additions = <String, Track>{};
        for (final song in songs) {
          if (keysBySong.containsKey(song.id)) continue;
          final track = await resolve(song);
          final key = trackCollectionKey(track);
          if (!lovedKeys.contains(key)) additions[key] = track;
        }
        if (additions.isNotEmpty) {
          await collections.toggleLovedTracks(additions.values);
        }
      } else {
        final removals = <String>{};
        for (final song in songs) {
          removals.addAll(keysBySong[song.id] ?? const []);
          final key = trackCollectionKey(await resolve(song));
          if (lovedKeys.contains(key)) removals.add(key);
        }
        if (removals.isNotEmpty) await collections.removeLovedTracks(removals);
      }
    }
    final artists = request.args['artists'];
    if (artists is List && artists.isNotEmpty) {
      final favorites = await _favoriteArtists(db);
      for (final artist in artists.whereType<Map<Object?, Object?>>()) {
        final id = _string(artist['id']);
        final name = _string(artist['name']);
        if (id == null) continue;
        final matches = [
          for (final favorite in favorites)
            if (favorite.catalogId == id || favorite.artistId == id)
              favorite.key,
        ];
        if (starred && matches.isEmpty && name != null) {
          await collections.toggleFavoriteArtist(
            artistId: id,
            providerId: null,
            name: name,
          );
        } else if (!starred) {
          for (final key in matches) {
            await collections.removeFavoriteArtist(key);
          }
        }
      }
    }
    return const <String, dynamic>{};
  }

  Future<List<({String key, String artistId, String catalogId})>>
  _favoriteArtists(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      'SELECT artist_key, artist_json FROM favorite_artists '
      'ORDER BY added_at DESC, rowid DESC',
    );
    final favorites = <({String key, String artistId, String catalogId})>[];
    for (final row in rows) {
      try {
        final json = jsonDecode(row['artist_json']! as String);
        if (json is! Map) continue;
        final name = json['name'];
        if (name is! String || name.trim().isEmpty) continue;
        final artistId = json['artistId'];
        favorites.add((
          key: row['artist_key']! as String,
          artistId: artistId is String ? artistId : '',
          catalogId: linkCatalogArtistId(name),
        ));
      } on FormatException {
        continue;
      }
    }
    return favorites;
  }

  Future<Object?> getStarred(LinkRequest request) async {
    final db = await _store.database;
    final index = ref.read(linkCatalogIndexProvider);
    final loved = await db.rawQuery(
      'SELECT track_json FROM loved_tracks ORDER BY added_at DESC, rowid DESC',
    );
    final songIds = <String>{
      for (final row in loved) ?_songId(index, _decodeTrack(row['track_json'])),
    };
    final artistIds = <String>{
      for (final favorite in await _favoriteArtists(db)) favorite.catalogId,
    };
    return {
      'songIds': songIds.toList(),
      'albumIds': const <String>[],
      'artistIds': artistIds.toList(),
    };
  }

  /// Subsonic `scrobble`: a submission counts one full play of each song
  /// as this desktop's listening; "now playing" notifications are ignored.
  Future<Object?> scrobble(LinkRequest request) async {
    if (request.args['submission'] == false) return const <String, dynamic>{};
    final songs = LinkSongInfo.listFromJson(request.args['songs']);
    final rawTimes = request.args['timesMs'];
    final times = rawTimes is List ? rawTimes : const <Object?>[];
    final now = DateTime.now().millisecondsSinceEpoch;
    final deltas = <ListeningDelta>[];
    for (final (position, song) in songs.indexed) {
      final time = position < times.length
          ? linkSyncInt(times[position])
          : null;
      deltas.add(
        ListeningDelta(
          listeningDay(DateTime.fromMillisecondsSinceEpoch(time ?? now)),
          ListeningTrack(
            key: song.path ?? song.id,
            title: song.title,
            artist: song.artist,
            album: song.album ?? '',
          ),
          song.durationMs ?? 0,
          1,
        ),
      );
    }
    await ref.read(linkHistorySyncStoreProvider).record(deltas);
    if (deltas.isNotEmpty) refreshLinkListeningProviders(ref);
    return const <String, dynamic>{};
  }
}
