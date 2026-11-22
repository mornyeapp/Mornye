/// What a Home pin opens. Saved pins store the value's name, so renaming one
/// drops it from saved pins.
enum HomePinKind { album, playlist, loved, artist, genre, folder }

/// A Library album, playlist, artist, genre or folder pinned to Home.
class HomePin {
  const HomePin({
    required this.kind,
    required this.id,
    required this.title,
    this.subtitle = '',
    this.cover,
    this.coverFile,
    this.source,
  });

  /// A downloaded or scanned album. [source] is the Library's `local` or
  /// `downloaded`; a scanned album is known by its [albumKey], a download by
  /// its names.
  factory HomePin.album({
    required String source,
    required String albumKey,
    required String name,
    required String artist,
    String? cover,
    String? coverFile,
  }) => HomePin(
    kind: HomePinKind.album,
    // The Library opens every album that is not scanned as a download.
    source: source == 'local' ? 'local' : 'downloaded',
    id: source == 'local'
        ? albumKey
        : '${name.trim().toLowerCase()}|${artist.trim().toLowerCase()}',
    title: name,
    subtitle: artist,
    cover: cover,
    coverFile: coverFile,
  );

  /// A user playlist by its id.
  factory HomePin.playlist({
    required String id,
    required String name,
    String? cover,
  }) => HomePin(kind: HomePinKind.playlist, id: id, title: name, cover: cover);

  /// The Loved collection; Home names it in the current language.
  static const loved = HomePin(
    kind: HomePinKind.loved,
    id: 'loved',
    title: 'Loved',
  );

  /// A Library artist by name.
  factory HomePin.artist({
    required String name,
    String? cover,
    String? coverFile,
    String? source,
  }) => HomePin(
    kind: HomePinKind.artist,
    id: name.trim().toLowerCase(),
    title: name,
    cover: cover,
    coverFile: coverFile,
    source: source,
  );

  /// A Library genre by its key.
  factory HomePin.genre({
    required String key,
    required String name,
    String? cover,
    String? coverFile,
    String? source,
  }) => HomePin(
    kind: HomePinKind.genre,
    id: key,
    title: name,
    cover: cover,
    coverFile: coverFile,
    source: source,
  );

  /// A Library folder by its key.
  factory HomePin.folder({
    required String key,
    required String name,
    String path = '',
    String? cover,
    String? coverFile,
  }) => HomePin(
    kind: HomePinKind.folder,
    id: key,
    title: name,
    subtitle: path,
    cover: cover,
    coverFile: coverFile,
  );

  final HomePinKind kind;

  /// The target within its kind: an album key or names, a playlist id, an
  /// artist name, a genre key or a folder key.
  final String id;
  final String title;
  final String subtitle;

  /// Artwork as a web address or a local image path.
  final String? cover;

  /// A song file whose own artwork stands in when [cover] is missing.
  final String? coverFile;

  /// Where the songs behind the artwork come from: `local` or `downloaded`.
  /// It also tells a scanned album from a downloaded one.
  final String? source;

  /// Identifies the target across saves; two pins with one key are one pin.
  String get key => kind == HomePinKind.album
      ? '${kind.name}:$source:$id'
      : '${kind.name}:$id';

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'id': id,
    'title': title,
    if (subtitle.isNotEmpty) 'subtitle': subtitle,
    'cover': ?cover,
    'coverFile': ?coverFile,
    'source': ?source,
  };

  /// Null for saved data this version cannot open: an unknown kind or a
  /// missing id or title.
  static HomePin? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = HomePinKind.values.asNameMap()[json['kind']];
    final id = json['id'];
    final title = json['title'];
    if (kind == null || id is! String || id.isEmpty || title is! String) {
      return null;
    }
    String? text(String name) =>
        json[name] is String && (json[name] as String).isNotEmpty
        ? json[name] as String
        : null;
    final source = text('source');
    if (kind == HomePinKind.album && source == null) return null;
    return HomePin(
      kind: kind,
      id: id,
      title: title,
      subtitle: text('subtitle') ?? '',
      cover: text('cover'),
      coverFile: text('coverFile'),
      source: source,
    );
  }

  @override
  bool operator ==(Object other) => other is HomePin && other.key == key;

  @override
  int get hashCode => key.hashCode;
}
