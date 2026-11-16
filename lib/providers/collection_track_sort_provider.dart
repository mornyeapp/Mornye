import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/services/library_directory_index.dart'
    show compareNaturally;
import 'package:mornye/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('CollectionTrackSort');

/// How a playlist, Liked Songs or the Wishlist lists its songs. [custom] is
/// the saved order, the one Edit order changes.
enum CollectionTrackSort { custom, title, artist, album, latest }

/// The key of a user playlist in [collectionTrackSortsProvider]; Liked Songs
/// and the Wishlist use `loved` and `wishlist`.
String playlistTrackSortKey(String playlistId) => 'playlist:$playlistId';

/// [entries] as [sort] lists them. Names compare as a file manager does and
/// ties keep the saved order. An album lists its songs by disc and number.
List<CollectionTrackEntry> sortCollectionEntries(
  List<CollectionTrackEntry> entries,
  CollectionTrackSort sort,
) {
  if (sort == CollectionTrackSort.custom || entries.length < 2) return entries;
  int byName(String a, String b) => compareNaturally(a.trim(), b.trim());
  int compare(CollectionTrackEntry a, CollectionTrackEntry b) {
    final x = a.track;
    final y = b.track;
    switch (sort) {
      case CollectionTrackSort.custom:
        return 0;
      case CollectionTrackSort.title:
        return byName(x.name, y.name);
      case CollectionTrackSort.artist:
        final artist = byName(x.artistName, y.artistName);
        return artist != 0 ? artist : byName(x.name, y.name);
      case CollectionTrackSort.album:
        final album = byName(x.albumName, y.albumName);
        if (album != 0) return album;
        final disc = (x.discNumber ?? 1).compareTo(y.discNumber ?? 1);
        if (disc != 0) return disc;
        return (x.trackNumber ?? 999).compareTo(y.trackNumber ?? 999);
      case CollectionTrackSort.latest:
        return b.addedAt.compareTo(a.addedAt);
    }
  }

  final indexed = entries.indexed.toList()
    ..sort((a, b) {
      final order = compare(a.$2, b.$2);
      return order != 0 ? order : a.$1.compareTo(b.$1);
    });
  return [for (final (_, entry) in indexed) entry];
}

final collectionTrackSortsProvider =
    NotifierProvider<CollectionTrackSorts, Map<String, CollectionTrackSort>>(
      CollectionTrackSorts.new,
    );

/// The collections whose songs are not listed in their saved order.
class CollectionTrackSorts extends Notifier<Map<String, CollectionTrackSort>> {
  static const _prefsKey = 'collection_track_sorts';
  Future<void>? _loading;

  @override
  Map<String, CollectionTrackSort> build() {
    _loading = _load();
    return const {};
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonDecode(prefs.getString(_prefsKey) ?? '{}');
      if (json is! Map || json.isEmpty || !ref.mounted) return;
      final sorts = CollectionTrackSort.values.asNameMap();
      state = {
        for (final entry in json.entries)
          if (entry.key is String && sorts[entry.value] != null)
            entry.key as String: sorts[entry.value]!,
        ...state,
      };
    } catch (error) {
      _log.w('Ignoring saved collection sorts: ${error.runtimeType}');
    }
  }

  void setSort(String key, CollectionTrackSort sort) {
    if ((state[key] ?? CollectionTrackSort.custom) == sort) return;
    state = {
      for (final entry in state.entries)
        if (entry.key != key) entry.key: entry.value,
      if (sort != CollectionTrackSort.custom) key: sort,
    };
    unawaited(_save());
  }

  Future<void> _save() async {
    try {
      await _loading;
      if (!ref.mounted) return;
      final saved = jsonEncode({
        for (final entry in state.entries) entry.key: entry.value.name,
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, saved);
    } catch (error) {
      _log.w('Could not save the collection sort: ${error.runtimeType}');
    }
  }
}
