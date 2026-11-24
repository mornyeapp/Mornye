import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('SongLyricsOffsets');

/// Where the per-song lyric timing offsets are kept: one JSON object of
/// `{"<song key>": [offsetMs, editedMs]}`. A song in sync stores nothing.
const String kSongLyricsOffsetsKey = 'lyrics_song_offsets_v1';

/// Most songs that keep their own offset. Past it the song edited longest
/// ago gives its offset up, so the store and a sync exchange stay small.
const int kMaxSongLyricsOffsets = 500;

/// The key a song's own lyric timing offset is kept under: its title and
/// artist, trimmed and lowercased, as Library, History and Link already
/// match a song across devices ([HistoryDatabase.matchKeyFor]). A file path
/// would change with a move and differs on every device; the title and
/// artist do not. Empty for a song without a title, which keeps none.
String songLyricsOffsetKey(String? title, String? artist) =>
    HistoryDatabase.matchKeyFor(title, artist);

/// [songLyricsOffsetKey] of [item], or empty without one.
String songLyricsOffsetKeyOf(MediaItem? item) =>
    item == null ? '' : songLyricsOffsetKey(item.title, item.artist);

/// One song's own offset and when it was last set on this device (or, for
/// a synced value, by the device that set it).
@immutable
class SongLyricsOffset {
  const SongLyricsOffset(this.offsetMs, this.editedMs);

  final int offsetMs;
  final int editedMs;

  @override
  bool operator ==(Object other) =>
      other is SongLyricsOffset &&
      other.offsetMs == offsetMs &&
      other.editedMs == editedMs;

  @override
  int get hashCode => Object.hash(offsetMs, editedMs);
}

/// Parses the stored offsets, skipping anything damaged.
Map<String, SongLyricsOffset> decodeSongLyricsOffsets(String? raw) {
  if (raw == null || raw.isEmpty) return const {};
  try {
    final json = jsonDecode(raw);
    if (json is! Map) return const {};
    final offsets = <String, SongLyricsOffset>{};
    for (final MapEntry(:key, :value) in json.entries) {
      if (key is! String || key.isEmpty || value is! List || value.isEmpty) {
        continue;
      }
      final first = value.first;
      final offsetMs = normalizeLyricsOffsetMs(first is num ? first : null);
      if (offsetMs == 0) continue;
      final edited = value.length > 1 ? value[1] : null;
      offsets[key] = SongLyricsOffset(
        offsetMs,
        edited is num && edited.isFinite ? edited.toInt() : 0,
      );
    }
    return offsets;
  } on FormatException {
    return const {};
  }
}

String _encode(Map<String, SongLyricsOffset> offsets) => jsonEncode({
  for (final MapEntry(:key, :value) in offsets.entries)
    key: [value.offsetMs, value.editedMs],
});

/// The offset stored for [key] in [prefs], read without the provider (the
/// lock screen reads it on its own).
int storedSongLyricsOffsetMs(SharedPreferences prefs, String key) {
  if (key.isEmpty) return 0;
  return decodeSongLyricsOffsets(
        prefs.getString(kSongLyricsOffsetsKey),
      )[key]?.offsetMs ??
      0;
}

/// Each song's own lyric timing offset, added to the app-wide one for that
/// song's synced lyrics. Unlike the app-wide offset, which makes up for
/// this device's output delay, it belongs to the song's lyrics, so it is
/// the same on every device and may sync over Link.
class SongLyricsOffsetsNotifier
    extends Notifier<Map<String, SongLyricsOffset>> {
  SongLyricsOffsetsNotifier({
    Future<SharedPreferences>? preferences,
    int Function()? clock,
  }) : _prefs = preferences ?? SharedPreferences.getInstance(),
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Future<SharedPreferences> _prefs;
  final int Function() _clock;
  late Future<void> _loadFuture;
  Future<void> _saveChain = Future<void>.value();
  final _loadingEdits =
      <Map<String, SongLyricsOffset> Function(Map<String, SongLyricsOffset>)>[];
  bool _loaded = false;

  /// When a song went back in sync here, this run, so a sync can date the
  /// removal by the edit and not by when it noticed it.
  final _resetAt = <String, int>{};

  @override
  Map<String, SongLyricsOffset> build() {
    _loadFuture = _load();
    return const {};
  }

  /// Completes once the stored offsets are read.
  Future<void> ensureLoaded() => _loadFuture;

  /// When [key] went back in sync on this device during this run, if it did.
  int? resetAt(String key) => _resetAt[key];

  Future<void> _load() async {
    try {
      final prefs = await _prefs;
      var loaded = decodeSongLyricsOffsets(
        prefs.getString(kSongLyricsOffsetsKey),
      );
      for (final edit in _loadingEdits) {
        loaded = edit(loaded);
      }
      if (ref.mounted) state = Map.unmodifiable(loaded);
    } catch (error) {
      _log.w('Could not read song lyric offsets: $error');
    } finally {
      _loaded = true;
      _loadingEdits.clear();
    }
  }

  void _edit(
    Map<String, SongLyricsOffset> Function(Map<String, SongLyricsOffset>) edit,
  ) {
    if (!_loaded) _loadingEdits.add(edit);
    state = Map.unmodifiable(edit(state));
  }

  Future<void> _save() => _saveChain = _saveChain.then((_) async {
    try {
      await _loadFuture;
      final prefs = await _prefs;
      if (!ref.mounted) return;
      final snapshot = state;
      if (snapshot.isEmpty) {
        await prefs.remove(kSongLyricsOffsetsKey);
      } else {
        await prefs.setString(kSongLyricsOffsetsKey, _encode(snapshot));
      }
    } catch (error) {
      _log.w('Could not save song lyric offsets: $error');
    }
  });

  /// Sets the offset of the song under [key]; 0 puts it back in sync and
  /// stores nothing. [persist] false previews it while a slider moves.
  Future<void> setOffsetMs(String key, int value, {bool persist = true}) async {
    if (key.isEmpty) return;
    final offsetMs = normalizeLyricsOffsetMs(value);
    final now = _clock();
    if (offsetMs == 0) {
      _resetAt[key] = now;
    } else {
      _resetAt.remove(key);
    }
    _edit((current) => _with(current, {key: SongLyricsOffset(offsetMs, now)}));
    if (persist) await _save();
  }

  /// Applies offsets synced from another device, each dated by its author's
  /// edit. An offset of 0 removes the song's.
  Future<void> applySynced(Map<String, SongLyricsOffset> values) async {
    if (values.isEmpty) return;
    for (final MapEntry(:key, :value) in values.entries) {
      if (value.offsetMs == 0) {
        _resetAt[key] = value.editedMs;
      } else {
        _resetAt.remove(key);
      }
    }
    _edit((current) => _with(current, values));
    await _save();
  }

  /// [current] with [changes]: a zero offset removes its song, and past
  /// [kMaxSongLyricsOffsets] the song edited longest ago goes first.
  static Map<String, SongLyricsOffset> _with(
    Map<String, SongLyricsOffset> current,
    Map<String, SongLyricsOffset> changes,
  ) {
    final next = Map<String, SongLyricsOffset>.of(current);
    for (final MapEntry(:key, :value) in changes.entries) {
      final offsetMs = normalizeLyricsOffsetMs(value.offsetMs);
      if (offsetMs == 0) {
        next.remove(key);
      } else {
        next[key] = SongLyricsOffset(offsetMs, value.editedMs);
      }
    }
    if (next.length > kMaxSongLyricsOffsets) {
      final oldest =
          next.entries
              .where((entry) => !changes.containsKey(entry.key))
              .toList()
            ..sort((a, b) => a.value.editedMs.compareTo(b.value.editedMs));
      for (final entry in oldest.take(next.length - kMaxSongLyricsOffsets)) {
        next.remove(entry.key);
      }
    }
    return next;
  }
}

final songLyricsOffsetsProvider =
    NotifierProvider<SongLyricsOffsetsNotifier, Map<String, SongLyricsOffset>>(
      SongLyricsOffsetsNotifier.new,
    );

/// The song's own offset under [key], 0 for none.
final songLyricsOffsetMsProvider = Provider.autoDispose.family<int, String>(
  (ref, key) => key.isEmpty
      ? 0
      : ref.watch(
          songLyricsOffsetsProvider.select(
            (offsets) => offsets[key]?.offsetMs ?? 0,
          ),
        ),
);

/// The offset synced lyrics of the song under [key] are drawn with: the
/// app-wide offset plus the song's own.
final lyricsOffsetMsForSongProvider = Provider.autoDispose.family<int, String>(
  (ref, key) =>
      ref.watch(themeProvider.select((theme) => theme.lyricsOffsetMs)) +
      ref.watch(songLyricsOffsetMsProvider(key)),
);
