import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/album_track_order.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/track_file_resolver.dart';
import 'package:mornye/utils/file_access.dart' show isCueVirtualPath;

/// The songs a media browser item plays, the one to start at, and whether
/// playing it turns shuffle on.
typedef BrowserQueue = ({List<PlayableMedia> items, int index, bool shuffle});

/// The Library as media browsers such as Android Auto show it: tabs for
/// songs, albums, artists and playlists, a search, and the queue each item
/// plays. Item ids are `mornye-browse:` URIs, apart from the queue's own ids.
class MediaLibraryBrowser {
  MediaLibraryBrowser({
    required this.library,
    required this.history,
    required this.collections,
    required this.includeLocal,
    required this.strings,
  });

  final LibraryDatabase library;
  final HistoryDatabase history;
  final LibraryCollectionsDatabase collections;

  /// Whether scanned songs belong to the Library, as on the Library tab.
  final bool Function() includeLocal;
  final AppLocalizations Function() strings;

  static const _scheme = 'mornye-browse';

  /// The most items one list shows. Cars cut long lists short while driving,
  /// and a search reaches the rest.
  static const listLimit = 500;

  static const songsId = '$_scheme:songs';
  static const albumsId = '$_scheme:albums';
  static const artistsId = '$_scheme:artists';
  static const playlistsId = '$_scheme:playlists';
  static const shuffleId = '$_scheme:shuffle';
  static const lovedId = '$_scheme:loved';

  /// Extras for [AudioServiceConfig.androidBrowsableRootExtras]: searchable,
  /// with items in lists unless a folder asks for a grid.
  static const rootExtras = <String, dynamic>{
    'android.media.browse.SEARCH_SUPPORTED': true,
    AndroidContentStyle.supportedKey: true,
    AndroidContentStyle.browsableHintKey: AndroidContentStyle.listItemHintValue,
    AndroidContentStyle.playableHintKey: AndroidContentStyle.listItemHintValue,
  };

  static const _gridChildren = <String, dynamic>{
    AndroidContentStyle.browsableHintKey: AndroidContentStyle.gridItemHintValue,
  };
  static const _groupTitleKey =
      'android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT';

  static bool isBrowserId(String id) => id.startsWith('$_scheme:');

  static String _id(String path, Map<String, String> query) =>
      Uri(scheme: _scheme, path: path, queryParameters: query).toString();

  static Uri? _parse(String id) {
    final uri = Uri.tryParse(id);
    return uri?.scheme == _scheme ? uri : null;
  }

  Future<List<MediaItem>> children(
    String parentId, [
    Map<String, dynamic>? options,
  ]) async {
    if (parentId == AudioService.browsableRootId) return _tabs();
    final uri = _parse(parentId);
    if (uri == null) return const [];
    final query = uri.queryParameters;
    final items = switch (uri.path) {
      'songs' => [
        _shuffleItem(),
        ..._trackItems(songsId, await _librarySongs(limit: listLimit)),
      ],
      'albums' => await _albumItems(),
      'artists' => await _artistItems(),
      'playlists' => await _playlistItems(),
      'album' => _trackItems(parentId, await _albumSongs(query)),
      'artist' => await _albumItems(artist: query['name'] ?? ''),
      'loved' => _trackItems(parentId, await _lovedSongs()),
      'playlist' => _trackItems(
        parentId,
        await _playlistSongs(query['id'] ?? ''),
      ),
      _ => const <MediaItem>[],
    };
    return _page(items, options);
  }

  /// One page when the browser asks for pages, otherwise every item.
  static List<MediaItem> _page(
    List<MediaItem> items,
    Map<String, dynamic>? options,
  ) {
    final page = options?['android.media.browse.extra.PAGE'];
    final size = options?['android.media.browse.extra.PAGE_SIZE'];
    if (page is! int || size is! int || page < 0 || size <= 0) return items;
    final start = min(page * size, items.length);
    return items.sublist(start, min(start + size, items.length));
  }

  List<MediaItem> _tabs() {
    final l10n = strings();
    return [
      MediaItem(id: songsId, title: l10n.searchSongs, playable: false),
      MediaItem(
        id: albumsId,
        title: l10n.searchAlbums,
        playable: false,
        extras: _gridChildren,
      ),
      MediaItem(id: artistsId, title: l10n.searchArtists, playable: false),
      MediaItem(id: playlistsId, title: l10n.searchPlaylists, playable: false),
    ];
  }

  MediaItem _shuffleItem() =>
      MediaItem(id: shuffleId, title: strings().nowPlayingShuffleLibrary);

  /// Artwork a car can load. It cannot open the app's own files, so local
  /// covers are left out of lists; the playing song keeps its artwork. Nor
  /// can it load the loopback URLs older builds stored in collections.
  static Uri? _browserArt(String? art) =>
      art != null &&
          art.startsWith('http') &&
          durableCoverReference(art) != null
      ? Uri.tryParse(art)
      : null;

  static Map<String, dynamic>? _group(String? title) =>
      title == null ? null : {_groupTitleKey: title};

  List<MediaItem> _trackItems(
    String parentId,
    List<PlayableMedia> songs, {
    String? group,
  }) => [
    for (final media in songs)
      MediaItem(
        id: _id('track', {'parent': parentId, 'path': media.source}),
        title: media.title.isEmpty ? strings().unknownTitle : media.title,
        artist: media.artist.isEmpty ? null : media.artist,
        album: media.album.isEmpty ? null : media.album,
        duration: media.duration,
        artUri: _browserArt(media.artUri),
        extras: _group(group),
      ),
  ];

  MediaItem _albumItem({
    required String source,
    required String name,
    required String artist,
    String? key,
    String? cover,
    String? group,
  }) => MediaItem(
    id: _id('album', {
      'source': source,
      'key': ?key,
      'name': name,
      'artist': artist,
    }),
    title: name.isEmpty ? strings().unknownTitle : name,
    artist: artist.isEmpty ? null : artist,
    artUri: _browserArt(cover),
    playable: false,
    extras: _group(group),
  );

  MediaItem _artistItem(String name, {String? cover, String? group}) =>
      MediaItem(
        id: _id('artist', {'name': name}),
        title: name,
        artUri: _browserArt(cover),
        playable: false,
        extras: {..._gridChildren, ...?_group(group)},
      );

  MediaItem _playlistItem(
    ({String id, String name, int trackCount, String? coverUrl}) playlist, {
    String? group,
  }) => MediaItem(
    id: _id('playlist', {'id': playlist.id}),
    title: playlist.name,
    artUri: _browserArt(playlist.coverUrl),
    playable: false,
    extras: _group(group),
  );

  Future<List<MediaItem>> _albumItems({String? artist}) async {
    final page = await library.getQueueAlbumPageResult(
      QueueLibraryDbQuery(
        includeSingleTrackAlbums: true,
        albumArtist: artist,
        limit: listLimit,
        sortMode: 'a-z',
        includeLocal: includeLocal(),
      ),
    );
    return [
      for (final row in page.rows)
        _albumItem(
          source: row['queue_source'] as String? ?? '',
          key: row['album_key'] as String?,
          name: row['album_name'] as String? ?? '',
          artist: row['artist_name'] as String? ?? '',
          cover: row['cover_url'] as String?,
        ),
    ];
  }

  Future<List<MediaItem>> _artistItems() async {
    final rows = await library.getQueueArtistPage(
      QueueLibraryDbQuery(limit: listLimit, includeLocal: includeLocal()),
    );
    return [
      for (final row in rows)
        if ((row['artist_name'] as String? ?? '').isNotEmpty)
          _artistItem(
            row['artist_name'] as String,
            cover: row['cover_url'] as String?,
          ),
    ];
  }

  Future<List<MediaItem>> _playlistItems() async => [
    MediaItem(id: lovedId, title: strings().collectionLoved, playable: false),
    for (final playlist in await collections.loadPlaylistSummaries())
      if (playlist.trackCount > 0) _playlistItem(playlist),
  ];

  /// Songs that play in the built-in player: a file, not a CUE track that
  /// needs splitting first.
  static List<PlayableMedia> _playable(Iterable<PlayableMedia> songs) => [
    for (final media in songs)
      if (media.source.trim().isNotEmpty && !isCueVirtualPath(media.source))
        media,
  ];

  /// Every Library song in Library order, downloads and enabled scanned
  /// sources alike.
  Future<List<PlayableMedia>> librarySongs() => _librarySongs();

  /// The Library songs in Library order, or the first [limit] of them.
  Future<List<PlayableMedia>> _librarySongs({int? limit}) async {
    const pageSize = 1000;
    final songs = <PlayableMedia>[];
    QueueLibraryDbCursor? cursor;
    for (var offset = 0; limit == null || offset < limit; offset += pageSize) {
      final size = limit == null ? pageSize : min(pageSize, limit - offset);
      final page = await library.getQueueTrackPageResult(
        QueueLibraryDbQuery(
          includeLocal: includeLocal(),
          limit: size,
          offset: offset,
          cursor: cursor,
        ),
      );
      for (final row in page.rows) {
        final item = Map<String, dynamic>.from(row['item'] as Map);
        final media = switch (row['source']) {
          'local' => playableFromLocal(LocalLibraryItem.fromJson(item)),
          'downloaded' => playableFromHistory(
            DownloadHistoryItem.fromJson(item),
          ),
          _ => null,
        };
        if (media != null) songs.add(media);
      }
      if (page.rows.length < size) break;
      cursor = page.nextCursor;
    }
    return _playable(songs);
  }

  Future<List<PlayableMedia>> _albumSongs(Map<String, String> album) async {
    if (album['source'] == 'local') {
      final rows = await library.getQueueLocalAlbumTracksByKey(
        album['key'] ?? '',
      );
      return _playable(
        AlbumTrackOrder(
          rows.map(LocalLibraryItem.fromJson),
          discNumber: (track) => track.discNumber,
          trackNumber: (track) => track.trackNumber,
          trackName: (track) => track.trackName,
        ).tracks.map(playableFromLocal),
      );
    }
    final rows = await history.getAlbumTracks(
      album['name'] ?? '',
      album['artist'] ?? '',
    );
    return _playable(
      AlbumTrackOrder(
        rows.map(DownloadHistoryItem.fromJson),
        discNumber: (track) => track.discNumber,
        trackNumber: (track) => track.trackNumber,
        trackName: (track) => track.trackName,
      ).tracks.map(playableFromHistory),
    );
  }

  /// An artist's albums one after another, each in album order.
  Future<List<PlayableMedia>> _artistSongs(String name) async {
    final page = await library.getQueueAlbumPageResult(
      QueueLibraryDbQuery(
        includeSingleTrackAlbums: true,
        albumArtist: name,
        limit: listLimit,
        sortMode: 'a-z',
        includeLocal: includeLocal(),
      ),
    );
    final albums = await Future.wait([
      for (final row in page.rows)
        _albumSongs({
          'source': row['queue_source'] as String? ?? '',
          'key': row['album_key'] as String? ?? '',
          'name': row['album_name'] as String? ?? '',
          'artist': row['artist_name'] as String? ?? '',
        }),
    ]);
    return [for (final songs in albums) ...songs];
  }

  Future<List<PlayableMedia>> _collectionSongs(List<Track> tracks) async {
    final (:paths, missingHistoryIds: _) = await resolveTrackFiles(
      tracks,
      library: library,
      history: history,
      includeLocal: includeLocal(),
    );
    return _playable([
      for (var i = 0; i < tracks.length; i++)
        if (paths[i] case final path?) playableFromTrack(tracks[i], path),
    ]);
  }

  Future<List<PlayableMedia>> _lovedSongs() async =>
      _collectionSongs(await collections.loadLovedTracks(limit: listLimit));

  Future<List<PlayableMedia>> _playlistSongs(String id) async =>
      _collectionSongs(
        await collections.loadPlaylistTracks(id, limit: listLimit),
      );

  Future<List<PlayableMedia>> _searchSongs(String query) async {
    final hits = await library.searchLibrary(
      query: query,
      kind: LibrarySearchKind.songs,
      includeLocal: includeLocal(),
    );
    final songs = await Future.wait([
      for (final hit in hits)
        hit.source == 'local'
            ? library
                  .getById(hit.id)
                  .then(
                    (row) => row == null
                        ? null
                        : playableFromLocal(LocalLibraryItem.fromJson(row)),
                  )
            : history
                  .getById(hit.id)
                  .then(
                    (row) => row == null
                        ? null
                        : playableFromHistory(
                            DownloadHistoryItem.fromJson(row),
                          ),
                  ),
    ]);
    return _playable(songs.nonNulls);
  }

  Future<List<({String id, String name, int trackCount, String? coverUrl})>>
  _searchPlaylists(String query) async {
    final search = LibrarySearchQuery(query);
    return [
      for (final playlist in await collections.loadPlaylistSummaries())
        if (playlist.trackCount > 0 && search.matches(playlist.name)) playlist,
    ];
  }

  Future<List<MediaItem>> search(String query) async {
    final text = query.trim();
    if (text.isEmpty) return const [];
    final l10n = strings();
    final (songs, albums, artists, playlists) = await (
      _searchSongs(text),
      library.searchLibrary(
        query: text,
        kind: LibrarySearchKind.albums,
        includeLocal: includeLocal(),
        limit: 20,
      ),
      library.searchLibrary(
        query: text,
        kind: LibrarySearchKind.artists,
        includeLocal: includeLocal(),
        limit: 20,
      ),
      _searchPlaylists(text),
    ).wait;
    return [
      ..._trackItems(
        _id('search', {'q': text}),
        songs,
        group: l10n.searchSongs,
      ),
      for (final hit in albums)
        _albumItem(
          source: hit.source,
          key: hit.id,
          name: hit.title,
          artist: hit.artist,
          cover: hit.cover,
          group: l10n.searchAlbums,
        ),
      for (final hit in artists)
        _artistItem(hit.title, cover: hit.cover, group: l10n.searchArtists),
      for (final playlist in playlists)
        _playlistItem(playlist, group: l10n.searchPlaylists),
    ];
  }

  /// The queue a browser item plays: the songs of the folder a song was
  /// chosen from, starting at that song, or the whole Library shuffled.
  Future<BrowserQueue?> queueFor(String mediaId) async {
    final uri = _parse(mediaId);
    if (uri == null) return null;
    if (uri.path == 'shuffle') return _shuffled(await librarySongs());
    if (uri.path != 'track') return null;
    final parent = _parse(uri.queryParameters['parent'] ?? '');
    final path = uri.queryParameters['path'] ?? '';
    if (parent == null || path.isEmpty) return null;
    final query = parent.queryParameters;
    final songs = switch (parent.path) {
      'songs' => await librarySongs(),
      'album' => await _albumSongs(query),
      'loved' => await _lovedSongs(),
      'playlist' => await _playlistSongs(query['id'] ?? ''),
      'search' => await _searchSongs(query['q'] ?? ''),
      _ => const <PlayableMedia>[],
    };
    final index = songs.indexWhere((media) => media.source == path);
    return index < 0 ? null : (items: songs, index: index, shuffle: false);
  }

  static BrowserQueue? _shuffled(List<PlayableMedia> songs) => songs.isEmpty
      ? null
      : (items: songs, index: Random().nextInt(songs.length), shuffle: true);

  /// What a spoken request such as "play Blue on Mornye" plays: matching
  /// songs, else the first matching album, artist or playlist. [extras] can
  /// name the kind asked for first. An empty request shuffles the Library.
  Future<BrowserQueue?> queueForSearch(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    final text = query.trim();
    if (text.isEmpty) return _shuffled(await librarySongs());
    Future<List<PlayableMedia>> album() async {
      final hits = await library.searchLibrary(
        query: text,
        kind: LibrarySearchKind.albums,
        includeLocal: includeLocal(),
        limit: 1,
      );
      if (hits.isEmpty) return const [];
      final hit = hits.first;
      return _albumSongs({
        'source': hit.source,
        'key': hit.id,
        'name': hit.title,
        'artist': hit.artist,
      });
    }

    Future<List<PlayableMedia>> artist() async {
      final hits = await library.searchLibrary(
        query: text,
        kind: LibrarySearchKind.artists,
        includeLocal: includeLocal(),
        limit: 1,
      );
      return hits.isEmpty ? const [] : _artistSongs(hits.first.title);
    }

    Future<List<PlayableMedia>> playlist() async {
      final matches = await _searchPlaylists(text);
      return matches.isEmpty ? const [] : _playlistSongs(matches.first.id);
    }

    final focus = extras?['android.intent.extra.focus']?.toString() ?? '';
    final order = [
      if (focus.endsWith('/album')) album,
      if (focus.endsWith('/artist')) artist,
      if (focus.endsWith('/playlist')) playlist,
      () => _searchSongs(text),
      album,
      artist,
      playlist,
    ];
    for (final find in order) {
      final songs = await find();
      if (songs.isNotEmpty) return (items: songs, index: 0, shuffle: false);
    }
    return null;
  }
}
