import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/utils/file_access.dart' show isContentUri;
import 'package:mornye/utils/int_utils.dart';
import 'package:mornye/utils/ios_container_paths.dart';
import 'package:mornye/utils/string_utils.dart';

class PlayableMedia {
  final String id;
  final String source;
  final String title;
  final String artist;
  final String album;
  final String? artUri;
  final String? networkArtworkSource;
  final Duration? duration;
  final int? bitDepth;
  final int? sampleRate;
  final int? bitrate;
  final String? format;
  final bool explicit;
  final String? genre;
  final bool autoplay;

  const PlayableMedia({
    required this.id,
    required this.source,
    required this.title,
    required this.artist,
    this.album = '',
    this.artUri,
    this.networkArtworkSource,
    this.duration,
    this.bitDepth,
    this.sampleRate,
    this.bitrate,
    this.format,
    this.explicit = false,
    this.genre,
    this.autoplay = false,
  });

  /// The `network://` cover the cover store keeps for this song:
  /// [networkArtworkSource], or [artUri] when it names one, as a cover
  /// reference listening statistics recorded does.
  String? get coverReference =>
      networkArtworkSource ?? (CoverStore.fetches(artUri) ? artUri : null);

  bool get isContentUri => source.startsWith('content://');
  bool get isNetwork =>
      const {'network', 'http', 'https'}.contains(Uri.tryParse(source)?.scheme);

  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source,
    'title': title,
    'artist': artist,
    'album': album,
    if (artUri != null && artUri!.isNotEmpty && networkArtworkSource == null)
      'artUri': artUri,
    if (networkArtworkSource != null)
      'networkArtworkSource': networkArtworkSource,
    if (duration != null) 'durationMs': duration!.inMilliseconds,
    if (bitDepth != null && bitDepth! > 0) 'bitDepth': bitDepth,
    if (sampleRate != null && sampleRate! > 0) 'sampleRate': sampleRate,
    if (bitrate != null && bitrate! > 0) 'bitrate': bitrate,
    if (format != null && format!.trim().isNotEmpty) 'format': format,
    if (explicit) 'explicit': true,
    if (genre != null) 'genre': genre,
    if (autoplay) 'autoplay': true,
  };

  static PlayableMedia? fromJson(
    Map<String, dynamic> json, {
    String? iosDocumentsPath,
  }) {
    final id = json['id'] as String?;
    final source = json['source'] as String?;
    if (id == null || id.isEmpty || source == null || source.isEmpty) {
      return null;
    }
    final durationMs = (json['durationMs'] as num?)?.toInt();
    var artwork = json['artUri'] as String?;
    if (artwork != null && iosDocumentsPath != null) {
      final uri = Uri.tryParse(artwork);
      if (uri != null && uri.scheme == 'file' && uri.host.isEmpty) {
        try {
          final path = uri.toFilePath();
          final rebased = rebaseIosSandboxPath(path, iosDocumentsPath);
          if (rebased != path) artwork = Uri.file(rebased).toString();
        } on UnsupportedError {
          // Leave malformed or non-local artwork URIs to the image fallback.
        }
      }
    }
    return PlayableMedia(
      id: id,
      source: source,
      title: json['title'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      album: json['album'] as String? ?? '',
      artUri: artwork,
      networkArtworkSource: json['networkArtworkSource'] as String?,
      duration: (durationMs != null && durationMs > 0)
          ? Duration(milliseconds: durationMs)
          : null,
      bitDepth: readPositiveInt(json['bitDepth']),
      sampleRate: readPositiveInt(json['sampleRate']),
      bitrate: readPositiveInt(json['bitrate']),
      format: json['format']?.toString(),
      explicit: parseExplicitFlag(json['explicit']) == true,
      genre: json['genre'] as String?,
      autoplay: json['autoplay'] == true,
    );
  }

  /// The item players show. A network song shows the file [covers] stored
  /// for it, the same on every play: the cover from its tags once read,
  /// else its network cover ([coverReference]), which travels as
  /// `extras['artworkRef']`, the reference to keep instead of the file. A
  /// `network://` string is never the item's artUri.
  MediaItem toMediaItem({
    String? resolvedSource,
    String? resolvedArtwork,
    String? unknownTitle,
    String? unknownArtist,
    CoverStore? covers,
  }) {
    final reference = coverReference;
    final stored = resolvedArtwork == null
        ? (covers ?? musicPlayerRuntime.dependencies.coverStore).songCover(
            source,
            reference,
          )
        : null;
    final artwork =
        resolvedArtwork ?? (CoverStore.fetches(artUri) ? null : artUri);
    return MediaItem(
      id: id,
      title: title.isEmpty
          ? unknownTitle ?? musicPlayerRuntime.unknownTitle
          : title,
      artist: artist.isEmpty
          ? unknownArtist ?? musicPlayerRuntime.unknownArtist
          : artist,
      album: album.isEmpty ? null : album,
      duration: duration,
      artUri: stored != null
          ? Uri.file(stored.path)
          : (artwork != null && artwork.isNotEmpty)
          ? Uri.tryParse(artwork)
          : null,
      extras: {
        'source': source,
        if (resolvedSource != null && resolvedSource.isNotEmpty)
          'resolvedSource': resolvedSource,
        'artworkRef': ?reference,
        if (bitDepth != null && bitDepth! > 0) 'bit_depth': bitDepth,
        if (sampleRate != null && sampleRate! > 0) 'sample_rate': sampleRate,
        if (bitrate != null && bitrate! > 0) 'bitrate': bitrate,
        if (format != null && format!.trim().isNotEmpty)
          'format': format!.trim(),
        if (explicit) 'explicit': true,
        if (autoplay) 'autoplay': true,
      },
    );
  }
}

/// A cover path or URL as a media artwork URI.
String? normalizeArtUri(String cover) {
  final value = cover.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('http') ||
      isContentUri(value) ||
      value.startsWith('file://')) {
    return value;
  }
  return Uri.file(value).toString();
}

/// A collection or catalog [track] that plays the file at [path]. A
/// `network://` cover stays the reference, its [PlayableMedia.coverReference],
/// while a network [path] plays; a local file shows its own cover instead.
PlayableMedia playableFromTrack(Track track, String path) {
  final cover = track.coverUrl ?? '';
  return PlayableMedia(
    id: path,
    source: path,
    title: track.name,
    artist: track.artistName,
    album: track.albumName,
    artUri: !CoverStore.fetches(cover)
        ? normalizeArtUri(cover)
        : path.startsWith('network://')
        ? cover
        : null,
    duration: track.duration > 0 ? Duration(seconds: track.duration) : null,
    explicit: track.isExplicit,
  );
}

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
