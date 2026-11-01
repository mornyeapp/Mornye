import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/lyrics_translation.dart';

final _sourceHash = RegExp(r'^[0-9a-f]{64}$');

bool isLyricsTranslationHash(Object? value) =>
    value is String && _sourceHash.hasMatch(value);

/// A completed translation, independent of the AI account and local paths.
/// Source text hashes let another device keep its own lyric timestamps.
class SharedLyricsTranslation {
  const SharedLyricsTranslation({
    required this.sourceHash,
    required this.language,
    required this.result,
    required this.updatedMs,
  });

  final String sourceHash;
  final String language;
  final LyricsTranslationResult result;
  final int updatedMs;

  Map<String, dynamic> toJson() => {
    'sourceHash': sourceHash,
    'language': language,
    'translations': result.translations,
    'romanizations': result.romanizations,
    'updatedMs': updatedMs,
  };

  static SharedLyricsTranslation? fromJson(Object? value) {
    if (value is! Map) return null;
    final hash = value['sourceHash'];
    final language = value['language'];
    final updated = value['updatedMs'];
    final translations = value['translations'];
    final romanizations = value['romanizations'] ?? const <String?>[];
    bool validLines(Object? lines) =>
        lines is List &&
        lines.length <= 2000 &&
        lines.every(
          (line) => line == null || (line is String && line.length <= 4000),
        );
    if (!isLyricsTranslationHash(hash) ||
        language is! String ||
        !RegExp(r'^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$').hasMatch(language) ||
        updated is! int ||
        updated < 0 ||
        !validLines(translations) ||
        !validLines(romanizations)) {
      return null;
    }
    final texts = (translations as List).cast<String?>();
    final readings = (romanizations as List).cast<String?>();
    if (texts.isEmpty ||
        texts.every((line) => line == null || line.isEmpty) ||
        (readings.isNotEmpty && readings.length != texts.length)) {
      return null;
    }
    final update = SharedLyricsTranslation(
      sourceHash: hash as String,
      language: language,
      result: LyricsTranslationResult(
        List.unmodifiable(texts),
        romanizations: List.unmodifiable(readings),
      ),
      updatedMs: updated,
    );
    // Stay well below Link's frame and outgoing queue limits.
    return utf8.encode(jsonEncode(update.toJson())).length <= 128 * 1024
        ? update
        : null;
  }
}

/// Completed results available to Link, plus the overlay received from it.
/// Incoming results never go back onto [outgoing], avoiding echo loops.
class LyricsTranslationSharing {
  final _available = <String, SharedLyricsTranslation>{};
  final _received = <String>{};
  final _outgoing = StreamController<SharedLyricsTranslation>.broadcast();
  final _incoming = StreamController<SharedLyricsTranslation>.broadcast();
  final _requests = StreamController<String>.broadcast();
  String? requestedSourceHash;

  Stream<SharedLyricsTranslation> get outgoing => _outgoing.stream;
  Stream<SharedLyricsTranslation> get incoming => _incoming.stream;
  Stream<String> get requests => _requests.stream;

  SharedLyricsTranslation? lookup(String hash) => _available[hash];
  SharedLyricsTranslation? receivedFor(String hash) =>
      _received.contains(hash) ? _available[hash] : null;

  void request(String hash) {
    if (requestedSourceHash == hash) return;
    requestedSourceHash = hash;
    _requests.add(hash);
  }

  void _remember(SharedLyricsTranslation update) {
    _available.remove(update.sourceHash);
    _available[update.sourceHash] = update;
    while (_available.length > 50) {
      final oldest = _available.keys.first;
      _available.remove(oldest);
      _received.remove(oldest);
    }
  }

  void publish(SharedLyricsTranslation update) {
    _remember(update);
    _received.remove(update.sourceHash);
    _outgoing.add(update);
  }

  bool receive(SharedLyricsTranslation update) {
    final previous = lookup(update.sourceHash);
    if (previous != null &&
        (previous.updatedMs > update.updatedMs ||
            jsonEncode(previous.toJson()) == jsonEncode(update.toJson()))) {
      return false;
    }
    _remember(update);
    _received.add(update.sourceHash);
    _incoming.add(update);
    return true;
  }

  /// An explicit local language or AI configuration choice takes priority.
  void clearReceived() => _received.clear();

  void clear() {
    _available.clear();
    _received.clear();
    requestedSourceHash = null;
  }

  void dispose() {
    unawaited(_outgoing.close());
    unawaited(_incoming.close());
    unawaited(_requests.close());
  }
}

final lyricsTranslationSharingProvider = Provider<LyricsTranslationSharing>((
  ref,
) {
  final sharing = LyricsTranslationSharing();
  ref.onDispose(sharing.dispose);
  return sharing;
});
