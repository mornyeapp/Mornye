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

const _cacheKey = 'home_top_picks_v1';

/// The most extension playlists Top Picks show after the mixes.
const homeTopPickPlaylists = 9;

/// Up to [count] playlists of [sections] with a cover, each once, in an order
/// that holds for the [day] and changes with the next.
@visibleForTesting
List<ExploreItem> pickTopPickPlaylists(
  List<ExploreSection> sections,
  String day, {
  int count = homeTopPickPlaylists,
}) {
  final playlists = <String, ExploreItem>{};
  for (final section in sections) {
    for (final item in section.items) {
      if (item.type != 'playlist' || item.id.isEmpty) continue;
      if (item.coverUrl?.trim().isNotEmpty != true) continue;
      playlists.putIfAbsent(item.id, () => item);
    }
  }
  final ordered = playlists.values.toList()
    ..sort((a, b) => a.id.compareTo(b.id))
    ..shuffle(Random(int.tryParse(day.replaceAll('-', '')) ?? 0));
  return ordered.take(count).toList(growable: false);
}

/// The extension Top Picks read: the one the Home feed uses, or with the feed
/// switched off the first that offers a feed.
final homeTopPicksExtensionProvider = Provider<String?>((ref) {
  final preferred = ref.watch(
    settingsProvider.select((settings) => settings.homeFeedProvider),
  );
  final available = ref
      .watch(extensionProvider.select((state) => state.extensions))
      .where((extension) => extension.enabled && extension.hasHomeFeed);
  if (preferred != null &&
      preferred.isNotEmpty &&
      preferred != AppSettings.homeFeedProviderOff) {
    return available.where((e) => e.id == preferred).firstOrNull?.id;
  }
  return available.firstOrNull?.id;
});

/// A day's random extension playlists, kept for that day. A failed read falls
/// back on the last day's picks and is tried again on the next launch.
final homeTopPicksProvider = FutureProvider<List<ExploreItem>>((ref) async {
  final extensionId = ref.watch(homeTopPicksExtensionProvider);
  if (extensionId == null) return const [];
  final prefs = await SharedPreferences.getInstance();
  final day = listeningDay(DateTime.now());
  final cached = _decode(prefs.getString(_cacheKey));
  final usable = cached?.extensionId == extensionId ? cached : null;
  if (usable != null && usable.day == day) return usable.items;
  try {
    final sections = await readExtensionHomeFeed(extensionId);
    if (sections == null) return usable?.items ?? const [];
    final items = pickTopPickPlaylists(sections, day);
    await prefs.setString(
      _cacheKey,
      jsonEncode({
        'day': day,
        'extensionId': extensionId,
        'items': [for (final item in items) item.toJson()],
      }),
    );
    return items;
  } on Object catch (error, stack) {
    _log.w('Could not read Top Picks playlists: $error\n$stack');
    return usable?.items ?? const [];
  }
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
