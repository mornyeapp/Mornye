import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/song_lyrics_offset_provider.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/lyrics_options_button.dart';
import 'package:mornye/widgets/lyrics_size_setting.dart';

import 'lyrics_translation_provider_test.dart' show MemoryLyricsAiKeyStore;
import 'support/fixed_settings.dart';
import 'support/tooltip_finder.dart';

const _lrc = '''
[00:01.00]First example line
[00:04.00]Second example line
''';

final _item = MediaItem(
  id: 'example-song',
  title: 'Example Song',
  artist: 'Example Artist',
  extras: const {'source': '/music/example.flac'},
);

final _song = songLyricsOffsetKey('Example Song', 'Example Artist');

class _MemoryCache extends LyricsTranslationCache {
  @override
  Future<LyricsTranslationResult?> read(String key) async => null;

  @override
  Future<void> write(String key, LyricsTranslationResult result) async {}

  @override
  Future<int> count() async => 0;

  @override
  Future<void> clear() async {}
}

/// A notifier on its own container, reading and writing [prefs].
ProviderContainer _container({int Function()? clock}) {
  final container = ProviderContainer(
    overrides: [
      songLyricsOffsetsProvider.overrideWith(
        () => SongLyricsOffsetsNotifier(clock: clock),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.listen(songLyricsOffsetsProvider, (_, _) {});
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('storage', () {
    test('the key ignores case and spaces, and needs a title', () {
      expect(
        songLyricsOffsetKey(' Example Song ', 'EXAMPLE ARTIST'),
        'example song|example artist',
      );
      expect(songLyricsOffsetKey('Example Song', null), 'example song|');
      expect(songLyricsOffsetKey('  ', 'Example Artist'), '');
      expect(songLyricsOffsetKeyOf(null), '');
      expect(songLyricsOffsetKeyOf(_item), _song);
    });

    test('a song in sync stores nothing; others survive a restart', () async {
      var now = 100;
      final first = _container(clock: () => now++);
      final songs = first.read(songLyricsOffsetsProvider.notifier);
      await songs.ensureLoaded();

      // A slider being dragged previews without saving.
      await songs.setOffsetMs(_song, 300, persist: false);
      expect(first.read(songLyricsOffsetMsProvider(_song)), 300);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kSongLyricsOffsetsKey), isNull);

      await songs.setOffsetMs(_song, 9000);
      expect(first.read(songLyricsOffsetMsProvider(_song)), kMaxLyricsOffsetMs);
      expect(jsonDecode(prefs.getString(kSongLyricsOffsetsKey)!), {
        _song: [kMaxLyricsOffsetMs, 101],
      });

      final second = _container();
      await second.read(songLyricsOffsetsProvider.notifier).ensureLoaded();
      expect(second.read(songLyricsOffsetMsProvider(_song)), 2000);
      // The app-wide offset is added, per song.
      await second.read(themeProvider.notifier).setLyricsOffsetMs(-500);
      expect(second.read(lyricsOffsetMsForSongProvider(_song)), 1500);
      expect(second.read(lyricsOffsetMsForSongProvider('other song|')), -500);

      await second
          .read(songLyricsOffsetsProvider.notifier)
          .setOffsetMs(_song, 0);
      expect(prefs.getString(kSongLyricsOffsetsKey), isNull);
      expect(second.read(songLyricsOffsetsProvider), isEmpty);
    });

    test('past the limit the song set longest ago gives way', () async {
      SharedPreferences.setMockInitialValues({
        kSongLyricsOffsetsKey: jsonEncode({
          for (var i = 0; i < kMaxSongLyricsOffsets; i++) 'song $i|': [100, i],
        }),
      });
      final container = _container(clock: () => 100000);
      final songs = container.read(songLyricsOffsetsProvider.notifier);
      await songs.ensureLoaded();
      await songs.setOffsetMs(_song, 500);
      final kept = container.read(songLyricsOffsetsProvider);
      expect(kept, hasLength(kMaxSongLyricsOffsets));
      expect(kept.containsKey('song 0|'), isFalse);
      expect(kept.containsKey('song 1|'), isTrue);
      expect(kept[_song]?.offsetMs, 500);
    });

    test('damaged storage reads as no offsets', () {
      expect(decodeSongLyricsOffsets('not json'), isEmpty);
      expect(
        decodeSongLyricsOffsets(
          jsonEncode({
            'a|': 'late',
            'b|': [0, 1],
            'c|': [250.4],
          }),
        ),
        {'c|': const SongLyricsOffset(250, 0)},
      );
    });
  });

  for (final mornye in [false, true]) {
    testWidgets('the player sets this song\'s timing apart from all songs '
        '(mornye=$mornye)', (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final metadata = PlayerMetadataController(
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        readMetadata: (_) async => {
          'title': 'Example Song',
          'artist': 'Example Artist',
          'lyrics': _lrc,
        },
      );
      addTearDown(metadata.dispose);
      await tester.runAsync(() => metadata.load(_item));
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(FixedSettingsNotifier.new),
          lyricsAiKeyStoreProvider.overrideWithValue(MemoryLyricsAiKeyStore()),
          lyricsTranslationCacheProvider.overrideWithValue(_MemoryCache()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark, accent: MornyeAccent.blue)
                : AppTheme.dark(),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomRight,
                child: LyricsOptionsButton(
                  metadata: metadata,
                  colorScheme: const ColorScheme.dark(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Without language choices the menu is not a language menu.
      expect(
        find.byKey(const ValueKey('lyrics-language-options')),
        findsNothing,
      );
      expect(findByTooltip('Lyrics options'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lyrics-options')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lyrics timing'));
      await tester.pumpAndSettle();

      final thisSong = find.byKey(const ValueKey('lyrics-offset-this-song'));
      final allSongs = find.byKey(const ValueKey('lyrics-offset-all-songs'));
      expect(find.text('This song'), findsOneWidget);
      expect(find.text('Example Song'), findsOneWidget);
      expect(find.text('All songs'), findsOneWidget);
      expect(find.text('In sync'), findsNWidgets(2));

      AppSlider slider(Finder row) => tester.widget<AppSlider>(
        find.descendant(of: row, matching: find.byType(AppSlider)),
      );
      expect(slider(thisSong).divisions, slider(allSongs).divisions);
      expect(slider(thisSong).min, slider(allSongs).min);
      expect(slider(thisSong).max, slider(allSongs).max);

      slider(thisSong).onChanged!(500);
      await tester.pump();
      expect(
        find.descendant(of: thisSong, matching: find.text('0.5 s later')),
        findsOneWidget,
      );
      slider(thisSong).onChangeEnd!(500);
      await tester.pumpAndSettle();
      expect(container.read(songLyricsOffsetMsProvider(_song)), 500);
      expect(container.read(themeProvider).lyricsOffsetMs, 0);
      expect(container.read(lyricsOffsetMsForSongProvider(_song)), 500);

      slider(allSongs).onChangeEnd!(-300);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: allSongs, matching: find.text('0.3 s earlier')),
        findsOneWidget,
      );
      expect(container.read(lyricsOffsetMsForSongProvider(_song)), 200);

      // Each row resets only its own offset.
      await tester.tap(
        find.descendant(of: thisSong, matching: findByTooltip('Reset')),
      );
      await tester.pumpAndSettle();
      expect(container.read(songLyricsOffsetsProvider), isEmpty);
      expect(container.read(themeProvider).lyricsOffsetMs, -300);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('the settings page keeps only the app-wide timing', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: LyricsOffsetSetting()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Lyrics timing'), findsOneWidget);
    expect(find.text('This song'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
