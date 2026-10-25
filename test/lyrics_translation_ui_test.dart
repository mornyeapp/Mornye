import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/lyrics_ai_translation_page.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/lyrics_options_button.dart';
import 'package:mornye/widgets/player_lyrics_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lyrics_translation_provider_test.dart' show MemoryLyricsAiKeyStore;

class _Lyrics extends PlayerMetadataController {
  _Lyrics(this._value);

  final ParsedLyrics _value;

  @override
  ParsedLyrics get lyrics => _value;

  @override
  bool get loading => false;
}

class _MemoryCache extends LyricsTranslationCache {
  final entries = <String, List<String?>>{};

  @override
  Future<List<String?>?> read(String key) async => entries[key];

  @override
  Future<void> write(String key, List<String?> translations) async =>
      entries[key] = translations;

  @override
  Future<int> count() async => entries.length;

  @override
  Future<void> clear() async => entries.clear();
}

class _MediaItems extends CurrentMediaItemNotifier {
  @override
  Stream<MediaItem?> build() =>
      Stream.value(const MediaItem(id: 'song', title: 'Song'));
}

final _lyrics = ParsedLyrics(
  synced: true,
  wordSynced: false,
  lines: const [
    LyricLine(
      time: Duration.zero,
      end: Duration(seconds: 3),
      text: 'Hello there',
    ),
    LyricLine(
      time: Duration(seconds: 3),
      end: Duration(seconds: 6),
      text: 'Second line',
    ),
  ],
  plainText: 'Hello there\nSecond line',
);

http.Response _translated(http.Request request, String prefix) {
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
                  {'id': item['id'], 'text': '$prefix${item['text']}'},
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

Widget _app({
  required bool mornye,
  required List<Override> overrides,
  required Widget home,
}) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    theme: mornye
        ? MornyeTheme.build(Brightness.dark, accent: MornyeAccent.blue)
        : AppTheme.dark(),
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final mornye in [false, true]) {
    testWidgets('the lyrics menu translates into a chosen language ($mornye)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final playback = StreamController<PlaybackState>.broadcast();
      addTearDown(playback.close);
      final metadata = _Lyrics(_lyrics);
      final preview = PlaybackSeekPreview();
      addTearDown(metadata.dispose);
      addTearDown(preview.dispose);
      final requests = <http.Request>[];
      await tester.pumpWidget(
        _app(
          mornye: mornye,
          overrides: [
            initialSettingsProvider.overrideWithValue(
              const AppSettings(
                lyricsAiModel: 'gpt-4.1-mini',
                lyricsTranslationLanguage: 'en',
              ),
            ),
            playbackStateProvider.overrideWith((ref) => playback.stream),
            musicPlayerControllerProvider.overrideWith(
              (ref) => throw StateError('Unexpected audio access'),
            ),
            currentMediaItemProvider.overrideWith(_MediaItems.new),
            lyricsAiKeyStoreProvider.overrideWithValue(
              MemoryLyricsAiKeyStore({'openai': 'sk-test-1234'}),
            ),
            lyricsTranslationCacheProvider.overrideWithValue(_MemoryCache()),
            lyricsAiHttpClientProvider.overrideWithValue(
              () => MockClient((request) async {
                requests.add(request);
                return _translated(request, 'de:');
              }),
            ),
          ],
          home: Scaffold(
            body: PlayerLyricsSection(
              metadata: metadata,
              seekPreview: preview,
              colorScheme: const ColorScheme.dark(),
              isActive: true,
              options: LyricsOptionsButton(
                metadata: metadata,
                colorScheme: const ColorScheme.dark(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final options = find.byKey(const ValueKey('lyrics-language-options'));
      expect(options, findsOneWidget);
      await tester.tap(options);
      await tester.pumpAndSettle();
      // Nothing to show or hide yet, only the translation itself.
      expect(find.text('Show Translation'), findsNothing);
      expect(find.text('Hide Translation'), findsNothing);
      await tester.tap(find.text('Translate Lyrics'));
      await tester.pumpAndSettle();

      expect(find.text('Translate Into'), findsOneWidget);
      expect(find.text('The lyrics are sent to OpenAI.'), findsOneWidget);
      final german = find.byKey(const ValueKey('lyrics-language-de'));
      await tester.scrollUntilVisible(
        german,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(german);
      await tester.pumpAndSettle();

      expect(requests, hasLength(1));
      expect(
        find.textContaining('de:Hello there', findRichText: true),
        findsWidgets,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayerLyricsSection)),
      );
      expect(container.read(settingsProvider).lyricsTranslationLanguage, 'de');

      // The existing toggle now offers the original lyrics only.
      await tester.tap(options);
      await tester.pumpAndSettle();
      expect(find.text('Hide Translation'), findsOneWidget);
      await tester.tap(find.text('Hide Translation'));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).playerShowTranslation, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('the menu stays hidden until a provider is set up', (
    tester,
  ) async {
    final playback = StreamController<PlaybackState>.broadcast();
    addTearDown(playback.close);
    final metadata = _Lyrics(_lyrics);
    final preview = PlaybackSeekPreview();
    addTearDown(metadata.dispose);
    addTearDown(preview.dispose);
    await tester.pumpWidget(
      _app(
        mornye: false,
        overrides: [
          playbackStateProvider.overrideWith((ref) => playback.stream),
          musicPlayerControllerProvider.overrideWith(
            (ref) => throw StateError('Unexpected audio access'),
          ),
          lyricsAiKeyStoreProvider.overrideWithValue(MemoryLyricsAiKeyStore()),
          lyricsTranslationCacheProvider.overrideWithValue(_MemoryCache()),
        ],
        home: Scaffold(
          body: PlayerLyricsSection(
            metadata: metadata,
            seekPreview: preview,
            colorScheme: const ColorScheme.dark(),
            isActive: true,
            options: LyricsOptionsButton(
              metadata: metadata,
              colorScheme: const ColorScheme.dark(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lyrics-language-options')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final mornye in [false, true]) {
    testWidgets('settings save the key and test the connection ($mornye)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final keys = MemoryLyricsAiKeyStore();
      var status = 200;
      await tester.pumpWidget(
        _app(
          mornye: mornye,
          overrides: [
            initialSettingsProvider.overrideWithValue(const AppSettings()),
            lyricsAiKeyStoreProvider.overrideWithValue(keys),
            lyricsTranslationCacheProvider.overrideWithValue(_MemoryCache()),
            lyricsAiHttpClientProvider.overrideWithValue(
              () => MockClient(
                (request) async => status == 200
                    ? _translated(request, 'x:')
                    : http.Response('{"error":{}}', status),
              ),
            ),
          ],
          home: const LyricsAiTranslationPage(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('sent to the provider'), findsOneWidget);
      expect(find.text('OpenAI'), findsOneWidget);
      expect(find.text('Default (gpt-6-luna)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('lyrics-ai-api-key')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), ' sk-abcdef5678 ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(keys.keys['openai'], 'sk-abcdef5678');
      expect(find.text('Saved, ends in 5678'), findsOneWidget);
      // The key never reaches the settings JSON.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(LyricsAiTranslationPage)),
      );
      expect(
        jsonEncode(container.read(settingsProvider).toJson()),
        isNot(contains('abcdef')),
      );

      await tester.tap(find.byKey(const ValueKey('lyrics-ai-test')));
      await tester.pumpAndSettle();
      expect(find.text('The connection works'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      status = 401;
      await tester.tap(find.byKey(const ValueKey('lyrics-ai-test')));
      await tester.pumpAndSettle();
      expect(
        find.text('The provider did not accept the API key'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
