import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:mornye/models/track.dart';

enum LibraryTracksFolderMode { wishlist, loved, playlist }

/// Shared identity for catalog, downloaded, and local playlist entries.
String libraryTrackCollectionKey({
  required String id,
  String? source,
  String? isrc,
}) {
  final trimmedIsrc = isrc?.trim();
  if (trimmedIsrc != null && trimmedIsrc.isNotEmpty) {
    return 'isrc:${trimmedIsrc.toUpperCase()}';
  }
  final trimmedSource = source?.trim();
  return '${trimmedSource?.isNotEmpty == true ? trimmedSource : 'builtin'}:$id';
}

String trackCollectionKey(Track track) => libraryTrackCollectionKey(
  id: track.id,
  source: track.source,
  isrc: track.isrc,
);

/// Stable entry keys preserve repeated positions when importing a playlist.
/// The first occurrence keeps the existing membership key, so re-importing
/// fills missing occurrences without appending the entire playlist again.
Iterable<String> playlistImportKeys(Iterable<Track> tracks) sync* {
  final occurrences = <String, int>{};
  for (final track in tracks) {
    final key = trackCollectionKey(track);
    final count = occurrences.update(
      key,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    yield count == 1 ? key : 'occurrence:$count:$key';
  }
}

String collectionArtistId(String value) {
  final colonIndex = value.indexOf(':');
  if (colonIndex <= 0 || colonIndex == value.length - 1) {
    return value.trim();
  }
  return value.substring(colonIndex + 1).trim();
}

String artistCollectionKey({
  required String artistId,
  required String? providerId,
}) {
  final trimmedArtistId = artistId.trim();
  final trimmedProviderId = providerId?.trim();
  final source = trimmedProviderId != null && trimmedProviderId.isNotEmpty
      ? trimmedProviderId.toLowerCase()
      : (trimmedArtistId.contains(':')
            ? trimmedArtistId.split(':').first.toLowerCase()
            : 'builtin');
  return '$source:${collectionArtistId(trimmedArtistId)}';
}

class CollectionTrackEntry {
  final String key;
  final Track track;
  final DateTime addedAt;

  const CollectionTrackEntry({
    required this.key,
    required this.track,
    required this.addedAt,
  });

  Map<String, dynamic> toJson() => {
    'key': key,
    'track': track.toJson(),
    'addedAt': addedAt.toIso8601String(),
  };
}

class CollectionArtistEntry {
  final String key;
  final String artistId;
  final String? providerId;
  final String name;
  final String? imageUrl;
  final DateTime addedAt;

  const CollectionArtistEntry({
    required this.key,
    required this.artistId,
    required this.providerId,
    required this.name,
    this.imageUrl,
    required this.addedAt,
  });

  Map<String, dynamic> toJson() => {
    'key': key,
    'artistId': artistId,
    'providerId': providerId,
    'name': name,
    'imageUrl': imageUrl,
    'addedAt': addedAt.toIso8601String(),
  };

  factory CollectionArtistEntry.fromJson(Map<String, dynamic> json) {
    final artistId = json['artistId'] as String;
    final providerId = json['providerId'] as String?;
    final addedAtRaw = json['addedAt'] as String?;
    return CollectionArtistEntry(
      key:
          json['key'] as String? ??
          artistCollectionKey(artistId: artistId, providerId: providerId),
      artistId: artistId,
      providerId: providerId,
      name: json['name'] as String? ?? '',
      imageUrl: json['imageUrl'] as String?,
      addedAt: DateTime.tryParse(addedAtRaw ?? '') ?? DateTime.now(),
    );
  }
}

class UserPlaylistCollection {
  final String id;
  final String name;
  final String? coverImagePath;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<CollectionTrackEntry> tracks;
  final String? previewCover;
  final bool tracksLoaded;
  final Set<String> _trackKeys;

  UserPlaylistCollection({
    required this.id,
    required this.name,
    this.coverImagePath,
    required this.createdAt,
    required this.updatedAt,
    required this.tracks,
    this.previewCover,
    this.tracksLoaded = true,
    Set<String>? trackKeys,
  }) : _trackKeys = trackKeys ?? tracks.map((entry) => entry.key).toSet();

  UserPlaylistCollection copyWith({
    String? id,
    String? name,
    String? Function()? coverImagePath,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<CollectionTrackEntry>? tracks,
    String? previewCover,
    bool? tracksLoaded,
  }) {
    final nextTracks = tracks ?? this.tracks;
    final keepTrackIndex = identical(nextTracks, this.tracks);
    return UserPlaylistCollection(
      id: id ?? this.id,
      name: name ?? this.name,
      coverImagePath: coverImagePath != null
          ? coverImagePath()
          : this.coverImagePath,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      tracks: nextTracks,
      previewCover: previewCover ?? this.previewCover,
      tracksLoaded:
          tracksLoaded ??
          (identical(nextTracks, this.tracks) ? this.tracksLoaded : true),
      trackKeys: keepTrackIndex ? _trackKeys : null,
    );
  }

  bool containsTrackKey(String trackKey) {
    return _trackKeys.contains(trackKey);
  }

  bool sharesMembershipIndexWith(UserPlaylistCollection other) =>
      identical(_trackKeys, other._trackKeys);

  /// Publishes tracks and their index built by the hydration worker. When it
  /// verified unchanged membership, keep the original index so the enclosing
  /// collections state need not rescan every other playlist's tracks.
  UserPlaylistCollection withHydratedTracks({
    required List<CollectionTrackEntry> tracks,
    required Set<String> trackKeys,
    required bool membershipUnchanged,
  }) => UserPlaylistCollection(
    id: id,
    name: name,
    coverImagePath: coverImagePath,
    createdAt: createdAt,
    updatedAt: updatedAt,
    tracks: tracks,
    previewCover: previewCover,
    tracksLoaded: true,
    trackKeys: membershipUnchanged ? _trackKeys : trackKeys,
  );

  Set<String> get trackKeys => UnmodifiableSetView(_trackKeys);
  int get trackCount => _trackKeys.length;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (coverImagePath != null) 'coverImagePath': coverImagePath,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'tracks': tracks.map((e) => e.toJson()).toList(),
  };
}

/// A bounded database projection shared directly with playlist picker UI.
class PlaylistPickerSummary {
  final String id;
  final String name;
  final String? coverImagePath;
  final String? previewCover;
  final int trackCount;
  final bool containsAllRequestedTracks;

  const PlaylistPickerSummary({
    required this.id,
    required this.name,
    this.coverImagePath,
    this.previewCover,
    required this.trackCount,
    required this.containsAllRequestedTracks,
  });
}

class PlaylistPickerSummaryRequest {
  final List<String> trackKeys;

  PlaylistPickerSummaryRequest._(this.trackKeys);

  factory PlaylistPickerSummaryRequest.fromTracks(
    Iterable<Track> tracks, {
    bool preserveOccurrences = false,
  }) {
    final keys =
        (preserveOccurrences
                ? playlistImportKeys(tracks)
                : tracks.map(trackCollectionKey))
            .where((key) => key.trim().isNotEmpty)
            .toSet()
            .toList(growable: false)
          ..sort();
    return PlaylistPickerSummaryRequest._(List.unmodifiable(keys));
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaylistPickerSummaryRequest &&
          listEquals(trackKeys, other.trackKeys);

  @override
  int get hashCode => Object.hashAll(trackKeys);
}

class LibraryCollectionsState {
  final List<CollectionTrackEntry> wishlist;
  final List<CollectionTrackEntry> loved;
  final List<UserPlaylistCollection> playlists;
  final List<CollectionArtistEntry> favoriteArtists;
  final bool isLoaded;
  final Set<String> _wishlistKeys;
  final Set<String> _lovedKeys;
  final Set<String> _favoriteArtistKeys;
  final Map<String, UserPlaylistCollection> _playlistsById;
  final Set<String> _allPlaylistTrackKeys;

  LibraryCollectionsState({
    this.wishlist = const [],
    this.loved = const [],
    this.playlists = const [],
    this.favoriteArtists = const [],
    this.isLoaded = false,
    Set<String>? wishlistKeys,
    Set<String>? lovedKeys,
    Set<String>? favoriteArtistKeys,
    Map<String, UserPlaylistCollection>? playlistsById,
    Set<String>? allPlaylistTrackKeys,
  }) : _wishlistKeys =
           wishlistKeys ?? wishlist.map((entry) => entry.key).toSet(),
       _lovedKeys = lovedKeys ?? loved.map((entry) => entry.key).toSet(),
       _favoriteArtistKeys =
           favoriteArtistKeys ??
           favoriteArtists.map((entry) => entry.key).toSet(),
       _playlistsById =
           playlistsById ??
           Map.fromEntries(
             playlists.map((playlist) => MapEntry(playlist.id, playlist)),
           ),
       _allPlaylistTrackKeys =
           allPlaylistTrackKeys ?? _buildPlaylistTrackKeys(playlists);

  int get wishlistCount => wishlist.length;
  int get lovedCount => loved.length;
  int get playlistCount => playlists.length;
  int get favoriteArtistCount => favoriteArtists.length;

  bool isInWishlist(Track track) {
    final key = trackCollectionKey(track);
    return _wishlistKeys.contains(key);
  }

  bool isLoved(Track track) {
    final key = trackCollectionKey(track);
    return _lovedKeys.contains(key);
  }

  bool containsWishlistKey(String trackKey) {
    return _wishlistKeys.contains(trackKey);
  }

  bool containsLovedKey(String trackKey) {
    return _lovedKeys.contains(trackKey);
  }

  bool isFavoriteArtist({
    required String artistId,
    required String? providerId,
  }) {
    final key = artistCollectionKey(artistId: artistId, providerId: providerId);
    return _favoriteArtistKeys.contains(key);
  }

  bool containsFavoriteArtistKey(String artistKey) {
    return _favoriteArtistKeys.contains(artistKey);
  }

  UserPlaylistCollection? playlistById(String playlistId) {
    return _playlistsById[playlistId];
  }

  bool isTrackInAnyPlaylist(String trackKey) {
    return _allPlaylistTrackKeys.contains(trackKey);
  }

  bool get hasPlaylistTracks => _allPlaylistTrackKeys.isNotEmpty;

  LibraryCollectionsState copyWith({
    List<CollectionTrackEntry>? wishlist,
    List<CollectionTrackEntry>? loved,
    List<UserPlaylistCollection>? playlists,
    List<CollectionArtistEntry>? favoriteArtists,
    bool? isLoaded,
  }) {
    final nextWishlist = wishlist ?? this.wishlist;
    final nextLoved = loved ?? this.loved;
    final nextPlaylists = playlists ?? this.playlists;
    final nextFavoriteArtists = favoriteArtists ?? this.favoriteArtists;
    final keepWishlistIndex = identical(nextWishlist, this.wishlist);
    final keepLovedIndex = identical(nextLoved, this.loved);
    final keepPlaylistIndex = identical(nextPlaylists, this.playlists);
    final keepFavoriteArtistIndex = identical(
      nextFavoriteArtists,
      this.favoriteArtists,
    );

    return LibraryCollectionsState(
      wishlist: nextWishlist,
      loved: nextLoved,
      playlists: nextPlaylists,
      favoriteArtists: nextFavoriteArtists,
      isLoaded: isLoaded ?? this.isLoaded,
      wishlistKeys: keepWishlistIndex ? _wishlistKeys : null,
      lovedKeys: keepLovedIndex ? _lovedKeys : null,
      favoriteArtistKeys: keepFavoriteArtistIndex ? _favoriteArtistKeys : null,
      playlistsById: keepPlaylistIndex ? _playlistsById : null,
      allPlaylistTrackKeys:
          keepPlaylistIndex || _hasSamePlaylistMembership(nextPlaylists)
          ? _allPlaylistTrackKeys
          : null,
    );
  }

  bool _hasSamePlaylistMembership(List<UserPlaylistCollection> nextPlaylists) {
    if (nextPlaylists.length != playlists.length ||
        _playlistsById.length != playlists.length) {
      return false;
    }
    final seen = <String>{};
    for (final playlist in nextPlaylists) {
      final previous = _playlistsById[playlist.id];
      if (!seen.add(playlist.id) ||
          previous == null ||
          !identical(previous._trackKeys, playlist._trackKeys)) {
        return false;
      }
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
    'wishlist': wishlist.map((e) => e.toJson()).toList(),
    'loved': loved.map((e) => e.toJson()).toList(),
    'playlists': playlists.map((e) => e.toJson()).toList(),
    'favoriteArtists': favoriteArtists.map((e) => e.toJson()).toList(),
  };
}

Set<String> _buildPlaylistTrackKeys(List<UserPlaylistCollection> playlists) {
  final keys = <String>{};
  for (final playlist in playlists) {
    keys.addAll(playlist._trackKeys);
  }
  return keys;
}

class PlaylistAddBatchResult {
  final int addedCount;
  final int alreadyInPlaylistCount;

  const PlaylistAddBatchResult({
    required this.addedCount,
    required this.alreadyInPlaylistCount,
  });
}
