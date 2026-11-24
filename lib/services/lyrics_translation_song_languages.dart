import 'dart:convert';

import 'package:mornye/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('LyricsSongLanguages');

/// Translation languages picked for single songs, by lyrics hash. The oldest
/// choices leave first once [maxEntries] are kept.
class LyricsTranslationSongLanguages {
  LyricsTranslationSongLanguages({this.maxEntries = 500});

  final int maxEntries;
  final _codes = <String, String>{};
  Future<bool>? _loading;

  static const _key = 'lyrics_translation_song_languages';

  String? operator [](String sourceHash) => _codes[sourceHash];

  /// Reads the saved choices once. True when this call brought any in.
  Future<bool> load() => _loading ??= _read();

  Future<bool> _read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonDecode(prefs.getString(_key) ?? '{}');
      if (json is! Map) return false;
      // Choices made while this read ran are newer.
      final made = Map.of(_codes);
      _codes.clear();
      json.forEach((hash, code) {
        if (hash is String && code is String) _codes[hash] = code;
      });
      _codes.addAll(made);
      return _codes.isNotEmpty;
    } catch (error) {
      _log.w('Ignoring saved song languages: ${error.runtimeType}');
      return false;
    }
  }

  /// Keeps [code] for the song, or forgets its choice when null.
  Future<void> set(String sourceHash, String? code) async {
    _codes.remove(sourceHash);
    if (code != null) _codes[sourceHash] = code;
    while (_codes.length > maxEntries) {
      _codes.remove(_codes.keys.first);
    }
    try {
      await load();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(_codes));
    } catch (error) {
      _log.w('Could not save the song language: ${error.runtimeType}');
    }
  }
}
