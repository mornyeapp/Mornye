import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/weekly_releases.dart';
import 'package:mornye/utils/provider_resource_ids.dart';

final weeklyReleasesProvider = FutureProvider.autoDispose
    .family<WeeklyReleaseFeed, bool>((ref, refresh) async {
      final collections = ref.watch(
        libraryCollectionsProvider.select(
          (s) => (isLoaded: s.isLoaded, favoriteArtists: s.favoriteArtists),
        ),
      );
      final extensions = ref.watch(
        extensionProvider.select(
          (s) => (isInitialized: s.isInitialized, extensions: s.extensions),
        ),
      );
      final preferred = ref.watch(
        settingsProvider.select((s) => s.searchProvider),
      );
      if (!collections.isLoaded || !extensions.isInitialized) {
        return const WeeklyReleaseFeed([]);
      }
      final providers = extensions.extensions
          .where(
            (extension) => extension.enabled && extension.hasMetadataProvider,
          )
          .toList(growable: false);
      var cancelled = false;
      ref.onDispose(() => cancelled = true);
      final service = WeeklyReleaseService(
        preferences: SharedPreferences.getInstance(),
        loadArtist: (artist) async {
          if (cancelled) throw StateError('Weekly releases request cancelled');
          final directProvider = artist.providerId;
          if (directProvider != null &&
              providers.any((p) => p.id == directProvider)) {
            return (
              providerId: directProvider,
              metadata: await PlatformBridge.getProviderMetadata(
                directProvider,
                'artist',
                stripPrefixedResourceId(artist.artistId),
              ),
            );
          }
          // Older favorites may not have a provider ID. Resolve them by an
          // exact artist name in a search-capable metadata extension.
          final candidates = providers.where((p) => p.hasCustomSearch).toList()
            ..sort(
              (a, b) => a.id == preferred
                  ? -1
                  : b.id == preferred
                  ? 1
                  : 0,
            );
          for (final provider in candidates) {
            if (cancelled) {
              throw StateError('Weekly releases request cancelled');
            }
            try {
              final matches = await PlatformBridge.customSearchWithExtension(
                provider.id,
                artist.name,
                options: {'filter': 'artist', 'limit': 10},
              );
              if (cancelled) {
                throw StateError('Weekly releases request cancelled');
              }
              for (final match in matches) {
                if (match['name']?.toString().trim().toLowerCase() !=
                    artist.name.trim().toLowerCase()) {
                  continue;
                }
                final id = match['id']?.toString() ?? '';
                if (id.isEmpty) continue;
                return (
                  providerId: provider.id,
                  metadata: await PlatformBridge.getProviderMetadata(
                    provider.id,
                    'artist',
                    stripPrefixedResourceId(id),
                  ),
                );
              }
            } catch (_) {
              // Try the next installed metadata provider.
            }
          }
          throw StateError('No installed provider can resolve this artist');
        },
      );
      return service.load(
        collections.favoriteArtists,
        refresh: refresh,
        isCancelled: () => cancelled,
      );
    });
