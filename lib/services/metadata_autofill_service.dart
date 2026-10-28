import 'package:mornye/models/extension.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/string_utils.dart';

class MetadataAutofillResult {
  final Map<String, String> values;
  final String? coverUrl;
  final String? headerVideoUrl;
  final String sourceId;
  final String? lyricsSource;

  const MetadataAutofillResult({
    required this.values,
    required this.coverUrl,
    this.headerVideoUrl,
    required this.sourceId,
    required this.lyricsSource,
  });
}

/// Provider lookup and enrichment without widget state or navigation access.
class MetadataAutofillService {
  static final _log = AppLogger('MetadataAutofill');
  static final RegExp _metadataCollapsePattern = RegExp(
    r'[^\p{L}\p{M}\p{N}]+',
    unicode: true,
  );
  static final RegExp _metadataWhitespacePattern = RegExp(r'\s+');
  static final RegExp _spotifyTrackIdPattern = RegExp(r'^[A-Za-z0-9]{22}$');
  static final RegExp _deezerTrackIdPattern = RegExp(r'^\d+$');
  static final RegExp _isrcPattern = RegExp(r'^[A-Z]{2}[A-Z0-9]{3}\d{7}$');

  Future<List<Map<String, dynamic>>> search(
    String query, {
    Extension? provider,
  }) {
    if (provider == null) {
      return PlatformBridge.searchTracksWithMetadataProviders(query, limit: 5);
    }
    if (provider.hasCustomSearch) {
      final filter = provider.searchBehavior?.filterIdForKind('track');
      return PlatformBridge.customSearchWithExtension(
        provider.id,
        query,
        options: {'limit': 5, 'filter': ?filter},
      );
    }
    return PlatformBridge.searchTracksWithMetadataProvider(
      provider.id,
      query,
      limit: 5,
    );
  }

  Future<Map<String, dynamic>> resolveDetails(
    Map<String, dynamic> candidate, {
    required String providerId,
    required bool includeCover,
  }) async {
    var resolved = candidate;
    if (providerId.isEmpty) return resolved;
    final trackId = candidate['id']?.toString().trim() ?? '';
    if (trackId.isNotEmpty) {
      try {
        final details = await PlatformBridge.getProviderMetadata(
          providerId,
          'track',
          trackId,
        );
        resolved = {
          ...candidate,
          for (final entry in unwrapTrackPayload(details).entries)
            if (entry.value != null && entry.value.toString().trim().isNotEmpty)
              entry.key: entry.value,
        };
      } catch (error) {
        _log.w(
          'Detailed metadata lookup failed for $providerId/$trackId: $error',
        );
      }
    }
    if (includeCover &&
        (coverUrl(resolved) == null ||
            normalizeRemoteHttpUrl(resolved['header_video']?.toString()) ==
                null)) {
      final albumId = resolved['album_id']?.toString().trim() ?? '';
      if (albumId.isNotEmpty) {
        try {
          final details = await PlatformBridge.getProviderMetadata(
            providerId,
            'album',
            albumId,
          );
          final album = details['album_info'] ?? details['album'];
          final artwork = album is Map<String, dynamic> ? album : details;
          final url = coverUrl(artwork);
          final video = normalizeRemoteHttpUrl(
            artwork['header_video']?.toString(),
          );
          resolved = {
            ...resolved,
            if (coverUrl(resolved) == null && url != null) 'cover_url': url,
            'header_video': ?video,
          };
        } catch (error) {
          _log.w(
            'Album artwork lookup failed for $providerId/$albumId: $error',
          );
        }
      }
    }
    return resolved;
  }

  Future<MetadataAutofillResult?> enrich(
    Map<String, dynamic>? selectedBest, {
    required Map<String, String> currentValues,
    required Set<String> fields,
    required String? providerId,
    required String? sourceTrackId,
    required int durationMs,
    required Future<void> Function() syncLyricsSettings,
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) return null;
    final title = currentValues['title']?.trim() ?? '';
    final artist = currentValues['artist']?.trim() ?? '';
    final currentIsrc = currentValues['isrc']?.trim().toUpperCase() ?? '';
    final usesAutomaticProvider = providerId?.isNotEmpty != true;
    final shouldFetchLyrics = fields.contains('lyrics');
    String? deezerId;
    String? lyricsSourceName;
    final enriched = <String, String>{};
    if (selectedBest != null) {
      mergeTrackData(enriched, selectedBest);
    }

    final enrichedIsrc = (enriched['isrc'] ?? '').trim();
    final needsIsrc = fields.contains('isrc') && enrichedIsrc.isEmpty;
    final needsExtended =
        fields.contains('genre') ||
        fields.contains('label') ||
        fields.contains('copyright') ||
        fields.contains('composer');

    final rawSpotifyId = selectedBest == null
        ? spotifyTrackIdFromValue(sourceTrackId)
        : spotifyTrackId(selectedBest);

    deezerId ??= selectedBest == null ? null : deezerTrackId(selectedBest);
    final candidateIsrc = enrichedIsrc.toUpperCase();
    final deezerLookupIsrc = looksLikeIsrc(currentIsrc)
        ? currentIsrc
        : (looksLikeIsrc(candidateIsrc) ? candidateIsrc : '');

    if (usesAutomaticProvider && (needsIsrc || needsExtended)) {
      try {
        if (deezerId == null && deezerLookupIsrc.isNotEmpty) {
          final deezerResult = await PlatformBridge.searchDeezerByISRC(
            deezerLookupIsrc,
          );
          deezerId = deezerTrackId(deezerResult);
          mergeTrackData(enriched, deezerResult);
        }

        if (deezerId == null && rawSpotifyId != null) {
          // Spotify IDs can be mapped through SongLink to a Deezer track.
          final deezerData = await PlatformBridge.convertSpotifyToDeezer(
            'track',
            rawSpotifyId,
          );
          final trackData = deezerData['track'];
          if (trackData is Map<String, dynamic>) {
            deezerId = deezerTrackId(trackData);
            mergeTrackData(enriched, trackData);
          }
          deezerId ??= deezerTrackId(deezerData);
        }
      } catch (_) {
        // Deezer resolution is best-effort
      }
    }

    if (!isCurrent()) return null;

    if (usesAutomaticProvider &&
        needsIsrc &&
        (enriched['isrc'] ?? '').trim().isEmpty &&
        deezerId != null) {
      try {
        final deezerMeta = await PlatformBridge.getProviderMetadata(
          'deezer',
          'track',
          deezerId,
        );
        final trackData = unwrapTrackPayload(deezerMeta);
        mergeTrackData(enriched, trackData);
        final deezerIsrc = (trackData['isrc'] ?? '').toString().trim();
        if (deezerIsrc.isNotEmpty) {
          enriched['isrc'] = deezerIsrc;
        }
      } catch (_) {}
    }

    if (!isCurrent()) return null;

    if (usesAutomaticProvider && needsExtended && deezerId != null) {
      try {
        final extended = await PlatformBridge.getDeezerExtendedMetadata(
          deezerId,
        );
        if (extended != null) {
          enriched['genre'] = extended['genre'] ?? '';
          enriched['label'] = extended['label'] ?? '';
          enriched['copyright'] = extended['copyright'] ?? '';
        }
      } catch (_) {
        // Extended metadata is best-effort
      }
    }

    if (shouldFetchLyrics) {
      await syncLyricsSettings();

      if (!isCurrent()) return null;

      final lyricsTitle =
          ((selectedBest?['name'] ?? selectedBest?['title'] ?? title)
                  .toString())
              .trim();
      final lyricsArtist =
          ((selectedBest?['artists'] ?? selectedBest?['artist'] ?? artist)
                  .toString())
              .trim();

      if (lyricsTitle.isNotEmpty && lyricsArtist.isNotEmpty) {
        try {
          final lyricsResult = await PlatformBridge.getLyricsLRCWithSource(
            rawSpotifyId ?? '',
            lyricsTitle,
            lyricsArtist,
            durationMs: durationMs,
          );
          final lyricsText = lyricsResult['lyrics']?.toString().trim() ?? '';
          final lyricsSource = lyricsResult['source']?.toString().trim() ?? '';
          if (lyricsSource.isNotEmpty) lyricsSourceName = lyricsSource;
          final instrumental =
              (lyricsResult['instrumental'] as bool? ?? false) ||
              lyricsText == '[instrumental:true]';
          if (!instrumental && lyricsText.isNotEmpty) {
            enriched['lyrics'] = lyricsText;
          }
        } catch (e) {
          _log.w('Lyrics autofill failed: $e');
        }
      }
    }

    if (!isCurrent()) return null;

    final availableValues = <String, String>{};
    for (final entry in enriched.entries) {
      final value = entry.value.trim();
      final isExplicitValue = entry.key == 'explicit';
      if (value.isNotEmpty &&
          (isExplicitValue || value != '0') &&
          value != 'null') {
        availableValues[entry.key] = value;
      }
    }
    final artworkUrl = selectedBest == null ? null : coverUrl(selectedBest);

    return MetadataAutofillResult(
      values: availableValues,
      coverUrl: artworkUrl,
      headerVideoUrl: fields.contains('cover')
          ? normalizeRemoteHttpUrl(selectedBest?['header_video']?.toString())
          : null,
      sourceId: providerId?.isNotEmpty == true
          ? providerId!
          : selectedBest?['provider_id']?.toString().trim() ?? '',
      lyricsSource: selectedBest == null ? lyricsSourceName : null,
    );
  }

  List<Extension> orderedProviders(ExtensionState state) {
    final providersById = <String, Extension>{
      for (final extension in state.extensions)
        if (extension.enabled && extension.hasMetadataProvider)
          extension.id: extension,
    };
    final ordered = <Extension>[];
    for (final id in state.metadataProviderPriority) {
      final extension = providersById.remove(id);
      if (extension != null) ordered.add(extension);
    }
    final remaining = providersById.values.toList()
      ..sort(
        (a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      );
    return [...ordered, ...remaining];
  }

  String normalizeText(String value) {
    final collapsed = value
        .toLowerCase()
        .replaceAll(_metadataCollapsePattern, ' ')
        .trim();
    return collapsed.replaceAll(_metadataWhitespacePattern, ' ');
  }

  bool looksLikeIsrc(String value) {
    return _isrcPattern.hasMatch(value.trim().toUpperCase());
  }

  String? spotifyTrackIdFromValue(Object? value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return null;

    if (_spotifyTrackIdPattern.hasMatch(raw)) {
      return raw;
    }

    if (raw.startsWith('spotify:')) {
      final parts = raw.split(':');
      final last = parts.isNotEmpty ? parts.last.trim() : '';
      if (_spotifyTrackIdPattern.hasMatch(last)) {
        return last;
      }
      return null;
    }

    final uri = Uri.tryParse(raw);
    if (uri != null &&
        uri.host.contains('spotify.com') &&
        uri.pathSegments.length >= 2 &&
        uri.pathSegments.first == 'track') {
      final candidate = uri.pathSegments[1].trim();
      if (_spotifyTrackIdPattern.hasMatch(candidate)) {
        return candidate;
      }
    }

    return null;
  }

  String? deezerTrackIdFromValue(Object? value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return null;

    if (_deezerTrackIdPattern.hasMatch(raw)) {
      return raw;
    }

    if (raw.startsWith('deezer:')) {
      final parts = raw.split(':');
      final last = parts.isNotEmpty ? parts.last.trim() : '';
      if (_deezerTrackIdPattern.hasMatch(last)) {
        return last;
      }
    }

    final uri = Uri.tryParse(raw);
    if (uri != null && uri.host.contains('deezer.com')) {
      final trackIndex = uri.pathSegments.indexOf('track');
      if (trackIndex >= 0 && trackIndex + 1 < uri.pathSegments.length) {
        final candidate = uri.pathSegments[trackIndex + 1].trim();
        if (_deezerTrackIdPattern.hasMatch(candidate)) {
          return candidate;
        }
      }
    }

    return null;
  }

  String? spotifyTrackId(Map<String, dynamic> track) {
    for (final candidate in [track['spotify_id'], track['id']]) {
      final spotifyId = spotifyTrackIdFromValue(candidate);
      if (spotifyId != null) return spotifyId;
    }

    final externalLinks = track['external_links'];
    if (externalLinks is Map) {
      final spotifyId = spotifyTrackIdFromValue(externalLinks['spotify']);
      if (spotifyId != null) return spotifyId;
    }

    return null;
  }

  String? deezerTrackId(Map<String, dynamic> track) {
    for (final candidate in [
      track['deezer_id'],
      track['spotify_id'],
      track['id'],
    ]) {
      final deezerId = deezerTrackIdFromValue(candidate);
      if (deezerId != null) return deezerId;
    }

    final externalLinks = track['external_links'];
    if (externalLinks is Map) {
      final deezerId = deezerTrackIdFromValue(externalLinks['deezer']);
      if (deezerId != null) return deezerId;
    }

    return null;
  }

  Map<String, dynamic> unwrapTrackPayload(Map<String, dynamic> payload) {
    final track = payload['track'];
    if (track is Map<String, dynamic>) {
      return track;
    }
    return payload;
  }

  void mergeTrackData(
    Map<String, String> enriched,
    Map<String, dynamic> track,
  ) {
    void put(String key, Object? value) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty && text != 'null') {
        enriched[key] = text;
      }
    }

    put('title', track['name'] ?? track['title']);
    put('artist', track['artists'] ?? track['artist']);
    put('album', track['album_name'] ?? track['album']);
    put('album_artist', track['album_artist']);
    put('date', track['release_date']);
    put('track_number', track['track_number']);
    put('total_tracks', track['total_tracks']);
    put('disc_number', track['disc_number']);
    put('total_discs', track['total_discs']);
    put('isrc', track['isrc']);
    put('genre', track['genre']);
    put('label', track['label']);
    put('copyright', track['copyright']);
    put('composer', track['composer']);
    put('comment', track['comment']);
    put('album_type', track['album_type'] ?? track['albumType']);
    put('explicit', track['explicit'] ?? track['is_explicit']);
    put('upc', track['upc'] ?? track['barcode']);
  }

  int matchScore(
    Map<String, dynamic> track, {
    required String currentTitle,
    required String currentArtist,
    required String currentAlbum,
    required String currentIsrc,
  }) {
    int textScore(String current, Object? value, int exact, int partial) {
      final candidate = normalizeText((value ?? '').toString());
      if (current.isEmpty || candidate.isEmpty) return 0;
      if (candidate == current) return exact;
      return _metadataTextMatches(current, candidate) ? partial : 0;
    }

    final candidateIsrc = track['isrc']?.toString().trim().toUpperCase() ?? '';
    return (currentIsrc.isNotEmpty && candidateIsrc == currentIsrc
            ? 10000
            : 0) +
        textScore(currentTitle, track['name'] ?? track['title'], 400, 180) +
        textScore(
          currentArtist,
          track['artists'] ?? track['artist'],
          320,
          140,
        ) +
        textScore(currentAlbum, track['album_name'] ?? track['album'], 120, 50);
  }

  bool _metadataTextMatches(String current, String candidate) {
    if (current.isEmpty || candidate.isEmpty) return false;
    return current == candidate ||
        candidate.contains(current) ||
        current.contains(candidate);
  }

  bool matchIsConfident(
    Map<String, dynamic> track, {
    required String currentTitle,
    required String currentArtist,
    required String currentAlbum,
    required String currentIsrc,
  }) {
    final candidateIsrc = (track['isrc']?.toString() ?? '')
        .trim()
        .toUpperCase();
    if (currentIsrc.isNotEmpty && candidateIsrc == currentIsrc) {
      return true;
    }

    final candidateTitle = normalizeText(
      (track['name'] ?? track['title'] ?? '').toString(),
    );
    final candidateArtist = normalizeText(
      (track['artists'] ?? track['artist'] ?? '').toString(),
    );
    final candidateAlbum = normalizeText(
      (track['album_name'] ?? track['album'] ?? '').toString(),
    );

    final titleMatches = _metadataTextMatches(currentTitle, candidateTitle);
    final artistMatches = _metadataTextMatches(currentArtist, candidateArtist);
    final albumMatches = _metadataTextMatches(currentAlbum, candidateAlbum);

    if (currentTitle.isNotEmpty && currentArtist.isNotEmpty) {
      return titleMatches && artistMatches;
    }
    if (currentTitle.isNotEmpty && currentAlbum.isNotEmpty) {
      return titleMatches && albumMatches;
    }
    if (currentTitle.isNotEmpty) {
      return titleMatches;
    }
    if (currentAlbum.isNotEmpty) {
      return albumMatches;
    }

    return false;
  }

  String? coverUrl(Map<String, dynamic> track) {
    String? fromValue(Object? value) {
      if (value is String) {
        final normalized = value.trim();
        return normalized.isEmpty ? null : normalized;
      }
      if (value is List) {
        for (final item in value) {
          final resolved = fromValue(item);
          if (resolved != null) return resolved;
        }
      }
      if (value is Map) {
        for (final key in const ['url', 'original', 'large', 'src']) {
          final resolved = fromValue(value[key]);
          if (resolved != null) return resolved;
        }
      }
      return null;
    }

    return fromValue(track['cover_url']) ?? fromValue(track['images']);
  }
}
