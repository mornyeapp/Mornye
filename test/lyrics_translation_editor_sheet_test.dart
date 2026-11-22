import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/lyrics_translation_editor_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lyrics_translation_provider_test.dart' show MemoryLyricsAiKeyStore;

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

Widget _app({required List<Override> overrides, required Widget home}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: AppTheme.dark(),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('hand-written translation is saved with the song', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    addTearDown(metadata.dispose);
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
        overrides: [
          initialSettingsProvider.overrideWithValue(
            const AppSettings(lyricsTranslationLanguage: 'fa'),
          ),
          lyricsAiKeyStoreProvider.overrideWithValue(MemoryLyricsAiKeyStore()),
          lyricsTranslationCacheProvider.overrideWithValue(_MemoryCache()),
        ],
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => openLyricsTranslationEditor(context, metadata),
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();

    // No translation yet, so the sheet offers to add one, with the
    // original lines above their empty fields.
    expect(find.text('Add translation'), findsOneWidget);
    expect(find.text('Hello there'), findsOneWidget);
    expect(find.text('Second line'), findsOneWidget);
    // Nothing to change yet, so no note on what an edit drops.
    expect(find.textContaining('word-by-word timing'), findsNothing);
    expect(find.textContaining('Translation into'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('lyrics-translation-field-0')),
      'سلام',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('lyrics-translation-editor-save')),
    );
    await tester.pumpAndSettle();

    expect(saved, [
      (
        '/music/Album/song.flac',
        '[00:00.00]Hello there\n'
            '[x-translated:0:سلام]\n'
            '[00:03.00]Second line',
      ),
    ]);
    expect(find.text('Translation saved'), findsOneWidget);
    expect(metadata.lyrics.lines.map((line) => line.translation), [
      'سلام',
      null,
    ]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('editing an AI translation replaces it, line by line', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final saved = <(String, String)>[];
    final events = _Events();
    final cache = _MemoryCache();
    final metadata = PlayerMetadataController(
      readMetadata: (path) async => {
        'lyrics': '[00:00.00]Hello there\n[00:03.00]Second line',
      },
      parseLyrics: (raw) async => LyricsParser.parse(raw),
      saveOnlineLyrics: (source, raw) async => saved.add((source, raw)),
      metadataEvents: events,
    );
    addTearDown(metadata.dispose);
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
        overrides: [
          initialSettingsProvider.overrideWithValue(
            const AppSettings(
              lyricsAiModel: 'gpt-4.1-mini',
              lyricsTranslationLanguage: 'fa',
            ),
          ),
          lyricsAiKeyStoreProvider.overrideWithValue(
            MemoryLyricsAiKeyStore({'openai': 'sk-test-1234'}),
          ),
          lyricsTranslationCacheProvider.overrideWithValue(cache),
        ],
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => openLyricsTranslationEditor(context, metadata),
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Seed the cache with an AI translation, as a completed job would.
    final container = ProviderScope.containerOf(
      tester.element(find.text('Open editor')),
    );
    final translations = container.read(lyricsTranslationProvider.notifier);
    final original = metadata.lyrics;
    final key = lyricsTranslationCacheKey(
      sourceHash: LyricsTranslationSource.cached(original).hash,
      language: 'fa',
      config: lyricsAiConfigFor(
        container.read(settingsProvider),
        apiKey: 'sk-test-1234',
      ),
    );
    await cache.write(
      key,
      const LyricsTranslationResult(['سلام قدیمی', 'خط دوم']),
    );
    // The player loads the cached translation before the editor opens,
    // as it does on every build of the lyrics view.
    translations.display(original);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();

    expect(find.text('Edit translation'), findsOneWidget);
    expect(find.text('سلام قدیمی'), findsOneWidget);
    expect(find.textContaining('word-by-word timing'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('lyrics-translation-field-0')),
      'سلام تازه',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('lyrics-translation-editor-save')),
    );
    await tester.pumpAndSettle();

    expect(saved.length, 1);
    expect(saved.single.$2, contains('[x-translated:0:سلام تازه]'));
    expect(saved.single.$2, isNot(contains('سلام قدیمی')));
    // The cache now holds the edit, so the old AI text cannot come back.
    final stored = await cache.read(key);
    expect(stored?.translations, ['سلام تازه', 'خط دوم']);
    expect(metadata.lyrics.lines.map((line) => line.translation), [
      'سلام تازه',
      'خط دوم',
    ]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
