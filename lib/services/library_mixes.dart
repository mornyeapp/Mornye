import 'dart:io';
import 'dart:math';

import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/autoplay_signal.dart';
import 'package:mornye/services/listening_statistics.dart' show listeningDay;
import 'package:mornye/services/music_player_service.dart'
    show rankAutoplayTracks;
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/sqlite_helpers.dart' show normalizeLookupText;
import 'package:mornye/utils/artist_utils.dart' show splitArtistTagValues;
import 'package:mornye/utils/file_access.dart'
    show isContentUri, stripCueTrackSuffix;

/// A Library with fewer playable songs than this gets no mixes.
const libraryMixMinLibrary = 30;

/// The most mixes Home shows.
const libraryMixMaxCount = 6;

/// A mix shorter than this is left out.
const libraryMixMinSongs = 20;

/// The length a mix aims for when its pool has enough songs.
const libraryMixTargetSongs = 40;

/// The largest share of a mix one artist may take.
const _artistShare = 0.2;

/// Songs a genre needs before it can be a mix of its own.
const _minClusterCore = 12;

/// Songs ranked per mix, so a large Library ranks in bounded time.
const _poolLimit = 1500;

/// Played songs needed before the favorites mix appears.
const libraryMixFavoritesMinPlayed = 8;

/// How much each hint of taste counts, in plays, when listening statistics
/// are off: a loved song, a song in the saved queue, a song of an album
/// opened lately.
const _lovedPlays = 3.0, _queuedPlays = 1.0, _albumPlays = 0.5;

/// Mixes sharing more of their songs than this are one mix twice.
const _maxOverlap = 0.6;

enum LibraryMixKind { favorites, genre, artist }

/// One generated mix: what it is named after and its songs in play order.
class LibraryMix {
  const LibraryMix({
    required this.kind,
    required this.key,
    required this.label,
    required this.artists,
    required this.songIds,
  });

  final LibraryMixKind kind;

  /// Stable identity: the genre family, or the anchor artist's lookup key.
  final String key;

  /// The genre or artist the title names; empty for the favorites mix.
  final String label;

  /// The artists heard most in the mix, most first, for its subtitle.
  final List<String> artists;

  /// Library ids as [UnifiedLibraryItem] spells them (`dl_` or `local_`).
  final List<String> songIds;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'key': key,
    'label': label,
    'artists': artists,
    'songs': songIds,
  };

  static LibraryMix? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = LibraryMixKind.values
        .where((kind) => kind.name == json['kind'])
        .firstOrNull;
    final key = json['key'], label = json['label'];
    final artists = json['artists'], songs = json['songs'];
    if (kind == null ||
        key is! String ||
        label is! String ||
        artists is! List ||
        songs is! List) {
      return null;
    }
    return LibraryMix(
      kind: kind,
      key: key,
      label: label,
      artists: artists.whereType<String>().toList(growable: false),
      songIds: songs.whereType<String>().toList(growable: false),
    );
  }
}

/// What [buildLibraryMixes] works from. Plain data only, so building can
/// run on a worker isolate.
class LibraryMixRequest {
  const LibraryMixRequest({
    required this.songs,
    required this.at,
    this.plays = const {},
    this.signals = const [],
    this.preference,
    this.weights = const {},
    this.exists,
  });

  /// Every Library song, its id spelled as [LibraryMix.songIds] spells it.
  final List<PlayableMedia> songs;

  /// When the mixes are made; its day seeds their order.
  final DateTime at;

  /// How much the listener plays each song, by id, recent plays counting
  /// more. Absent songs count as unplayed.
  final Map<String, double> plays;

  /// What Autoplay knows beyond metadata, such as how songs sound.
  final List<AutoplaySignal> signals;

  /// Autoplay's learned preferences, while learning is on.
  final AutoplayPreferenceModel? preference;

  /// Autoplay's learned weights of the score parts.
  final Map<String, double> weights;

  /// Whether a song's file can still play; [libraryMixFileExists] when
  /// null.
  final bool Function(String source)? exists;
}

/// Whether a mix may hold [source]: a file that still exists, or a content
/// URI, which only the platform can check and the player skips when gone.
bool libraryMixFileExists(String source) {
  if (isContentUri(source)) return true;
  try {
    return File(stripCueTrackSuffix(source)).existsSync();
  } on Object {
    return false;
  }
}

/// What the app keeps of the listener's taste besides listening
/// statistics, so the mixes still know favorites while statistics are off.
class LibraryMixHints {
  const LibraryMixHints({
    this.loved = const [],
    this.liked = const [],
    this.queued = const [],
    this.albums = const [],
  });

  /// Loved songs.
  final List<({String artist, String title})> loved;

  /// Autoplay's learning log while learning is on: songs as normalized
  /// `artist|title`, how much each listen was liked, and when.
  final List<({String song, double reward, DateTime at})> liked;

  /// Sources of the saved queue's songs, up to the one playing.
  final List<String> queued;

  /// Albums opened lately; the artist when known.
  final List<({String album, String? artist})> albums;
}

/// Plays by song id that [hints] stand for, as [LibraryMixRequest.plays]
/// counts them: liked listens of the last 90 days by how much they were
/// liked, those of the last 14 counting twice.
Map<String, double> libraryMixHintPlays(
  List<PlayableMedia> songs,
  LibraryMixHints hints,
  DateTime now,
) {
  String songKey(String artist, String title) =>
      '${normalizeLookupText(artist)}|${normalizeLookupText(title)}';
  final bySong = <String, double>{}, bySource = <String, double>{};
  for (final song in hints.loved) {
    final key = songKey(song.artist, song.title);
    bySong[key] = (bySong[key] ?? 0) + _lovedPlays;
  }
  for (final listen in hints.liked) {
    final age = now.difference(listen.at);
    if (listen.reward <= 0 || age.inDays >= 90) continue;
    bySong[listen.song] =
        (bySong[listen.song] ?? 0) + listen.reward * (age.inDays < 14 ? 2 : 1);
  }
  for (final source in hints.queued) {
    bySource[source] = (bySource[source] ?? 0) + _queuedPlays;
  }
  final albums = <String, Set<String>>{};
  for (final album in hints.albums) {
    final name = normalizeLookupText(album.album);
    if (name.isEmpty) continue;
    albums
        .putIfAbsent(name, () => {})
        .add(normalizeLookupText(album.artist ?? ''));
  }
  final plays = <String, double>{};
  for (final song in songs) {
    var heard =
        (bySong[songKey(song.artist, song.title)] ?? 0) +
        (bySource[song.source] ?? 0);
    final artist = normalizeLookupText(song.artist);
    if (albums[normalizeLookupText(song.album)]?.any(
          (album) => album.isEmpty || artist.contains(album),
        ) ??
        false) {
      heard += _albumPlays;
    }
    if (heard > 0) plays[song.id] = heard;
  }
  return plays;
}

// Genre families: each name matches whole words of a tag. When several
// match, the one ending last wins, since a genre's last word usually names
// its family ("pop rap" is rap, "dance pop" is pop), and the longer name
// breaks a tie ("j rock" over "rock").
const _genreFamilies = <(String, String, List<String>)>[
  (
    'hiphop',
    'Hip-Hop',
    [
      'hip hop',
      'hiphop',
      'rap',
      'trap',
      'drill',
      'grime',
      'boom bap',
      'phonk',
      'gangsta',
    ],
  ),
  (
    'rnb',
    'R&B',
    ['rnb', 'soul', 'neo soul', 'funk', 'motown', 'new jack swing'],
  ),
  (
    'pop',
    'Pop',
    [
      'pop',
      'synthpop',
      'electropop',
      'europop',
      'teen pop',
      'top 40',
      'mandopop',
      'cantopop',
      'opm',
    ],
  ),
  ('kpop', 'K-Pop', ['k pop', 'kpop', 'korean pop']),
  (
    'jpop',
    'J-Pop',
    [
      'j pop',
      'jpop',
      'j rock',
      'jrock',
      'anime',
      'anisong',
      'city pop',
      'vocaloid',
      'visual kei',
    ],
  ),
  (
    'rock',
    'Rock',
    ['rock', 'grunge', 'rockabilly', 'britpop', 'garage rock', 'post rock'],
  ),
  (
    'metal',
    'Metal',
    ['metal', 'metalcore', 'deathcore', 'djent', 'thrash', 'doom'],
  ),
  ('punk', 'Punk', ['punk', 'emo', 'hardcore', 'screamo']),
  (
    'indie',
    'Indie & Alternative',
    [
      'indie',
      'alternative',
      'alt',
      'shoegaze',
      'dream pop',
      'bedroom pop',
      'indie pop',
      'indie rock',
      'alternative rock',
      'alt rock',
    ],
  ),
  (
    'electronic',
    'Electronic',
    [
      'electronic',
      'electronica',
      'edm',
      'house',
      'techno',
      'trance',
      'dubstep',
      'dnb',
      'jungle',
      'electro',
      'dance',
      'disco',
      'garage',
      'synthwave',
      'idm',
      'hardstyle',
      'future bass',
      'eurodance',
      'breakbeat',
      'club',
    ],
  ),
  (
    'chill',
    'Chill & Lo-Fi',
    [
      'lofi',
      'lo fi',
      'chillhop',
      'chill',
      'chillout',
      'chillwave',
      'ambient',
      'downtempo',
      'trip hop',
      'new age',
      'lounge',
    ],
  ),
  (
    'jazz',
    'Jazz',
    ['jazz', 'bebop', 'swing', 'bossa nova', 'big band', 'smooth jazz'],
  ),
  ('blues', 'Blues', ['blues']),
  (
    'classical',
    'Classical',
    [
      'classical',
      'orchestral',
      'orchestra',
      'baroque',
      'opera',
      'symphony',
      'chamber music',
    ],
  ),
  (
    'soundtrack',
    'Soundtrack',
    [
      'soundtrack',
      'ost',
      'score',
      'film score',
      'video game music',
      'game music',
      'vgm',
      'musical',
      'show tunes',
    ],
  ),
  (
    'country',
    'Country',
    ['country', 'bluegrass', 'americana', 'honky tonk', 'country pop'],
  ),
  (
    'folk',
    'Folk & Acoustic',
    ['folk', 'acoustic', 'singer songwriter', 'indie folk'],
  ),
  (
    'latin',
    'Latin',
    [
      'latin',
      'latino',
      'latin pop',
      'reggaeton',
      'salsa',
      'bachata',
      'cumbia',
      'merengue',
      'dembow',
      'corridos',
      'regional mexican',
      'banda',
      'urbano latino',
      'samba',
      'sertanejo',
      'mpb',
      'tango',
    ],
  ),
  ('reggae', 'Reggae', ['reggae', 'dancehall', 'dub', 'ska']),
  (
    'afro',
    'Afrobeats',
    [
      'afrobeats',
      'afrobeat',
      'afropop',
      'afro pop',
      'afro',
      'amapiano',
      'highlife',
      'afroswing',
    ],
  ),
  (
    'gospel',
    'Gospel & Worship',
    ['gospel', 'worship', 'christian', 'ccm', 'praise'],
  ),
  ('dangdut', 'Dangdut', ['dangdut', 'koplo', 'campursari']),
];

/// Tags that say nothing about how a song sounds.
const _ignoredGenres = {
  'other',
  'others',
  'unknown',
  'misc',
  'miscellaneous',
  'music',
  'general',
  'various',
  'none',
  'genre',
  'default',
  'undefined',
  'unclassifiable',
};

final _tagSeparators = RegExp(r'[,;/|&\\\u0000]');
final _rhythmAndBlues = RegExp(
  r"\br\s*(?:&|'n'|n|and)\s*b\b",
  caseSensitive: false,
);
final _drumAndBass = RegExp(
  r'\bdrum\s*(?:&|n|and)\s*bass\b',
  caseSensitive: false,
);
final _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final _numeric = RegExp(r'^\d+$');

/// The display name of a genre family key, such as `Hip-Hop` for
/// `hiphop`, or null for a tag outside the known families.
String? libraryGenreFamilyLabel(String key) {
  for (final (family, label, _) in _genreFamilies) {
    if (family == key) return label;
  }
  return null;
}

/// The genre families a tag such as `Hip-Hop/Rap; R&B` names, in tag
/// order: `hiphop` and `rnb` here. A part outside the known families keeps
/// its own family, `tag:` and its normalized words.
List<String> libraryGenreFamilies(String? tag) => _familiesOf(tag, null);

List<String> _familiesOf(String? tag, Map<String, String>? labels) {
  final protected = (tag ?? '')
      .replaceAll(_rhythmAndBlues, 'RnB')
      .replaceAll(_drumAndBass, 'DnB');
  final families = <String>[];
  for (final part in protected.split(_tagSeparators)) {
    final text = part.toLowerCase().replaceAll(_nonWord, ' ').trim();
    if (text.isEmpty ||
        text.length > 40 ||
        _numeric.hasMatch(text) ||
        _ignoredGenres.contains(text)) {
      continue;
    }
    final family = _familyOf(text) ?? 'tag:$text';
    if (family.startsWith('tag:')) labels?.putIfAbsent(family, part.trim);
    if (!families.contains(family)) families.add(family);
  }
  return families;
}

String? _familyOf(String text) {
  final padded = ' $text ';
  String? best;
  var bestEnd = -1, bestLength = 0;
  for (final (family, _, names) in _genreFamilies) {
    for (final name in names) {
      final at = padded.lastIndexOf(' $name ');
      if (at < 0) continue;
      final end = at + name.length;
      if (end > bestEnd || (end == bestEnd && name.length > bestLength)) {
        best = family;
        bestEnd = end;
        bestLength = name.length;
      }
    }
  }
  return best;
}

String _artistKey(String artist) => normalizeLookupText(artist);

bool _remote(String source) =>
    source.startsWith('http://') ||
    source.startsWith('https://') ||
    source.startsWith('network://');

/// A stable 32-bit FNV-1a hash, since [String.hashCode] may change between
/// runs.
int _stableHash(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// Adds what a mix knows beyond Autoplay: how much the listener plays a
/// song, the artist an artist mix is named after and the artists credited
/// with them, and a small cost for songs earlier mixes already hold.
class _MixSignal extends AutoplaySignal {
  _MixSignal({
    required this.plays,
    required this.maxPlays,
    required this.used,
    this.anchor = '',
    this.credits = const {},
  });

  final Map<String, double> plays;
  final double maxPlays;
  final Set<String> used;
  final String anchor;
  final Set<String> credits;

  @override
  String get name => 'mix';

  @override
  double score(PlayableMedia candidate) {
    var score = 0.0;
    final heard = plays[candidate.id] ?? 0;
    if (heard > 0 && maxPlays > 0) {
      score += 2.5 * log(1 + heard) / log(1 + maxPlays);
    }
    if (used.contains(candidate.id)) score -= 1.5;
    if (anchor.isNotEmpty) {
      if (_artistKey(candidate.artist) == anchor) {
        score += 2;
      } else if (splitArtistTagValues(
        candidate.artist,
      ).any((name) => credits.contains(_artistKey(name)))) {
        score += 1;
      }
    }
    return score;
  }
}

/// Builds the day's mixes from [request]: a favorites mix of the most
/// played songs and songs like them, then one mix per genre family the
/// listener plays most, and artist mixes where genre tags are missing.
/// Songs are picked with Autoplay's ranking, as if Autoplay continued from
/// the mix's best known songs, so the mix keeps its genre and spaces its
/// artists. The same request on the same day gives the same mixes.
List<LibraryMix> buildLibraryMixes(LibraryMixRequest request) =>
    _MixBuilder(request).build();

class _MixBuilder {
  _MixBuilder(this.request)
    : exists = request.exists ?? libraryMixFileExists,
      day = listeningDay(request.at);

  final LibraryMixRequest request;
  final bool Function(String) exists;
  final String day;

  /// Display names of `tag:` families, as first spelled in the Library.
  final labels = <String, String>{};
  final familiesById = <String, List<String>>{};
  final tagsById = <String, String>{};

  /// Songs ranked by their families instead of their raw tags, so `Rap` and
  /// `Hip-Hop` count as one genre in the genre part of the score.
  final songs = <PlayableMedia>[];
  final familySongs = <String, List<PlayableMedia>>{};
  final familyPlays = <String, double>{};
  final artistSongs = <String, List<PlayableMedia>>{};
  final artistNames = <String, String>{};

  /// Families of each artist's tagged songs, with their counts.
  final artistFamilies = <String, Map<String, int>>{};
  final adjacency = <String, Map<String, int>>{};
  final used = <String>{};
  double maxPlays = 0;

  double plays(PlayableMedia song) => request.plays[song.id] ?? 0;

  int byPlays(PlayableMedia a, PlayableMedia b) {
    final order = plays(b).compareTo(plays(a));
    return order != 0 ? order : a.id.compareTo(b.id);
  }

  /// [songs] most played first, in an order for the day when unplayed.
  List<PlayableMedia> _byPlays(Iterable<PlayableMedia> songs, Random random) {
    final ordered = songs.toList()..shuffle(random);
    if (ordered.any((song) => plays(song) > 0)) ordered.sort(byPlays);
    return ordered;
  }

  /// The song as learning knows it, with its own genre tag.
  AutoplayLearningTrack _learning(PlayableMedia media) => AutoplayLearningTrack(
    source: media.source,
    title: media.title,
    artist: media.artist,
    album: media.album,
    genre: tagsById[media.id] ?? '',
    duration: media.duration,
  );

  List<LibraryMix> build() {
    _index();
    if (songs.length < libraryMixMinLibrary) return const [];
    final mixes = <LibraryMix>[];
    if (_favorites() case final mix?) mixes.add(mix);
    final ranked =
        [
          for (final MapEntry(:key, :value) in familySongs.entries)
            if (value.length >= _minClusterCore) key,
        ]..sort((a, b) {
          final order = _familyScore(b).compareTo(_familyScore(a));
          return order != 0 ? order : a.compareTo(b);
        });
    for (final family in ranked) {
      if (mixes.length >= libraryMixMaxCount) break;
      _add(mixes, _genreMix(family));
    }
    // Where tags are missing, the artists played most anchor mixes of
    // their own.
    final tagged = songs.where((song) => familiesById[song.id]!.isNotEmpty);
    if (mixes.length < 3 || tagged.length * 2 < songs.length) {
      var added = 0;
      for (final artist in _anchorArtists()) {
        if (mixes.length >= libraryMixMaxCount || added == 3) break;
        if (mixes.any((mix) => mix.key == artist)) continue;
        if (_add(mixes, _artistMix(artist))) added++;
      }
    }
    // Favorites lead; the other mixes follow how much they are played, in
    // the order they were made when equal.
    double weight(LibraryMix mix) =>
        mix.songIds.fold(0.0, (sum, id) => sum + (request.plays[id] ?? 0));
    final rest =
        [
          for (final (index, mix) in mixes.indexed)
            if (mix.kind != LibraryMixKind.favorites)
              (mix: mix, index: index, weight: weight(mix)),
        ]..sort((a, b) {
          final order = b.weight.compareTo(a.weight);
          return order != 0 ? order : a.index.compareTo(b.index);
        });
    return [
      ...mixes.where((mix) => mix.kind == LibraryMixKind.favorites),
      for (final entry in rest) entry.mix,
    ];
  }

  void _index() {
    final seen = <String>{};
    final tags = <String, List<String>>{};
    final raw = <PlayableMedia>[];
    for (final song in request.songs) {
      if (song.source.isEmpty || _remote(song.source) || !seen.add(song.id)) {
        continue;
      }
      final families = tags[song.genre ?? ''] ??= _familiesOf(
        song.genre,
        labels,
      );
      familiesById[song.id] = families;
      tagsById[song.id] = song.genre ?? '';
      final artist = _artistKey(song.artist);
      artistNames.putIfAbsent(artist, () => song.artist.trim());
      final counts = artistFamilies[artist] ??= {};
      for (final family in families) {
        counts[family] = (counts[family] ?? 0) + 1;
      }
      for (var i = 0; i < families.length; i++) {
        for (var j = i + 1; j < families.length; j++) {
          _link(families[i], families[j]);
        }
      }
      raw.add(song);
    }
    for (final counts in artistFamilies.values) {
      final families = counts.keys.toList();
      for (var i = 0; i < families.length; i++) {
        for (var j = i + 1; j < families.length; j++) {
          _link(families[i], families[j]);
        }
      }
    }
    for (final song in raw) {
      var families = familiesById[song.id]!;
      final artist = _artistKey(song.artist);
      if (families.isEmpty) {
        // An untagged song takes its artist's most tagged family.
        final counts = artistFamilies[artist]!;
        if (counts.isNotEmpty) {
          final top = counts.entries.reduce(
            (a, b) =>
                b.value > a.value ||
                    (b.value == a.value && b.key.compareTo(a.key) < 0)
                ? b
                : a,
          );
          families = familiesById[song.id] = [top.key];
        }
      }
      final ranked = PlayableMedia(
        id: song.id,
        source: song.source,
        title: song.title,
        artist: song.artist,
        album: song.album,
        duration: song.duration,
        genre: families.join(';'),
      );
      songs.add(ranked);
      (artistSongs[artist] ??= []).add(ranked);
      final heard = plays(ranked);
      if (heard > maxPlays) maxPlays = heard;
      for (final family in families) {
        (familySongs[family] ??= []).add(ranked);
        familyPlays[family] =
            (familyPlays[family] ?? 0) + heard / families.length;
      }
    }
  }

  void _link(String a, String b) {
    final ab = adjacency[a] ??= {}, ba = adjacency[b] ??= {};
    ab[b] = (ab[b] ?? 0) + 1;
    ba[a] = (ba[a] ?? 0) + 1;
  }

  /// Plays first; among unplayed genres the larger one leads.
  double _familyScore(String family) =>
      (familyPlays[family] ?? 0) + 0.01 * familySongs[family]!.length;

  bool _add(List<LibraryMix> mixes, LibraryMix? mix) {
    if (mix == null) return false;
    final songs = mix.songIds.toSet();
    for (final other in mixes) {
      final shared = other.songIds.where(songs.contains).length;
      if (shared > _maxOverlap * min(songs.length, other.songIds.length)) {
        return false;
      }
    }
    mixes.add(mix);
    used.addAll(songs);
    return true;
  }

  Random _random(LibraryMixKind kind, String key) =>
      Random(_stableHash('$day|${kind.name}|$key'));

  LibraryMix? _favorites() {
    final played = songs.where((song) => plays(song) > 0).toList()
      ..sort(byPlays);
    if (played.length < libraryMixFavoritesMinPlayed) return null;
    // The genres of the favorites, weighted by plays, bring songs like them.
    final weights = <String, double>{};
    for (final song in played.take(50)) {
      final families = familiesById[song.id]!;
      for (final family in families) {
        weights[family] =
            (weights[family] ?? 0) + plays(song) / families.length;
      }
    }
    final families = weights.keys.toList()
      ..sort((a, b) => weights[b]!.compareTo(weights[a]!));
    final pool = <PlayableMedia>{
      ...played.take(100),
      for (final family in families.take(3)) ...familySongs[family]!,
      if (families.isEmpty) ...songs,
    };
    return _mix(
      kind: LibraryMixKind.favorites,
      key: 'favorites',
      label: '',
      pool: pool.toList(),
      seeds: played.take(12).toList(),
    );
  }

  LibraryMix? _genreMix(String family) {
    final core = familySongs[family]!;
    final pool = <PlayableMedia>{...core};
    if (core.length < libraryMixTargetSongs) {
      // A small genre borrows from the genres its songs and artists share.
      final neighbors =
          (adjacency[family] ?? const <String, int>{}).entries.toList()
            ..sort((a, b) {
              final order = b.value.compareTo(a.value);
              return order != 0 ? order : a.key.compareTo(b.key);
            });
      for (final neighbor in neighbors.take(2)) {
        pool.addAll(familySongs[neighbor.key] ?? const []);
      }
    }
    return _mix(
      kind: LibraryMixKind.genre,
      key: family,
      label: labels[family] ?? libraryGenreFamilyLabel(family) ?? family,
      pool: pool.toList(),
      seeds: _seeds(core, _random(LibraryMixKind.genre, family)),
    );
  }

  /// Artists by plays, then by songs, with enough songs to anchor a mix.
  List<String> _anchorArtists() {
    final heard = {
      for (final MapEntry(:key, :value) in artistSongs.entries)
        key: value.fold(0.0, (sum, song) => sum + plays(song)),
    };
    return [
      for (final MapEntry(:key, :value) in artistSongs.entries)
        if (key.isNotEmpty && value.length >= 3) key,
    ]..sort((a, b) {
      final order = heard[b]!.compareTo(heard[a]!);
      if (order != 0) return order;
      final size = artistSongs[b]!.length.compareTo(artistSongs[a]!.length);
      return size != 0 ? size : a.compareTo(b);
    });
  }

  LibraryMix? _artistMix(String artist) {
    final own = artistSongs[artist]!;
    final families = (artistFamilies[artist] ?? const {}).keys.toList();
    final pool = <PlayableMedia>{
      ...own,
      for (final family in families) ...familySongs[family] ?? const [],
      // Without tags, any untagged song may sit beside the artist.
      if (families.isEmpty)
        ...songs.where((song) => familiesById[song.id]!.isEmpty),
    };
    final name = artistNames[artist] ?? artist;
    return _mix(
      kind: LibraryMixKind.artist,
      key: artist,
      label: name,
      pool: pool.toList(),
      seeds: _byPlays(own, _random(LibraryMixKind.artist, artist)),
      anchor: artist,
      credits: {
        for (final credit in splitArtistTagValues(name)) _artistKey(credit),
      },
    );
  }

  /// The most played song of each of the genre's most played artists, or a
  /// song picked for the day when nothing in it was played.
  List<PlayableMedia> _seeds(List<PlayableMedia> core, Random random) {
    final ordered = _byPlays(core, random);
    final best = <String, PlayableMedia>{};
    for (final song in ordered) {
      if (plays(song) <= 0) break;
      best.putIfAbsent(_artistKey(song.artist), () => song);
    }
    final seeds = best.values.take(4).toList();
    return seeds.isNotEmpty ? seeds : ordered;
  }

  LibraryMix? _mix({
    required LibraryMixKind kind,
    required String key,
    required String label,
    required List<PlayableMedia> pool,
    required List<PlayableMedia> seeds,
    String anchor = '',
    Set<String> credits = const {},
  }) {
    final random = _random(kind, key);
    final songs = _compose(
      pool: pool,
      seeds: seeds,
      random: random,
      signal: _MixSignal(
        plays: request.plays,
        maxPlays: maxPlays,
        used: used,
        anchor: anchor,
        credits: credits,
      ),
    );
    if (songs.length < libraryMixMinSongs) return null;
    return LibraryMix(
      kind: kind,
      key: key,
      label: label,
      artists: _headliners(songs),
      songIds: [for (final song in songs) song.id],
    );
  }

  /// Picks songs as Autoplay refills its queue: the mix so far is the
  /// session, so genre fit, artist fatigue and spacing, album spreading and
  /// the signals apply as they do while playing. On top, no artist takes
  /// more than [_artistShare] of the mix or plays twice in a row, and songs
  /// whose files are gone are skipped.
  List<PlayableMedia> _compose({
    required List<PlayableMedia> pool,
    required List<PlayableMedia> seeds,
    required Random random,
    required _MixSignal signal,
  }) {
    var candidates = pool;
    if (pool.length > _poolLimit) {
      // The songs played most, then a sample for the day of the rest.
      final heard = pool.where((song) => plays(song) > 0).toList()
        ..sort(byPlays);
      final rest = pool.where((song) => plays(song) <= 0).toList()
        ..shuffle(random);
      candidates = {
        ...seeds.take(4),
        ...heard.take(_poolLimit ~/ 2),
        ...rest,
      }.take(_poolLimit).toList();
    }
    final target = min(libraryMixTargetSongs, candidates.length);
    final cap = max(2, (target * _artistShare).ceil());
    final mix = <PlayableMedia>[];
    final counts = <String, int>{};
    final excluded = <String>{};
    for (final seed in seeds) {
      if (exists(seed.source)) {
        mix.add(seed);
        counts[_artistKey(seed.artist)] = 1;
        break;
      }
      excluded.add(seed.source);
    }
    if (mix.isEmpty) return const [];
    final model = request.preference;
    final signals = [signal, ...request.signals];
    while (mix.length < target) {
      final capped = {
        for (final song in candidates)
          if ((counts[_artistKey(song.artist)] ?? 0) >= cap) song.source,
      };
      final previous = _learning(mix.last);
      final picks = rankAutoplayTracks(
        seed: mix.first,
        candidates: candidates,
        upcoming: mix.sublist(1),
        recent: const [],
        dismissedSources: {...excluded, ...capped},
        random: random,
        limit: min(6, target - mix.length),
        preferenceAdjustment: model == null
            ? null
            : (song) => model.rankAdjustment(
                _learning(song),
                previous: previous,
                at: request.at,
              ),
        signals: signals,
        weights: request.weights,
      );
      var added = 0;
      for (final pick in picks) {
        final song = pick.media;
        final artist = _artistKey(song.artist);
        if ((counts[artist] ?? 0) >= cap) continue;
        // Left for a later refill, once another artist sits between.
        if (artist.isNotEmpty && artist == _artistKey(mix.last.artist)) {
          continue;
        }
        if (!exists(song.source)) {
          excluded.add(song.source);
          continue;
        }
        mix.add(song);
        counts[artist] = (counts[artist] ?? 0) + 1;
        added++;
      }
      // Only artists that would repeat or exceed their share are left.
      if (added == 0) break;
    }
    return mix;
  }

  /// The three artists heard most in [mix], by songs, then plays.
  List<String> _headliners(List<PlayableMedia> mix) {
    final count = <String, int>{};
    final heard = <String, double>{};
    for (final song in mix) {
      final artist = _artistKey(song.artist);
      if (artist.isEmpty) continue;
      count[artist] = (count[artist] ?? 0) + 1;
      heard[artist] = (heard[artist] ?? 0) + plays(song);
    }
    final artists = count.keys.toList()
      ..sort((a, b) {
        final order = count[b]!.compareTo(count[a]!);
        return order != 0 ? order : heard[b]!.compareTo(heard[a]!);
      });
    return [for (final artist in artists.take(3)) artistNames[artist]!];
  }
}
