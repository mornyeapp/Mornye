import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/track_table.dart';
import 'package:mornye/widgets/now_playing_indicator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

/// Loaded Library rows: ten pages of the Library's 300.
const _songCount = 3000;

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(
    defaultLibraryView: 'all',
    historyFilterMode: 'all',
    historyViewMode: 'list',
    listeningStatisticsEnabled: false,
  );
}

/// No song in memory, so every Library row comes from the database pages.
class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState(totalCount: _songCount);

  /// What a finished download does: the Library index moves on.
  void reloadIndex() => state = DownloadHistoryState(
    totalCount: _songCount,
    loadedIndexVersion: state.loadedIndexVersion + 1,
  );
}

class _Local extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() => DownloadQueueState();
}

/// Titles the database reports instead of `Song <n>`.
final _renamed = <int, String>{};

const _songColumns = [
  'queue_source',
  'id',
  'track_name',
  'artist_name',
  'album_name',
  'file_path',
  'service',
  'downloaded_at',
  'quality',
  'bit_depth',
  'sample_rate',
  'format',
  'duration',
];

List<Object?> _songRow(int index) => [
  'downloaded',
  'song-$index',
  _renamed[index] ?? 'Song $index',
  'Artist ${index % 40}',
  'Album ${index % 250}',
  '/music/song-$index.flac',
  'example-provider',
  DateTime.utc(2026, 1, 1).toIso8601String(),
  'FLAC 24-bit/96kHz',
  24,
  96000,
  'flac',
  200,
];

/// The rows of [after] that are not carried over from [before].
int _rebuiltRows(List<TrackTableRow> before, List<TrackTableRow> after) {
  final kept = Set<TrackTableRow>.identity()..addAll(before);
  return after.where((row) => !kept.contains(row)).length;
}

List<TrackTableRow> _tableRows(WidgetTester tester) =>
    tester.widget<SliverTrackTable>(find.byType(SliverTrackTable)).rows;

/// Pumps frames, letting real IO run for the one-time database open.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _shiftClick(WidgetTester tester, Finder finder) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.tap(finder);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _renamed.clear();
    SharedPreferences.setMockInitialValues({});
    final previousFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactorySqflitePlugin;
    addTearDown(() => databaseFactory = previousFactory);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final root = Directory.systemTemp.createTempSync('library-table-');
    addTearDown(() => root.deleteSync(recursive: true));
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
    // The Library's track pages and counts; every other query is empty.
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
      if (sql.contains('AS all_count')) {
        return {
          'columns': ['all_count', 'album_count', 'single_count'],
          'rows': [
            [_songCount, 0, 0],
          ],
        };
      }
      if (sql.contains('queue_source') && sql.contains('LIMIT ?')) {
        final values = args['arguments'] as List;
        final limit = values[values.length - 2] as int;
        final offset = values.last as int;
        return {
          'columns': _songColumns,
          'rows': [
            for (var i = offset; i < offset + limit && i < _songCount; i++)
              _songRow(i),
          ],
        };
      }
      return {'columns': <String>[], 'rows': <List<Object?>>[]};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(sqlite, null));
  });
  tearDown(() => debugDesktopPlatformOverride = null);

  group('desktop Library Songs table', () {
    late _History history;
    late ValueNotifier<ThemeMode> themeMode;
    late StreamController<MediaItem?> nowPlaying;

    Future<void> pumpLibrary(WidgetTester tester) async {
      debugDesktopPlatformOverride = true;
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      themeMode = ValueNotifier(ThemeMode.light);
      addTearDown(themeMode.dispose);
      nowPlaying = StreamController<MediaItem?>();
      addTearDown(nowPlaying.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            downloadHistoryProvider.overrideWith(() => history = _History()),
            localLibraryProvider.overrideWith(_Local.new),
            libraryCollectionsProvider.overrideWith(_Collections.new),
            downloadQueueProvider.overrideWith(_Queue.new),
            downloadQueueLookupProvider.overrideWithValue(
              DownloadQueueLookup.fromItems(const []),
            ),
            currentMediaItemProvider.overrideWithBuild(
              (ref, notifier) => nowPlaying.stream,
            ),
          ],
          child: ValueListenableBuilder(
            valueListenable: themeMode,
            builder: (context, mode, _) => MaterialApp(
              theme: AppTheme.light(),
              darkTheme: AppTheme.dark(),
              themeMode: mode,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const Scaffold(body: QueueTab()),
            ),
          ),
        ),
      );
      await _settle(tester);
    }

    ScrollPosition songsPosition(WidgetTester tester) => tester
        .state<ScrollableState>(
          find
              .ancestor(
                of: find.byType(SliverTrackTable),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;

    /// Scrolls the table near its end, one page per scroll, until [count]
    /// rows are loaded.
    Future<void> loadRows(WidgetTester tester, int count) async {
      for (var page = 0; page < 20; page++) {
        if (_tableRows(tester).length >= count) return;
        final position = songsPosition(tester);
        position.jumpTo(position.maxScrollExtent * 0.8);
        await _settle(tester);
      }
      fail('loaded ${_tableRows(tester).length} of $count rows');
    }

    /// Shows the last loaded row once every page is in.
    Future<void> scrollToEnd(WidgetTester tester) async {
      final position = songsPosition(tester);
      // The list estimates its extent, so the end moves as rows lay out.
      for (var i = 0; i < 8; i++) {
        if (position.pixels >= position.maxScrollExtent) break;
        position.jumpTo(position.maxScrollExtent);
        await tester.pump();
      }
      await _settle(tester);
    }

    ProviderContainer container(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byType(QueueTab)));

    testWidgets('a click, a resize and playback keep every loaded row', (
      tester,
    ) async {
      await pumpLibrary(tester);
      await loadRows(tester, _songCount);
      await scrollToEnd(tester);
      final rows = _tableRows(tester);
      expect(rows, hasLength(_songCount));
      expect(rows.last.quality, '24-bit');

      final last = find.text('Song ${_songCount - 1}');
      await _shiftClick(tester, last);
      final table = tester.widget<SliverTrackTable>(
        find.byType(SliverTrackTable),
      );
      expect(table.selectedIds, {'dl_song-${_songCount - 1}'});
      expect(_rebuiltRows(rows, table.rows), 0);
      expect(table.rows, same(rows));

      tester.view.physicalSize = const Size(1440, 900);
      await _settle(tester);
      expect(_rebuiltRows(rows, _tableRows(tester)), 0);
      expect(last, findsOneWidget);

      // The playing song marks its own row.
      expect(find.byType(NowPlayingIndicator), findsNothing);
      nowPlaying.add(
        MediaItem(
          id: 'song-${_songCount - 2}',
          title: 'Song ${_songCount - 2}',
          extras: {'source': '/music/song-${_songCount - 2}.flac'},
        ),
      );
      await _settle(tester);
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('Song ${_songCount - 2}'),
            matching: find.byType(InkWell),
          ),
          matching: find.byType(NowPlayingIndicator),
        ),
        findsOneWidget,
      );
      expect(find.byType(NowPlayingIndicator), findsOneWidget);
      expect(_tableRows(tester), same(rows));
    });

    testWidgets('a new page builds only its own rows; a reload shows the '
        'changed songs', (tester) async {
      await pumpLibrary(tester);
      await loadRows(tester, _songCount - 300);
      final beforePage = _tableRows(tester);
      expect(beforePage, hasLength(_songCount - 300));
      await loadRows(tester, _songCount);
      expect(_rebuiltRows(beforePage, _tableRows(tester)), 300);

      // A finished download reloads the Library from its first page, with
      // new rows that show the changed song.
      final beforeReload = _tableRows(tester);
      _renamed[0] = 'Renamed';
      history.reloadIndex();
      await _settle(tester);
      songsPosition(tester).jumpTo(0);
      await _settle(tester);
      final reloaded = _tableRows(tester);
      expect(_rebuiltRows(beforeReload, reloaded), reloaded.length);
      expect(reloaded.first.title, 'Renamed');
      expect(find.text('Renamed'), findsOneWidget);
      expect(find.text('Song 0'), findsNothing);
      expect(find.text('Song 1'), findsOneWidget);
    });

    testWidgets('the quality label setting and the theme rebuild every row', (
      tester,
    ) async {
      await pumpLibrary(tester);
      await loadRows(tester, _songCount);
      final rows = _tableRows(tester);
      expect(find.text('24-bit'), findsWidgets);

      container(tester)
          .read(settingsProvider.notifier)
          .setLibraryQualityLabelMode(AppSettings.libraryQualityLabelBitDepth);
      await _settle(tester);
      final relabeled = _tableRows(tester);
      expect(_rebuiltRows(rows, relabeled), _songCount);
      expect(relabeled.map((row) => row.quality).toSet(), {'24-bit/96kHz'});
      expect(find.text('24-bit/96kHz'), findsWidgets);
      expect(find.text('24-bit'), findsNothing);

      themeMode.value = ThemeMode.dark;
      await _settle(tester);
      expect(_rebuiltRows(relabeled, _tableRows(tester)), _songCount);
    });
  });
}
