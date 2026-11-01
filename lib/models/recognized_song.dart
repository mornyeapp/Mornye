/// A song the recognition service identified from the microphone.
///
/// Holds only display metadata and links; the service's lyrics are never
/// kept.
class RecognizedSong {
  const RecognizedSong({
    this.key = '',
    required this.title,
    required this.artist,
    this.album,
    this.coverUrl,
    this.release,
    this.genre,
    this.label,
    this.isrc,
    this.webUrl,
    required this.recognizedAt,
  });

  /// The service's track ID, empty when it gave none.
  final String key;
  final String title;
  final String artist;
  final String? album;
  final String? coverUrl;

  /// A year or date as the service wrote it.
  final String? release;
  final String? genre;
  final String? label;
  final String? isrc;

  /// The song's page on the service's website.
  final String? webUrl;
  final DateTime recognizedAt;

  /// The native job's `song` object (snake case).
  static RecognizedSong? fromNative(Object? value, DateTime recognizedAt) {
    if (value is! Map) return null;
    final title = _text(value['title']);
    final artist = _text(value['artist']);
    if (title == null || artist == null) return null;
    return RecognizedSong(
      key: _text(value['key']) ?? '',
      title: title,
      artist: artist,
      album: _text(value['album']),
      coverUrl: _webLink(value['cover_url']),
      release: _text(value['release']),
      genre: _text(value['genre']),
      label: _text(value['label']),
      isrc: _text(value['isrc']),
      webUrl: _webLink(value['web_url']),
      recognizedAt: recognizedAt,
    );
  }

  /// A stored history entry, or null when it is not one.
  static RecognizedSong? fromJson(Object? value) {
    if (value is! Map) return null;
    final title = _text(value['title']);
    final artist = _text(value['artist']);
    final recognizedAt = DateTime.tryParse(
      value['recognizedAt']?.toString() ?? '',
    );
    if (title == null || artist == null || recognizedAt == null) return null;
    return RecognizedSong(
      key: _text(value['key']) ?? '',
      title: title,
      artist: artist,
      album: _text(value['album']),
      coverUrl: _webLink(value['coverUrl']),
      release: _text(value['release']),
      genre: _text(value['genre']),
      label: _text(value['label']),
      isrc: _text(value['isrc']),
      webUrl: _webLink(value['webUrl']),
      recognizedAt: recognizedAt,
    );
  }

  Map<String, Object?> toJson() => {
    'key': key,
    'title': title,
    'artist': artist,
    'album': album,
    'coverUrl': coverUrl,
    'release': release,
    'genre': genre,
    'label': label,
    'isrc': isrc,
    'webUrl': webUrl,
    'recognizedAt': recognizedAt.toUtc().toIso8601String(),
  };

  /// One history entry per song: the service's track ID when known, else
  /// its title, artist and ISRC.
  String get historyKey => key.isNotEmpty
      ? 'key:$key'
      : 'song:${title.toLowerCase()}|${artist.toLowerCase()}|'
            '${isrc?.toUpperCase() ?? ''}';

  /// The words a catalog search for this song starts with.
  String get searchQuery => '$title $artist';

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String? _webLink(Object? value) {
    final link = _text(value);
    final uri = link == null ? null : Uri.tryParse(link);
    return uri != null &&
            (uri.scheme == 'https' || uri.scheme == 'http') &&
            uri.host.isNotEmpty
        ? link
        : null;
  }
}
