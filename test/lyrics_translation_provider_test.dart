import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/lyrics_ai_client.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MemoryLyricsAiKeyStore implements LyricsAiKeyStore {
  MemoryLyricsAiKeyStore([Map<String, String>? keys]) : keys = keys ?? {};

  final Map<String, String> keys;

  @override
  Future<String?> read(String provider) async => keys[provider];

  @override
  Future<void> write(String provider, String key) async => keys[provider] = key;

  @override
  Future<void> delete(String provider) async => keys.remove(provider);
}

class _MediaItems extends CurrentMediaItemNotifier {
  _MediaItems(this._items);

  final Stream<MediaItem?> _items;

  @override
  Stream<MediaItem?> build() => _items;
}

const _settings = AppSettings(
  lyricsAiProvider: 'openai',
  lyricsAiModel: 'gpt-4.1-mini',
  lyricsTranslationLanguage: 'es',
);

final _lyrics = ParsedLyrics(
  synced: true,
  wordSynced: false,
  lines: const [
    LyricLine(time: Duration.zero, text: 'Hello'),
    LyricLine(time: Duration(seconds: 1), text: 'World'),
    LyricLine(time: Duration(seconds: 2), text: 'Hello'),
  ],
  plainText: 'Hello\nWorld\nHello',
);

/// A chat completion that puts "es:" before each text.
http.Response _reply(http.Request request) {
  final body = jsonDecode(request.body) as Map<String, dynamic>;
  final user = (body['messages'] as List).last as Map;
  final items = jsonDecode(user['content'] as String) as List;
  return http.Response(
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
    200,
  );
}

/// Waits for work that includes real file IO.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late StreamController<MediaItem?> mediaItems;
  late List<http.Request> requests;
  late Completer<void> gate;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('lyrics_translation');
    mediaItems = StreamController<MediaItem?>.broadcast();
    requests = [];
    gate = Completer<void>()..complete();
  });

  tearDown(() async {
    await mediaItems.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<ProviderContainer> containerFor({
    AppSettings settings = _settings,
    Map<String, String>? keys,
  }) async {
    final container = ProviderContainer(
      overrides: [
        initialSettingsProvider.overrideWithValue(settings),
        lyricsAiKeyStoreProvider.overrideWithValue(
          MemoryLyricsAiKeyStore(keys ?? {'openai': 'sk-test'}),
        ),
        lyricsTranslationCacheProvider.overrideWithValue(
          LyricsTranslationCache(directory: () async => directory),
        ),
        lyricsAiHttpClientProvider.overrideWithValue(
          () => MockClient((request) async {
            requests.add(request);
            await gate.future;
            return _reply(request);
          }),
        ),
        currentMediaItemProvider.overrideWith(
          () => _MediaItems(mediaItems.stream),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(currentMediaItemProvider, (_, _) {});
    mediaItems.add(const MediaItem(id: 'song-a', title: 'A'));
    await Future<void>.delayed(Duration.zero);
    return container;
  }

  test('translates once, shows it and persists it apart', () async {
    final container = await containerFor();
    final controller = container.read(lyricsTranslationProvider.notifier);

    final first = controller.translate(_lyrics);
    // The busy state is set synchronously, so a double tap is ignored.
    expect(container.read(lyricsTranslationProvider).job, isNotNull);
    final second = await controller.translate(_lyrics);
    expect(second.busy, isTrue);

    final outcome = await first;
    expect(outcome.error, isNull);
    expect(outcome.missing, 0);
    expect(requests, hasLength(1));
    final messages =
        (jsonDecode(requests.single.body) as Map)['messages'] as List;
    final sent = jsonDecode((messages.last as Map)['content'] as String);
    expect(sent, [
      {'id': 0, 'text': 'Hello'},
      {'id': 1, 'text': 'World'},
    ]);
    expect(container.read(lyricsTranslationProvider).job, isNull);

    final shown = controller.display(_lyrics);
    expect(shown.lines.map((line) => line.translation), [
      'es:Hello',
      'es:World',
      'es:Hello',
    ]);
    expect(_lyrics.lines.first.translation, isNull);
    expect(identical(controller.display(_lyrics), shown), isTrue);

    // A new session reads the translation from disk without a request.
    final restarted = await containerFor();
    final later = restarted.read(lyricsTranslationProvider.notifier);
    expect(later.display(_lyrics).lines.first.translation, isNull);
    await _until(
      () => restarted.read(lyricsTranslationProvider).results.isNotEmpty,
    );
    expect(later.display(_lyrics).lines.first.translation, 'es:Hello');
    expect(requests, hasLength(1));

    // Another target language is another translation.
    restarted
        .read(settingsProvider.notifier)
        .setLyricsTranslationLanguage('ja');
    expect(later.display(_lyrics).lines.first.translation, isNull);
  });

  test('cancelling and changing tracks stop the job', () async {
    final container = await containerFor();
    final controller = container.read(lyricsTranslationProvider.notifier);
    gate = Completer<void>();
    final owner = Object();

    var pending = controller.translate(_lyrics, owner: owner);
    await pumpEventQueue();
    controller.cancel(owner: Object());
    expect(container.read(lyricsTranslationProvider).job, isNotNull);
    controller.cancel(owner: owner);
    expect(container.read(lyricsTranslationProvider).job, isNull);
    expect((await pending).cancelled, isTrue);

    pending = controller.translate(_lyrics);
    await pumpEventQueue();
    mediaItems.add(const MediaItem(id: 'song-b', title: 'B'));
    await pumpEventQueue();
    expect((await pending).cancelled, isTrue);
    expect(container.read(lyricsTranslationProvider).job, isNull);
    gate.complete();
    expect(controller.display(_lyrics).lines.first.translation, isNull);
    expect(await controller.cachedCount(), 0);
  });

  test('reports a missing setup without sending anything', () async {
    final container = await containerFor(keys: {});
    final outcome = await container
        .read(lyricsTranslationProvider.notifier)
        .translate(_lyrics);
    expect(outcome.error, LyricsAiErrorKind.notConfigured);
    expect(requests, isEmpty);

    final empty = await container
        .read(lyricsTranslationProvider.notifier)
        .translate(
          const ParsedLyrics(
            synced: true,
            wordSynced: false,
            lines: [LyricLine(time: Duration.zero, text: '♪')],
            plainText: '♪',
          ),
        );
    expect(empty.error, LyricsAiErrorKind.noLyrics);
  });

  test('translates automatically only when enabled', () async {
    final off = await containerFor();
    off.read(lyricsTranslationProvider.notifier).display(_lyrics);
    await pumpEventQueue();
    expect(requests, isEmpty);

    final on = await containerFor(
      settings: _settings.copyWith(lyricsAutoTranslate: true),
    );
    final controller = on.read(lyricsTranslationProvider.notifier);
    controller.display(_lyrics);
    await _until(() => on.read(lyricsTranslationProvider).results.isNotEmpty);
    expect(requests, hasLength(1));
    expect(controller.display(_lyrics).lines[1].translation, 'es:World');

    // Lyrics with their own translation are left alone.
    final translated = ParsedLyrics(
      synced: true,
      wordSynced: false,
      lines: const [
        LyricLine(time: Duration.zero, text: 'Other', translation: 'Otra'),
      ],
      plainText: 'Other',
    );
    controller.display(translated);
    await pumpEventQueue();
    expect(requests, hasLength(1));
  });

  test('the target follows the app language by default', () {
    expect(
      lyricsTranslationTargetFor(const AppSettings(locale: 'pt_PT')).code,
      'pt-PT',
    );
    expect(
      lyricsTranslationTargetFor(const AppSettings(locale: 'zh_TW')).code,
      'zh-Hant',
    );
    expect(
      lyricsTranslationTargetFor(
        const AppSettings(locale: 'id', lyricsTranslationLanguage: 'ko'),
      ).code,
      'ko',
    );
    expect(lyricsAiModelFor(const AppSettings()), isNotEmpty);
    expect(
      lyricsAiReady(const AppSettings(lyricsAiProvider: 'custom'), ''),
      isFalse,
    );
    expect(
      lyricsAiReady(
        const AppSettings(
          lyricsAiProvider: 'custom',
          lyricsAiModel: 'llama',
          lyricsAiBaseUrl: 'http://localhost:11434/v1',
        ),
        '',
      ),
      isTrue,
    );
  });
}
