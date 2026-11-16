import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/lyrics_ai_client.dart';
import 'package:mornye/services/lyrics_language_guess.dart';
import 'package:mornye/services/lyrics_romanization.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/services/lyrics_translation_languages.dart';
import 'package:mornye/services/lyrics_translation_sharing.dart';
import 'package:mornye/services/lyrics_translation_song_languages.dart';
import 'package:mornye/services/romanization/pinyin.dart';
import 'package:mornye/services/romanization/text_romanizer.dart';
import 'package:mornye/services/secure_storage_options.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/lyrics_parser.dart';

final _log = AppLogger('LyricsTranslation');

/// Where AI provider keys are kept, one per provider.
abstract class LyricsAiKeyStore {
  Future<String?> read(String provider);
  Future<void> write(String provider, String key);
  Future<void> delete(String provider);
}

class SecureLyricsAiKeyStore implements LyricsAiKeyStore {
  const SecureLyricsAiKeyStore();

  static const _storage = FlutterSecureStorage(
    aOptions: secureStorageAndroidOptions,
    mOptions: secureStorageMacOsOptions,
  );

  static String _key(String provider) => 'lyrics_ai_api_key_$provider';

  @override
  Future<String?> read(String provider) async {
    try {
      return await _storage.read(key: _key(provider));
    } catch (error) {
      _log.w('Could not read the AI translation key: ${error.runtimeType}');
      return null;
    }
  }

  @override
  Future<void> write(String provider, String key) =>
      _storage.write(key: _key(provider), value: key);

  @override
  Future<void> delete(String provider) => _storage.delete(key: _key(provider));
}

final lyricsAiKeyStoreProvider = Provider<LyricsAiKeyStore>(
  (ref) => const SecureLyricsAiKeyStore(),
);

final lyricsTranslationCacheProvider = Provider<LyricsTranslationCache>(
  (ref) => LyricsTranslationCache(),
);

final lyricsTranslationSongLanguagesProvider =
    Provider<LyricsTranslationSongLanguages>(
      (ref) => LyricsTranslationSongLanguages(),
    );

final pinyinDataLoaderProvider = Provider<PinyinDataLoader>(
  (ref) => PinyinDataLoader(),
);

/// The scripts of the app's language, or of the system's when the app
/// follows it: the user reads them, so they are never romanized.
Set<LyricsScript> lyricsReaderScriptsFor(AppSettings settings) =>
    lyricsReaderScripts(
      localeFromAppSetting(settings.locale) ??
          PlatformDispatcher.instance.locale,
    );

/// Whether a translation of [lyrics] also asks for romanization: for the
/// lines offline romanization cannot give, when the settings want both.
bool lyricsAiRomanizes(AppSettings settings, ParsedLyrics lyrics) =>
    settings.lyricsRomanize &&
    settings.lyricsAiRomanize &&
    linesNeedingAiRomanization(
      lyrics,
      readerScripts: lyricsReaderScriptsFor(settings),
    ).isNotEmpty;

/// Creates the HTTP client of one job; tests substitute a mock.
final lyricsAiHttpClientProvider = Provider<http.Client Function()>(
  (ref) => http.Client.new,
);

/// The saved key of a provider id, or an empty string.
final lyricsAiKeyProvider = FutureProvider.family<String, String>(
  (ref, provider) async =>
      (await ref.watch(lyricsAiKeyStoreProvider).read(provider))?.trim() ?? '',
);

/// The model a request uses: the chosen one or the provider's default.
String lyricsAiModelFor(AppSettings settings) {
  final chosen = settings.lyricsAiModel.trim();
  if (chosen.isNotEmpty) return chosen;
  return LyricsAiProvider.fromId(settings.lyricsAiProvider).defaultModel ?? '';
}

LyricsAiConfig lyricsAiConfigFor(AppSettings settings, {String apiKey = ''}) =>
    LyricsAiConfig(
      provider: LyricsAiProvider.fromId(settings.lyricsAiProvider),
      model: lyricsAiModelFor(settings),
      apiKey: apiKey,
      baseUrl: settings.lyricsAiBaseUrl,
    );

/// Whether requests can be sent: a model, plus a key or a server URL.
bool lyricsAiReady(AppSettings settings, String apiKey) {
  final config = lyricsAiConfigFor(settings, apiKey: apiKey);
  if (config.model.isEmpty) return false;
  if (config.provider == LyricsAiProvider.custom) {
    return isValidLyricsAiBaseUrl(config.baseUrl);
  }
  return apiKey.isNotEmpty;
}

/// The chosen target language, else the app's language.
LyricsTranslationLanguage lyricsTranslationTargetFor(AppSettings settings) =>
    lyricsTranslationLanguageFor(settings.lyricsTranslationLanguage) ??
    lyricsTranslationLanguageForLocale(
      localeFromAppSetting(settings.locale) ??
          PlatformDispatcher.instance.locale,
    );

class LyricsTranslationJob {
  const LyricsTranslationJob({
    required this.id,
    required this.sourceHash,
    required this.done,
    required this.total,
  });

  final int id;
  final String sourceHash;
  final int done;
  final int total;

  double? get progress => total == 0 ? null : done / total;
}

class LyricsTranslationState {
  const LyricsTranslationState({this.results = const {}, this.job});

  /// Translations read or made this session, by cache key.
  final Map<String, LyricsTranslationResult> results;
  final LyricsTranslationJob? job;
}

class LyricsTranslationOutcome {
  const LyricsTranslationOutcome.success({
    this.missing = 0,
    this.unchanged = false,
  }) : error = null,
       cancelled = false,
       busy = false;
  const LyricsTranslationOutcome.failed(LyricsAiErrorKind this.error)
    : missing = 0,
      unchanged = false,
      cancelled = false,
      busy = false;
  const LyricsTranslationOutcome.cancelled()
    : error = null,
      missing = 0,
      unchanged = false,
      cancelled = true,
      busy = false;
  const LyricsTranslationOutcome.busy()
    : error = null,
      missing = 0,
      unchanged = false,
      cancelled = false,
      busy = true;

  final LyricsAiErrorKind? error;

  final int missing;

  /// The model returned every line as it was: the lyrics are already in
  /// the target language.
  final bool unchanged;
  final bool cancelled;

  final bool busy;
}

final lyricsTranslationProvider =
    NotifierProvider<LyricsTranslationController, LyricsTranslationState>(
      LyricsTranslationController.new,
    );

/// Owns AI translations of the playing lyrics: the persistent cache, the
/// single running job and automatic translation. Lyrics themselves are
/// never changed; [display] overlays a translation when one exists.
class LyricsTranslationController extends Notifier<LyricsTranslationState> {
  final _lookedUp = <String>{};
  final _autoAttempted = <String>{};
  final _merged =
      Expando<(LyricsTranslationResult, ParsedLyrics, Set<LyricsScript>)>();
  final _alreadyInTarget = <String, bool>{};
  LyricsTranslationCancelToken? _cancel;
  Object? _owner;
  int _jobIds = 0;
  late LyricsTranslationSharing _sharing;
  late LyricsTranslationSongLanguages _songLanguages;
  late PinyinDataLoader _pinyin;
  final _shown =
      Expando<(bool, bool, PinyinData?, Set<LyricsScript>, ParsedLyrics)>();
  bool _pinyinRequested = false;

  @override
  LyricsTranslationState build() {
    _pinyin = ref.watch(pinyinDataLoaderProvider);
    _sharing = ref.watch(lyricsTranslationSharingProvider);
    _songLanguages = ref.watch(lyricsTranslationSongLanguagesProvider);
    unawaited(
      _songLanguages.load().then((loaded) {
        if (loaded && ref.mounted) _refreshLanguage();
      }),
    );
    final incoming = _sharing.incoming.listen((update) {
      if (!ref.mounted) return;
      state = LyricsTranslationState(
        // The sharing store owns the bounded overlays. This entry only
        // invalidates views that watch results, without retaining every song.
        results: {...state.results, 'link:latest': update.result},
        job: state.job,
      );
    });
    ref.onDispose(incoming.cancel);
    ref.listen(
      settingsProvider.select(
        (settings) => (
          settings.lyricsTranslationLanguage,
          settings.lyricsTranslationSecondLanguage,
          settings.locale,
          settings.lyricsAiProvider,
          settings.lyricsAiModel,
          settings.lyricsAiBaseUrl,
        ),
      ),
      (_, _) {
        _sharing.clearReceived();
        _lookedUp.clear();
      },
    );
    ref.onDispose(() => _cancel?.cancel());
    return const LyricsTranslationState();
  }

  String? _cacheKey(
    LyricsTranslationSource source,
    AppSettings settings, {
    String? language,
  }) {
    final config = lyricsAiConfigFor(settings);
    if (source.isEmpty || config.model.isEmpty) return null;
    return lyricsTranslationCacheKey(
      sourceHash: source.hash,
      language: language ?? _targetOf(source, settings).code,
      config: config,
    );
  }

  /// The second language when the song is already in the first, else the
  /// first.
  LyricsTranslationLanguage _settingsTargetOf(
    LyricsTranslationSource source,
    AppSettings settings,
  ) {
    final first = lyricsTranslationTargetFor(settings);
    final second = lyricsTranslationLanguageFor(
      settings.lyricsTranslationSecondLanguage,
    );
    if (second == null || second.code == first.code) return first;
    return _alreadyIn(source, first.code) ? second : first;
  }

  bool _alreadyIn(LyricsTranslationSource source, String code) {
    if (_alreadyInTarget.length > 64) _alreadyInTarget.clear();
    return _alreadyInTarget.putIfAbsent(
      '${source.hash}:$code',
      () => lyricsAlreadyIn(source.texts, code),
    );
  }

  LyricsTranslationLanguage _targetOf(
    LyricsTranslationSource source,
    AppSettings settings,
  ) =>
      lyricsTranslationLanguageFor(_songLanguages[source.hash] ?? '') ??
      _settingsTargetOf(source, settings);

  /// The language [lyrics] translate into: the song's own choice, else what
  /// the settings give for this song.
  LyricsTranslationLanguage targetFor(ParsedLyrics lyrics) => _targetOf(
    LyricsTranslationSource.cached(lyrics),
    ref.read(settingsProvider),
  );

  /// Whether [lyrics] already read in the language [targetFor] gives: they
  /// are written in it, or its AI translation is shown.
  bool inTargetLanguage(ParsedLyrics lyrics) {
    final source = LyricsTranslationSource.cached(lyrics);
    if (source.isEmpty) return false;
    final settings = ref.read(settingsProvider);
    final target = _targetOf(source, settings).code;
    // A linked device's translation is the one [display] shows, if any.
    final shared = _sharing.receivedFor(source.hash);
    final key = _cacheKey(source, settings, language: target);
    final shown = shared != null
        ? shared.language == target
        : key != null && state.results.containsKey(key);
    return shown || _alreadyIn(source, target);
  }

  LyricsTranslationLanguage settingsTargetFor(ParsedLyrics lyrics) =>
      _settingsTargetOf(
        LyricsTranslationSource.cached(lyrics),
        ref.read(settingsProvider),
      );

  /// The language picked for this song alone, if any.
  String? songLanguage(ParsedLyrics lyrics) =>
      _songLanguages[LyricsTranslationSource.cached(lyrics).hash];

  /// Keeps [code] for the song of [lyrics] alone, leaving the settings
  /// as they are. An empty code follows the settings again.
  void chooseSongLanguage(ParsedLyrics lyrics, String code) {
    unawaited(
      _songLanguages.set(
        LyricsTranslationSource.cached(lyrics).hash,
        code.isEmpty ? null : code,
      ),
    );
    _refreshLanguage();
  }

  void _refreshLanguage() {
    _sharing.clearReceived();
    _lookedUp.clear();
    state = LyricsTranslationState(results: state.results, job: state.job);
  }

  /// [lyrics] with the AI translation for the current settings, when one
  /// was made. Looks the cache up once per song and may start an automatic
  /// translation; both report back through the state.
  ParsedLyrics display(ParsedLyrics lyrics) {
    if (lyrics.isEmpty) return lyrics;
    final settings = ref.read(settingsProvider);
    final source = LyricsTranslationSource.cached(lyrics);
    if (source.isEmpty) return lyrics;
    _sharing.request(source.hash);
    final shared = _sharing.receivedFor(source.hash);
    if (shared != null) return _apply(lyrics, source, shared.result);
    final key = _cacheKey(source, settings);
    if (key == null) return lyrics;
    final result = state.results[key];
    if (result == null) {
      if (_lookedUp.add(key)) {
        scheduleMicrotask(() => _lookUp(key, lyrics, settings));
      }
      return lyrics;
    }
    return _apply(lyrics, source, result);
  }

  /// [lyrics] as the player shows them: [display], with the offline
  /// romanization and the main line the settings choose. Saving uses
  /// [display]: offline romanization is worked out again, never saved.
  ParsedLyrics shown(ParsedLyrics lyrics) {
    final translated = display(lyrics);
    final settings = ref.read(settingsProvider);
    final romanize = settings.lyricsRomanize;
    final mainLine = settings.lyricsRomanizedMainLine;
    if (!romanize && !mainLine) return translated;
    final pinyin = _pinyin.data;
    final readers = lyricsReaderScriptsFor(settings);
    final memo = _shown[translated];
    if (memo != null &&
        memo.$1 == romanize &&
        memo.$2 == mainLine &&
        identical(memo.$3, pinyin) &&
        setEquals(memo.$4, readers)) {
      return memo.$5;
    }
    var result = translated;
    if (romanize) {
      if (pinyin == null &&
          lyricsNeedPinyin(translated, readerScripts: readers)) {
        _loadPinyin();
      }
      result = lyricsWithOfflineRomanization(
        result,
        pinyin: pinyin,
        readerScripts: readers,
      );
    }
    if (mainLine) result = lyricsWithRomanizedMainLines(result);
    _shown[translated] = (romanize, mainLine, pinyin, readers, result);
    return result;
  }

  /// Loads the Chinese readings, then has the views show them.
  void _loadPinyin() {
    if (_pinyinRequested) return;
    _pinyinRequested = true;
    unawaited(
      _pinyin.load().then((data) {
        if (data == null || !ref.mounted) return;
        state = LyricsTranslationState(
          results: {...state.results},
          job: state.job,
        );
      }),
    );
  }

  /// [lyrics] with [result], timed word by word wherever [result] has the
  /// timing, whatever the mode: the mode only decides whether a new
  /// translation asks for it. A translation from a linked device, or one
  /// saved in Synced mode, keeps its timing.
  ParsedLyrics _apply(
    ParsedLyrics lyrics,
    LyricsTranslationSource source,
    LyricsTranslationResult result,
  ) {
    final readers = lyricsReaderScriptsFor(ref.read(settingsProvider));
    final memo = _merged[lyrics];
    if (memo != null &&
        identical(memo.$1, result) &&
        setEquals(memo.$3, readers)) {
      return memo.$2;
    }
    final merged = lyricsWithoutReaderRomanization(
      lyrics,
      applyLyricsTranslation(
        lyrics,
        source,
        result.translations,
        romanizations: result.romanizations,
        alignments: result.alignments,
        romanizationAlignments: result.romanizationAlignments,
      ),
      readers,
    );
    _merged[lyrics] = (result, merged, readers);
    return merged;
  }

  void _publish(
    String sourceHash,
    String language,
    LyricsTranslationResult result,
  ) {
    _sharing.publish(
      SharedLyricsTranslation(
        sourceHash: sourceHash,
        language: language,
        result: result,
        updatedMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> _lookUp(
    String key,
    ParsedLyrics lyrics,
    AppSettings settings,
  ) async {
    if (!ref.mounted) return;
    final cached = await ref.read(lyricsTranslationCacheProvider).read(key);
    if (!ref.mounted) return;
    final source = LyricsTranslationSource.cached(lyrics);
    // A peer can finish while the local disk lookup is still pending.
    if (_sharing.receivedFor(source.hash) != null) return;
    if (cached != null) {
      state = LyricsTranslationState(
        results: {...state.results, key: cached},
        job: state.job,
      );
      if (_cacheKey(source, ref.read(settingsProvider)) == key) {
        _publish(source.hash, _targetOf(source, settings).code, cached);
      }
      return;
    }
    // Automatic translation is for synced lyrics, as its setting says;
    // plain lyrics translate when asked.
    if (!settings.lyricsAutoTranslate ||
        !lyrics.synced ||
        state.job != null ||
        lyricsHaveTranslation(lyrics) ||
        !_autoAttempted.add(key)) {
      return;
    }
    // A song already in the target language has nothing to translate.
    if (_alreadyIn(source, _targetOf(source, settings).code)) {
      return;
    }
    final apiKey = await ref.read(
      lyricsAiKeyProvider(settings.lyricsAiProvider).future,
    );
    if (!ref.mounted ||
        !lyricsAiReady(settings, apiKey) ||
        _sharing.receivedFor(source.hash) != null) {
      return;
    }
    final outcome = await translate(lyrics);
    if (outcome.error != null) {
      _log.w('Automatic translation failed: ${outcome.error!.name}');
    }
  }

  /// Translates [lyrics] into [language] (the saved target by default).
  /// Only one job runs at a time; the busy state is set before anything is
  /// awaited, so a second tap returns [LyricsTranslationOutcome.busy].
  /// [owner] lets the screen that started it cancel it on leaving.
  Future<LyricsTranslationOutcome> translate(
    ParsedLyrics lyrics, {
    String? language,
    Object? owner,
  }) async {
    if (state.job != null) return const LyricsTranslationOutcome.busy();
    final source = LyricsTranslationSource.cached(lyrics);
    if (source.isEmpty) {
      return const LyricsTranslationOutcome.failed(LyricsAiErrorKind.noLyrics);
    }
    final settings = ref.read(settingsProvider);
    final target =
        lyricsTranslationLanguageFor(language ?? '') ??
        _targetOf(source, settings);
    final key = _cacheKey(source, settings, language: target.code);
    if (key == null) {
      return const LyricsTranslationOutcome.failed(
        LyricsAiErrorKind.notConfigured,
      );
    }
    final id = ++_jobIds;
    final cancel = _cancel = LyricsTranslationCancelToken();
    _owner = owner;
    state = LyricsTranslationState(
      results: state.results,
      job: LyricsTranslationJob(
        id: id,
        sourceHash: source.hash,
        done: 0,
        total: source.texts.length,
      ),
    );
    // A track change abandons the job. The first id seen counts as the
    // track when the player had not reported one yet.
    final song = ref.read(currentMediaItemProvider).value;
    var mediaId = song?.id;
    final trackSub = ref.listen(
      currentMediaItemProvider.select((item) => item.value?.id),
      (previous, next) {
        if (mediaId == null) {
          mediaId = next;
        } else if (next != mediaId) {
          cancel.cancel();
        }
      },
    );
    http.Client? client;
    try {
      final cache = ref.read(lyricsTranslationCacheProvider);
      final cached = await cache.read(key);
      cancel.throwIfCancelled();
      // An explicit translation can upgrade older line-only cache entries.
      final romanize = lyricsAiRomanizes(settings, lyrics);
      final wordSync = settings.lyricsAiWordSync && source.wordSynced;
      final timedRomanize =
          wordSync &&
          romanize &&
          linesNeedingAiRomanization(
            lyrics,
            readerScripts: lyricsReaderScriptsFor(settings),
          ).any((line) => line.hasWordTiming);
      final reusable =
          cached != null &&
          (!romanize || cached.romanized) &&
          (!timedRomanize || cached.romanizationWordSynced) &&
          (!wordSync || cached.wordSynced);
      if (reusable && cached.missing == 0) {
        _finish(id, key, cached);
        _publish(source.hash, target.code, cached);
        return const LyricsTranslationOutcome.success();
      }
      final apiKey = await ref.read(
        lyricsAiKeyProvider(settings.lyricsAiProvider).future,
      );
      cancel.throwIfCancelled();
      if (!lyricsAiReady(settings, apiKey)) {
        throw const LyricsAiException(LyricsAiErrorKind.notConfigured);
      }
      client = ref.read(lyricsAiHttpClientProvider)();
      cancel.onCancel(client.close);
      final translator = LyricsTranslator(
        LyricsAiClient(
          lyricsAiConfigFor(settings, apiKey: apiKey),
          client: client,
        ),
      );
      final result = await translator.translate(
        source.texts,
        initialResult: reusable ? cached : null,
        sourceWords: wordSync ? source.words : const [],
        systemPrompt: lyricsTranslationSystemPrompt(
          languageName: target.englishName,
          languageCode: target.code,
          title: song?.title ?? '',
          artist: song?.artist ?? '',
          instruction: settings.lyricsAiInstruction,
          romanize: romanize,
          wordSync: wordSync,
        ),
        cancel: cancel,
        onProgress: (done, total) {
          final job = state.job;
          if (job?.id != id || !ref.mounted) return;
          state = LyricsTranslationState(
            results: state.results,
            job: LyricsTranslationJob(
              id: id,
              sourceHash: job!.sourceHash,
              done: done,
              total: total,
            ),
          );
        },
      );
      cancel.throwIfCancelled();
      await cache.write(key, result);
      cancel.throwIfCancelled();
      _finish(id, key, result);
      _publish(source.hash, target.code, result);
      return LyricsTranslationOutcome.success(
        missing: result.missing,
        unchanged: lyricsTranslationUnchanged(source, result.translations),
      );
    } on LyricsTranslationCancelled {
      _finish(id, null, null);
      return const LyricsTranslationOutcome.cancelled();
    } on LyricsAiException catch (error) {
      _finish(id, null, null);
      if (cancel.isCancelled) return const LyricsTranslationOutcome.cancelled();
      _log.w('Lyrics translation failed: $error');
      return LyricsTranslationOutcome.failed(error.kind);
    } finally {
      trackSub.close();
      client?.close();
      if (identical(_cancel, cancel)) {
        _cancel = null;
        _owner = null;
      }
    }
  }

  void _finish(int id, String? key, LyricsTranslationResult? result) {
    if (!ref.mounted) return;
    final current = state.job?.id == id ? null : state.job;
    state = LyricsTranslationState(
      results: key == null ? state.results : {...state.results, key: result!},
      job: current,
    );
  }

  /// Stops the running job. With [owner], only a job that owner started.
  void cancel({Object? owner}) {
    if (owner != null && !identical(owner, _owner)) return;
    final token = _cancel;
    if (token == null) return;
    token.cancel();
    if (ref.mounted && state.job != null) {
      state = LyricsTranslationState(results: state.results);
    }
  }

  /// Translates one line with [config] to check the key and model.
  Future<void> testConnection(LyricsAiConfig config) async {
    final client = ref.read(lyricsAiHttpClientProvider)();
    try {
      final target = lyricsTranslationTargetFor(ref.read(settingsProvider));
      final result =
          await LyricsAiClient(
            config,
            client: client,
            timeout: const Duration(seconds: 45),
          ).translate(
            const [LyricsAiItem(0, 'Hello, can you hear me singing?')],
            systemPrompt: lyricsTranslationSystemPrompt(
              languageName: target.englishName,
              languageCode: target.code,
            ),
          );
      if (result.isEmpty) {
        throw const LyricsAiException(LyricsAiErrorKind.badResponse);
      }
    } finally {
      client.close();
    }
  }

  Future<List<String>> listModels(LyricsAiConfig config) async {
    final client = ref.read(lyricsAiHttpClientProvider)();
    try {
      return await LyricsAiClient(
        config,
        client: client,
        timeout: const Duration(seconds: 30),
      ).listModels();
    } finally {
      client.close();
    }
  }

  Future<int> cachedCount() => ref.read(lyricsTranslationCacheProvider).count();

  Future<void> clearCache() async {
    await ref.read(lyricsTranslationCacheProvider).clear();
    _sharing.clear();
    _lookedUp.clear();
    _autoAttempted.clear();
    if (ref.mounted) state = LyricsTranslationState(job: state.job);
  }
}
