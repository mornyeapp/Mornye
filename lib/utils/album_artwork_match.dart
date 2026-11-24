import 'package:mornye/utils/provider_resource_ids.dart';
import 'package:mornye/utils/string_utils.dart';

/// A Local Library album that artwork is looked up for.
class ArtworkAlbum {
  const ArtworkAlbum({
    required this.key,
    required this.album,
    required this.artist,
    this.trackCount = 0,
    this.year,
  });

  /// The Library's `album_key`.
  final String key;
  final String album;

  /// The album artist, or the song artist when the tags have none.
  final String artist;
  final int trackCount;
  final int? year;
}

/// An album a metadata provider returned for an [ArtworkAlbum].
class ArtworkCandidate {
  const ArtworkCandidate({
    required this.providerId,
    required this.albumId,
    required this.name,
    required this.artists,
    this.coverUrl,
    this.totalTracks = 0,
    this.year,
  });

  final String providerId;
  final String albumId;
  final String name;
  final String artists;
  final String? coverUrl;
  final int totalTracks;
  final int? year;

  /// Reads a search result. An album result names the album itself; a song
  /// result names the album it is on, which works as well for its cover.
  static ArtworkCandidate? fromSearchResult(
    String providerId,
    Map<String, dynamic> result,
  ) {
    String text(String key) => result[key]?.toString().trim() ?? '';
    final type = text('item_type').toLowerCase();
    final album = type == 'album';
    final name = album ? text('name') : text('album_name');
    final id = album ? text('id') : text('album_id');
    if (type.isNotEmpty && !album && type != 'track') return null;
    if (name.isEmpty || id.isEmpty) return null;
    final albumArtist = text('album_artist');
    return ArtworkCandidate(
      providerId: providerId,
      albumId: stripPrefixedResourceId(id),
      name: name,
      artists: albumArtist.isNotEmpty && !album
          ? albumArtist
          : text('artists').isNotEmpty
          ? text('artists')
          : text('artist'),
      coverUrl: normalizeRemoteHttpUrl(
        (result['cover_url'] ?? result['images'])?.toString(),
      ),
      totalTracks: album ? int.tryParse(text('total_tracks')) ?? 0 : 0,
      year: album ? artworkYear(text('release_date')) : null,
    );
  }
}

/// The year of a release date such as `2011-05-02` or `2011`.
int? artworkYear(String? value) {
  final match = RegExp(r'^\s*(\d{4})').firstMatch(value ?? '');
  return match == null ? null : int.parse(match.group(1)!);
}

final _separators = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// [value] in lower case with `&` read as "and" and punctuation as spaces,
/// so "Tom & Jerry!" and "tom and jerry" compare equal.
String artworkMatchText(String value) => value
    .toLowerCase()
    .replaceAll('&', ' and ')
    .replaceAll(_separators, ' ')
    .trim();

final _trailingQualifier = RegExp(r'\s*[(\[][^()\[\]]*[)\]]\s*$');
final _trailingEdition = RegExp(
  r'\s+-\s+(ep|single|(deluxe|expanded|remaster|anniversary|special|bonus)'
  r'[^-]*)$',
  caseSensitive: false,
);

/// An album title without the edition it ends with, such as
/// "(Deluxe Edition)", "[Remastered 2011]" or " - EP".
String artworkBaseTitle(String value) {
  var title = value.trim();
  while (true) {
    final shorter = title
        .replaceFirst(_trailingQualifier, '')
        .replaceFirst(_trailingEdition, '')
        .trim();
    if (shorter == title || shorter.isEmpty) break;
    title = shorter;
  }
  return artworkMatchText(title);
}

bool _artistMatches(String local, String candidate) {
  final mine = artworkMatchText(local);
  final theirs = artworkMatchText(candidate);
  if (mine.isEmpty || theirs.isEmpty) return false;
  return mine == theirs ||
      ' $theirs '.contains(' $mine ') ||
      ' $mine '.contains(' $theirs ');
}

/// The lowest score a candidate needs: the same title, or the same title
/// without its edition with nothing else against it.
const artworkMatchThreshold = 70;

/// How well [candidate] fits [album], or null when it is another album.
///
/// The artist must match and so must the title, exactly or without the
/// edition. A provider album with fewer songs than the local one, or a
/// release year more than a year apart, is likely another edition and
/// counts against it; a matching song count or year counts for it.
int? artworkMatchScore(ArtworkAlbum album, ArtworkCandidate candidate) {
  if (!_artistMatches(album.artist, candidate.artists)) return null;
  final int base;
  if (artworkMatchText(album.album) == artworkMatchText(candidate.name)) {
    base = 100;
  } else {
    final title = artworkBaseTitle(album.album);
    if (title.isEmpty || title != artworkBaseTitle(candidate.name)) {
      return null;
    }
    base = 70;
  }
  var score = base;
  if (album.trackCount > 0 && candidate.totalTracks > 0) {
    if (album.trackCount > candidate.totalTracks + 1) {
      score -= 40;
    } else if (album.trackCount == candidate.totalTracks) {
      score += 10;
    }
  }
  final (mine, theirs) = (album.year, candidate.year);
  if (mine != null && theirs != null) {
    final gap = (mine - theirs).abs();
    if (gap == 0) {
      score += 10;
    } else if (gap > 1) {
      score -= 20;
    }
  }
  return score;
}

/// The best of [candidates] for [album], or null when none is close enough.
/// Ties keep the earlier one, which the provider ranked higher.
ArtworkCandidate? pickArtworkCandidate(
  ArtworkAlbum album,
  Iterable<ArtworkCandidate> candidates,
) {
  ArtworkCandidate? best;
  var bestScore = artworkMatchThreshold - 1;
  for (final candidate in candidates) {
    final score = artworkMatchScore(album, candidate);
    if (score != null && score > bestScore) {
      best = candidate;
      bestScore = score;
    }
  }
  return best;
}
