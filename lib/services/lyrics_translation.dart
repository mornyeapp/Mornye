import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mornye/services/lyrics_ai_client.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:path_provider/path_provider.dart';

final _log = AppLogger('LyricsTranslation');

final _wordTimeTag = RegExp(r'<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>');
final _lineTimeTag = RegExp(r'\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\]');
final _hasWord = RegExp(r'[\p{L}\p{N}]', unicode: true);
final _instrumental = RegExp(
  r'^[(\[]?\s*(instrumental|music|intro|outro|interlude|solo)\s*[)\]]?$',
  caseSensitive: false,
);

/// The text of a lyric line as sent for translation: timing tags removed
/// and whitespace collapsed. Empty for lines with nothing to translate.
String translatableLyricText(String text) {
  final clean = text
      .replaceAll(_wordTimeTag, '')
      .replaceAll(_lineTimeTag, '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (!_hasWord.hasMatch(clean) || _instrumental.hasMatch(clean)) return '';
  return clean;
}

/// The distinct lines of a song to translate, in first-sung order, and
/// which of them each lyric line shows. A repeated chorus is sent once.
class LyricsTranslationSource {
  LyricsTranslationSource._(this.texts, this.lineSegments, this.hash);

  factory LyricsTranslationSource.of(ParsedLyrics lyrics) {
    final texts = <String>[];
    final index = <String, int>{};
    final lineSegments = <int?>[];
    for (final line in lyrics.lines) {
      final text = translatableLyricText(line.text);
      if (text.isEmpty) {
        lineSegments.add(null);
        continue;
      }
      final segment = index.putIfAbsent(text, () {
        texts.add(text);
        return texts.length - 1;
      });
      lineSegments.add(segment);
    }
    final hash = sha256.convert(utf8.encode(texts.join('\n'))).toString();
    return LyricsTranslationSource._(
      List.unmodifiable(texts),
      List.unmodifiable(lineSegments),
      hash,
    );
  }

  static final _memo = Expando<LyricsTranslationSource>();

  /// Shared per [ParsedLyrics] instance, so rebuilding a view is cheap.
  static LyricsTranslationSource cached(ParsedLyrics lyrics) =>
      _memo[lyrics] ??= LyricsTranslationSource.of(lyrics);

  /// Normalized distinct texts; their index is the id sent to the model.
  final List<String> texts;

  /// For each lyric line, its index in [texts], or null.
  final List<int?> lineSegments;

  /// Hash of [texts], identifying these lyrics regardless of timing.
  final String hash;

  bool get isEmpty => texts.isEmpty;
}

/// The persistent cache key of one translation: the source text, target
/// language, provider and model. A custom server's address is part of its
/// provider identity.
String lyricsTranslationCacheKey({
  required String sourceHash,
  required String language,
  required LyricsAiConfig config,
}) {
  final provider = config.provider == LyricsAiProvider.custom
      ? 'custom:${normalizeLyricsAiBaseUrl(config.baseUrl)}'
      : config.provider.id;
  return sha256
      .convert(
        utf8.encode('v1\n$sourceHash\n$language\n$provider\n${config.model}'),
      )
      .toString();
}

/// Whether any line already carries a provider translation.
bool lyricsHaveTranslation(ParsedLyrics lyrics) =>
    lyrics.lines.any((line) => line.translation?.trim().isNotEmpty == true);

/// Shows [translations] (indexed like [LyricsTranslationSource.texts]) as
/// the lines' translations. An AI translation exists only because the user
/// asked for it, or because the lyrics had none, so it replaces a provider
/// translation on the lines it covers; other lines keep theirs.
ParsedLyrics applyLyricsTranslation(
  ParsedLyrics lyrics,
  LyricsTranslationSource source,
  List<String?> translations,
) {
  var changed = false;
  final lines = <LyricLine>[];
  for (var i = 0; i < lyrics.lines.length; i++) {
    final line = lyrics.lines[i];
    final segment = i < source.lineSegments.length
        ? source.lineSegments[i]
        : null;
    final translation = segment != null && segment < translations.length
        ? translations[segment]
        : null;
    if (translation == null ||
        translation.isEmpty ||
        translation == line.translation) {
      lines.add(line);
      continue;
    }
    changed = true;
    lines.add(line.withTranslation(translation));
  }
  if (!changed) return lyrics;
  return ParsedLyrics(
    synced: lyrics.synced,
    wordSynced: lyrics.wordSynced,
    lines: lines,
    plainText: lyrics.plainText,
    writers: lyrics.writers,
    provider: lyrics.provider,
  );
}

/// Splits [items] into requests of at most [maxItems] lines and [maxChars]
/// characters of text, keeping their order.
List<List<LyricsAiItem>> batchLyricsItems(
  List<LyricsAiItem> items, {
  int maxItems = 60,
  int maxChars = 5000,
}) {
  final batches = <List<LyricsAiItem>>[];
  var current = <LyricsAiItem>[];
  var chars = 0;
  for (final item in items) {
    if (current.isNotEmpty &&
        (current.length >= maxItems || chars + item.text.length > maxChars)) {
      batches.add(current);
      current = [];
      chars = 0;
    }
    current.add(item);
    chars += item.text.length;
  }
  if (current.isNotEmpty) batches.add(current);
  return batches;
}

/// Thrown when a translation was cancelled; never shown to the user.
class LyricsTranslationCancelled implements Exception {
  const LyricsTranslationCancelled();
}

/// Lets the owner of a job stop it. Closing the HTTP client aborts the
/// request in flight.
class LyricsTranslationCancelToken {
  bool _cancelled = false;
  final _listeners = <void Function()>[];
  final _done = Completer<void>();

  bool get isCancelled => _cancelled;

  /// [future], or a [LyricsTranslationCancelled] as soon as this is
  /// cancelled, even if the request itself never returns.
  Future<T> race<T>(Future<T> future) {
    future.ignore();
    return Future.any([
      future,
      _done.future.then<T>((_) => throw const LyricsTranslationCancelled()),
    ]);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _done.complete();
    for (final listener in List.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void throwIfCancelled() {
    if (_cancelled) throw const LyricsTranslationCancelled();
  }
}

/// The outcome of a translation: one entry per source text, null where the
/// model returned nothing usable.
class LyricsTranslationResult {
  const LyricsTranslationResult(this.translations);

  final List<String?> translations;

  int get missing => translations.where((value) => value == null).length;
}

/// Sends a song's lines in sequential batches. A malformed batch is retried
/// once, then split; a truncated one is split straight away. Lines a batch
/// still cannot return stay untranslated instead of failing the song.
class LyricsTranslator {
  LyricsTranslator(this._client, {this.maxItems = 60, this.maxChars = 5000});

  final LyricsAiClient _client;
  final int maxItems;
  final int maxChars;

  Future<LyricsTranslationResult> translate(
    List<String> texts, {
    required String systemPrompt,
    LyricsTranslationCancelToken? cancel,
    void Function(int done, int total)? onProgress,
  }) async {
    if (texts.isEmpty) {
      throw const LyricsAiException(LyricsAiErrorKind.noLyrics);
    }
    final translations = List<String?>.filled(texts.length, null);
    final items = [
      for (var i = 0; i < texts.length; i++) LyricsAiItem(i, texts[i]),
    ];
    var done = 0;
    LyricsAiException? softError;
    onProgress?.call(0, texts.length);

    Future<void> run(List<LyricsAiItem> batch, {bool retried = false}) async {
      cancel?.throwIfCancelled();
      try {
        final request = _client.translate(batch, systemPrompt: systemPrompt);
        final result = await (cancel?.race(request) ?? request);
        cancel?.throwIfCancelled();
        result.forEach((id, text) => translations[id] = text);
        done += batch.length;
        onProgress?.call(done, texts.length);
      } on LyricsAiException catch (error) {
        cancel?.throwIfCancelled();
        if (error.fatal) rethrow;
        softError = error;
        final retry = error.kind == LyricsAiErrorKind.badResponse && !retried;
        if (retry) return run(batch, retried: true);
        if (error.kind != LyricsAiErrorKind.refused && batch.length > 1) {
          final half = batch.length ~/ 2;
          await run(batch.sublist(0, half));
          await run(batch.sublist(half));
          return;
        }
        _log.w('Leaving ${batch.length} lines untranslated: $error');
        done += batch.length;
        onProgress?.call(done, texts.length);
      }
    }

    for (final batch in batchLyricsItems(
      items,
      maxItems: maxItems,
      maxChars: maxChars,
    )) {
      await run(batch);
    }
    if (translations.every((value) => value == null)) {
      throw softError ?? const LyricsAiException(LyricsAiErrorKind.badResponse);
    }
    return LyricsTranslationResult(translations);
  }
}

/// Translations kept apart from the lyrics themselves, in one JSON file in
/// the app support directory. The least recently used entries go first
/// once [maxEntries] is reached.
class LyricsTranslationCache {
  LyricsTranslationCache({
    Future<Directory> Function()? directory,
    this.maxEntries = 500,
  }) : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;
  final int maxEntries;
  Map<String, _CacheEntry>? _entries;
  Future<Map<String, _CacheEntry>>? _loading;
  Future<void> _writes = Future.value();

  static const _fileName = 'lyrics_translations.json';

  Future<File> get _file async =>
      File('${(await _directory()).path}/$_fileName');

  Future<Map<String, _CacheEntry>> _load() {
    if (_entries != null) return Future.value(_entries);
    return _loading ??= () async {
      final entries = <String, _CacheEntry>{};
      try {
        final file = await _file;
        if (await file.exists()) {
          final json = jsonDecode(await file.readAsString());
          final stored = json is Map ? json['entries'] : null;
          if (stored is Map) {
            stored.forEach((key, value) {
              final entry = _CacheEntry.fromJson(value);
              if (key is String && entry != null) entries[key] = entry;
            });
          }
        }
      } catch (error) {
        _log.w('Ignoring unreadable translation cache: $error');
      }
      return _entries = entries;
    }();
  }

  Future<List<String?>?> read(String key) async {
    final entry = (await _load())[key];
    if (entry == null) return null;
    entry.usedAt = DateTime.now().millisecondsSinceEpoch;
    return entry.translations;
  }

  Future<void> write(String key, List<String?> translations) async {
    final entries = await _load();
    entries[key] = _CacheEntry(
      List.unmodifiable(translations),
      DateTime.now().millisecondsSinceEpoch,
    );
    if (entries.length > maxEntries) {
      final oldest = entries.entries.toList()
        ..sort((a, b) => a.value.usedAt.compareTo(b.value.usedAt));
      for (final entry in oldest.take(entries.length - maxEntries)) {
        entries.remove(entry.key);
      }
    }
    await _persist();
  }

  Future<int> count() async => (await _load()).length;

  Future<void> clear() async {
    (await _load()).clear();
    await _persist();
  }

  Future<void> _persist() {
    final snapshot = jsonEncode({
      'version': 1,
      'entries': {
        for (final entry in _entries!.entries) entry.key: entry.value.toJson(),
      },
    });
    return _writes = _writes.then((_) async {
      try {
        final file = await _file;
        await file.parent.create(recursive: true);
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(snapshot, flush: true);
        await temp.rename(file.path);
      } catch (error) {
        _log.w('Could not save translation cache: $error');
      }
    });
  }
}

class _CacheEntry {
  _CacheEntry(this.translations, this.usedAt);

  final List<String?> translations;
  int usedAt;

  static _CacheEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final list = json['t'];
    if (list is! List) return null;
    return _CacheEntry(
      List.unmodifiable([
        for (final value in list) value is String ? value : null,
      ]),
      (json['at'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, Object> toJson() => {'t': translations, 'at': usedAt};
}
