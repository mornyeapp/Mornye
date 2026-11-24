import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/lyrics_ai_client.dart';
import 'package:mornye/services/lyrics_language_guess.dart';
import 'package:mornye/services/lyrics_sidecar.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/services/lyrics_translation_languages.dart';
import 'package:mornye/services/playback_metadata.dart';
import 'package:mornye/services/player_lyrics_persistence.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/lyrics_draft.dart';
import 'package:mornye/utils/lyrics_parser.dart';

final _log = AppLogger('DownloadLyricsTranslation');

/// A finished download: where its file is and what plays in it.
typedef DownloadedSong = ({String source, String title, String artist});

final downloadLyricsTranslatorProvider = Provider<DownloadLyricsTranslator>(
  DownloadLyricsTranslator.new,
);

/// Translates the lyrics of finished downloads while Translate Downloads is
/// on, one song at a time, and saves them as Save Translation to File does:
/// into the song's lyrics or a `.mlrc` file next to it, so they show
/// offline. The translation lands in the translation cache at once, so the
/// player shows it before it is written. Song files are written once the
/// download queue is idle, because finishing an album rewrites its earlier
/// files (album ReplayGain). A song that fails is logged and skipped.
class DownloadLyricsTranslator {
  DownloadLyricsTranslator(
    this._ref, {
    Future<Map<String, dynamic>> Function(String source)? readMetadata,
    Future<ParsedLyrics> Function(String? raw)? parseLyrics,
    Future<void> Function(String source, String lyrics)? saveLyrics,
    LyricsSidecarStore? sidecar,
    SourceMetadataEvents? metadataEvents,
  }) : _readMetadata = readMetadata ?? readPlaybackFileMetadataWithRetry,
       _parseLyrics = parseLyrics ?? LyricsParser.parseAsyncNative,
       _saveLyrics = saveLyrics ?? persistPlayerLyrics,
       _sidecar = sidecar ?? const LyricsSidecarStore(),
       _metadataEvents = metadataEvents ?? SourceMetadataEvents.instance {
    // Built inside its provider, so the listener and the disposal follow it.
    _ref.listen(downloadQueueProvider.select((queue) => queue.isProcessing), (
      _,
      processing,
    ) {
      if (!processing) flushWrites();
    });
    _ref.onDispose(dispose);
  }

  final Ref _ref;
  final Future<Map<String, dynamic>> Function(String source) _readMetadata;
  final Future<ParsedLyrics> Function(String? raw) _parseLyrics;
  final Future<void> Function(String source, String lyrics) _saveLyrics;
  final LyricsSidecarStore _sidecar;
  final SourceMetadataEvents _metadataEvents;

  final _pending = Queue<DownloadedSong>();
  final _writes = Queue<DownloadLyricsWrite>();
  var _translating = false;
  var _writing = false;
  var _disposed = false;
  LyricsTranslationCancelToken? _cancel;

  /// Queues [song] when Translate Downloads is on. Network songs are left
  /// out: their files sit on a server.
  void enqueue(DownloadedSong song) {
    if (_disposed ||
        !_ref.read(settingsProvider).lyricsTranslateDownloads ||
        !_supported(song.source)) {
      return;
    }
    _pending.add(song);
    if (!_translating) unawaited(_translateAll());
  }

  static bool _supported(String source) {
    if (source.isEmpty || source.startsWith('network://')) return false;
    return !const {'http', 'https'}.contains(Uri.tryParse(source)?.scheme);
  }

  Future<void> _translateAll() async {
    _translating = true;
    try {
      while (_pending.isNotEmpty && !_disposed) {
        final song = _pending.removeFirst();
        try {
          final write = await translate(song);
          if (write != null) _writes.add(write);
        } catch (error) {
          _log.w('Could not translate ${song.source}: $error');
        }
        flushWrites();
      }
    } finally {
      _translating = false;
    }
  }

  /// Writes the translations waiting for an idle download queue.
  void flushWrites() {
    if (_writing || _disposed || _writes.isEmpty) return;
    if (_ref.read(downloadQueueProvider).isProcessing) return;
    unawaited(_writeAll());
  }

  Future<void> _writeAll() async {
    _writing = true;
    try {
      while (_writes.isNotEmpty && !_disposed) {
        // A queue that starts again holds the rest until it is idle.
        if (_ref.read(downloadQueueProvider).isProcessing) return;
        final write = _writes.removeFirst();
        try {
          await this.write(write);
        } catch (error) {
          _log.w('Could not save the translation of ${write.source}: $error');
        }
      }
    } finally {
      _writing = false;
    }
  }

  /// Translates [song]'s lyrics into the settings' language and returns what
  /// to write, or null when there is nothing to save: Translate Downloads is
  /// off, translation is not set up, the song has no lyrics, they already
  /// carry a translation, or they are in every chosen language.
  Future<DownloadLyricsWrite?> translate(DownloadedSong song) async {
    final settings = _ref.read(settingsProvider);
    if (!settings.lyricsTranslateDownloads) return null;
    final apiKey = await _ref.read(
      lyricsAiKeyProvider(settings.lyricsAiProvider).future,
    );
    if (!lyricsAiReady(settings, apiKey)) return null;
    final metadata = await _readMetadata(song.source);
    final raw = metadata['lyrics']?.toString() ?? '';
    if (raw.trim().isEmpty) return null;
    final lyrics = await _parseLyrics(raw);
    if (lyrics.isEmpty) return null;
    final saved = await _readSaved(song.source);
    if (lyricsHaveTranslation(mergeSavedLyrics(lyrics, saved))) return null;
    final source = LyricsTranslationSource.cached(lyrics);
    if (source.isEmpty) return null;
    final target = _targetOf(source, settings);
    if (target == null) return null;

    final romanize = lyricsAiRomanizes(settings, lyrics);
    final wordSync = settings.lyricsAiWordSync && source.wordSynced;
    final cache = _ref.read(lyricsTranslationCacheProvider);
    final key = lyricsTranslationCacheKey(
      sourceHash: source.hash,
      language: target.code,
      config: lyricsAiConfigFor(settings),
    );
    final cached = await cache.read(key);
    final reusable =
        cached != null &&
        (!romanize || cached.romanized) &&
        (!wordSync || cached.wordSynced);
    var result = reusable && cached.missing == 0 ? cached : null;
    if (result == null) {
      final client = _ref.read(lyricsAiHttpClientProvider)();
      final cancel = _cancel = LyricsTranslationCancelToken();
      cancel.onCancel(client.close);
      try {
        result =
            await LyricsTranslator(
              LyricsAiClient(
                lyricsAiConfigFor(settings, apiKey: apiKey),
                client: client,
              ),
            ).translate(
              source.texts,
              initialResult: reusable ? cached : null,
              sourceWords: wordSync ? source.words : const [],
              systemPrompt: lyricsTranslationSystemPrompt(
                languageName: target.englishName,
                languageCode: target.code,
                title: song.title,
                artist: song.artist,
                instruction: settings.lyricsAiInstruction,
                romanize: romanize,
                wordSync: wordSync,
              ),
              cancel: cancel,
            );
      } finally {
        client.close();
        if (identical(_cancel, cancel)) _cancel = null;
      }
      await cache.write(key, result);
    }
    final shown = applyLyricsTranslation(
      lyrics,
      source,
      result.translations,
      romanizations: result.romanizations,
      // A translation saved in Synced mode keeps its word timing.
      alignments: result.alignments,
      romanizationAlignments: result.romanizationAlignments,
    );
    if (!lyricsTranslationUnsaved(lyrics, shown)) return null;
    return DownloadLyricsWrite(
      source: song.source,
      raw: raw,
      synced: lyrics.synced,
      shown: shown,
      hasMlrc: saved != null,
    );
  }

  /// Saves [write] where the settings choose, as the player's Save
  /// Translation to File does. Returns false when neither the song's
  /// lyrics nor a `.mlrc` file can take it.
  Future<bool> write(DownloadLyricsWrite write) async {
    final settings = _ref.read(settingsProvider);
    final embedded = write.synced && LyricsDraft.canEdit(write.raw)
        ? lyricsWithTranslations(write.raw, write.shown)
        : null;
    final sidecarWritable = _sidecar.canWrite(write.source);
    final preferSidecar =
        settings.lyricsTranslationSaveTo == lyricsTranslationSaveToMlrc;
    if ((preferSidecar || embedded == null) && sidecarWritable) {
      await _sidecar.write(
        write.source,
        buildMlrc(raw: write.raw, shown: write.shown),
      );
    } else if (embedded != null) {
      await _saveLyrics(write.source, embedded);
      // An older .mlrc file would bring back what the song now replaces.
      if (write.hasMlrc && sidecarWritable) {
        await _sidecar.write(
          write.source,
          buildMlrc(raw: embedded, shown: write.shown),
        );
      }
    } else {
      return false;
    }
    await _metadataEvents.publish(write.source);
    return true;
  }

  Future<ParsedLyrics?> _readSaved(String source) async {
    try {
      final raw = await _sidecar.read(source);
      if (raw == null || raw.trim().isEmpty) return null;
      final saved = await readMlrc(raw, _parseLyrics);
      return saved.isEmpty ? null : saved;
    } catch (error) {
      _log.w('Could not read the .mlrc lyrics: $error');
      return null;
    }
  }

  /// The first language, or the second when the lyrics are already in the
  /// first, as in the player. Null when they are in the only one chosen.
  static LyricsTranslationLanguage? _targetOf(
    LyricsTranslationSource source,
    AppSettings settings,
  ) {
    final first = lyricsTranslationTargetFor(settings);
    if (!lyricsAlreadyIn(source.texts, first.code)) return first;
    final second = lyricsTranslationLanguageFor(
      settings.lyricsTranslationSecondLanguage,
    );
    if (second == null || second.code == first.code) return null;
    return lyricsAlreadyIn(source.texts, second.code) ? null : second;
  }

  void dispose() {
    _disposed = true;
    _pending.clear();
    _writes.clear();
    _cancel?.cancel();
  }
}

/// A translation waiting to be written next to or into its song.
class DownloadLyricsWrite {
  const DownloadLyricsWrite({
    required this.source,
    required this.raw,
    required this.synced,
    required this.shown,
    required this.hasMlrc,
  });

  final String source;

  /// The song's own lyrics, as read from its file.
  final String raw;
  final bool synced;

  /// The lyrics with the translation laid over them.
  final ParsedLyrics shown;

  final bool hasMlrc;
}
