import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/listening_statistics.dart' show listeningDay;
import 'package:mornye/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('HomeTopPicks');

const _cacheKey = 'home_top_picks_v3';

/// The most extension playlists and albums Top Picks show beside the mixes.
const homeTopPicks = 9;

/// The most of those that are albums.
const homeTopPickAlbums = 4;

/// Exclude chart playlists and sections from the daily selection.
final _chartName = RegExp(r'\b(top \d+|charts?)\b', caseSensitive: false);

/// Up to [count] playlists and albums of [sections] with a cover, each once,
/// at most [albums] of them albums while playlists are left to take. The
/// order holds for the [day] and changes with the next: an album, then a
/// playlist, by turns. Charts are left out.
@visibleForTesting
List<ExploreItem> pickTopPicks(
  List<ExploreSection> sections,
  String day, {
  int count = homeTopPicks,
  int albums = homeTopPickAlbums,
}) {
  final found = {
    for (final type in const ['album', 'playlist'])
      type: <(String?, String), ExploreItem>{},
  };
  for (final section in sections) {
    if (_chartName.hasMatch(section.title)) continue;
    for (final item in section.items) {
      final ofType = found[item.type];
      if (ofType == null || item.id.isEmpty) continue;
      if (_chartName.hasMatch(item.name)) continue;
      if (item.coverUrl?.trim().isNotEmpty != true) continue;
      ofType.putIfAbsent((item.providerId, item.id), () => item);
    }
  }
  final seed = int.tryParse(day.replaceAll('-', '')) ?? 0;
  List<ExploreItem> ordered(String type) => found[type]!.values.toList()
    ..sort((a, b) {
      final provider = (a.providerId ?? '').compareTo(b.providerId ?? '');
      return provider != 0 ? provider : a.id.compareTo(b.id);
    })
    ..shuffle(Random(seed));
  final allAlbums = ordered('album'), allPlaylists = ordered('playlist');
  // Albums take their share, and what playlists leave of the rest.
  final albumCount = min(
    count,
    min(allAlbums.length, max(albums, count - allPlaylists.length)),
  );
  final pickedAlbums = allAlbums.take(albumCount).toList();
  final pickedPlaylists = allPlaylists.take(count - albumCount).toList();
  return [
    for (
      var index = 0;
      index < max(pickedAlbums.length, pickedPlaylists.length);
      index++
    ) ...[
      if (index < pickedAlbums.length) pickedAlbums[index],
      if (index < pickedPlaylists.length) pickedPlaylists[index],
    ],
  ];
}

/// Respect the Home feed selection. Auto uses the first available extension;
/// Off or an unavailable selection does not query another extension.
@visibleForTesting
String? pickTopPicksExtension(List<String> available, String? homeFeed) {
  if (homeFeed == AppSettings.homeFeedProviderOff) return null;
  if (homeFeed != null && homeFeed.isNotEmpty) {
    return available.contains(homeFeed) ? homeFeed : null;
  }
  return available.firstOrNull;
}

final homeTopPicksExtensionProvider = Provider<String?>((ref) {
  final homeFeed = ref.watch(
    settingsProvider.select((settings) => settings.homeFeedProvider),
  );
  final available = ref
      .watch(extensionProvider.select((state) => state.extensions))
      .where((extension) => extension.enabled && extension.hasHomeFeed);
  return pickTopPicksExtension([
    for (final extension in available) extension.id,
  ], homeFeed);
});

/// A day's random extension playlists and albums, kept for that day. A failed
/// read falls back on the last day's picks and is tried again on the next
/// launch.
final homeTopPicksProvider = FutureProvider<List<ExploreItem>>((ref) async {
  final extensionId = ref.watch(homeTopPicksExtensionProvider);
  if (extensionId == null) return const [];
  final prefs = await SharedPreferences.getInstance();
  final day = listeningDay(DateTime.now());
  final cached = _decode(prefs.getString(_cacheKey));
  final usable = cached?.extensionId == extensionId ? cached : null;
  if (usable != null && usable.day == day) return usable.items;
  List<ExploreSection>? sections;
  try {
    sections = await readExtensionHomeFeed(extensionId);
  } on Object catch (error, stack) {
    _log.w('Could not read Top Picks playlists: $error\n$stack');
  }
  if (sections == null) {
    if (usable != null) return usable.items;
    // Startup clears the bridge's caches and cancels reads under way: failing
    // with an Exception, not an Error, has Riverpod try again in a moment.
    throw Exception('Top Picks have no playlists yet');
  }
  final items = pickTopPicks(sections, day);
  // The picks kept before albums were among them.
  await prefs.remove('home_top_picks_v2');
  await prefs.setString(
    _cacheKey,
    jsonEncode({
      'day': day,
      'extensionId': extensionId,
      'items': [for (final item in items) item.toJson()],
    }),
  );
  return items;
});

({String day, String extensionId, List<ExploreItem> items})? _decode(
  String? value,
) {
  if (value == null) return null;
  try {
    final json = jsonDecode(value);
    if (json is! Map) return null;
    final day = json['day'], extensionId = json['extensionId'];
    final items = json['items'];
    if (day is! String || extensionId is! String || items is! List) return null;
    return (
      day: day,
      extensionId: extensionId,
      items: [
        for (final item in items)
          if (item is Map<String, dynamic>) ExploreItem.fromJson(item),
      ],
    );
  } on FormatException {
    return null;
  }
}
