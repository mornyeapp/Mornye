import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
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
import 'package:mornye/services/lyrics_ai_client.dart';
import 'package:mornye/services/lyrics_sidecar.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/services/lyrics_translation_sharing.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/lyrics_options_button.dart';
import 'package:mornye/widgets/lyrics_options_activity.dart';
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
  final entries = <String, LyricsTranslationResult>{};

  @override
  Future<LyricsTranslationResult?> read(String key) async => entries[key];

  @override
  Future<void> write(String key, LyricsTranslationResult result) async =>
      entries[key] = result;

  @override
  Future<int> count() async => entries.length;

  @override
  Future<void> clear() async => entries.clear();
}

class _Events extends SourceMetadataEvents {
  final published = <String>[];

  @override
  Future<void> publish(String source) async => published.add(source);
}

class _MemorySidecar extends LyricsSidecarStore {
  final files = <String, String>{};

  @override
  bool canWrite(String source) => true;

  @override
  Future<String?> read(String source) async => files[source];

  @override
  Future<void> write(String source, String content) async =>
      files[source] = content;
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
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var parsedReplies = 0;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    parsedReplies = 0;
    // Widget tests fake the worker boundary. Real native parser parity is
    // covered separately, without spawning an isolate under the fake clock.
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'runNativeDataJob') throw MissingPluginException();
      final arguments = call.arguments as Map;
      final request = jsonDecode(arguments['request_json'] as String) as Map;
      expect(request['operation'], 'parse_lyrics_translation_reply');
      final reply = utf8.decode(arguments['bytes'] as Uint8List);
      final ids = (request['ids'] as List).cast<int>().toSet();
      final parsed = parseLyricsTranslationReply(reply, ids);
      parsedReplies++;
      return jsonEncode({
        'lines': [
          for (final entry in parsed.entries)
            {
              'id': entry.key,
              'text': entry.value.text,
              'romanization': entry.value.romanization,
              'alignment': [
                for (final chunk in entry.value.alignment) chunk.toJson(),
              ],
              'romanizationAlignment': [
                for (final chunk in entry.value.romanizationAlignment)
                  chunk.toJson(),
              ],
            },
        ],
      });
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final desktop in [false, true]) {
    for (final mornye in [false, true]) {
      testWidgets('translation mode applies on tap '
          '(desktop=$desktop, mornye=$mornye)', (tester) async {
        debugDesktopPlatformOverride = desktop;
        addTearDown(() => debugDesktopPlatformOverride = null);
        tester.view.physicalSize = Size(desktop ? 1200 : 390, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _app(
            mornye: mornye,
            overrides: [
              initialSettingsProvider.overrideWithValue(const AppSettings()),
              lyricsAiKeyStoreProvider.overrideWithValue(
                MemoryLyricsAiKeyStore(),
              ),
              lyricsTranslationCacheProvider.overrideWithValue(_MemoryCache()),
            ],
            home: const LyricsAiTranslationPage(),
          ),
        );
        await tester.pumpAndSettle();
        final mode = find.byKey(const ValueKey('lyrics-ai-mode'));
        await tester.scrollUntilVisible(mode, 250);
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byType(LyricsAiTranslationPage)),
        );
        expect(container.read(settingsProvider).lyricsAiWordSync, isFalse);
        await tester.tap(mode);
        await tester.pumpAndSettle();
        expect(find.textContaining('Takes longer'), findsOneWidget);
        await tester.tap(find.text('Synced'));
        await tester.pumpAndSettle();
        expect(container.read(settingsProvider).lyricsAiWordSync, isTrue);
        expect(
          find.descendant(of: mode, matching: find.text('Synced')),
          findsOneWidget,
        );
        await tester.tap(mode);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fast'));
        await tester.pumpAndSettle();
        expect(container.read(settingsProvider).lyricsAiWordSync, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final mornye in [false, true]) {
    testWidgets('lyrics options honor accessible navigation opt-in ($mornye)', (
      tester,
    ) async {
      final metadata = _Lyrics(_lyrics);
      addTearDown(metadata.dispose);
      await tester.pumpWidget(
        _app(
          mornye: mornye,
          overrides: [
            initialSettingsProvider.overrideWithValue(
              const AppSettings(lyricsAiModel: 'gpt-4.1-mini'),
            ),
            lyricsAiKeyStoreProvider.overrideWithValue(
              MemoryLyricsAiKeyStore({'openai': 'sk-test-1234'}),
            ),
            lyricsTranslationCacheProvider.overrideWithValue(_MemoryCache()),
          ],
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(accessibleNavigation: true),
              child: LyricsOptionsActivity(
                child: Scaffold(
                  body: Center(
                    child: LyricsOptionsButton(
                      metadata: metadata,
                      colorScheme: const ColorScheme.dark(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final options = find.byKey(const ValueKey('lyrics-language-options'));
      await tester.pump(const Duration(seconds: 6));
      expect(options.hitTestable(), findsOneWidget);
      final settings = ProviderScope.containerOf(
        tester.element(find.byType(LyricsOptionsButton)),
      ).read(settingsProvider.notifier);
      settings.setAutoHideLyricsControls(true);
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(options.hitTestable(), findsNothing);
      settings.setAutoHideLyricsControls(false);
      await tester.pumpAndSettle();
      expect(options.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lyrics options sit at the end and fade with fullscreen lyrics '
        'off ($mornye)', (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final metadata = _Lyrics(_lyrics);
      final preview = PlaybackSeekPreview();
      addTearDown(metadata.dispose);
      addTearDown(preview.dispose);
      await tester.pumpWidget(
        _app(
          mornye: mornye,
          overrides: [
            initialSettingsProvider.overrideWithValue(
              const AppSettings(
                lyricsAiModel: 'gpt-4.1-mini',
                autoHideLyricsControls: false,
              ),
            ),
            playbackStateProvider.overrideWith(
              (ref) => const Stream<PlaybackState>.empty(),
            ),
            musicPlayerControllerProvider.overrideWith(
              (ref) => throw StateError('Unexpected audio access'),
            ),
            currentMediaItemProvider.overrideWith(_MediaItems.new),
            lyricsAiKeyStoreProvider.overrideWithValue(
              MemoryLyricsAiKeyStore({'openai': 'sk-test-1234'}),
            ),
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
      final options = find.byKey(const ValueKey('lyrics-language-options'));
      final pane = tester.getRect(find.byType(PlayerLyricsSection));
      expect(tester.getCenter(options).dx, greaterThan(pane.center.dx));
      expect(options.hitTestable(), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(options.hitTestable(), findsNothing);
      await tester.tapAt(Offset(pane.left + 4, pane.top + 8));
      await tester.pumpAndSettle();
      expect(options.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final desktop in [false, true]) {
      testWidgets('lyrics options fade and reveal without interrupting a menu '
          '(desktop=$desktop, mornye=$mornye)', (tester) async {
        debugDesktopPlatformOverride = desktop;
        addTearDown(() => debugDesktopPlatformOverride = null);
        tester.view.physicalSize = Size(desktop ? 1200 : 420, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final metadata = _Lyrics(_lyrics);
        final preview = PlaybackSeekPreview();
        addTearDown(metadata.dispose);
        addTearDown(preview.dispose);
        await tester.pumpWidget(
          _app(
            mornye: mornye,
            overrides: [
              initialSettingsProvider.overrideWithValue(
                const AppSettings(lyricsAiModel: 'gpt-4.1-mini'),
              ),
              playbackStateProvider.overrideWith(
                (ref) => const Stream<PlaybackState>.empty(),
              ),
              musicPlayerControllerProvider.overrideWith(
                (ref) => throw StateError('Unexpected audio access'),
              ),
              currentMediaItemProvider.overrideWith(_MediaItems.new),
              lyricsAiKeyStoreProvider.overrideWithValue(
                MemoryLyricsAiKeyStore({'openai': 'sk-test-1234'}),
              ),
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
        final options = find.byKey(const ValueKey('lyrics-language-options'));
        final pane = tester.getRect(find.byType(PlayerLyricsSection));
        final blank = Offset(pane.right - 4, pane.top + 8);
        expect(options.hitTestable(), findsOneWidget);
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
        expect(options.hitTestable(), findsNothing);

        final touch = await tester.startGesture(blank);
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
        expect(options.hitTestable(), findsOneWidget);
        await touch.up();
        await tester.pumpAndSettle();
        await tester.tap(options);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 6));
        expect(find.text('Other Language…').hitTestable(), findsOneWidget);
        await tester.tapAt(blank);
        await tester.pumpAndSettle();
        expect(find.text('Other Language…'), findsNothing);
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
        expect(options.hitTestable(), findsNothing);
        await tester.tapAt(blank);
        await tester.pumpAndSettle();
        expect(options.hitTestable(), findsOneWidget);
        if (desktop) {
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: blank);
          await tester.pumpAndSettle();
          await mouse.moveTo(tester.getCenter(options));
          await tester.pumpAndSettle();
          await tester.pump(const Duration(seconds: 6));
          expect(options.hitTestable(), findsOneWidget);
          await mouse.moveTo(blank);
          await tester.pumpAndSettle();
          await tester.pump(const Duration(seconds: 6));
          await tester.pumpAndSettle();
          expect(options.hitTestable(), findsNothing);
          await mouse.moveTo(blank + const Offset(0, 2));
          await tester.pumpAndSettle();
          expect(options.hitTestable(), findsOneWidget);
          await mouse.removePointer();
        }
        final focus = Focus.of(tester.element(options));
        focus.requestFocus();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 6));
        expect(options.hitTestable(), findsOneWidget);
        focus.unfocus();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
        expect(options.hitTestable(), findsNothing);

        final container = ProviderScope.containerOf(
          tester.element(find.byType(PlayerLyricsSection)),
        );
        container
            .read(settingsProvider.notifier)
            .setAutoHideLyricsControls(false);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 6));
        // The switch is about the player's controls; this button still fades.
        expect(options.hitTestable(), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('linked AI translation refreshes open lyrics ($mornye)', (
      tester,
    ) async {
      final metadata = _Lyrics(_lyrics);
      final preview = PlaybackSeekPreview();
      addTearDown(metadata.dispose);
      addTearDown(preview.dispose);
      await tester.pumpWidget(
        _app(
          mornye: mornye,
          overrides: [
            initialSettingsProvider.overrideWithValue(
              const AppSettings(lyricsAiProvider: 'custom', lyricsAiModel: ''),
            ),
            lyricsTranslationCacheProvider.overrideWithValue(_MemoryCache()),
          ],
          home: Scaffold(
            body: PlayerLyricsSection(
              metadata: metadata,
              seekPreview: preview,
              colorScheme: const ColorScheme.dark(),
              isActive: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayerLyricsSection)),
      );
      container
          .read(lyricsTranslationSharingProvider)
          .receive(
            SharedLyricsTranslation(
              sourceHash: LyricsTranslationSource.of(_lyrics).hash,
              language: 'id',
              updatedMs: 1,
              result: const LyricsTranslationResult([
                'Halo di sana',
                'Dunia yang indah',
              ]),
            ),
          );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Halo di sana', findRichText: true),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final pick in [false, true]) {
      testWidgets('the lyrics menu translates into '
          '${pick ? 'a picked' : 'the settings'} language ($mornye)', (
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
                AppSettings(
                  lyricsAiModel: 'gpt-4.1-mini',
                  lyricsTranslationLanguage: pick ? 'en' : 'de',
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
        expect(find.text('Other Language…'), findsOneWidget);
        if (pick) {
          await tester.tap(find.text('Other Language…'));
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
        } else {
          // The language from settings needs no sheet.
          await tester.tap(find.text('Translate to Deutsch'));
        }
        await tester.pumpAndSettle();
        expect(find.text('Translate Into'), findsNothing);

        expect(requests, hasLength(1));
        expect(parsedReplies, 1);
        expect(
          find.textContaining('de:Hello there', findRichText: true),
          findsWidgets,
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(PlayerLyricsSection)),
        );
        // A language picked here stays with the song.
        expect(
          container.read(settingsProvider).lyricsTranslationLanguage,
          pick ? 'en' : 'de',
        );

        // The existing toggle now offers the original lyrics only, and the
        // lyrics are not offered for the language they are shown in.
        await tester.tap(options);
        await tester.pumpAndSettle();
        expect(find.text('Translate to Deutsch'), findsNothing);
        expect(find.text('Translate Into…'), findsOneWidget);
        expect(find.text('Hide Translation'), findsOneWidget);
        await tester.tap(find.text('Hide Translation'));
        await tester.pumpAndSettle();
        expect(container.read(settingsProvider).playerShowTranslation, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final mornye in [false, true]) {
    testWidgets('the lyrics menu saves the translation to the file ($mornye)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final playback = StreamController<PlaybackState>.broadcast();
      addTearDown(playback.close);
      final saved = <(String, String)>[];
      final events = _Events();
      final metadata = PlayerMetadataController(
        readMetadata: (path) async => {
          'lyrics': '[00:00.00]Hello there\n[00:03.00]Second line',
        },
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        saveOnlineLyrics: (source, raw) async => saved.add((source, raw)),
        metadataEvents: events,
      );
      final preview = PlaybackSeekPreview();
      addTearDown(metadata.dispose);
      addTearDown(preview.dispose);
      await metadata.load(
        const MediaItem(
          id: '/music/Album/song.flac',
          title: 'Song',
          artist: 'Artist',
          extras: {'source': '/music/Album/song.flac'},
        ),
      );
      await tester.pumpWidget(
        _app(
          mornye: mornye,
          overrides: [
            initialSettingsProvider.overrideWithValue(
              const AppSettings(
                lyricsAiModel: 'gpt-4.1-mini',
                lyricsTranslationLanguage: 'de',
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
              () => MockClient((request) async => _translated(request, 'de:')),
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
      await tester.tap(options);
      await tester.pumpAndSettle();
      // Nothing is translated yet, so nothing can be saved.
      expect(find.text('Save Translation to File'), findsNothing);
      await tester.tap(find.text('Translate to Deutsch'));
      await tester.pumpAndSettle();

      await tester.tap(options);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Translation to File'));
      await tester.pumpAndSettle();

      String tag(int ms, String text) => '[x-translated:$ms:$text]';
      expect(saved, [
        (
          '/music/Album/song.flac',
          '[00:00.00]Hello there\n'
              '${tag(0, 'de:Hello there')}\n'
              '[00:03.00]Second line\n'
              '${tag(3000, 'de:Second line')}',
        ),
      ]);
      expect(find.text("Translation saved to the song's file"), findsOneWidget);
      expect(events.published, ['/music/Album/song.flac']);
      expect(metadata.lyrics.lines.map((line) => line.translation), [
        'de:Hello there',
        'de:Second line',
      ]);

      // The file holds the translation now, so the action goes.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await tester.tap(options);
      await tester.pumpAndSettle();
      expect(find.text('Hide Translation'), findsOneWidget);
      expect(find.text('Save Translation to File'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  String tag(int key, String text) => '[x-translated:$key:$text]';

  Future<
    ({
      PlayerMetadataController metadata,
      _MemorySidecar sidecar,
      Finder options,
    })
  >
  pumpSavedLyrics(
    WidgetTester tester, {
    required bool mornye,
    required String lyrics,
    required AppSettings settings,
    required List<String> saved,
  }) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final playback = StreamController<PlaybackState>.broadcast();
    addTearDown(playback.close);
    final sidecar = _MemorySidecar();
    final metadata = PlayerMetadataController(
      readMetadata: (path) async => {'lyrics': lyrics},
      parseLyrics: (raw) async => LyricsParser.parse(raw),
      saveOnlineLyrics: (source, raw) async => saved.add(raw),
      metadataEvents: _Events(),
      sidecar: sidecar,
    );
    final preview = PlaybackSeekPreview();
    addTearDown(metadata.dispose);
    addTearDown(preview.dispose);
    await metadata.load(
      const MediaItem(
        id: '/music/Album/song.flac',
        title: 'Song',
        artist: 'Artist',
        extras: {'source': '/music/Album/song.flac'},
      ),
    );
    await tester.pumpWidget(
      _app(
        mornye: mornye,
        overrides: [
          initialSettingsProvider.overrideWithValue(settings),
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
            () => MockClient((request) async => _translated(request, 'de:')),
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
    return (
      metadata: metadata,
      sidecar: sidecar,
      options: find.byKey(const ValueKey('lyrics-language-options')),
    );
  }

  for (final mornye in [false, true]) {
    testWidgets('plain lyrics translate and save to a .mlrc file ($mornye)', (
      tester,
    ) async {
      final saved = <String>[];
      final (:metadata, :sidecar, :options) = await pumpSavedLyrics(
        tester,
        mornye: mornye,
        lyrics: 'Hello there\nSecond line',
        settings: const AppSettings(
          lyricsAiModel: 'gpt-4.1-mini',
          lyricsTranslationLanguage: 'de',
          // Plain lyrics translate when asked, never by themselves.
          lyricsAutoTranslate: true,
        ),
        saved: saved,
      );
      expect(find.text('Hello there\nSecond line'), findsOneWidget);

      await tester.tap(options);
      await tester.pumpAndSettle();
      expect(find.text('Save Translation to File'), findsNothing);
      await tester.tap(find.text('Translate to Deutsch'));
      await tester.pumpAndSettle();
      expect(find.text('Hello there'), findsOneWidget);
      expect(find.text('de:Hello there'), findsOneWidget);
      expect(find.text('de:Second line'), findsOneWidget);

      await tester.tap(options);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Translation to File'));
      await tester.pumpAndSettle();
      expect(find.text('Translation saved to a .mlrc file'), findsOneWidget);
      // The song's own plain lyrics stay as they are.
      expect(saved, isEmpty);
      expect(sidecar.files, {
        '/music/Album/song.flac':
            '[x-mlrc:2]\n'
            'Hello there\n'
            '${tag(0, 'de:Hello there')}\n'
            'Second line\n'
            '${tag(1, 'de:Second line')}\n',
      });
      expect(metadata.lyrics.lines.map((line) => line.translation), [
        'de:Hello there',
        'de:Second line',
      ]);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await tester.tap(options);
      await tester.pumpAndSettle();
      expect(find.text('Save Translation to File'), findsNothing);
      await tester.tap(find.text('Hide Translation'));
      await tester.pumpAndSettle();
      expect(find.text('de:Hello there'), findsNothing);
      expect(find.text('Hello there\nSecond line'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('translations save by themselves when asked', (tester) async {
    final saved = <String>[];
    final (:metadata, :sidecar, :options) = await pumpSavedLyrics(
      tester,
      mornye: false,
      lyrics: '[00:00.00]Hello there\n[00:03.00]Second line',
      settings: const AppSettings(
        lyricsAiModel: 'gpt-4.1-mini',
        lyricsTranslationLanguage: 'de',
        lyricsTranslationSaveTo: lyricsTranslationSaveToMlrc,
        lyricsTranslationAutoSave: true,
      ),
      saved: saved,
    );
    expect(sidecar.files, isEmpty);
    await tester.tap(options);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Translate to Deutsch'));
    await tester.pumpAndSettle();

    expect(sidecar.files, {
      '/music/Album/song.flac':
          '[x-mlrc:2]\n'
          '[00:00.00]Hello there\n'
          '${tag(0, 'de:Hello there')}\n'
          '[00:03.00]Second line\n'
          '${tag(3000, 'de:Second line')}\n',
    });
    expect(saved, isEmpty);
    // An automatic save stays quiet.
    expect(find.text('Translation saved to a .mlrc file'), findsNothing);
    expect(metadata.rawLyrics, '[00:00.00]Hello there\n[00:03.00]Second line');
    expect(metadata.lyrics.lines.map((line) => line.translation), [
      'de:Hello there',
      'de:Second line',
    ]);
    await tester.tap(options);
    await tester.pumpAndSettle();
    expect(find.text('Save Translation to File'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final language in ['en', 'de']) {
    testWidgets('English lyrics ${language == 'en' ? 'skip' : 'offer'} '
        'Translate to $language', (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final playback = StreamController<PlaybackState>.broadcast();
      addTearDown(playback.close);
      final english = [
        'I know you never like the way it was',
        'But we can be all that you want now',
        'When the night is over you will know',
        "It's just my heart and your love",
      ];
      final metadata = _Lyrics(
        ParsedLyrics(
          synced: true,
          wordSynced: false,
          lines: [
            for (final (index, text) in english.indexed)
              LyricLine(
                time: Duration(seconds: index * 3),
                end: Duration(seconds: index * 3 + 3),
                text: text,
              ),
          ],
          plainText: english.join('\n'),
        ),
      );
      final preview = PlaybackSeekPreview();
      addTearDown(metadata.dispose);
      addTearDown(preview.dispose);
      await tester.pumpWidget(
        _app(
          mornye: false,
          overrides: [
            initialSettingsProvider.overrideWithValue(
              AppSettings(
                lyricsAiModel: 'gpt-4.1-mini',
                lyricsTranslationLanguage: language,
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

      await tester.tap(find.byKey(const ValueKey('lyrics-language-options')));
      await tester.pumpAndSettle();
      if (language == 'en') {
        expect(find.textContaining('Translate to'), findsNothing);
        expect(find.text('Translate Into…'), findsOneWidget);
      } else {
        expect(find.text('Translate to Deutsch'), findsOneWidget);
        expect(find.text('Other Language…'), findsOneWidget);
      }
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
    // Synced lyrics still offer their timing.
    expect(find.byKey(const ValueKey('lyrics-options')), findsOneWidget);
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
      expect(parsedReplies, 1);

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

    testWidgets('settings pick where translations are saved ($mornye)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          mornye: mornye,
          overrides: [
            initialSettingsProvider.overrideWithValue(const AppSettings()),
            lyricsAiKeyStoreProvider.overrideWithValue(
              MemoryLyricsAiKeyStore(),
            ),
            lyricsTranslationCacheProvider.overrideWithValue(_MemoryCache()),
          ],
          home: const LyricsAiTranslationPage(),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(LyricsAiTranslationPage)),
      );
      final saveTo = find.byKey(const ValueKey('lyrics-ai-save-to'));
      await tester.ensureVisible(saveTo);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: saveTo, matching: find.text('Song File')),
        findsOneWidget,
      );
      await tester.tap(saveTo);
      await tester.pumpAndSettle();
      await tester.tap(find.text('.mlrc File'));
      await tester.pumpAndSettle();
      expect(
        container.read(settingsProvider).lyricsTranslationSaveTo,
        lyricsTranslationSaveToMlrc,
      );
      expect(
        find.descendant(of: saveTo, matching: find.text('.mlrc File')),
        findsOneWidget,
      );

      final autoSave = find.text('Save Automatically');
      await tester.ensureVisible(autoSave);
      await tester.pumpAndSettle();
      await tester.tap(autoSave);
      await tester.pumpAndSettle();
      expect(
        container.read(settingsProvider).lyricsTranslationAutoSave,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
