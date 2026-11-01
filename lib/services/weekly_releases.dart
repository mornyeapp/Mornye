import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/utils/string_utils.dart';

class WeeklyRelease {
  const WeeklyRelease({
    required this.id,
    required this.name,
    required this.artist,
    required this.providerId,
    required this.date,
    this.coverUrl,
  });

  final String id;
  final String name;
  final String artist;
  final String providerId;
  final DateTime date;
  final String? coverUrl;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'artists': artist,
    'provider_id': providerId,
    'release_date': date.toIso8601String(),
    'cover_url': coverUrl,
  };

  static WeeklyRelease? fromMetadata(
    Map<String, dynamic> metadata, {
    required String providerId,
    required String artist,
  }) {
    final rawDate = metadata['release_date']?.toString() ?? '';
    // Year/month-only dates are not precise enough for a weekly feed.
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}(?:$|T)').hasMatch(rawDate)) return null;
    final parsed = DateTime.tryParse(rawDate);
    if (parsed == null) return null;
    final date = DateTime(parsed.year, parsed.month, parsed.day);
    if (rawDate.substring(0, 10) != date.toIso8601String().substring(0, 10)) {
      return null;
    }
    final id = metadata['id']?.toString().trim() ?? '';
    final name = metadata['name']?.toString().trim() ?? '';
    if (id.isEmpty || name.isEmpty) return null;
    return WeeklyRelease(
      id: id,
      name: name,
      artist: metadata['artists']?.toString().trim().isNotEmpty == true
          ? metadata['artists'].toString()
          : artist,
      providerId: metadata['provider_id']?.toString() ?? providerId,
      date: date,
      coverUrl: normalizeCoverReference(
        (metadata['cover_url'] ?? metadata['images'])?.toString(),
      ),
    );
  }
}

class WeeklyReleaseFeed {
  const WeeklyReleaseFeed(this.releases, {this.unavailableArtists = const []});

  final List<WeeklyRelease> releases;
  final List<String> unavailableArtists;

  List<WeeklyRelease> inPeriod(DateTime now, int days) {
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final start = DateTime(now.year, now.month, now.day - days + 1);
    return releases
        .where(
          (release) =>
              !release.date.isBefore(start) && release.date.isBefore(tomorrow),
        )
        .toList(growable: false);
  }
}

typedef ArtistReleaseLoader =
    Future<({String providerId, Map<String, dynamic> metadata})> Function(
      CollectionArtistEntry artist,
    );

/// No provider code is embedded in the app. The existing artist metadata
/// contract supplies the catalog; failures keep the last successful catalog.
class WeeklyReleaseService {
  WeeklyReleaseService({required this.loadArtist, required this.preferences});

  final ArtistReleaseLoader loadArtist;
  final Future<SharedPreferences> preferences;

  Future<WeeklyReleaseFeed> load(
    List<CollectionArtistEntry> artists, {
    bool refresh = false,
    DateTime? now,
    bool Function()? isCancelled,
  }) async {
    final date = now ?? DateTime.now();
    final prefs = await preferences;
    final releases = <String, WeeklyRelease>{};
    final unavailable = <String>[];
    var next = 0;
    Future<void> worker() async {
      while (next < artists.length && isCancelled?.call() != true) {
        final artist = artists[next++];
        final key = 'weekly_releases_v1:${artist.key}';
        var cached = <WeeklyRelease>[];
        DateTime? checkedAt;
        try {
          final raw = prefs.getString(key);
          if (raw != null) {
            final json = jsonDecode(raw) as Map<String, dynamic>;
            checkedAt = DateTime.tryParse(json['checked_at'] as String? ?? '');
            cached = _parseCatalog(
              json,
              artist.name,
              json['provider_id']?.toString() ?? '',
            );
          }
        } catch (_) {
          // An invalid cache is rebuilt; it must not break other artists.
        }
        var catalog = cached;
        final age = checkedAt == null ? null : date.difference(checkedAt);
        if (refresh || age == null || age.isNegative || age.inHours >= 24) {
          try {
            final result = await loadArtist(
              artist,
            ).timeout(const Duration(seconds: 25));
            if (isCancelled?.call() == true) return;
            final metadata = result.metadata;
            // Missing catalogs mean unsupported, rather than an empty result
            // that silently replaces a previously successful cache.
            if (metadata['albums'] is! List && metadata['releases'] is! List) {
              throw StateError('Artist catalog is unavailable');
            }
            catalog = _parseCatalog(metadata, artist.name, result.providerId);
            await prefs.setString(
              key,
              jsonEncode({
                'checked_at': date.toIso8601String(),
                'provider_id': result.providerId,
                'albums': catalog.map((release) => release.toJson()).toList(),
              }),
            );
          } catch (_) {
            unavailable.add(artist.name);
          }
        }
        for (final release in catalog) {
          releases['${release.providerId}:${release.id}'] = release;
        }
      }
    }

    // Keep large favorite lists from issuing a burst of extension requests.
    await Future.wait([worker(), worker()]);
    final sorted = releases.values.toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    return WeeklyReleaseFeed(sorted, unavailableArtists: unavailable);
  }

  List<WeeklyRelease> _parseCatalog(
    Map<String, dynamic> data,
    String artist,
    String providerId,
  ) {
    final releases = <String, WeeklyRelease>{};
    for (final field in ['albums', 'releases']) {
      final raw = data[field];
      if (raw is! List) continue;
      for (final value in raw.take(300)) {
        if (value is! Map) continue;
        final release = WeeklyRelease.fromMetadata(
          Map<String, dynamic>.from(value),
          providerId: providerId,
          artist: artist,
        );
        if (release != null) {
          releases['${release.providerId}:${release.id}'] = release;
        }
      }
    }
    return releases.values.toList(growable: false);
  }
}
