import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/album_track_order.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('AlbumTrackSort');

enum AlbumTrackSort { album, mostPlayed, custom }

/// One album of the Library, kept apart from a same-named album by another
/// artist.
typedef AlbumTrackSortKey = ({String album, String artist});

/// How one album orders its songs. [custom] holds [albumTrackRankKey]s and
/// outlives a switch to another sort.
class AlbumTrackChoice {
  const AlbumTrackChoice({
    this.sort = AlbumTrackSort.album,
    this.custom = const [],
  });

  factory AlbumTrackChoice.fromJson(Map<String, dynamic> json) =>
      AlbumTrackChoice(
        sort: AlbumTrackSort.values.firstWhere(
          (sort) => sort.name == json['sort'],
          orElse: () => AlbumTrackSort.album,
        ),
        custom: [
          for (final key in json['custom'] as List? ?? const [])
            if (key is String) key,
        ],
      );

  final AlbumTrackSort sort;
  final List<String> custom;

  Map<String, dynamic> toJson() => {'sort': sort.name, 'custom': custom};
}

final albumTrackChoicesProvider =
    NotifierProvider<AlbumTrackChoices, Map<String, AlbumTrackChoice>>(
      AlbumTrackChoices.new,
    );

String _storedKey(AlbumTrackSortKey key) =>
    '${key.album.trim().toLowerCase()}|${key.artist.trim().toLowerCase()}';

/// The choice of [key] among [choices], which is the default when unset.
AlbumTrackChoice albumTrackChoiceIn(
  Map<String, AlbumTrackChoice> choices,
  AlbumTrackSortKey key,
) => choices[_storedKey(key)] ?? const AlbumTrackChoice();

/// The albums whose songs are not in album order.
class AlbumTrackChoices extends Notifier<Map<String, AlbumTrackChoice>> {
  static const _prefsKey = 'album_track_choices';
  Future<void>? _loading;

  @override
  Map<String, AlbumTrackChoice> build() {
    _loading = _load();
    return const {};
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonDecode(prefs.getString(_prefsKey) ?? '{}');
      if (json is! Map || json.isEmpty || !ref.mounted) return;
      state = {
        for (final entry in json.entries)
          if (entry.key is String && entry.value is Map<String, dynamic>)
            entry.key as String: AlbumTrackChoice.fromJson(
              entry.value as Map<String, dynamic>,
            ),
        ...state,
      };
    } catch (error) {
      _log.w('Ignoring saved album orders: ${error.runtimeType}');
    }
  }

  AlbumTrackChoice of(AlbumTrackSortKey key) => albumTrackChoiceIn(state, key);

  void setSort(AlbumTrackSortKey key, AlbumTrackSort sort) =>
      _set(key, AlbumTrackChoice(sort: sort, custom: of(key).custom));

  /// Applies [songs], in their new order, as the album's custom order.
  void setCustom(AlbumTrackSortKey key, List<String> songs) => _set(
    key,
    AlbumTrackChoice(
      sort: AlbumTrackSort.custom,
      custom: [for (final song in songs) albumTrackRankKey(song)],
    ),
  );

  void _set(AlbumTrackSortKey key, AlbumTrackChoice choice) {
    final stored = _storedKey(key);
    state = {...state, stored: choice};
    unawaited(_save());
  }

  Future<void> _save() async {
    try {
      await _loading;
      if (!ref.mounted) return;
      final saved = jsonEncode(state);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, saved);
    } catch (error) {
      _log.w('Could not save the album order: ${error.runtimeType}');
    }
  }
}

/// Plays per song of an album, read once each time the album opens so that
/// a song ending does not reorder the page under the listener.
final albumTrackPlaysProvider = FutureProvider.autoDispose
    .family<Map<String, int>, String>((ref, album) async {
      await listeningRecorder.flush();
      return ListeningStatisticsStore.instance.loadAlbumPlays(album);
    });

/// The ranks for [AlbumTrackOrder], or null for album order.
final albumTrackRanksProvider = Provider.autoDispose
    .family<Map<String, int>?, AlbumTrackSortKey>((ref, key) {
      final choice = ref.watch(
        albumTrackChoicesProvider.select((choices) => choices[_storedKey(key)]),
      );
      switch (choice?.sort) {
        case null || AlbumTrackSort.album:
          return null;
        case AlbumTrackSort.mostPlayed:
          final plays = ref.watch(albumTrackPlaysProvider(key.album)).value;
          return plays == null ? null : albumTrackPlayRanks(plays);
        case AlbumTrackSort.custom:
          return albumTrackCustomRanks(choice!.custom);
      }
    });
