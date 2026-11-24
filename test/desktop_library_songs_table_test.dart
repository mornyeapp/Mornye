import 'package:audio_service/audio_service.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/mornye_library_screen.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/desktop/desktop_selection.dart';
import 'package:mornye/widgets/desktop/track_table.dart';
import 'package:mornye/widgets/library_track_selection_bar.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:mornye/widgets/song_row_tap.dart';
import 'package:mornye/widgets/track_card.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'support/app_icon_finder.dart';
import 'support/tooltip_finder.dart';

class _Settings extends SettingsNotifier {
  _Settings(this.viewMode, {this.filterMode = 'all'});

  final String viewMode;
  final String filterMode;

  // The Rewind banner animates for as long as it is shown; keep it off so
  // the page settles.
  @override
  AppSettings build() => AppSettings(
    defaultLibraryView: filterMode,
    historyFilterMode: filterMode,
    historyViewMode: viewMode,
    listeningStatisticsEnabled: false,
  );
}

/// Two downloaded songs. With a queue item present and the database page
/// empty, the Library renders this in-memory snapshot.
class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState(
    items: [
      for (final (index, name) in ['Bravo', 'Alpha'].indexed)
        DownloadHistoryItem(
          id: 'song-$index',
          trackName: name,
          artistName: 'Artist',
          albumName: 'Album $index',
          filePath: '/music/$name.flac',
          service: 'example-provider',
          downloadedAt: DateTime(2026, 1, 10 + index),
        ),
    ],
    totalCount: 2,
  );
}

class _Local extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

class _Collections extends LibraryCollectionsNotifier {
  _Collections({this.withPlaylistTracks = false});

  final bool withPlaylistTracks;

  @override
  LibraryCollectionsState build() => LibraryCollectionsState(
    isLoaded: true,
    playlists: [
      if (withPlaylistTracks)
        UserPlaylistCollection(
          id: 'playlist',
          name: 'Playlist',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          tracks: const [],
          tracksLoaded: false,
          trackKeys: {'example-provider:song-0', 'example-provider:song-1'},
        ),
    ],
  );
}

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() => DownloadQueueState();
}

class _Playback extends PlaybackController {
  final started = <String>[];
  List<PlayableMedia> _queue = [];
  int? _startIndex;

  @override
  Future<void> playMediaQueue(
    Iterable<PlayableMedia> queue, {
    required int startIndex,
    required String externalPath,
  }) async {
    started.add(externalPath);
    _queue = queue.toList();
    _startIndex = startIndex;
  }
}

class _Player extends MusicPlayerController {
  final toggles = <bool>[];

  @override
  Future<void> togglePlayPause(bool isPlaying) async {
    toggles.add(isPlaying);
  }
}

/// The Library's database page keeps a loading indicator spinning, so this
/// settles with bounded pumps.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Opening the details reads the song's file first, which needs real time
/// between the frames.
Future<void> _settleDetails(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(
    tester.getCenter(finder),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final previousFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactorySqflitePlugin;
    addTearDown(() => databaseFactory = previousFactory);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(paths, (_) async => '/test/documents');
    addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
    // An empty database: every page query returns no rows.
    const sqlite = MethodChannel('com.tekartik.sqflite');
    final versions = <int, int>{};
    messenger.setMockMethodCallHandler(sqlite, (call) async {
      final args = (call.arguments as Map?) ?? {};
      if (call.method == 'openDatabase') {
        final id = versions.length + 1;
        versions[id] = (args['path'] as String).endsWith('history.db')
            ? HistoryDatabase.schemaVersion
            : LibraryDatabase.schemaVersion;
        return {'id': id};
      }
      final sql = args['sql'] as String? ?? '';
      if (call.method == 'execute' && sql.contains('CREATE VIRTUAL TABLE')) {
        throw PlatformException(code: 'sqlite_error', message: 'no fts5');
      }
      if (call.method != 'query') return null;
      if (sql.toLowerCase().contains('pragma user_version')) {
        return {
          'columns': ['user_version'],
          'rows': [
            [versions[args['id']]],
          ],
        };
      }
      return {'columns': <String>[], 'rows': <List<Object?>>[]};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(sqlite, null));
  });
  // Clicks of one test must not complete a double click of the last one.
  setUp(DesktopDoubleClick.reset);
  tearDown(() => debugDesktopPlatformOverride = null);

  Future<void> pumpLibrary(
    WidgetTester tester, {
    required bool desktop,
    bool mornye = false,
    String viewMode = 'list',
    String filterMode = 'all',
    bool withPlaylistTracks = false,
    bool root = false,
    PlaybackController? playback,
    MusicPlayerController? player,
    MediaItem? currentItem,
    bool playing = false,
    bool loading = false,
    bool? tapPlays,
  }) async {
    debugDesktopPlatformOverride = desktop;
    tester.view.physicalSize = desktop
        ? const Size(1280, 900)
        : const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final queue = DownloadQueueLookup.fromItems([
      DownloadItem(
        id: 'completed',
        track: const Track(
          id: 'song',
          name: 'Song',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 1000,
        ),
        service: 'example-provider',
        status: DownloadStatus.completed,
        createdAt: DateTime(2026),
      ),
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(
            () => _Settings(viewMode, filterMode: filterMode),
          ),
          downloadHistoryProvider.overrideWith(_History.new),
          localLibraryProvider.overrideWith(_Local.new),
          libraryCollectionsProvider.overrideWith(
            () => _Collections(withPlaylistTracks: withPlaylistTracks),
          ),
          downloadQueueProvider.overrideWith(_Queue.new),
          downloadQueueLookupProvider.overrideWithValue(queue),
          if (playback != null) playbackProvider.overrideWith(() => playback),
          if (player != null)
            musicPlayerControllerProvider.overrideWith((ref) => player),
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => Stream.value(currentItem),
          ),
          playbackPlayingProvider.overrideWith((ref) => playing),
          playbackLoadingProvider.overrideWith((ref) => loading),
          // Without a choice these tests play songs with a tap on the row.
          librarySongTapPlaysProvider.overrideWithValue(tapPlays ?? true),
        ],
        child: MaterialApp(
          theme: mornye
              ? MornyeTheme.build(Brightness.light)
              : AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          // Mornye opens Songs as a section page from its Library root.
          home: Scaffold(
            body: QueueTab(librarySection: mornye && !root ? filterMode : null),
          ),
        ),
      ),
    );
    // The app's player bar keeps the current item loaded, which Mornye rows
    // do not watch themselves.
    ProviderScope.containerOf(
      tester.element(find.byType(QueueTab)),
    ).listen(currentMediaItemProvider, (_, _) {});
    await _settle(tester);
  }

  for (final mornye in [false, true]) {
    testWidgets('desktop Songs list is the songs table (mornye: $mornye)', (
      tester,
    ) async {
      await pumpLibrary(tester, desktop: true, mornye: mornye);
      expect(find.byType(SliverTrackTable), findsOneWidget);
      expect(find.byType(TrackCard), findsNothing);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Bravo'), findsOneWidget);
      // No month sections: the table sorts through its header instead.
      expect(find.text('January 2026'), findsNothing);
      final l10n = AppLocalizations.of(tester.element(find.byType(QueueTab)));
      await tester.tap(find.text(l10n.editMetadataFieldTitle));
      await _settle(tester);
      final preferences = await SharedPreferences.getInstance();
      expect(loadBootstrapSettings(preferences).historySortMode, 'a-z');
    });

    testWidgets(
      'list play button starts the full queue without opening details '
      '(mornye: $mornye)',
      (tester) async {
        final playback = _Playback();
        await pumpLibrary(
          tester,
          desktop: true,
          mornye: mornye,
          playback: playback,
          tapPlays: false,
        );
        final l10n = AppLocalizations.of(tester.element(find.byType(QueueTab)));
        final button = findByTooltip(
          l10n.a11yPlayTrackByArtist('Alpha', 'Artist'),
        );
        expect(button.hitTestable(), findsOneWidget);
        expect(
          find.descendant(
            of: button,
            matching: findAppIcon(Icons.play_circle_outline_rounded),
          ),
          findsOneWidget,
        );

        await tester.tap(button);
        await _settle(tester);
        expect(playback.started, ['/music/Alpha.flac']);
        expect(playback._queue.map((item) => item.source), [
          '/music/Bravo.flac',
          '/music/Alpha.flac',
        ]);
        expect(playback._startIndex, 1);
        expect(find.byType(SliverTrackTable), findsOneWidget);
        expect(find.byType(LibraryTrackSelectionBar), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    for (final playing in [false, true]) {
      testWidgets('current list play button toggles playback in place '
          '(mornye: $mornye, playing: $playing)', (tester) async {
        final playback = _Playback();
        final player = _Player();
        await pumpLibrary(
          tester,
          desktop: true,
          mornye: mornye,
          playback: playback,
          player: player,
          currentItem: const MediaItem(
            id: '/music/Alpha.flac',
            title: 'Alpha',
            artist: 'Artist',
          ),
          playing: playing,
          tapPlays: false,
        );
        final icon = findAppIcon(
          playing
              ? Icons.pause_circle_filled_rounded
              : Icons.play_circle_fill_rounded,
        );
        expect(icon, findsOneWidget);
        await tester.tap(icon);
        await _settle(tester);
        expect(player.toggles, [playing]);
        expect(playback.started, isEmpty);
        expect(find.byType(SliverTrackTable), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('current list play button is disabled while loading '
        '(mornye: $mornye)', (tester) async {
      final player = _Player();
      await pumpLibrary(
        tester,
        desktop: true,
        mornye: mornye,
        player: player,
        currentItem: const MediaItem(
          id: '/music/Alpha.flac',
          title: 'Alpha',
          artist: 'Artist',
        ),
        loading: true,
        tapPlays: false,
      );
      final l10n = AppLocalizations.of(tester.element(find.byType(QueueTab)));
      final button = find.byWidgetPredicate(
        (widget) =>
            widget is AppIconButton &&
            widget.tooltip == l10n.a11yPlayTrackByArtist('Alpha', 'Artist'),
      );
      expect(tester.widget<AppIconButton>(button).onPressed, isNull);
      expect(player.toggles, isEmpty);
      expect(tester.takeException(), isNull);
    });

    // By default a click plays as the Play button does, and the button
    // opens the details instead.
    testWidgets('a click plays the full queue; the info button opens the '
        'details (mornye: $mornye)', (tester) async {
      final playback = _Playback();
      await pumpLibrary(
        tester,
        desktop: true,
        mornye: mornye,
        playback: playback,
      );
      final l10n = AppLocalizations.of(tester.element(find.byType(QueueTab)));
      expect(
        findByTooltip(l10n.a11yPlayTrackByArtist('Alpha', 'Artist')),
        findsNothing,
      );
      expect(findByTooltip('Show details'), findsNWidgets(2));

      await tester.tap(find.text('Alpha'));
      await _settle(tester);
      expect(playback.started, ['/music/Alpha.flac']);
      expect(playback._queue.map((item) => item.source), [
        '/music/Bravo.flac',
        '/music/Alpha.flac',
      ]);
      expect(playback._startIndex, 1);
      expect(find.byType(TrackMetadataScreen), findsNothing);
      expect(find.byType(LibraryTrackSelectionBar), findsNothing);

      // Material extracts the embedded cover before the details open, which
      // this host test cannot do, so only Mornye follows the route.
      if (!mornye) return;
      await tester.tap(findByTooltip('Show details').first);
      await _settleDetails(tester);
      expect(find.byType(TrackMetadataScreen), findsOneWidget);
      expect(playback.started, ['/music/Alpha.flac']);
    });

    testWidgets('with the details setting a click opens the details '
        '(mornye: $mornye)', (tester) async {
      final playback = _Playback();
      await pumpLibrary(
        tester,
        desktop: true,
        mornye: mornye,
        playback: playback,
        tapPlays: false,
      );
      expect(findByTooltip('Show details'), findsNothing);
      await tester.tap(find.text('Alpha'));
      await _settleDetails(tester);
      // See above: Material stops at the cover extraction.
      if (mornye) expect(find.byType(TrackMetadataScreen), findsOneWidget);
      expect(playback.started, isEmpty);
    });

    for (final playing in [false, true]) {
      testWidgets('a click on the current song toggles playback in place '
          '(mornye: $mornye, playing: $playing)', (tester) async {
        final playback = _Playback();
        final player = _Player();
        await pumpLibrary(
          tester,
          desktop: true,
          mornye: mornye,
          playback: playback,
          player: player,
          currentItem: const MediaItem(
            id: '/music/Alpha.flac',
            title: 'Alpha',
            artist: 'Artist',
          ),
          playing: playing,
        );
        await tester.tap(find.text('Alpha'));
        await _settle(tester);
        expect(player.toggles, [playing]);
        expect(playback.started, isEmpty);
        expect(find.byType(TrackMetadataScreen), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a click on the current song does nothing while it loads '
        '(mornye: $mornye)', (tester) async {
      final playback = _Playback();
      final player = _Player();
      await pumpLibrary(
        tester,
        desktop: true,
        mornye: mornye,
        playback: playback,
        player: player,
        currentItem: const MediaItem(
          id: '/music/Alpha.flac',
          title: 'Alpha',
          artist: 'Artist',
        ),
        loading: true,
      );
      await tester.tap(find.text('Alpha'));
      await _settle(tester);
      expect(player.toggles, isEmpty);
      expect(playback.started, isEmpty);
      expect(find.byType(TrackMetadataScreen), findsNothing);
    });

    testWidgets('a Shift-click still selects instead of playing '
        '(mornye: $mornye)', (tester) async {
      final playback = _Playback();
      await pumpLibrary(
        tester,
        desktop: true,
        mornye: mornye,
        playback: playback,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.text('Alpha'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await _settle(tester);
      expect(find.byType(LibraryTrackSelectionBar), findsOneWidget);
      expect(playback.started, isEmpty);
      expect(find.byType(TrackMetadataScreen), findsNothing);
    });

    testWidgets('a right-click menu leaves the selection toolbar closed '
        '(mornye: $mornye)', (tester) async {
      final playback = _Playback();
      await pumpLibrary(
        tester,
        desktop: true,
        mornye: mornye,
        playback: playback,
      );
      final toolbar = find.byType(LibraryTrackSelectionBar);
      Finder menuRow(String label) => find.descendant(
        of: find.byType(mornye ? MornyeContextMenu : M3EMenuPopup<int>),
        matching: find.text(label),
      );

      // The menu acts on the song without opening the toolbar under it,
      // and closing the menu ends that selection.
      await _rightClick(tester, find.text('Alpha'));
      expect(menuRow('Play next'), findsOneWidget);
      expect(toolbar, findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(menuRow('Play next'), findsNothing);
      expect(toolbar, findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(toolbar, findsNothing);

      await _rightClick(tester, find.text('Alpha'));
      await tester.tap(menuRow('Play'));
      await _settle(tester);
      expect(playback.started, ['/music/Alpha.flac']);
      expect(toolbar, findsNothing);

      // A bulk action keeps the selection, so the toolbar returns.
      await _rightClick(tester, find.text('Bravo'));
      // The long menu scrolls inside the window.
      await tester.ensureVisible(menuRow('Delete 1 track'));
      await _settle(tester);
      await tester.tap(menuRow('Delete 1 track'));
      await _settle(tester);
      expect(toolbar, findsOneWidget);
    });
  }

  testWidgets('desktop Songs grid keeps the cover grid', (tester) async {
    await pumpLibrary(tester, desktop: true, viewMode: 'grid');
    expect(find.byType(SliverTrackTable), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('phones keep the sectioned song cards', (tester) async {
    await pumpLibrary(tester, desktop: false);
    expect(find.byType(SliverTrackTable), findsNothing);
    expect(find.byType(TrackCard), findsNWidgets(2));
    expect(find.text('January 2026'), findsOneWidget);
  });

  for (final mornye in [false, true]) {
    for (final tapPlays in [true, false]) {
      testWidgets('a phone Songs row ${tapPlays ? 'plays' : 'opens details'} '
          'on a tap (mornye: $mornye)', (tester) async {
        final playback = _Playback();
        await pumpLibrary(
          tester,
          desktop: false,
          mornye: mornye,
          playback: playback,
          // Null keeps the default setting.
          tapPlays: tapPlays ? null : false,
        );
        final l10n = AppLocalizations.of(tester.element(find.byType(QueueTab)));
        final row = find.widgetWithText(TrackCard, 'Alpha');
        expect(
          find.descendant(of: row, matching: findByTooltip('Show details')),
          tapPlays ? findsOneWidget : findsNothing,
        );
        expect(
          find.descendant(
            of: row,
            matching: findByTooltip(
              l10n.a11yPlayTrackByArtist('Alpha', 'Artist'),
            ),
          ),
          tapPlays ? findsNothing : findsOneWidget,
        );

        await tester.tap(find.text('Alpha'));
        await _settleDetails(tester);
        if (tapPlays) {
          expect(playback.started, ['/music/Alpha.flac']);
          expect(playback._queue.map((item) => item.source), [
            '/music/Bravo.flac',
            '/music/Alpha.flac',
          ]);
          expect(find.byType(TrackMetadataScreen), findsNothing);
        } else {
          expect(playback.started, isEmpty);
          // Material extracts the embedded cover first; see the desktop test.
          if (mornye) {
            expect(find.byType(TrackMetadataScreen), findsOneWidget);
          }
        }
      });
    }

    testWidgets('a phone Songs row keeps toggling selection on a tap '
        '(mornye: $mornye)', (tester) async {
      final playback = _Playback();
      await pumpLibrary(
        tester,
        desktop: false,
        mornye: mornye,
        playback: playback,
      );
      await tester.longPress(find.text('Alpha'));
      await _settle(tester);
      expect(find.byType(LibraryTrackSelectionBar), findsOneWidget);
      await tester.tap(find.text('Bravo'));
      await _settle(tester);
      expect(
        tester
            .widget<TrackCard>(find.widgetWithText(TrackCard, 'Bravo'))
            .isSelected,
        isTrue,
      );
      expect(playback.started, isEmpty);
      expect(find.byType(TrackMetadataScreen), findsNothing);
    });
  }

  testWidgets('a phone Songs row whose file is missing keeps opening its '
      'details', (tester) async {
    final playback = _Playback();
    // Mornye, which opens the details without extracting a cover first.
    await pumpLibrary(tester, desktop: false, mornye: true, playback: playback);
    // The test songs have no files; the Library confirms the miss after its
    // retries.
    for (var i = 0; i < 14; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 500));
    }
    final row = find.widgetWithText(TrackCard, 'Alpha');
    final l10n = AppLocalizations.of(tester.element(find.byType(QueueTab)));
    expect(
      find.descendant(
        of: row,
        matching: findByTooltip(l10n.queueDownloadedFileMissing),
      ),
      findsOneWidget,
    );
    expect(findByTooltip('Show details'), findsNothing);

    await tester.tap(find.text('Alpha'));
    await _settleDetails(tester);
    expect(playback.started, isEmpty);
    expect(find.byType(TrackMetadataScreen), findsOneWidget);
  });

  for (final desktop in [false, true]) {
    for (final mornye in [false, true]) {
      for (final viewMode in mornye ? ['list'] : ['list', 'grid']) {
        for (final mode in ['all', 'singles']) {
          testWidgets(
            'playlist members remain visible '
            '(desktop: $desktop, mornye: $mornye, view: $viewMode, mode: $mode)',
            (tester) async {
              await pumpLibrary(
                tester,
                desktop: desktop,
                mornye: mornye,
                viewMode: viewMode,
                filterMode: mode,
                withPlaylistTracks: true,
              );
              expect(find.text('2 tracks'), findsWidgets);
              expect(find.text('Alpha'), findsOneWidget);
              expect(find.text('Bravo'), findsOneWidget);
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }
  }

  testWidgets(
    'switching from Mornye to Material keeps playlist songs visible',
    (tester) async {
      await pumpLibrary(
        tester,
        desktop: false,
        mornye: true,
        root: true,
        withPlaylistTracks: true,
      );
      expect(find.byType(MornyeLibraryScreen), findsOneWidget);
      await pumpLibrary(
        tester,
        desktop: false,
        viewMode: 'grid',
        withPlaylistTracks: true,
      );
      expect(find.byType(MornyeLibraryScreen), findsNothing);
      expect(find.text('2 tracks'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Bravo'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
