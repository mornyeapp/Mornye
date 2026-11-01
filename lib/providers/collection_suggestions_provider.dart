import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/services/collection_suggestions.dart';
import 'package:mornye/services/platform_bridge.dart';

/// Suggestions for the collection [key] (`playlist:<id>`, `album:<id>`...)
/// in refresh [round], from its [tracks] (most important first). Equal by
/// key and round only, so a rebuild with a new track list keeps the loaded
/// suggestions.
class CollectionSuggestionsRequest {
  const CollectionSuggestionsRequest({
    required this.key,
    required this.round,
    required this.tracks,
  });

  final String key;
  final int round;
  final List<Track> tracks;

  @override
  bool operator ==(Object other) =>
      other is CollectionSuggestionsRequest &&
      other.key == key &&
      other.round == round;

  @override
  int get hashCode => Object.hash(key, round);
}

/// How long suggestions stay after their page closes, so reopening it does
/// not ask the extension again.
const collectionSuggestionsKeepAlive = Duration(minutes: 10);

/// Songs to suggest under a collection.
final collectionSuggestionsProvider = FutureProvider.autoDispose
    .family<CollectionSuggestions, CollectionSuggestionsRequest>((
      ref,
      request,
    ) async {
      ref.watch(extensionProvider.select(collectionSuggestionSourceKey));
      final source = collectionSuggestionSource(
        ref.read(extensionProvider),
        collectionSuggestionSeeds(request.tracks, round: request.round),
      );
      if (source == null) return CollectionSuggestions.empty;
      final suggestions = await loadCollectionSuggestions(
        tracks: request.tracks,
        source: source,
        round: request.round,
        related: (extensionId, seeds, limit) =>
            PlatformBridge.getExtensionRelatedTracks(
              extensionId,
              seeds,
              limit: limit,
            ),
        search: (extensionId, query) =>
            PlatformBridge.searchTracksWithMetadataProvider(
              extensionId,
              query,
              limit: 15,
            ),
      );
      final link = ref.keepAlive();
      final timer = Timer(collectionSuggestionsKeepAlive, link.close);
      ref.onDispose(timer.cancel);
      return suggestions;
    });
