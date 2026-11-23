import 'dart:convert';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/home_pin.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/home_pins_provider.dart';
import 'package:mornye/providers/home_recommendations_provider.dart';
import 'package:mornye/providers/home_top_picks_provider.dart';
import 'package:mornye/providers/library_directory_provider.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/weekly_releases_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/screens/library_directory_screen.dart';
import 'package:mornye/services/library_directory_index.dart';
import 'package:mornye/services/weekly_releases.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

const _root = '/storage/emulated/0/Music';

/// Two album folders under one artist folder.
LibraryDirectoryIndex _index() => LibraryDirectoryIndex.build([
  for (final (id, path) in [
    ('a1', '$_root/Example Artist/First Album/01 Song.flac'),
    ('b1', '$_root/Example Artist/Second Album/01 Song.flac'),
  ])
    LibraryDirectoryEntry(source: 'downloaded', id: id, path: path),
]);

LibraryDirectory _folder(String name) =>
    _index().root.folders.firstWhere((folder) => folder.name == name);

HomePin _folderPin(String name) =>
    HomePin.folder(key: _folder(name).key, name: name);

UnifiedLibraryItem _song(String id) => UnifiedLibraryItem.fromDownloadHistory(
  DownloadHistoryItem(
    id: id,
    trackName: 'Song $id',
    artistName: 'Example Artist',
    albumName: 'Album',
    filePath: '$_root/$id.flac',
    service: 'example-provider',
    downloadedAt: DateTime(2026, 11, 20),
  ),
);

void _savePins(List<HomePin> pins) => SharedPreferences.setMockInitialValues({
  HomePinsNotifier.prefsKey: jsonEncode([for (final pin in pins) pin.toJson()]),
});

List<Override> _libraryOverrides() => [
  libraryDirectoryIndexProvider.overrideWith((ref) async => _index()),
  libraryDirectoryItemsLoaderProvider.overrideWithValue(
    (tracks) async => [for (final track in tracks) _song(track.id)],
  ),
  currentMediaItemProvider.overrideWithBuild(
    (ref, notifier) => Stream<MediaItem?>.value(null),
  ),
];

/// Home with nothing but its pins: no extensions, feed, played song or
/// Library shelves.
Widget _home({required bool mornye, bool targetsExist = true}) => ProviderScope(
  overrides: [
    ..._libraryOverrides(),
    homePinTargetExistsProvider.overrideWithValue((pin) async => targetsExist),
    homeRecommendationsProvider.overrideWith((ref) async => const []),
    homeNewReleasesProvider.overrideWith(
      (ref) => Stream.value(const <WeeklyRelease>[]),
    ),
    settingsProvider.overrideWith(
      () => FixedSettingsNotifier(
        const AppSettings(homeFeedProvider: AppSettings.homeFeedProviderOff),
      ),
    ),
    extensionProvider.overrideWith(_Extensions.new),
    exploreProvider.overrideWith(_Explore.new),
    downloadHistoryProvider.overrideWith(_History.new),
    recentAccessProvider.overrideWith(_Recent.new),
    libraryMixesProvider.overrideWith((ref) async => const []),
    homeTopPicksProvider.overrideWith((ref) async => const <ExploreItem>[]),
    homeRecentlyAddedProvider.overrideWith(
      (ref) async => (items: const <UnifiedLibraryItem>[], trackCount: 0),
    ),
    homeRecentlyPlayedProvider.overrideWith((ref) async => const []),
    homeOnRepeatProvider.overrideWith((ref) async => const []),
    homeQuickSongsProvider.overrideWith((ref) async => const []),
    playerUiEnabledProvider.overrideWithValue(true),
    playbackResumeProvider.overrideWith((ref) async => null),
  ],
  child: MaterialApp(
    theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const HomeTab(mode: HomeTabMode.browse),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _open(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(home);
  await _settle(tester);
}

List<HomePin> _pinsOf(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(HomeTab)),
).read(homePinsProvider);

void main() {
  group('HomePin', () {
    test('survives a save and load of every kind', () {
      final pins = [
        HomePin.album(
          source: 'local',
          albumKey: 'album-key',
          name: 'Album',
          artist: 'Example Artist',
          cover: '/covers/album.jpg',
          coverFile: '/music/01.flac',
        ),
        HomePin.album(
          source: 'downloaded',
          albumKey: '',
          name: 'Album',
          artist: 'Example Artist',
          cover: 'https://example.com/cover.jpg',
        ),
        HomePin.playlist(id: 'playlist-1', name: 'Road trip'),
        HomePin.loved,
        HomePin.artist(name: 'Example Artist', source: 'local'),
        HomePin.genre(key: 'jazz', name: 'Jazz'),
        HomePin.folder(key: 'root\u0000Albums', name: 'Albums', path: '/x'),
      ];
      final loaded = HomePinsNotifier.decode(
        jsonEncode([for (final pin in pins) pin.toJson()]),
      );
      expect(loaded, pins);
      for (final (index, pin) in loaded.indexed) {
        expect(pin.kind, pins[index].kind);
        expect(pin.title, pins[index].title);
        expect(pin.subtitle, pins[index].subtitle);
        expect(pin.cover, pins[index].cover);
        expect(pin.coverFile, pins[index].coverFile);
        expect(pin.source, pins[index].source);
      }
    });

    test('tells a scanned album from a download of the same names', () {
      final scanned = HomePin.album(
        source: 'local',
        albumKey: 'key',
        name: 'Album',
        artist: 'Artist',
      );
      final downloaded = HomePin.album(
        source: 'downloaded',
        albumKey: 'key',
        name: 'Album',
        artist: 'Artist',
      );
      expect(scanned.key, isNot(downloaded.key));
      // A download is the same pin whichever Library page pinned it.
      expect(
        HomePin.album(
          source: '',
          albumKey: 'other',
          name: ' album ',
          artist: 'ARTIST',
        ).key,
        downloaded.key,
      );
    });

    test('drops unknown kinds, broken entries and repeats', () {
      final pins = HomePinsNotifier.decode(
        jsonEncode([
          {'kind': 'mix', 'id': 'daily', 'title': 'Daily mix'},
          {'kind': 'genre', 'title': 'No id'},
          {'kind': 'album', 'id': 'a', 'title': 'No source'},
          'not a pin',
          HomePin.genre(key: 'jazz', name: 'Jazz').toJson(),
          HomePin.genre(key: 'jazz', name: 'Jazz again').toJson(),
        ]),
      );
      expect(pins.map((pin) => pin.title), ['Jazz']);
      expect(HomePinsNotifier.decode('{"kind": "genre"}'), isEmpty);
      expect(HomePinsNotifier.decode('not json'), isEmpty);
      expect(HomePinsNotifier.decode(null), isEmpty);
    });

    test('keeps the first pins of a list past the limit', () {
      final pins = HomePinsNotifier.decode(
        jsonEncode([
          for (var index = 0; index < 20; index++)
            HomePin.genre(key: 'g$index', name: 'Genre $index').toJson(),
        ]),
      );
      expect(pins, hasLength(HomePinsNotifier.limit));
      expect(pins.first.id, 'g0');
    });
  });

  group('homePinsProvider', () {
    Future<List<HomePin>> saved() async => HomePinsNotifier.decode(
      (await SharedPreferences.getInstance()).getString(
        HomePinsNotifier.prefsKey,
      ),
    );

    test('loads saved pins and saves each change', () async {
      _savePins([HomePin.genre(key: 'jazz', name: 'Jazz'), HomePin.loved]);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final pins = container.read(homePinsProvider.notifier);
      container.read(homePinsProvider);
      await pumpEventQueue();
      expect(container.read(homePinsProvider), [
        HomePin.genre(key: 'jazz', name: 'Jazz'),
        HomePin.loved,
      ]);

      final folder = HomePin.folder(key: 'f', name: 'Folder');
      expect(pins.add(folder), isTrue);
      expect(pins.isPinned(folder.key), isTrue);
      await pumpEventQueue();
      expect(await saved(), [
        HomePin.genre(key: 'jazz', name: 'Jazz'),
        HomePin.loved,
        folder,
      ]);

      pins.moveToFront(folder.key);
      await pumpEventQueue();
      expect((await saved()).first, folder);

      pins.remove(HomePin.loved.key);
      await pumpEventQueue();
      expect(await saved(), [folder, HomePin.genre(key: 'jazz', name: 'Jazz')]);
      expect(pins.isPinned(HomePin.loved.key), isFalse);
    });

    test('refuses a pin past the limit', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final pins = container.read(homePinsProvider.notifier);
      container.read(homePinsProvider);
      await pumpEventQueue();
      for (var index = 0; index < HomePinsNotifier.limit; index++) {
        expect(pins.add(HomePin.genre(key: 'g$index', name: 'G')), isTrue);
      }
      expect(pins.add(HomePin.genre(key: 'one more', name: 'G')), isFalse);
      // A pin already on Home is no new pin.
      expect(pins.add(HomePin.genre(key: 'g0', name: 'G')), isTrue);
      expect(container.read(homePinsProvider), hasLength(12));
    });
  });

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('the $style Home shows its pins', (tester) async {
      _savePins([_folderPin('First Album'), HomePin.loved]);
      await _open(tester, _home(mornye: mornye));
      expect(tester.takeException(), isNull);

      expect(find.text('First Album'), findsOneWidget);
      expect(find.text('Loved'), findsOneWidget);
      if (mornye) {
        expect(find.text('Pinned'), findsOneWidget);
        expect(find.text('Folder'), findsOneWidget);
        expect(find.text('Shortcuts'), findsNothing);
      } else {
        // Pins join the shortcuts, which keep their own tiles.
        expect(find.text('Shortcuts'), findsOneWidget);
        expect(find.text('Pinned'), findsNothing);
        expect(find.text('Equalizer'), findsOneWidget);
      }
    });

    testWidgets('a pin on the $style Home opens its folder', (tester) async {
      _savePins([_folderPin('Second Album')]);
      await _open(tester, _home(mornye: mornye));

      await tester.tap(find.text('Second Album'));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      final screen = tester.widget<LibraryDirectoryScreen>(
        find.byType(LibraryDirectoryScreen),
      );
      expect(screen.folderKey, _folder('Second Album').key);
      expect(find.text('Song b1'), findsWidgets);
    });

    testWidgets('a pin on the $style Home whose target is gone says so and '
        'offers to unpin', (tester) async {
      _savePins([_folderPin('First Album')]);
      await _open(tester, _home(mornye: mornye, targetsExist: false));

      await tester.tap(find.text('First Album'));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(LibraryDirectoryScreen), findsNothing);
      expect(find.text('This is no longer in your Library'), findsOneWidget);
      // Nothing goes without the person's say.
      expect(_pinsOf(tester), hasLength(1));

      await tester.tap(find.text('Unpin'));
      await _settle(tester);
      expect(_pinsOf(tester), isEmpty);
      expect(find.text('First Album'), findsNothing);
    });

    testWidgets('a long press on a $style pin moves it to the front or '
        'unpins it', (tester) async {
      _savePins([_folderPin('First Album'), _folderPin('Second Album')]);
      await _open(tester, _home(mornye: mornye));

      await tester.longPress(find.text('Second Album'));
      await _settle(tester);
      expect(find.text('Move to front'), findsOneWidget);
      await tester.tap(find.text('Move to front'));
      await _settle(tester);
      expect(_pinsOf(tester).map((pin) => pin.title), [
        'Second Album',
        'First Album',
      ]);

      await tester.longPress(find.text('First Album'));
      await _settle(tester);
      await tester.tap(find.text('Unpin'));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(_pinsOf(tester).map((pin) => pin.title), ['Second Album']);
      expect(find.text('First Album'), findsNothing);
    });

    testWidgets('a $style folder menu pins the folder to Home and unpins '
        'it', (tester) async {
      SharedPreferences.setMockInitialValues({});
      debugDesktopPlatformOverride = true;
      addTearDown(() => debugDesktopPlatformOverride = null);
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._libraryOverrides(),
            settingsProvider.overrideWith(FixedSettingsNotifier.new),
          ],
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.light)
                : AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const LibraryDirectoryScreen(),
          ),
        ),
      );
      await _settle(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(LibraryDirectoryScreen)),
      );

      Future<void> openMenu() async {
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('First Album')),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await gesture.up();
        await _settle(tester);
      }

      await openMenu();
      await tester.tap(find.text('Pin to Home'));
      await _settle(tester);
      final pins = container.read(homePinsProvider);
      expect(pins, [_folderPin('First Album')]);
      expect(pins.single.kind, HomePinKind.folder);

      await openMenu();
      await tester.tap(find.text('Unpin from Home'));
      await _settle(tester);
      expect(container.read(homePinsProvider), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();
}

class _Explore extends ExploreNotifier {
  @override
  ExploreState build() => const ExploreState();

  @override
  Future<void> fetchHomeFeed({bool forceRefresh = false}) async {}
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Recent extends RecentAccessNotifier {
  @override
  RecentAccessState build() => const RecentAccessState(isLoaded: true);
}
