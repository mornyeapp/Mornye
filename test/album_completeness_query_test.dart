import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:mornye/services/album_completeness.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_choice_chip.dart';

import 'support/tooltip_finder.dart';

String _definition(String file, String table) => RegExp(
  'CREATE TABLE $table\\s*\\([\\s\\S]*?\\n\\s*\\)',
).firstMatch(File(file).readAsStringSync())!.group(0)!;

// Execute the actual page/count queries with their bound parameters in SQLite.
// Schema/bootstrap calls are isolated from this fixed inventory fixture.
class _QueryFixture {
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    final result = await Process.run('python3', [
      '-c',
      r'''
import json, sqlite3, sys
data = json.loads(sys.argv[1])
db = sqlite3.connect(':memory:')
db.row_factory = sqlite3.Row
db.execute("ATTACH DATABASE ':memory:' AS history_db")
db.execute(data['history'].replace('CREATE TABLE history', 'CREATE TABLE history_db.history', 1))
db.execute(data['library'])
db.execute('CREATE TABLE library_sources (id TEXT PRIMARY KEY, enabled INTEGER, available INTEGER)')
db.execute("INSERT INTO library_sources VALUES ('internal',1,1)")
db.execute('CREATE VIEW library_visible AS SELECT * FROM library')
for table in ['library_path_keys', 'history_db.history_path_keys']:
    db.execute('CREATE TABLE '+table+' (item_id TEXT, path_key TEXT)')
def add(local, id, album, number, total, depth=16):
    table = 'library' if local else 'history_db.history'
    fields = dict(id=id, track_name='Song '+str(number), artist_name='Artist',
      album_name=album, album_artist='Artist', album_key=album+'|artist',
      file_path='/'+id+'.flac', track_number=number, total_tracks=total,
      disc_number=1, total_discs=1, bit_depth=depth,
      search_text=(album+' song '+str(number)+' artist').lower(),
      sort_genre='', sort_release='', sort_added=1)
    fields.update(dict(scanned_at='2026-01-01', source_id='internal',
                       track_name_norm='song '+str(number), artist_name_norm='artist', album_name_norm=album,
                       album_artist_norm='artist') if local else
                  dict(downloaded_at='2026-01-01', service='example-provider',
                       sort_track='song '+str(number), sort_artist='artist', sort_album=album,
                       sort_album_artist='artist'))
    db.execute('INSERT INTO '+table+' ('+','.join(fields)+') VALUES ('+','.join('?' for _ in fields)+')', list(fields.values()))
    keys = 'library_path_keys' if local else 'history_db.history_path_keys'
    db.execute('INSERT INTO '+keys+' VALUES (?,?)', (id, fields['file_path']))
add(False, 'missing1', 'missing', 1, 4, depth=24)
add(False, 'missing2', 'missing', 2, 4)
add(False, 'complete1', 'complete', 1, 2, depth=24)
add(False, 'complete2', 'complete', 2, 2)
add(False, 'unknown1', 'unknown', 1, None)
add(False, 'one1', 'one-track', 1, 12)
add(False, 'mixed1', 'mixed', 1, 2)
add(True, 'mixed2', 'mixed', 2, 2)
add(True, 'local1', 'local-only', 1, 3)
add(True, 'local3', 'local-only', 3, 3)
print(json.dumps([dict(row) for row in db.execute(data['sql'], data['args'])]))
''',
      jsonEncode({
        'history': _definition('lib/services/history_schema.dart', 'history'),
        'library': _definition('lib/services/library_schema.dart', 'library'),
        'sql': sql,
        'args': arguments ?? [],
      }),
    ]);
    if (result.exitCode != 0) {
      throw StateError('${result.stderr}\nSQL: $sql\nArgs: $arguments');
    }
    return (jsonDecode(result.stdout as String) as List)
        .map((row) => Map<String, Object?>.from(row as Map))
        .toList();
  }
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() =>
      const AppSettings(localLibraryEnabled: true, defaultLibraryView: 'all');

  @override
  void setHistoryFilterMode(String mode) {
    state = state.copyWith(historyFilterMode: mode);
  }
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState(totalCount: 7);
}

class _Local extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState(totalCount: 3);
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(
    finder,
    findsWidgets,
    reason: find
        .byType(Text)
        .evaluate()
        .map((element) => (element.widget as Text).data)
        .join(' | '),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('Google Sans Flex')
      ..addFont(rootBundle.load('assets/fonts/GoogleSansFlex.ttf'));
    await font.load();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final previousFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactorySqflitePlugin;
    addTearDown(() => databaseFactory = previousFactory);
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => '/test/documents');
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    const sqliteChannel = MethodChannel('com.tekartik.sqflite');
    final versions = <int, int>{};
    final executor = _QueryFixture();
    messenger.setMockMethodCallHandler(sqliteChannel, (call) async {
      final args = (call.arguments as Map?) ?? {};
      if (call.method == 'openDatabase') {
        final id = versions.length + 1;
        versions[id] = (args['path'] as String).endsWith('history.db')
            ? HistoryDatabase.schemaVersion
            : LibraryDatabase.schemaVersion;
        return {'id': id};
      }
      final sql = args['sql'] as String? ?? '';
      if (call.method == 'execute') {
        if (sql.contains('CREATE VIRTUAL TABLE')) {
          throw PlatformException(
            code: 'sqlite_error',
            message: 'no such module: fts5',
          );
        }
        return null;
      }
      if (call.method != 'query') return null;
      final rows = sql.toLowerCase().contains('pragma user_version')
          ? <Map<String, Object?>>[
              {'user_version': versions[args['id']]},
            ]
          : await executor.rawQuery(
              sql,
              (args['arguments'] as List?)?.cast<Object?>(),
            );
      final columns = rows.isEmpty ? <String>[] : rows.first.keys.toList();
      return {
        'columns': columns,
        'rows': [
          for (final row in rows) [for (final column in columns) row[column]],
        ],
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(sqliteChannel, null));
  });
  test(
    'production album/track/count queries filter full inventory and paginate consistently',
    () async {
      final db = LibraryDatabase.instance;
      const query = QueueLibraryDbQuery(
        filterMode: 'albums',
        metadata: incompleteAlbumFilter,
        sortMode: 'album-asc',
      );
      final albums = await db.getQueueAlbumPage(query);
      expect(albums.map((row) => row['album_name']), [
        'local-only',
        'missing',
        'one-track',
      ]);
      expect(albums.map((row) => row['album_present_tracks']), [2, 2, 1]);
      expect(albums.map((row) => row['album_expected_tracks']), [3, 4, 12]);
      final counts = await db.getQueueCounts(query);
      expect(counts.albumCount, 3);
      expect(counts.allTrackCount, 5);
      final tracks = await db.getQueueTrackPage(
        const QueueLibraryDbQuery(metadata: incompleteAlbumFilter),
      );
      expect(tracks, hasLength(5));
      expect(tracks.any((row) => row['albumName'] == 'mixed'), isFalse);
      final first = await db.getQueueAlbumPageResult(
        const QueueLibraryDbQuery(
          filterMode: 'albums',
          metadata: incompleteAlbumFilter,
          sortMode: 'album-asc',
          limit: 1,
        ),
      );
      final second = await db.getQueueAlbumPageResult(
        QueueLibraryDbQuery(
          filterMode: 'albums',
          metadata: incompleteAlbumFilter,
          sortMode: 'album-asc',
          limit: 1,
          cursor: first.nextCursor,
        ),
      );
      expect(first.rows.single['album_name'], 'local-only');
      expect(second.rows.single['album_name'], 'missing');
      final unknown = await db.getQueueAlbumPage(
        const QueueLibraryDbQuery(
          filterMode: 'albums',
          metadata: unknownAlbumCompletenessFilter,
        ),
      );
      expect(unknown.single['album_name'], 'unknown');
      expect(AlbumCompleteness.fromRow(unknown.single)!.badge, '?');
      final hiRes = await db.getQueueAlbumPage(
        const QueueLibraryDbQuery(
          filterMode: 'albums',
          metadata: incompleteAlbumFilter,
          quality: 'hires',
        ),
      );
      expect(hiRes.single['album_name'], 'missing');
      expect(hiRes.single['album_present_tracks'], 2);
      final searched = await db.getQueueAlbumPage(
        const QueueLibraryDbQuery(
          filterMode: 'albums',
          metadata: incompleteAlbumFilter,
          searchQuery: 'one-track',
        ),
      );
      expect(searched.single['album_name'], 'one-track');
      final local = await db.getQueueAlbumPage(
        const QueueLibraryDbQuery(
          filterMode: 'albums',
          metadata: incompleteAlbumFilter,
          source: 'local',
        ),
      );
      expect(local.single['album_name'], 'local-only');
      final noLocal = await db.getQueueAlbumPage(
        const QueueLibraryDbQuery(
          filterMode: 'albums',
          metadata: incompleteAlbumFilter,
          source: 'local',
          includeLocal: false,
        ),
      );
      expect(noLocal, isEmpty);
      final normal = await db.getQueueAlbumPage(
        const QueueLibraryDbQuery(filterMode: 'albums'),
      );
      expect(normal.every((row) => row['album_completeness'] == null), isTrue);
      expect(normal.any((row) => row['album_name'] == 'one-track'), isFalse);
    },
  );

  testWidgets(
    'Material sort and filter sheets stay usable above shell navigation',
    (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final tabActive = ValueNotifier(true);
      addTearDown(tabActive.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            downloadHistoryProvider.overrideWith(_History.new),
            localLibraryProvider.overrideWith(_Local.new),
            libraryCollectionsProvider.overrideWith(_Collections.new),
            downloadQueueLookupProvider.overrideWithValue(
              const DownloadQueueLookup.empty(),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              bottomNavigationBar: const SizedBox(
                height: 140,
                child: Center(child: Text('Shell navigation')),
              ),
              body: Navigator(
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => ValueListenableBuilder<bool>(
                    valueListenable: tabActive,
                    builder: (_, active, _) => Scaffold(
                      body: TickerMode(
                        enabled: active,
                        child: QueueTab(tabActive: tabActive),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _waitFor(tester, find.text('Filters').hitTestable());
      await _waitFor(tester, find.text('Song 1').hitTestable());
      await tester.tap(find.text('Latest').hitTestable());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Shell navigation').hitTestable(), findsNothing);
      final sortSheet = find.byType(AppBottomSheet);
      // Every sort no longer fits a phone: the sheet stops at its cap and
      // scrolls, leaving the screen above it visible.
      expect(tester.getSize(sortSheet).height, closeTo(915 * 0.85, 1));
      expect(find.text('Latest').hitTestable(), findsWidgets);
      final sheetScroll = find.descendant(
        of: sortSheet,
        matching: find.byType(SingleChildScrollView),
      );
      // A downward swipe inside the list closes the sheet at its top edge.
      await tester.drag(sheetScroll, const Offset(0, 450));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(sortSheet, findsNothing);
      await tester.tap(find.text('Latest').hitTestable());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.drag(sheetScroll, const Offset(0, -450));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Genre (Z-A)').hitTestable());
      await tester.pump(const Duration(milliseconds: 400));
      await _waitFor(tester, find.text('Shell navigation').hitTestable());
      expect(find.text('Genre (Z-A)').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Filters').hitTestable());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.getSize(sortSheet).height, closeTo(915 * 0.85, 1));
      await tester.drag(sheetScroll, const Offset(0, -200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.getSize(sortSheet).height, closeTo(915 * 0.95, 1));
      // At full height, return the body to its top before swiping to dismiss.
      await tester.drag(sheetScroll, const Offset(0, 200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.drag(sheetScroll, const Offset(0, 450));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(sortSheet, findsNothing);
      await tester.tap(find.text('Filters').hitTestable());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      // The handle and reset action stay available after scrolling the body.
      await tester.drag(sheetScroll, const Offset(0, -600));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AppSheetHandle).hitTestable(), findsOneWidget);
      expect(find.text('Reset').hitTestable(), findsOneWidget);
      await tester.fling(
        find.byType(AppSheetHandle),
        const Offset(0, 300),
        1000,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(sortSheet, findsNothing);
      await tester.tap(find.text('Filters').hitTestable());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final sortChoices = find
          .ancestor(of: find.text('Title (A-Z)'), matching: find.byType(Wrap))
          .first;
      final chips = find.descendant(
        of: sortChoices,
        matching: find.byType(AppChoiceChip),
      );
      Rect? previous;
      for (final chip in chips.evaluate()) {
        final bounds = tester.getRect(find.byWidget(chip.widget));
        if (previous != null && bounds.top > previous.top + 1) {
          expect(bounds.top - previous.bottom, greaterThanOrEqualTo(8));
        }
        previous = bounds;
      }
      // Every fixture file is FLAC. Other formats must still be selectable,
      // rather than disappearing when they are absent from the loaded page.
      for (final label in [
        'M4A / MP4',
        'AAC',
        'ALAC',
        'OPUS',
        'OGG',
        'WAV',
        'AIFF',
        'WavPack',
        'DSF',
        'DFF',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Has ReplayGain'), findsOneWidget);
      await tester.ensureVisible(find.text('M4A / MP4'));
      await _waitFor(tester, find.text('M4A / MP4').hitTestable());
      await tester.tap(find.text('M4A / MP4'));
      await tester.ensureVisible(find.text('Has ReplayGain'));
      await _waitFor(tester, find.text('Has ReplayGain').hitTestable());
      await tester.tap(find.text('Has ReplayGain'));
      await tester.ensureVisible(find.text('Apply'));
      await _waitFor(tester, find.text('Apply').hitTestable());
      await tester.tap(find.text('Apply'));
      await tester.pump(const Duration(milliseconds: 400));
      await _waitFor(tester, find.text('No download history'));
      expect(find.text('Song 1'), findsNothing);
      await tester.tap(find.text('Filters').hitTestable());
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('M4A / MP4'), findsOneWidget);
      expect(find.text('Has ReplayGain'), findsOneWidget);
      await _waitFor(tester, find.text('Reset').hitTestable());
      await tester.tap(find.text('Reset'));
      await tester.ensureVisible(find.text('Incomplete albums'));
      await _waitFor(tester, find.text('Incomplete albums').hitTestable());
      await tester.tap(find.text('Incomplete albums'));
      await tester.ensureVisible(find.text('Apply'));
      await _waitFor(tester, find.text('Apply').hitTestable());
      await tester.tap(find.text('Apply'));
      await tester.pump(const Duration(milliseconds: 400));
      await _waitFor(tester, find.text('1/12'));
      expect(find.text('2/4'), findsOneWidget);
      expect(find.text('2/3'), findsOneWidget);
      expect(find.text('complete'), findsNothing);
      expect(findByTooltip('2/4 tracks · 2 missing'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(QueueTab)),
      );
      expect(container.read(settingsProvider).historyFilterMode, 'albums');

      // Pushing an album/detail route disables the underlying route's ticker.
      // Popping it must retain Albums rather than reapply the All default.
      final navigator = Navigator.of(tester.element(find.byType(QueueTab)));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Album details')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Album details'), findsOneWidget);
      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(container.read(settingsProvider).historyFilterMode, 'albums');
      await _waitFor(tester, find.text('1/12'));

      await tester.enterText(find.byType(TextField), 'one-track');
      await tester.pump(const Duration(milliseconds: 400));
      await _waitFor(tester, find.text('1 album'));
      expect(find.text('1/12'), findsOneWidget);
      expect(find.text('2/4'), findsNothing);
      // Even an empty matching result must retain the filter controls.
      await tester.enterText(find.byType(TextField), 'no-such-album');
      await tester.pump(const Duration(milliseconds: 400));
      await _waitFor(tester, find.text('No album downloads'));
      expect(find.text('Filters').hitTestable(), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      await tester.pump(const Duration(milliseconds: 400));
      await _waitFor(tester, find.text('1/12'));
      await tester.tap(find.text('Filters').hitTestable());
      await tester.pump(const Duration(milliseconds: 400));
      await _waitFor(tester, find.text('Reset').hitTestable());
      await tester.tap(find.text('Reset'));
      await tester.ensureVisible(find.text('Apply'));
      await _waitFor(tester, find.text('Apply').hitTestable());
      await tester.tap(find.text('Apply'));
      await tester.pump(const Duration(milliseconds: 400));
      await _waitFor(tester, find.text('complete'));
      expect(find.text('1/12'), findsNothing);
      expect(container.read(settingsProvider).historyFilterMode, 'albums');
      // An actual shell-tab switch still applies the configured All default.
      tabActive.value = false;
      await tester.pump();
      tabActive.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(container.read(settingsProvider).historyFilterMode, 'all');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      // Let any already-dispatched SQLite queries finish after provider disposal.
      for (var attempt = 0; attempt < 10; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    },
  );
}
