import 'package:mornye/models/track.dart';
import 'package:mornye/providers/extension_provider.dart';

bool looksLikeUrlOrSpotifyUri(String text) =>
    text.startsWith('http') || text.startsWith('spotify:');

class HomeSearchResultBuckets {
  final List<Track> realTracks;
  final List<int> realTrackIndexes;
  final List<Track> albumItems;
  final List<Track> playlistItems;
  final List<Track> artistItems;

  const HomeSearchResultBuckets({
    required this.realTracks,
    required this.realTrackIndexes,
    required this.albumItems,
    required this.playlistItems,
    required this.artistItems,
  });
}

HomeSearchResultBuckets bucketHomeSearchResults(List<Track> tracks) {
  final realTracks = <Track>[];
  final realTrackIndexes = <int>[];
  final albumItems = <Track>[];
  final playlistItems = <Track>[];
  final artistItems = <Track>[];

  for (var index = 0; index < tracks.length; index++) {
    final track = tracks[index];
    if (!track.isCollection) {
      realTracks.add(track);
      realTrackIndexes.add(index);
    }
    if (track.isAlbumItem) albumItems.add(track);
    if (track.isPlaylistItem) playlistItems.add(track);
    if (track.isArtistItem) artistItems.add(track);
  }

  return HomeSearchResultBuckets(
    realTracks: realTracks,
    realTrackIndexes: realTrackIndexes,
    albumItems: albumItems,
    playlistItems: playlistItems,
    artistItems: artistItems,
  );
}

enum HomeSearchSortOption {
  defaultOrder,
  titleAsc,
  titleDesc,
  artistAsc,
  artistDesc,
  durationAsc,
  durationDesc,
  dateAsc,
  dateDesc,
}

List<T> sortHomeSearchItems<T>({
  required List<T> items,
  required HomeSearchSortOption option,
  required String Function(T) nameOf,
  required String Function(T) artistOf,
  required int Function(T) durationOf,
  required String? Function(T) dateOf,
}) {
  if (option == HomeSearchSortOption.defaultOrder) return items;

  final sorted = List<T>.of(items);
  switch (option) {
    case HomeSearchSortOption.defaultOrder:
      break;
    case HomeSearchSortOption.titleAsc:
      sorted.sort(
        (a, b) => nameOf(a).toLowerCase().compareTo(nameOf(b).toLowerCase()),
      );
    case HomeSearchSortOption.titleDesc:
      sorted.sort(
        (a, b) => nameOf(b).toLowerCase().compareTo(nameOf(a).toLowerCase()),
      );
    case HomeSearchSortOption.artistAsc:
      sorted.sort(
        (a, b) =>
            artistOf(a).toLowerCase().compareTo(artistOf(b).toLowerCase()),
      );
    case HomeSearchSortOption.artistDesc:
      sorted.sort(
        (a, b) =>
            artistOf(b).toLowerCase().compareTo(artistOf(a).toLowerCase()),
      );
    case HomeSearchSortOption.durationAsc:
      sorted.sort((a, b) => durationOf(a).compareTo(durationOf(b)));
    case HomeSearchSortOption.durationDesc:
      sorted.sort((a, b) => durationOf(b).compareTo(durationOf(a)));
    case HomeSearchSortOption.dateAsc:
      sorted.sort((a, b) => (dateOf(a) ?? '').compareTo(dateOf(b) ?? ''));
    case HomeSearchSortOption.dateDesc:
      sorted.sort((a, b) => (dateOf(b) ?? '').compareTo(dateOf(a) ?? ''));
  }
  return sorted;
}

/// Provider and filter selection rules shared by the home search surface and
/// its provider dropdown.
class HomeSearchProviderPolicy {
  const HomeSearchProviderPolicy._();

  static Extension? defaultExtension(List<Extension> extensions) {
    return defaultSearchExtension(extensions);
  }

  static String? resolveProvider(
    String? explicitSearchProvider,
    List<Extension> extensions,
  ) {
    final explicit = explicitSearchProvider?.trim();
    if (explicit != null &&
        explicit.isNotEmpty &&
        extensions.any(
          (extension) =>
              extension.enabled &&
              extension.hasCustomSearch &&
              extension.id == explicit,
        )) {
      return explicit;
    }
    return defaultExtension(extensions)?.id;
  }

  static bool hasProvider(
    String? explicitSearchProvider,
    List<Extension> extensions,
  ) {
    return resolveProvider(explicitSearchProvider, extensions) != null;
  }

  static String? sanitizeFilter(
    String? filter,
    String? currentSearchProvider,
    List<Extension> extensions,
  ) {
    if (filter == null || filter.isEmpty) {
      return null;
    }

    final canonicalFilter = canonicalFilterId(filter);
    if (currentSearchProvider == null || currentSearchProvider.isEmpty) {
      return switch (canonicalFilter) {
        'track' || 'artist' || 'album' || 'playlist' => canonicalFilter,
        _ => null,
      };
    }

    final extension = extensions
        .where(
          (candidate) =>
              candidate.id == currentSearchProvider && candidate.enabled,
        )
        .firstOrNull;
    final filters = extension?.searchBehavior?.filters;
    if (filters == null || filters.isEmpty) {
      return null;
    }

    return extension?.searchBehavior?.filterIdForKind(canonicalFilter);
  }

  static String canonicalFilterId(String value) =>
      canonicalExtensionSearchFilterId(value);

  static String? preferredFilter(
    String preferredSearchTab,
    String? currentSearchProvider,
    List<Extension> extensions,
  ) {
    final preferred = switch (preferredSearchTab) {
      'track' => 'track',
      'artist' => 'artist',
      'album' => 'album',
      'playlist' => 'playlist',
      _ => null,
    };

    return sanitizeFilter(preferred, currentSearchProvider, extensions);
  }

  static String displayFilterSelection(
    String? selectedSearchFilter,
    String preferredSearchTab,
    String? currentSearchProvider,
    List<Extension> extensions,
  ) {
    if (selectedSearchFilter == 'all') {
      return 'all';
    }
    if (selectedSearchFilter != null && selectedSearchFilter.isNotEmpty) {
      return sanitizeFilter(
            selectedSearchFilter,
            currentSearchProvider,
            extensions,
          ) ??
          'all';
    }
    return preferredFilter(
          preferredSearchTab,
          currentSearchProvider,
          extensions,
        ) ??
        'all';
  }
}
