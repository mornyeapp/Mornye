import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/explore_cache_store.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';

final _log = AppLogger('ExploreProvider');

final homeFeedExtensionProvider = Provider<Extension?>((ref) {
  final preferred = ref.watch(
    settingsProvider.select((settings) => settings.homeFeedProvider),
  );
  if (preferred == AppSettings.homeFeedProviderOff) return null;
  final extensions = ref.watch(
    extensionProvider.select((state) => state.extensions),
  );
  final available = extensions.where((ext) => ext.enabled && ext.hasHomeFeed);
  if (preferred != null && preferred.isNotEmpty) {
    return available.where((ext) => ext.id == preferred).firstOrNull;
  }
  return available.firstOrNull;
});

class ExploreItem {
  final String id;
  final String uri;
  final String type;
  final String name;
  final String artists;
  final String? description;
  final String? coverUrl;
  final String? featuredCoverUrl;
  final String? heading;
  final bool? explicit;
  final String? providerId;
  final String? albumId;
  final String? albumName;
  final String? releaseDate;
  final int durationMs;

  const ExploreItem({
    required this.id,
    required this.uri,
    required this.type,
    required this.name,
    required this.artists,
    this.description,
    this.coverUrl,
    this.featuredCoverUrl,
    this.heading,
    this.explicit,
    this.providerId,
    this.albumId,
    this.albumName,
    this.releaseDate,
    this.durationMs = 0,
  });

  factory ExploreItem.fromJson(Map<String, dynamic> json) {
    return ExploreItem(
      id: json['id'] as String? ?? '',
      uri: json['uri'] as String? ?? '',
      type: json['type'] as String? ?? 'track',
      name: json['name'] as String? ?? '',
      artists: json['artists'] as String? ?? '',
      description: json['description'] as String?,
      coverUrl: json['cover_url'] as String?,
      featuredCoverUrl: json['featured_cover_url'] as String?,
      heading: json['heading'] as String?,
      explicit: parseExplicitFlag(json['explicit']),
      providerId: json['provider_id'] as String?,
      albumId: json['album_id'] as String?,
      albumName: json['album_name'] as String?,
      releaseDate: json['release_date']?.toString(),
      durationMs: json['duration_ms'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'uri': uri,
    'type': type,
    'name': name,
    'artists': artists,
    'description': description,
    'cover_url': coverUrl,
    'featured_cover_url': featuredCoverUrl,
    'heading': heading,
    'explicit': explicit,
    'provider_id': providerId,
    'album_id': albumId,
    'album_name': albumName,
    'release_date': releaseDate,
    'duration_ms': durationMs,
  };
}

class ExploreSection {
  final String uri;
  final String title;
  final List<ExploreItem> items;
  final bool isQuickPicks;
  final bool isFeatured;

  const ExploreSection({
    required this.uri,
    required this.title,
    required this.items,
    this.isQuickPicks = false,
    this.isFeatured = false,
  });

  factory ExploreSection.fromJson(Map<String, dynamic> json) {
    final itemsList = json['items'] as List<dynamic>? ?? [];
    final items = itemsList
        .map((item) => ExploreItem.fromJson(item as Map<String, dynamic>))
        .toList();
    final layout = json['layout'];
    // Older feeds omit layout. Infer a compact track list from its content.
    // Compact rows expose track actions, so other item types use cards even
    // when a feed requests quick-picks.
    final isQuickPicks =
        (layout == null || layout == 'quick-picks') &&
        _isQuickPicksItems(items);
    return ExploreSection(
      uri: json['uri'] as String? ?? '',
      title: json['title'] as String? ?? '',
      items: items,
      isQuickPicks: isQuickPicks,
      isFeatured: layout == 'featured',
    );
  }

  Map<String, dynamic> toJson() => {
    'uri': uri,
    'title': title,
    'layout': isFeatured
        ? 'featured'
        : isQuickPicks
        ? 'quick-picks'
        : 'shelf',
    'items': items.map((i) => i.toJson()).toList(),
  };
}

class ExploreState {
  final bool isLoading;
  final String? error;
  final String? greeting;
  final String? providerId;
  final List<ExploreSection> sections;
  final DateTime? lastFetched;

  const ExploreState({
    this.isLoading = false,
    this.error,
    this.greeting,
    this.providerId,
    this.sections = const [],
    this.lastFetched,
  });

  bool get hasContent => sections.isNotEmpty;

  ExploreState copyWith({
    bool? isLoading,
    String? error,
    String? greeting,
    String? providerId,
    bool clearProviderId = false,
    List<ExploreSection>? sections,
    DateTime? lastFetched,
  }) {
    return ExploreState(
      isLoading: isLoading ?? this.isLoading,
      error: error,
      greeting: greeting ?? this.greeting,
      providerId: clearProviderId ? null : (providerId ?? this.providerId),
      sections: sections ?? this.sections,
      lastFetched: lastFetched ?? this.lastFetched,
    );
  }
}

String _getLocalGreeting() {
  final hour = DateTime.now().hour;
  if (hour >= 5 && hour < 12) {
    return 'Good morning';
  } else if (hour >= 12 && hour < 17) {
    return 'Good afternoon';
  } else if (hour >= 17 && hour < 21) {
    return 'Good evening';
  } else {
    return 'Good night';
  }
}

bool _isQuickPicksItems(List<ExploreItem> items) {
  if (items.isEmpty) return false;
  for (final item in items) {
    if (item.type != 'track') {
      return false;
    }
  }
  return true;
}

List<Map<String, Object?>> _normalizeExploreSectionsPayload(
  dynamic rawSections,
) {
  if (rawSections is! List) return const [];
  final sections = <Map<String, Object?>>[];
  for (final rawSection in rawSections) {
    if (rawSection is! Map) continue;
    final section = Map<Object?, Object?>.from(rawSection);
    final rawItems = section['items'];
    final items = <Map<String, Object?>>[];
    if (rawItems is List) {
      for (final rawItem in rawItems) {
        if (rawItem is! Map) continue;
        items.add(Map<String, Object?>.from(rawItem));
      }
    }
    sections.add({
      'uri': section['uri']?.toString() ?? '',
      'title': section['title']?.toString() ?? '',
      if (section['layout'] != null) 'layout': section['layout'].toString(),
      'items': items,
    });
  }
  return sections;
}

List<Map<String, Object?>> _withDefaultExploreProviderId(
  List<Map<String, Object?>> normalizedSections,
  String providerId,
) {
  final normalizedProviderId = providerId.trim();
  if (normalizedProviderId.isEmpty) return normalizedSections;

  return normalizedSections
      .map((section) {
        final rawItems = section['items'];
        if (rawItems is! List) return section;

        return <String, Object?>{
          ...section,
          'items': rawItems
              .map((rawItem) {
                if (rawItem is! Map) return rawItem;
                final item = Map<String, Object?>.from(rawItem);
                final itemProviderId =
                    item['provider_id']?.toString().trim() ?? '';
                if (itemProviderId.isEmpty) {
                  item['provider_id'] = normalizedProviderId;
                }
                return item;
              })
              .toList(growable: false),
        };
      })
      .toList(growable: false);
}

Map<String, Object?> _decodeExploreCache(String rawCache) {
  final decoded = jsonDecode(rawCache);
  if (decoded is! Map) {
    return const {'provider_id': null, 'sections': <Map<String, Object?>>[]};
  }

  final providerId = decoded['provider_id']?.toString().trim();
  var sections = _normalizeExploreSectionsPayload(decoded['sections']);
  if (providerId != null && providerId.isNotEmpty) {
    sections = _withDefaultExploreProviderId(sections, providerId);
  }

  return {
    'provider_id': providerId,
    'region': decoded['region'],
    'sections': sections,
  };
}

String _encodeExploreCache(Map<String, Object?> cachePayload) {
  return jsonEncode(cachePayload);
}

List<ExploreSection> _buildExploreSectionsFromNormalizedPayload(
  List<Map<String, Object?>> normalizedSections,
) {
  return normalizedSections
      .map(
        (section) =>
            ExploreSection.fromJson(Map<String, dynamic>.from(section)),
      )
      .toList(growable: false);
}

class ExploreNotifier extends Notifier<ExploreState> {
  ExploreNotifier({Future<Map<String, Object?>> Function(String)? decodeCache})
    : _decodeCache =
          decodeCache ?? ((raw) => compute(_decodeExploreCache, raw));

  final Future<Map<String, Object?>> Function(String) _decodeCache;
  int _homeFeedRequestId = 0;
  int? _activeHomeFeedRequestId;
  int _cacheRestoreGeneration = 0;

  bool _isRequestValid(int requestId) =>
      ref.mounted && requestId == _homeFeedRequestId;

  bool _isCacheRestoreValid(int generation) =>
      ref.mounted &&
      generation == _cacheRestoreGeneration &&
      ref.read(settingsProvider).homeFeedProvider !=
          AppSettings.homeFeedProviderOff;

  @override
  ExploreState build() {
    ref.listen(extensionProvider.select((state) => state.settingsRevisions), (
      previous,
      next,
    ) {
      final extension = _resolveHomeFeedExtension();
      if (extension != null && previous?[extension.id] != next[extension.id]) {
        _reloadConfiguration(extension.id);
      }
    });
    _restoreFromCache();
    return const ExploreState();
  }

  Future<void> _restoreFromCache() async {
    final generation = _cacheRestoreGeneration;
    try {
      if (ref.read(settingsProvider).homeFeedProvider ==
          AppSettings.homeFeedProviderOff) {
        _log.d('Home feed disabled, skipping cache restore');
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      if (!_isCacheRestoreValid(generation)) return;
      final snapshot = await ExploreCacheStore(prefs).read();
      if (!_isCacheRestoreValid(generation)) return;
      final cached = snapshot.payload;
      final cachedTs = snapshot.timestampMs;
      if (cached == null || cached.isEmpty) return;

      final cachePayload = await _decodeCache(cached);
      if (!_isCacheRestoreValid(generation)) return;
      final providerId = cachePayload['provider_id']?.toString().trim();
      final rawSections = cachePayload['sections'];
      var normalizedSections = rawSections is List
          ? rawSections
                .whereType<Map<Object?, Object?>>()
                .map((section) => Map<String, Object?>.from(section))
                .toList(growable: false)
          : const <Map<String, Object?>>[];
      final resolvedProviderId = providerId?.isNotEmpty == true
          ? providerId
          : _resolveHomeFeedExtension()?.id;
      var extension = _resolveHomeFeedExtension();
      if (extension == null && cachePayload['region'] != null) {
        // Regional caches cannot be validated until installed manifests and
        // their saved settings are available on a cold launch.
        await ref.read(extensionProvider.notifier).ensureInitialized();
        if (!_isCacheRestoreValid(generation)) return;
        extension = _resolveHomeFeedExtension();
        if (extension == null) return;
      }
      if (extension != null) {
        if (resolvedProviderId != extension.id) return;
        final region = await _homeFeedRegion(extension);
        if (!_isCacheRestoreValid(generation)) return;
        if (cachePayload['region'] != region) return;
      }
      if (resolvedProviderId != null && resolvedProviderId.isNotEmpty) {
        normalizedSections = _withDefaultExploreProviderId(
          normalizedSections,
          resolvedProviderId,
        );
      }
      final sections = _buildExploreSectionsFromNormalizedPayload(
        normalizedSections,
      );

      if (sections.isEmpty) return;

      final lastFetched = cachedTs != null
          ? DateTime.fromMillisecondsSinceEpoch(cachedTs)
          : null;

      _log.i('Restored ${sections.length} cached explore sections');
      // Cached content can replace the initial spinner while the separate
      // active request still owns refresh completion and deduplication.
      state = ExploreState(
        error: state.error,
        greeting: _getLocalGreeting(),
        providerId: resolvedProviderId,
        sections: sections,
        lastFetched: lastFetched,
      );
    } catch (e) {
      if (!_isCacheRestoreValid(generation)) return;
      _log.w('Failed to restore explore cache: $e');
      try {
        final prefs = await SharedPreferences.getInstance();
        if (!_isCacheRestoreValid(generation)) return;
        await ExploreCacheStore(prefs).clear();
        _log.d('Removed invalid explore cache');
      } catch (clearError) {
        _log.w('Failed to remove invalid explore cache: $clearError');
      }
    }
  }

  Extension? _resolveHomeFeedExtension() {
    return ref.read(homeFeedExtensionProvider);
  }

  Future<String?> _homeFeedRegion(Extension extension) async {
    final setting = extension.homeFeedRegionSetting;
    if (setting == null) return null;
    final settings = await ref.read(
      extensionSettingsProvider(extension.id).future,
    );
    return (settings[setting.key] ?? setting.defaultValue)
        ?.toString()
        .trim()
        .toUpperCase();
  }

  Future<void> _reloadConfiguration(String extensionId) async {
    clear();
    final generation = _homeFeedRequestId;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!_isRequestValid(generation)) return;
      await ExploreCacheStore(prefs).clear();
    } catch (error) {
      _log.w('Failed to clear changed home feed: $error');
    }
    if (_isRequestValid(generation) &&
        _resolveHomeFeedExtension()?.id == extensionId) {
      await refresh();
    }
  }

  Future<void> _saveToCache(
    List<Map<String, Object?>> normalizedSections,
    String providerId,
    String? region,
    int requestId,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = await compute(_encodeExploreCache, {
        'provider_id': providerId,
        'region': region,
        'sections': normalizedSections,
      });
      if (_isRequestValid(requestId)) {
        await ExploreCacheStore(prefs).write(encoded);
      }
    } catch (e) {
      _log.w('Failed to save explore cache: $e');
    }
  }

  Future<void> fetchHomeFeed({bool forceRefresh = false}) async {
    if (ref.read(settingsProvider).homeFeedProvider ==
        AppSettings.homeFeedProviderOff) {
      clear();
      return;
    }

    if (!forceRefresh &&
        state.hasContent &&
        state.lastFetched != null &&
        DateTime.now().difference(state.lastFetched!).inMinutes < 5) {
      _log.d('Using cached home feed (fresh enough)');
      return;
    }

    if (_activeHomeFeedRequestId != null && !forceRefresh) {
      _log.d('Home feed fetch already in progress');
      return;
    }

    final requestId = ++_homeFeedRequestId;
    _activeHomeFeedRequestId = requestId;
    final showLoading = !state.hasContent;
    state = state.copyWith(isLoading: showLoading, error: null);

    try {
      final targetExt = _resolveHomeFeedExtension();

      if (targetExt == null) {
        _log.w('No extension with homeFeed capability found');
        if (!_isRequestValid(requestId)) return;
        state = state.copyWith(
          isLoading: false,
          error: 'No extension with home feed support enabled',
        );
        return;
      }

      final region = await _homeFeedRegion(targetExt);
      if (!_isRequestValid(requestId)) return;
      final result = await PlatformBridge.getExtensionHomeFeed(
        targetExt.id,
        cancelPrevious: forceRefresh,
      );
      if (!_isRequestValid(requestId)) return;

      if (result == null) {
        state = state.copyWith(
          isLoading: false,
          error: 'Failed to fetch home feed',
        );
        return;
      }

      final success = result['success'] as bool? ?? false;
      if (!success) {
        final error = result['error'] as String? ?? 'Unknown error';
        state = state.copyWith(isLoading: false, error: error);
        return;
      }

      final sectionsData = result['sections'] as List<dynamic>? ?? [];
      final normalizedSectionsWithoutProvider = await compute(
        _normalizeExploreSectionsPayload,
        sectionsData,
      );
      final normalizedSections = _withDefaultExploreProviderId(
        normalizedSectionsWithoutProvider,
        targetExt.id,
      );
      if (!_isRequestValid(requestId)) return;
      final sections = _buildExploreSectionsFromNormalizedPayload(
        normalizedSections,
      );

      final localGreeting = _getLocalGreeting();
      _log.i(
        'Home feed updated: provider=${targetExt.id}, '
        'sections=${sections.length}',
      );

      _cacheRestoreGeneration++;
      state = ExploreState(
        isLoading: false,
        greeting: localGreeting,
        providerId: targetExt.id,
        sections: sections,
        lastFetched: DateTime.now(),
      );

      _saveToCache(normalizedSections, targetExt.id, region, requestId);
    } catch (e, stack) {
      _log.e('Error fetching home feed: $e', e, stack);
      if (!_isRequestValid(requestId)) return;
      state = state.copyWith(isLoading: false, error: e.toString());
    } finally {
      if (_activeHomeFeedRequestId == requestId) {
        _activeHomeFeedRequestId = null;
      }
    }
  }

  void clear() {
    _homeFeedRequestId++;
    _cacheRestoreGeneration++;
    // Top Picks share the bridge. Only request cancellation when this
    // notifier has an active fetch.
    if (_activeHomeFeedRequestId != null) {
      PlatformBridge.cancelExtensionHomeFeedRequests();
    }
    _activeHomeFeedRequestId = null;
    state = const ExploreState();
  }

  Future<void> refresh() => fetchHomeFeed(forceRefresh: true);
}

/// Read [extensionId]'s home feed with the same item normalization as Explore.
/// Return null on failure so callers can retain their cached content.
Future<List<ExploreSection>?> readExtensionHomeFeed(String extensionId) async {
  final result = await PlatformBridge.getExtensionHomeFeed(extensionId);
  if (result == null || result['success'] != true) return null;
  final normalized = await compute(
    _normalizeExploreSectionsPayload,
    result['sections'],
  );
  return _buildExploreSectionsFromNormalizedPayload(
    _withDefaultExploreProviderId(normalized, extensionId),
  );
}

final exploreProvider = NotifierProvider<ExploreNotifier, ExploreState>(() {
  return ExploreNotifier();
});
