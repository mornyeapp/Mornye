import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/artist_screen.dart';
import 'package:mornye/screens/album_screen.dart';
import 'package:mornye/screens/extension_collection_screens.dart'
    show ExtensionArtistScreen, ExtensionAlbumScreen;
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';

final _log = AppLogger('ClickableMetadata');

class _MetadataSearchResult {
  final String providerId;
  final List<Map<String, dynamic>> items;

  const _MetadataSearchResult({required this.providerId, required this.items});
}

Future<_MetadataSearchResult?> _searchMetadataProviders(
  BuildContext context,
  String query, {
  required String filter,
  int limit = 5,
  String? sourceProviderId,
}) async {
  final providerIds = _metadataSearchProviderCandidates(
    context,
    sourceProviderId: sourceProviderId,
  );

  for (final providerId in providerIds) {
    try {
      final items = await _searchMetadataProvider(
        providerId,
        query,
        filter: filter,
        limit: limit,
      );
      if (items.isNotEmpty) {
        return _MetadataSearchResult(providerId: providerId, items: items);
      }
    } catch (e) {
      _log.w(
        'Metadata lookup failed for provider "$providerId", filter=$filter: $e',
      );
    }
  }

  return null;
}

Future<List<Map<String, dynamic>>> _searchMetadataProvider(
  String providerId,
  String query, {
  required String filter,
  required int limit,
}) async {
  return PlatformBridge.customSearchWithExtension(
    providerId,
    query,
    options: {'filter': filter, 'limit': limit},
  );
}

List<String> _metadataSearchProviderCandidates(
  BuildContext context, {
  String? sourceProviderId,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  final extensionState = container.read(extensionProvider);
  final settings = container.read(settingsProvider);
  final extensionNotifier = container.read(extensionProvider.notifier);
  final candidates = <String>[];

  void addProvider(String? providerId) {
    final normalized = providerId?.trim();
    if (normalized == null ||
        normalized.isEmpty ||
        candidates.contains(normalized) ||
        !_canSearchMetadataProvider(normalized, extensionState)) {
      return;
    }
    candidates.add(normalized);
  }

  addProvider(sourceProviderId);
  addProvider(settings.searchProvider);

  for (final providerId in extensionState.metadataProviderPriority) {
    addProvider(providerId);
  }
  for (final providerId in extensionNotifier.getAllMetadataProviders()) {
    addProvider(providerId);
  }

  final searchExtensions = extensionState.extensions
      .where((ext) => ext.enabled && ext.hasCustomSearch)
      .toList(growable: false);
  for (final extension in searchExtensions.where(
    (ext) => ext.searchBehavior?.primary == true,
  )) {
    addProvider(extension.id);
  }
  for (final extension in searchExtensions.where(
    (ext) => ext.searchBehavior?.primary != true,
  )) {
    addProvider(extension.id);
  }

  return candidates;
}

bool _canSearchMetadataProvider(
  String providerId,
  ExtensionState extensionState,
) {
  return extensionState.extensions.any(
    (ext) => ext.enabled && ext.hasCustomSearch && ext.id == providerId,
  );
}

Future<void> navigateToArtistCredits(
  BuildContext context, {
  required String artistNames,
  String? artistIds,
  String? extensionId,
}) async {
  final artists = _buildArtistTapTargets(artistNames, artistIds);
  if (artists.isEmpty) return;
  final selected = artists.length == 1
      ? artists.single
      : await showAppBottomSheet<_ArtistTapTarget>(
          context: context,
          useRootNavigator: true,
          title: context.l10n.mornyeGoToArtist,
          maxHeightFactor: 0.6,
          builder: (context) => ListView(
            shrinkWrap: true,
            children: [
              for (final artist in artists)
                AppSheetOption(
                  leading: const Icon(Icons.person_outline),
                  title: Text(artist.name),
                  onTap: () => Navigator.pop(context, artist),
                ),
            ],
          ),
        );
  if (!context.mounted || selected == null) return;
  await navigateToArtist(
    context,
    artistName: selected.name,
    artistId: selected.artistId,
    extensionId: extensionId,
  );
}

Future<void> navigateToArtist(
  BuildContext context, {
  required String artistName,
  String? artistId,
  String? coverUrl,
  String? extensionId,
}) async {
  if (artistName.isEmpty) return;

  final normalizedArtistId = _normalizeArtistId(artistId);

  if (normalizedArtistId != null &&
      _canNavigateArtistDirectly(
        artistId: normalizedArtistId,
        extensionId: extensionId,
      )) {
    _pushArtistScreen(
      context,
      artistId: normalizedArtistId,
      artistName: artistName,
      coverUrl: coverUrl,
      extensionId: extensionId,
    );
    return;
  }

  _showLoadingSnackBar(context, context.l10n.clickableLookingUpArtist);
  try {
    final searchResult = await _searchMetadataProviders(
      context,
      artistName,
      filter: 'artist',
      limit: 20,
      sourceProviderId: extensionId,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    final artistList = searchResult?.items ?? const <Map<String, dynamic>>[];
    if (artistList.isEmpty) {
      _showUnavailable(context, context.l10n.trackArtist);
      return;
    }

    final bestMatch = _pickBestResultByName(artistList, artistName);
    if (bestMatch == null) {
      _showUnavailable(context, context.l10n.trackArtist);
      return;
    }

    final resolvedId = bestMatch['id'] as String? ?? '';
    final resolvedName = bestMatch['name'] as String? ?? artistName;
    final resolvedImage = bestMatch['images'] as String?;
    final resolvedProviderId = _resolveResultProviderId(
      bestMatch,
      searchResult?.providerId,
    );

    if (resolvedId.isEmpty) {
      _showUnavailable(context, context.l10n.trackArtist);
      return;
    }

    if (!context.mounted) return;
    _pushArtistScreen(
      context,
      artistId: resolvedId,
      artistName: resolvedName,
      coverUrl: resolvedImage ?? coverUrl,
      extensionId: resolvedProviderId,
    );
  } catch (e) {
    _log.e('Failed to look up artist "$artistName": $e', e);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    _showUnavailable(context, context.l10n.trackArtist);
  }
}

Future<void> navigateToAlbum(
  BuildContext context, {
  required String albumName,
  String? albumId,
  String? artistName,
  String? coverUrl,
  String? extensionId,
}) async {
  if (albumName.isEmpty) return;

  if (albumId != null && albumId.isNotEmpty && !_isUnknownResourceId(albumId)) {
    _pushAlbumScreen(
      context,
      albumId: albumId,
      albumName: albumName,
      coverUrl: coverUrl,
      extensionId: extensionId,
    );
    return;
  }

  _showLoadingSnackBar(context, 'Looking up album...');
  try {
    final query = artistName != null && artistName.isNotEmpty
        ? '$albumName $artistName'
        : albumName;

    final searchResult = await _searchMetadataProviders(
      context,
      query,
      filter: 'album',
      limit: 20,
      sourceProviderId: extensionId,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    final albumList = searchResult?.items ?? const <Map<String, dynamic>>[];
    if (albumList.isEmpty) {
      _showUnavailable(context, 'Album');
      return;
    }

    final bestMatch = _pickBestResultByName(albumList, albumName);
    if (bestMatch == null) {
      _showUnavailable(context, 'Album');
      return;
    }

    final resolvedId = bestMatch['id'] as String? ?? '';
    final resolvedName = bestMatch['name'] as String? ?? albumName;
    final resolvedImage = bestMatch['images'] as String?;
    final resolvedProviderId = _resolveResultProviderId(
      bestMatch,
      searchResult?.providerId,
    );

    if (resolvedId.isEmpty) {
      _showUnavailable(context, 'Album');
      return;
    }

    if (!context.mounted) return;
    _pushAlbumScreen(
      context,
      albumId: resolvedId,
      albumName: resolvedName,
      coverUrl: resolvedImage ?? coverUrl,
      extensionId: resolvedProviderId,
    );
  } catch (e) {
    _log.e('Failed to look up album "$albumName": $e', e);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    _showUnavailable(context, 'Album');
  }
}

/// Opens the album for a track, enriching sparse search results first when
/// they do not include album identity. This keeps collection actions generic:
/// any metadata extension can supply the missing track fields through search.
Future<void> navigateToTrackAlbum(BuildContext context, Track track) async {
  final albumName = track.albumName.trim();
  final albumId = track.albumId?.trim();
  final hasAlbumId = albumId != null && !_isUnknownResourceId(albumId);

  if (albumName.isNotEmpty || hasAlbumId) {
    await navigateToAlbum(
      context,
      albumName: albumName.isNotEmpty ? albumName : context.l10n.trackAlbum,
      albumId: hasAlbumId ? albumId : null,
      artistName: _preferredAlbumArtist(track),
      coverUrl: track.coverUrl,
      extensionId: track.source,
    );
    return;
  }

  final query = [
    track.name.trim(),
    track.artistName.trim(),
  ].where((part) => part.isNotEmpty).join(' ');
  if (query.isEmpty) {
    _showUnavailable(context, context.l10n.trackAlbum);
    return;
  }

  _showLoadingSnackBar(context, 'Looking up album...');
  try {
    final searchResult = await _searchMetadataProviders(
      context,
      query,
      filter: 'track',
      limit: 20,
      sourceProviderId: track.source,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    final matches = searchResult?.items ?? const <Map<String, dynamic>>[];
    final bestMatch = _pickBestResultByName(matches, track.name);
    if (bestMatch == null) {
      _showUnavailable(context, context.l10n.trackAlbum);
      return;
    }

    final providerId = _resolveResultProviderId(
      bestMatch,
      searchResult?.providerId,
    );
    final resolvedTrack = Track.fromBackendMap(bestMatch, source: providerId);
    final resolvedAlbumName = resolvedTrack.albumName.trim();
    final resolvedAlbumId = resolvedTrack.albumId?.trim();
    final hasResolvedAlbumId =
        resolvedAlbumId != null && !_isUnknownResourceId(resolvedAlbumId);
    if (resolvedAlbumName.isEmpty && !hasResolvedAlbumId) {
      _showUnavailable(context, context.l10n.trackAlbum);
      return;
    }

    await navigateToAlbum(
      context,
      albumName: resolvedAlbumName.isNotEmpty
          ? resolvedAlbumName
          : context.l10n.trackAlbum,
      albumId: hasResolvedAlbumId ? resolvedAlbumId : null,
      artistName: _preferredAlbumArtist(resolvedTrack),
      coverUrl: resolvedTrack.coverUrl ?? track.coverUrl,
      extensionId: providerId,
    );
  } catch (e) {
    _log.e('Failed to resolve album for track "${track.name}": $e', e);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    _showUnavailable(context, context.l10n.trackAlbum);
  }
}

String _preferredAlbumArtist(Track track) {
  final albumArtist = (track.albumArtist ?? '').trim();
  return albumArtist.isNotEmpty ? albumArtist : track.artistName;
}

void _pushArtistScreen(
  BuildContext context, {
  required String artistId,
  required String artistName,
  String? coverUrl,
  String? extensionId,
}) {
  final isExtension = extensionId != null;
  final resolvedProviderId = extensionId;

  pushViaPreferredNavigator(
    context,
    (context) => isExtension && resolvedProviderId != null
        ? ExtensionArtistScreen(
            extensionId: resolvedProviderId,
            artistId: artistId,
            artistName: artistName,
            coverUrl: coverUrl,
          )
        : ArtistScreen(
            artistId: artistId,
            artistName: artistName,
            coverUrl: coverUrl,
            extensionId: resolvedProviderId,
          ),
  );
}

void _pushAlbumScreen(
  BuildContext context, {
  required String albumId,
  required String albumName,
  String? coverUrl,
  String? extensionId,
}) {
  final isExtension = extensionId != null;
  final resolvedExtensionId = extensionId;

  pushViaPreferredNavigator(
    context,
    (context) => isExtension && resolvedExtensionId != null
        ? ExtensionAlbumScreen(
            extensionId: resolvedExtensionId,
            albumId: albumId,
            albumName: albumName,
            coverUrl: coverUrl,
          )
        : AlbumScreen(
            albumId: albumId,
            albumName: albumName,
            coverUrl: coverUrl,
            extensionId: resolvedExtensionId,
            tracks: const [],
          ),
    page: DetailPage.album(albumId, providerId: extensionId),
  );
}

/// The catalog page a route shows, so a link to the page already on top
/// keeps it instead of stacking a copy. A page without a provider matches
/// the same id from any provider.
class DetailPage {
  const DetailPage.album(this.id, {this.providerId}) : kind = 'album';

  final String kind;
  final String id;
  final String? providerId;

  bool matches(DetailPage other) =>
      kind == other.kind &&
      id == other.id &&
      (providerId == null ||
          other.providerId == null ||
          providerId == other.providerId);

  static final _routes = Expando<DetailPage>('detail page');

  /// Records that the route around [context] shows [page].
  static void mark(BuildContext context, DetailPage page) {
    final route = ModalRoute.of(context);
    if (route != null) _routes[route] = page;
  }

  static bool _isOnTop(NavigatorState navigator, DetailPage page) {
    Route<dynamic>? top;
    // Reads the top route without popping anything.
    navigator.popUntil((route) {
      top = route;
      return true;
    });
    final shown = top == null ? null : _routes[top!];
    return shown != null && shown.matches(page);
  }
}

/// Pushes detail pages into the active tab navigator when invoked from a root
/// modal such as Now Playing. The root modal is dismissed first so the album
/// is immediately visible instead of being hidden behind it. A [page] that
/// is already on top is not pushed again.
void pushViaPreferredNavigator(
  BuildContext context,
  WidgetBuilder builder, {
  DetailPage? page,
}) {
  final currentNavigator = Navigator.of(context);
  final rootNavigator = Navigator.of(context, rootNavigator: true);
  final activeTabNavigator = ShellNavigationService.activeTabNavigator();

  void push(NavigatorState navigator) {
    if (page != null && DetailPage._isOnTop(navigator, page)) return;
    navigator.push(MaterialPageRoute<void>(builder: builder));
  }

  final shouldRouteToTabNavigator =
      identical(currentNavigator, rootNavigator) && activeTabNavigator != null;

  if (!shouldRouteToTabNavigator) {
    push(currentNavigator);
    return;
  }

  final currentRoute = ModalRoute.of(context);
  final shouldPopCurrentRoute =
      currentRoute != null && currentRoute.isFirst == false;

  if (shouldPopCurrentRoute && currentNavigator.canPop()) {
    currentNavigator.pop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!activeTabNavigator.mounted) return;
      push(activeTabNavigator);
    });
    return;
  }

  push(activeTabNavigator);
}

/// Pushes a [MaterialPageRoute] built by [builder] onto the nearest navigator.
Future<T?> pushPage<T>(BuildContext context, WidgetBuilder builder) =>
    Navigator.push(context, MaterialPageRoute<T>(builder: builder));

void _showLoadingSnackBar(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: [
          const AppLoadingIndicator(size: 16, strokeWidth: 2),
          const SizedBox(width: 12),
          Text(message),
        ],
      ),
      duration: const Duration(seconds: 10),
    ),
  );
}

void _showUnavailable(BuildContext context, String type) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(context.l10n.clickableInformationUnavailable(type))),
  );
}

class ClickableArtistName extends StatefulWidget {
  final String artistName;
  final String? artistId;
  final String? coverUrl;
  final String? extensionId;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  const ClickableArtistName({
    super.key,
    required this.artistName,
    this.artistId,
    this.coverUrl,
    this.extensionId,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  @override
  State<ClickableArtistName> createState() => _ClickableArtistNameState();
}

class _ClickableArtistNameState extends State<ClickableArtistName> {
  List<_ArtistTapTarget> _artistTargets = const [];
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void initState() {
    super.initState();
    _rebuildArtistTargets();
  }

  @override
  void didUpdateWidget(covariant ClickableArtistName oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artistName != widget.artistName ||
        oldWidget.artistId != widget.artistId ||
        oldWidget.coverUrl != widget.coverUrl ||
        oldWidget.extensionId != widget.extensionId) {
      _rebuildArtistTargets();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  void _rebuildArtistTargets() {
    _disposeRecognizers();
    _artistTargets = _buildArtistTapTargets(widget.artistName, widget.artistId);
    if (_artistTargets.length <= 1) return;

    for (final target in _artistTargets) {
      final recognizer = TapGestureRecognizer()
        ..onTap = () => navigateToArtist(
          context,
          artistName: target.name,
          artistId: target.artistId,
          coverUrl: widget.coverUrl,
          extensionId: _extensionIdForTarget(target),
        );
      _recognizers.add(recognizer);
    }
  }

  String? _extensionIdForTarget(_ArtistTapTarget target) {
    if (widget.extensionId == null) return null;
    if (_artistTargets.length == 1) return widget.extensionId;
    return target.artistId != null ? widget.extensionId : null;
  }

  List<InlineSpan> _buildMultiArtistSpans() {
    final spans = <InlineSpan>[];
    for (var i = 0; i < _artistTargets.length; i++) {
      final target = _artistTargets[i];
      spans.add(
        TextSpan(
          text: target.name,
          style: widget.style,
          recognizer: _recognizers[i],
        ),
      );
      if (i < _artistTargets.length - 1) {
        spans.add(TextSpan(text: ', ', style: widget.style));
      }
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    if (_artistTargets.isEmpty) {
      return Text(
        widget.artistName,
        style: widget.style,
        maxLines: widget.maxLines,
        overflow: widget.overflow,
        textAlign: widget.textAlign,
      );
    }

    if (_artistTargets.length == 1) {
      final target = _artistTargets.first;
      return GestureDetector(
        onTap: () => navigateToArtist(
          context,
          artistName: target.name,
          artistId: target.artistId,
          coverUrl: widget.coverUrl,
          extensionId: _extensionIdForTarget(target),
        ),
        child: Text(
          target.name,
          style: widget.style,
          maxLines: widget.maxLines,
          overflow: widget.overflow,
          textAlign: widget.textAlign,
        ),
      );
    }

    return Text.rich(
      TextSpan(style: widget.style, children: _buildMultiArtistSpans()),
      maxLines: widget.maxLines,
      overflow: widget.overflow ?? TextOverflow.clip,
      textAlign: widget.textAlign ?? TextAlign.start,
    );
  }
}

class _ArtistTapTarget {
  final String name;
  final String? artistId;

  const _ArtistTapTarget({required this.name, this.artistId});
}

List<_ArtistTapTarget> _buildArtistTapTargets(
  String rawArtistNames,
  String? rawArtistIds,
) {
  final parsedIds = _parseArtistIds(rawArtistIds);
  final parsedNames = splitArtistNames(
    rawArtistNames,
    creditedArtistCount: parsedIds.length,
  );
  if (parsedNames.isEmpty) return const [];

  final uniqueNames = <String>[];
  final seen = <String>{};
  for (final parsed in parsedNames) {
    final key = parsed.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (key.isEmpty || !seen.add(key)) continue;
    uniqueNames.add(parsed);
  }
  if (uniqueNames.isEmpty) return const [];

  if (uniqueNames.length == 1) {
    return [
      _ArtistTapTarget(
        name: uniqueNames.first,
        artistId: _normalizeArtistId(rawArtistIds),
      ),
    ];
  }

  if (parsedIds.isEmpty || !parsedIds.any((id) => id != null)) {
    return uniqueNames
        .map((name) => _ArtistTapTarget(name: name))
        .toList(growable: false);
  }

  // Providers may return one id per artist (aligned with the names) or only
  // the primary artist's id. Map ids to names positionally, preserving empty
  // slots as null, so each tapped artist navigates by its own id when known.
  return List<_ArtistTapTarget>.generate(
    uniqueNames.length,
    (index) => _ArtistTapTarget(
      name: uniqueNames[index],
      artistId: index < parsedIds.length ? parsedIds[index] : null,
    ),
    growable: false,
  );
}

List<String?> _parseArtistIds(String? rawArtistIds) {
  final raw = rawArtistIds?.trim();
  if (raw == null || raw.isEmpty) return const [];

  return raw
      .split(RegExp(r'\s*,\s*'))
      .map(_normalizeArtistId)
      .toList(growable: false);
}

String? _normalizeArtistId(String? artistId) {
  final id = artistId?.trim();
  if (id == null || _isUnknownResourceId(id)) {
    return null;
  }
  return id;
}

bool _isUnknownResourceId(String id) {
  final normalized = id.trim().toLowerCase();
  return normalized.isEmpty ||
      normalized == 'unknown' ||
      normalized.endsWith(':unknown');
}

String? _resolveResultProviderId(
  Map<String, dynamic> result,
  String? fallbackProviderId,
) {
  final providerId = result['provider_id']?.toString().trim();
  if (providerId != null && providerId.isNotEmpty) return providerId;
  final source = result['source']?.toString().trim();
  if (source != null && source.isNotEmpty) return source;
  final fallback = fallbackProviderId?.trim();
  return fallback != null && fallback.isNotEmpty ? fallback : null;
}

bool _canNavigateArtistDirectly({
  required String artistId,
  required String? extensionId,
}) {
  if (extensionId != null) return true;
  return _spotifyArtistIdPattern.hasMatch(artistId);
}

/// Selects the result whose name best matches [query] instead of blindly
/// trusting the provider's first result. This prevents tapping an artist like
/// "creo" from opening a completely unrelated artist (e.g. "Tyler, the
/// Creator") just because the provider ranked it first.
Map<String, dynamic>? _pickBestResultByName(
  List<Map<String, dynamic>> results,
  String query,
) {
  if (results.isEmpty) return null;

  final normalizedQuery = _normalizeForMatch(query);
  if (normalizedQuery.isEmpty) return results.first;

  Map<String, dynamic>? best;
  double bestScore = -1;
  for (final result in results) {
    final name = result['name'] as String? ?? '';
    final normalizedName = _normalizeForMatch(name);
    if (normalizedName.isEmpty) continue;

    if (normalizedName == normalizedQuery) {
      return result;
    }

    final score = _nameMatchScore(normalizedQuery, normalizedName);
    if (score > bestScore) {
      bestScore = score;
      best = result;
    }
  }

  // Accept a fuzzy match only when it is reasonably close. Otherwise fall back
  // to the provider's own top result so we never crash on an empty match.
  if (best != null && bestScore >= 0.5) {
    if (bestScore < 0.85) {
      _log.w(
        'No exact match for "$query"; using closest result '
        '"${best['name']}" (score ${bestScore.toStringAsFixed(2)})',
      );
    }
    return best;
  }

  _log.w(
    'No close match for "$query" among ${results.length} results; '
    'falling back to first result "${results.first['name']}"',
  );
  return results.first;
}

String _normalizeForMatch(String value) {
  return value
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Returns a similarity score in [0, 1] between two normalized names.
double _nameMatchScore(String query, String candidate) {
  if (query == candidate) return 1.0;

  final queryTokens = query.split(' ').where((t) => t.isNotEmpty).toSet();
  final candidateTokens = candidate
      .split(' ')
      .where((t) => t.isNotEmpty)
      .toSet();
  if (queryTokens.isEmpty || candidateTokens.isEmpty) return 0;

  final intersection = queryTokens.intersection(candidateTokens).length;
  final union = queryTokens.union(candidateTokens).length;
  final jaccard = union == 0 ? 0.0 : intersection / union;

  // Reward full substring containment of the (shorter) query in the candidate.
  double containment = 0;
  if (candidate.contains(query) || query.contains(candidate)) {
    final shorter = query.length < candidate.length ? query : candidate;
    final longer = query.length < candidate.length ? candidate : query;
    containment = longer.isEmpty ? 0 : shorter.length / longer.length;
  }

  return jaccard > containment ? jaccard : containment;
}

final RegExp _spotifyArtistIdPattern = RegExp(r'^[A-Za-z0-9]{22}$');

class ClickableAlbumName extends StatelessWidget {
  final String albumName;
  final String? albumId;
  final String? artistName;
  final String? coverUrl;
  final String? extensionId;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  const ClickableAlbumName({
    super.key,
    required this.albumName,
    this.albumId,
    this.artistName,
    this.coverUrl,
    this.extensionId,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => navigateToAlbum(
        context,
        albumName: albumName,
        albumId: albumId,
        artistName: artistName,
        coverUrl: coverUrl,
        extensionId: extensionId,
      ),
      child: Text(
        albumName,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      ),
    );
  }
}
