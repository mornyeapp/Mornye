import 'package:json_annotation/json_annotation.dart';
import 'package:mornye/utils/int_utils.dart';
import 'package:mornye/utils/string_utils.dart';

part 'track.g.dart';

@JsonSerializable()
class Track {
  final String id;
  final String name;
  final String artistName;
  final String albumName;
  final String? albumArtist;
  final String? artistId;
  final String? albumId;
  final String? coverUrl;
  final String? headerVideoUrl;
  final String? isrc;
  final String? previewUrl;
  final int duration;
  final int? trackNumber;
  final int? discNumber;
  final int? totalDiscs;
  final String? releaseDate;
  final String? deezerId;
  final ServiceAvailability? availability;
  final String? source;
  final String? albumType;
  final int? totalTracks;
  final String? composer;
  final String? genre;
  final String? label;
  final String? copyright;
  final String? comment;
  final String? itemType;
  final String? audioQuality;
  final String? audioModes;
  final bool? explicit;
  final String? upc;

  const Track({
    required this.id,
    required this.name,
    required this.artistName,
    required this.albumName,
    this.albumArtist,
    this.artistId,
    this.albumId,
    this.coverUrl,
    this.headerVideoUrl,
    this.isrc,
    this.previewUrl,
    required this.duration,
    this.trackNumber,
    this.discNumber,
    this.totalDiscs,
    this.releaseDate,
    this.deezerId,
    this.availability,
    this.source,
    this.albumType,
    this.totalTracks,
    this.composer,
    this.genre,
    this.label,
    this.copyright,
    this.comment,
    this.itemType,
    this.audioQuality,
    this.audioModes,
    this.explicit,
    this.upc,
  });

  bool get isSingle => switch (albumType?.toLowerCase()) {
    'single' || 'ep' => true,
    _ => false,
  };

  bool get isAlbumItem => itemType == 'album';

  bool get isPlaylistItem => itemType == 'playlist';

  bool get isArtistItem => itemType == 'artist';

  bool get isCollection => isAlbumItem || isPlaylistItem || isArtistItem;

  factory Track.fromJson(Map<String, dynamic> json) => _$TrackFromJson(json);
  Map<String, dynamic> toJson() => _$TrackToJson(this);

  /// Builds a [Track] from a backend/extension search payload map.
  factory Track.fromBackendMap(
    Map<String, dynamic> data, {
    String? source,
    String? playlistName,
  }) {
    final durationMs = extractDurationMs(data);

    final itemType = data['item_type']?.toString();
    final effectiveSource =
        source ?? data['source']?.toString() ?? data['provider_id']?.toString();
    final spotifyId = (data['spotify_id'] ?? '').toString();
    final nativeId = (data['id'] ?? '').toString();
    final preferredId = effectiveSource != null && effectiveSource.isNotEmpty
        ? (nativeId.isNotEmpty ? nativeId : spotifyId)
        : (spotifyId.isNotEmpty ? spotifyId : nativeId);
    final rawAlbumName = (data['album_name'] ?? data['album'] ?? '').toString();
    final normalizedAlbumName = normalizeOptionalString(rawAlbumName);
    final normalizedPlaylistName = normalizeOptionalString(playlistName);
    final albumName =
        normalizedPlaylistName != null &&
            normalizedAlbumName?.toLowerCase() ==
                normalizedPlaylistName.toLowerCase()
        ? ''
        : rawAlbumName;

    return Track(
      id: preferredId,
      name: (data['name'] ?? '').toString(),
      artistName: (data['artists'] ?? data['artist'] ?? '').toString(),
      albumName: albumName,
      albumArtist: data['album_artist']?.toString(),
      artistId: (data['artist_id'] ?? data['artistId'])?.toString(),
      albumId: data['album_id']?.toString(),
      coverUrl: normalizeCoverReference(
        (data['cover_url'] ?? data['images'])?.toString(),
      ),
      headerVideoUrl: normalizeRemoteHttpUrl(data['header_video']?.toString()),
      isrc: data['isrc']?.toString(),
      duration: (durationMs / 1000).round(),
      trackNumber: data['track_number'] as int?,
      discNumber: data['disc_number'] as int?,
      totalDiscs: data['total_discs'] as int?,
      releaseDate: data['release_date']?.toString(),
      totalTracks: data['total_tracks'] as int?,
      source: effectiveSource,
      albumType: normalizeOptionalString(data['album_type']?.toString()),
      composer: data['composer']?.toString(),
      genre: data['genre']?.toString(),
      label: data['label']?.toString(),
      copyright: data['copyright']?.toString(),
      comment: data['comment']?.toString(),
      itemType: itemType,
      audioQuality: data['audio_quality']?.toString(),
      audioModes: data['audio_modes']?.toString(),
      previewUrl: data['preview_url']?.toString(),
      explicit: parseExplicitFlag(data['explicit']),
      upc: normalizeOptionalString(
        (data['upc'] ?? data['barcode'])?.toString(),
      ),
    );
  }

  Track copyWith({
    String? id,
    String? name,
    String? artistName,
    String? albumName,
    String? albumArtist,
    String? artistId,
    String? albumId,
    String? coverUrl,
    String? headerVideoUrl,
    String? isrc,
    String? previewUrl,
    int? duration,
    int? trackNumber,
    int? discNumber,
    int? totalDiscs,
    String? releaseDate,
    String? deezerId,
    ServiceAvailability? availability,
    String? source,
    String? albumType,
    int? totalTracks,
    String? composer,
    String? genre,
    String? label,
    String? copyright,
    String? comment,
    String? itemType,
    String? audioQuality,
    String? audioModes,
    bool? explicit,
    String? upc,
  }) {
    return Track(
      id: id ?? this.id,
      name: name ?? this.name,
      artistName: artistName ?? this.artistName,
      albumName: albumName ?? this.albumName,
      albumArtist: albumArtist ?? this.albumArtist,
      artistId: artistId ?? this.artistId,
      albumId: albumId ?? this.albumId,
      coverUrl: coverUrl ?? this.coverUrl,
      headerVideoUrl: headerVideoUrl ?? this.headerVideoUrl,
      isrc: isrc ?? this.isrc,
      previewUrl: previewUrl ?? this.previewUrl,
      duration: duration ?? this.duration,
      trackNumber: trackNumber ?? this.trackNumber,
      discNumber: discNumber ?? this.discNumber,
      totalDiscs: totalDiscs ?? this.totalDiscs,
      releaseDate: releaseDate ?? this.releaseDate,
      deezerId: deezerId ?? this.deezerId,
      availability: availability ?? this.availability,
      source: source ?? this.source,
      albumType: albumType ?? this.albumType,
      totalTracks: totalTracks ?? this.totalTracks,
      composer: composer ?? this.composer,
      genre: genre ?? this.genre,
      label: label ?? this.label,
      copyright: copyright ?? this.copyright,
      comment: comment ?? this.comment,
      itemType: itemType ?? this.itemType,
      audioQuality: audioQuality ?? this.audioQuality,
      audioModes: audioModes ?? this.audioModes,
      explicit: explicit ?? this.explicit,
      upc: upc ?? this.upc,
    );
  }

  bool get isDolbyAtmos =>
      audioModes != null && audioModes!.contains('DOLBY_ATMOS');

  bool get isExplicit => explicit == true;

  bool get hasPreview => previewUrl != null && previewUrl!.isNotEmpty;
}

@JsonSerializable()
class ServiceAvailability {
  final bool tidal;
  final bool qobuz;
  final bool amazon;
  final bool deezer;
  final String? tidalUrl;
  final String? qobuzUrl;
  final String? amazonUrl;
  final String? deezerUrl;
  final String? deezerId;

  const ServiceAvailability({
    this.tidal = false,
    this.qobuz = false,
    this.amazon = false,
    this.deezer = false,
    this.tidalUrl,
    this.qobuzUrl,
    this.amazonUrl,
    this.deezerUrl,
    this.deezerId,
  });

  factory ServiceAvailability.fromJson(Map<String, dynamic> json) =>
      _$ServiceAvailabilityFromJson(json);
  Map<String, dynamic> toJson() => _$ServiceAvailabilityToJson(this);
}
