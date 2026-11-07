import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_lyrics_translation_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/lyrics_sidecar.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/services/lyrics_translation_alignment.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _song = (
  source: '/Music/Example Artist - Example Song.flac',
  title: 'Example Song',
  artist: 'Example Artist',
);

const _lrc = '[00:00.00]Hello\n[00:01.00]World';

const _settings = AppSettings(
  lyricsAiProvider: 'openai',
  lyricsAiModel: 'gpt-4.1-mini',
  lyricsTranslationLanguage: 'es',
  lyricsTranslateDownloads: true,
);

class _Keys implements LyricsAiKeyStore {
  @override
  Future<String?> read(String provider) async => 'sk-test';

  @override
  Future<void> write(String provider, String key) async {}

  @override
  Future<void> delete(String provider) async {}
}

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() => const DownloadQueueState();

  void setProcessing(bool processing) =>
      state = state.copyWith(isProcessing: processing);
}

class _Sidecar extends LyricsSidecarStore {
  _Sidecar({this.existing});

  final String? existing;
  final writes = <String, String>{};

  @override
  bool canWrite(String source) => true;

  @override
  Future<String?> read(String source) async => existing;

  @override
  Future<void> write(String source, String content) async =>
      writes[source] = content;
}

/// A chat completion that puts "es:" before each text.
http.Response _reply(http.Request request) {
  final body = jsonDecode(request.body) as Map<String, dynamic>;
  final user = (body['messages'] as List).last as Map;
  final items = jsonDecode(user['content'] as String) as List;
  return http.Response.bytes(
    utf8.encode(
      jsonEncode({
        'choices': [
          {
            'message': {
              'content': jsonEncode({
                'lines': [
                  for (final item in items.cast<Map<String, dynamic>>())
                    {'id': item['id'], 'text': 'es:${item['text']}'},
                ],
              }),
            },
            'finish_reason': 'stop',
          },
        ],
      }),
    ),
    200,
  );
}

/// The tag a saved translation of the line at [ms] takes.
String _translation(int ms, String text) =>
    '[x-translation:$ms:${base64Encode(utf8.encode(text))}]';

/// Waits for work that includes real file IO.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late List<http.Request> requests;
  late Map<String, String> savedLyrics;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('download_translation');
    requests = [];
    savedLyrics = {};
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  ({
    ProviderContainer container,
    DownloadLyricsTranslator translator,
    _Queue queue,
  })
  setUpTranslator({
    AppSettings settings = _settings,
    String lyrics = _lrc,
    _Sidecar? sidecar,
  }) {
    final queue = _Queue();
    final translatorProvider = Provider<DownloadLyricsTranslator>(
      (ref) => DownloadLyricsTranslator(
        ref,
        readMetadata: (_) async => {'lyrics': lyrics},
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        saveLyrics: (source, value) async => savedLyrics[source] = value,
        sidecar: sidecar ?? _Sidecar(),
        metadataEvents: SourceMetadataEvents(),
      ),
    );
    final container = ProviderContainer(
      overrides: [
        initialSettingsProvider.overrideWithValue(settings),
        lyricsAiKeyStoreProvider.overrideWithValue(_Keys()),
        lyricsTranslationCacheProvider.overrideWithValue(
          LyricsTranslationCache(directory: () async => directory),
        ),
        lyricsAiHttpClientProvider.overrideWithValue(
          () => MockClient((request) async {
            requests.add(request);
            return _reply(request);
          }),
        ),
        downloadQueueProvider.overrideWith(() => queue),
      ],
    );
    addTearDown(container.dispose);
    container.read(downloadQueueProvider);
    return (
      container: container,
      translator: container.read(translatorProvider),
      queue: queue,
    );
  }

  test('saves the translation into the song\'s own lyrics', () async {
    final (:container, :translator, queue: _) = setUpTranslator();
    translator.enqueue(_song);
    await _until(() => savedLyrics.isNotEmpty);

    final saved = savedLyrics[_song.source]!;
    expect(saved, contains('Hello'));
    expect(saved, contains(_translation(0, 'es:Hello')));
    expect(saved, contains(_translation(1000, 'es:World')));
    expect(requests, hasLength(1));
    // The player reads the same translation from the cache.
    expect(await container.read(lyricsTranslationCacheProvider).count(), 1);
  });

  test('saves to a .mlrc file when the settings choose it', () async {
    final sidecar = _Sidecar();
    final (container: _, :translator, queue: _) = setUpTranslator(
      settings: _settings.copyWith(
        lyricsTranslationSaveTo: lyricsTranslationSaveToMlrc,
      ),
      sidecar: sidecar,
    );
    translator.enqueue(_song);
    await _until(() => sidecar.writes.isNotEmpty);

    final mlrc = sidecar.writes[_song.source]!;
    expect(mlrc, startsWith('[x-mlrc:1]'));
    expect(mlrc, contains(_translation(0, 'es:Hello')));
    expect(savedLyrics, isEmpty);
  });

  test('keeps the word timing of a saved translation in Fast mode', () async {
    const timed = '[00:00.00]<00:00.00>Hello <00:00.50>there<00:01.00>';
    final (:container, :translator, queue: _) = setUpTranslator(lyrics: timed);
    expect(_settings.lyricsAiWordSync, isFalse);
    await container
        .read(lyricsTranslationCacheProvider)
        .write(
          lyricsTranslationCacheKey(
            sourceHash: LyricsTranslationSource.of(
              LyricsParser.parse(timed),
            ).hash,
            language: 'es',
            config: lyricsAiConfigFor(_settings),
          ),
          const LyricsTranslationResult(
            ['Hola amigo'],
            alignments: [
              [
                LyricsTranslationChunk('Hola ', 0),
                LyricsTranslationChunk('amigo', 1),
              ],
            ],
          ),
        );
    translator.enqueue(_song);
    await _until(() => savedLyrics.isNotEmpty);

    final saved = savedLyrics[_song.source]!;
    expect(saved, contains(_translation(0, 'Hola amigo')));
    expect(saved, contains('[x-translation-words:0:'));
    expect(requests, isEmpty);
  });

  test('writes the song file only once the download queue is idle', () async {
    final (container: _, :translator, :queue) = setUpTranslator();
    queue.setProcessing(true);
    translator.enqueue(_song);
    await _until(() => requests.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(savedLyrics, isEmpty, reason: 'The queue is still downloading');

    queue.setProcessing(false);
    await _until(() => savedLyrics.isNotEmpty);
    expect(savedLyrics[_song.source], contains(_translation(1000, 'es:World')));
  });

  test('does nothing while Translate Downloads is off', () async {
    final (container: _, :translator, queue: _) = setUpTranslator(
      settings: _settings.copyWith(lyricsTranslateDownloads: false),
    );
    translator.enqueue(_song);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(requests, isEmpty);
    expect(savedLyrics, isEmpty);
  });

  test('leaves lyrics that already carry a translation', () async {
    final (container: _, :translator, queue: _) = setUpTranslator(
      sidecar: _Sidecar(
        existing: '[x-mlrc:1]\n$_lrc\n${_translation(0, 'Hola')}',
      ),
    );
    expect(await translator.translate(_song), isNull);
    expect(requests, isEmpty);
  });

  test('leaves network songs out', () async {
    final (container: _, :translator, queue: _) = setUpTranslator();
    translator.enqueue((
      source: 'network://nas/Music/song.flac',
      title: 'Song',
      artist: 'Artist',
    ));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(requests, isEmpty);
  });
}
