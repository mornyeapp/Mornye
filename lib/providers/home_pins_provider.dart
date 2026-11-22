import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/home_pin.dart';
import 'package:mornye/providers/library_artist_songs_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_directory_provider.dart';
import 'package:mornye/providers/library_genres_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('HomePins');

final homePinsProvider = NotifierProvider<HomePinsNotifier, List<HomePin>>(
  HomePinsNotifier.new,
);

/// What the person pinned to Home, in Home's order.
class HomePinsNotifier extends Notifier<List<HomePin>> {
  static const prefsKey = 'home_pins_v1';

  /// How many pins Home holds.
  static const limit = 12;

  Future<void>? _loading;

  @override
  List<HomePin> build() {
    _loading = _load();
    return const [];
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = decode(prefs.getString(prefsKey));
      if (saved.isEmpty || !ref.mounted) return;
      // Pins made while loading stay after the saved ones.
      state = [
        ...saved.where((pin) => !state.contains(pin)),
        ...state,
      ].take(limit).toList(growable: false);
    } catch (error) {
      _log.w('Ignoring saved Home pins: ${error.runtimeType}');
    }
  }

  /// The pins in [json], without unknown kinds, repeats or those past
  /// [limit]. Data that is not a list reads as no pins.
  static List<HomePin> decode(String? json) {
    if (json == null || json.isEmpty) return const [];
    Object? list;
    try {
      list = jsonDecode(json);
    } on FormatException {
      return const [];
    }
    if (list is! List) return const [];
    final pins = <HomePin>[];
    for (final entry in list) {
      final pin = HomePin.fromJson(entry);
      if (pin == null || pins.contains(pin)) continue;
      pins.add(pin);
      if (pins.length == limit) break;
    }
    return pins;
  }

  bool isPinned(String key) => state.any((pin) => pin.key == key);

  /// Pins [pin] after the others. False when Home already holds [limit].
  bool add(HomePin pin) {
    if (state.contains(pin)) return true;
    if (state.length >= limit) return false;
    state = [...state, pin];
    unawaited(_save());
    return true;
  }

  void remove(String key) {
    if (!isPinned(key)) return;
    state = [
      for (final pin in state)
        if (pin.key != key) pin,
    ];
    unawaited(_save());
  }

  void moveToFront(String key) {
    final index = state.indexWhere((pin) => pin.key == key);
    if (index <= 0) return;
    state = [state[index], ...state.take(index), ...state.skip(index + 1)];
    unawaited(_save());
  }

  Future<void> _save() async {
    try {
      await _loading;
      if (!ref.mounted) return;
      final saved = jsonEncode([for (final pin in state) pin.toJson()]);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, saved);
    } catch (error) {
      _log.w('Could not save the Home pins: ${error.runtimeType}');
    }
  }
}

/// Whether a pin's target is still in the Library. A check that fails
/// answers true, so the page itself says what is missing.
final homePinTargetExistsProvider = Provider<Future<bool> Function(HomePin)>(
  (ref) => (pin) async {
    try {
      switch (pin.kind) {
        case HomePinKind.loved:
          return true;
        case HomePinKind.playlist:
          final collections = ref.read(libraryCollectionsProvider);
          return !collections.isLoaded ||
              collections.playlists.any((playlist) => playlist.id == pin.id);
        case HomePinKind.album:
          final rows = pin.source == 'local'
              ? await LibraryDatabase.instance.getQueueLocalAlbumTracksByKey(
                  pin.id,
                )
              : await HistoryDatabase.instance.getAlbumTracks(
                  pin.title,
                  pin.subtitle,
                );
          return rows.isNotEmpty;
        case HomePinKind.artist:
          final songs = await ref.read(
            libraryArtistSongsProvider(pin.title).future,
          );
          return songs.isNotEmpty;
        case HomePinKind.genre:
          final genres = await ref.read(libraryGenresProvider.future);
          return genres.any((genre) => genre.key == pin.id);
        case HomePinKind.folder:
          final index = await ref.read(libraryDirectoryIndexProvider.future);
          return index[pin.id] != null;
      }
    } catch (error) {
      _log.w('Could not check a Home pin: ${error.runtimeType}');
      return true;
    }
  },
);
