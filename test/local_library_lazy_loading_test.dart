import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_search_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(defaultLibraryView: 'all');

  @override
  void setLocalLibraryEnabled(bool enabled) {
    state = state.copyWith(localLibraryEnabled: enabled);
  }
}

class _Local extends LocalLibraryNotifier {
  int _builds = 0;
  int _reloads = 0;

  @override
  LocalLibraryState build() {
    _builds++;
    return LocalLibraryState();
  }

  void publishIndexChange() {
    state = state.copyWith(loadedIndexVersion: state.loadedIndexVersion + 1);
  }

  @override
  Future<void> reloadFromStorage() async {
    _reloads++;
  }
}

class _History extends DownloadHistoryNotifier {
  int _reloads = 0;

  @override
  DownloadHistoryState build() => DownloadHistoryState();

  @override
  Future<void> reloadFromStorage() async {
    _reloads++;
  }
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() => DownloadQueueState();
}

class _DownloadSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(
    defaultLibraryView: 'all',
    defaultService: 'example',
    askQualityBeforeDownload: false,
  );
}

class _DownloadExtensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    extensions: [
      Extension(
        id: 'example',
        name: 'example',
        displayName: 'Example',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
      ),
    ],
  );
}

class _BatchQueue extends _Queue {
  _BatchQueue(this._record);
  final void Function(List<DownloadQueueBatch>, String, String?) _record;
  @override
  void addBatchesToQueue(
    List<DownloadQueueBatch> batches,
    String service, {
    String? qualityOverride,
  }) => _record(batches, service, qualityOverride);
}

class _SelectionCollections extends LibraryCollectionsNotifier {
  _SelectionCollections(this._record, {bool withTracks = false})
    : _withTracks = withTracks;
  final void Function(List<String>) _record;
  final bool _withTracks;

  @override
  LibraryCollectionsState build() => LibraryCollectionsState(
    isLoaded: true,
    playlists: [
      for (final id in ['First', 'Second', 'Keep'])
        UserPlaylistCollection(
          id: id,
          name: id,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          tracks: _withTracks
              ? [
                  for (var i = 0; i < (id == 'Second' ? 2 : 1); i++)
                    CollectionTrackEntry(
                      key: '$id-$i',
                      addedAt: DateTime.utc(2026),
                      track: Track(
                        id: '$id-$i',
                        name: '$id-$i',
                        artistName: 'Artist',
                        albumName: 'Album',
                        duration: 180,
                      ),
                    ),
                ]
              : const [],
        ),
    ],
  );

  @override
  Future<void> ensurePlaylistsLoaded(Iterable<String> ids) async {}

  @override
  Future<int> deletePlaylists(Iterable<String> ids) async {
    final selected = ids.toSet();
    _record(selected.toList());
    state = state.copyWith(
      playlists: state.playlists
          .where((p) => !selected.contains(p.id))
          .toList(),
    );
    return selected.length;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Local local;
  late _History history;
  late int queries;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    local = _Local();
    history = _History();
    queries = 0;
    final previousFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactorySqflitePlugin;
    addTearDown(() => databaseFactory = previousFactory);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(paths, (_) async => '/test/documents');
    addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
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
      queries++;
      return {'columns': <String>[], 'rows': <List<Object?>>[]};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(sqlite, null));
  });

  for (final mornye in [false, true]) {
    testWidgets(
      'playlist download confirms one grouped enqueue (Mornye: $mornye)',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final calls = <List<DownloadQueueBatch>>[];
        final services = <String>[];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(_DownloadSettings.new),
              extensionProvider.overrideWith(_DownloadExtensions.new),
              downloadHistoryProvider.overrideWith(() => history),
              localLibraryProvider.overrideWith(() => local),
              libraryCollectionsProvider.overrideWith(
                () => _SelectionCollections((_) {}, withTracks: true),
              ),
              downloadQueueProvider.overrideWith(
                () => _BatchQueue((batches, service, quality) {
                  calls.add(batches);
                  services.add(service);
                  expect(quality, isNull);
                }),
              ),
            ],
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.dark)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const Scaffold(body: QueueTab(librarySection: 'playlists')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final l10n = AppLocalizations.of(tester.element(find.byType(QueueTab)));
        await tester.ensureVisible(find.text('First'));
        await tester.longPress(find.text('First'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Second'));
        await tester.tap(find.text('Second'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.bulkDownloadPlaylistsButton(2)));
        await tester.pumpAndSettle();
        expect(
          find.text(l10n.dialogDownloadPlaylistsMessage(3, 2)),
          findsOneWidget,
        );
        await tester.tap(find.text(l10n.dialogCancel));
        await tester.pumpAndSettle();
        expect(calls, isEmpty);
        await tester.tap(find.text(l10n.bulkDownloadPlaylistsButton(2)));
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.dialogDownload));
        await tester.pumpAndSettle();
        expect(calls, hasLength(1));
        expect(services, ['example']);
        expect(calls.single.map((batch) => batch.playlistName), [
          'First',
          'Second',
        ]);
        expect(
          calls.single.map(
            (batch) => batch.tracks.map((track) => track.id).toList(),
          ),
          [
            ['First-0'],
            ['Second-0', 'Second-1'],
          ],
        );
        expect(find.text(l10n.snackbarAddedTracksToQueue(3)), findsOneWidget);
        expect(find.text(l10n.bulkDownloadPlaylistsButton(2)), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('playlist selection confirms one deletion (Mornye: $mornye)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = <List<String>>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            downloadHistoryProvider.overrideWith(() => history),
            localLibraryProvider.overrideWith(() => local),
            libraryCollectionsProvider.overrideWith(
              () => _SelectionCollections(calls.add),
            ),
            downloadQueueProvider.overrideWith(_Queue.new),
          ],
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark)
                : AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: QueueTab(librarySection: 'playlists')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(tester.element(find.byType(QueueTab)));
      await tester.ensureVisible(find.text('First'));
      await tester.longPress(find.text('First'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Second'));
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.selectionDeletePlaylistsCount(2)));
      await tester.pumpAndSettle();
      expect(
        find.text(l10n.collectionDeletePlaylistsMessage(2)),
        findsOneWidget,
      );
      await tester.tap(find.text(l10n.dialogCancel));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(find.text('First'), findsOneWidget);
      await tester.tap(find.text(l10n.selectionDeletePlaylistsCount(2)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.dialogDelete));
      await tester.pumpAndSettle();
      expect(calls, [
        ['First', 'Second'],
      ]);
      expect(find.text('First'), findsNothing);
      expect(find.text('Second'), findsNothing);
      expect(find.text('Keep'), findsOneWidget);
      expect(find.text(l10n.selectionDeletePlaylistsCount(2)), findsNothing);
      expect(find.text(l10n.collectionPlaylistsDeleted(2)), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test(
    'search and browse stop observing the local index when disabled',
    () async {
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          downloadHistoryProvider.overrideWith(() => history),
          localLibraryProvider.overrideWith(() => local),
        ],
      );
      addTearDown(container.dispose);
      final search = librarySearchProvider((
        query: 'Song',
        kind: LibrarySearchKind.songs,
        limit: 40,
        offset: 0,
      ));
      final browse = libraryBrowseProvider((
        artists: false,
        artist: null,
        search: '',
        sort: 'latest',
        limit: 40,
        completeness: null,
      ));
      container.listen(search, (_, _) {});
      container.listen(browse, (_, _) {});
      Future<void> settle() async {
        await container.read(search.future);
        await container.read(browse.future);
      }

      await settle();
      expect(local._builds, 0);
      container.read(settingsProvider.notifier).setLocalLibraryEnabled(true);
      await settle();
      expect(local._builds, 1);
      final enabledQueries = queries;
      local.publishIndexChange();
      await settle();
      expect(queries, greaterThan(enabledQueries));

      container.read(settingsProvider.notifier).setLocalLibraryEnabled(false);
      await settle();
      final disabledQueries = queries;
      local.publishIndexChange();
      await container.pump();
      expect(queries, disabledQueries);
      container.read(settingsProvider.notifier).setLocalLibraryEnabled(true);
      await settle();
      expect(local._builds, 1);
      expect(queries, greaterThan(disabledQueries));
    },
  );

  for (final section in ['all', 'albums']) {
    testWidgets('Queue $section stays lazy through blank-library repair', (
      tester,
    ) async {
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
            settingsProvider.overrideWith(_Settings.new),
            downloadHistoryProvider.overrideWith(() => history),
            localLibraryProvider.overrideWith(() => local),
            libraryCollectionsProvider.overrideWith(_Collections.new),
            downloadQueueProvider.overrideWith(_Queue.new),
            downloadQueueLookupProvider.overrideWithValue(queue),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: QueueTab(librarySection: section)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(history._reloads, greaterThan(0));
      expect(local._builds, 0);
      expect(local._reloads, 0);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(QueueTab)),
      );
      container.read(settingsProvider.notifier).setLocalLibraryEnabled(true);
      await tester.pumpAndSettle();
      expect(local._builds, 1);
      container.read(settingsProvider.notifier).setLocalLibraryEnabled(false);
      await tester.pumpAndSettle();
      final disabledQueries = queries;
      local.publishIndexChange();
      await tester.pumpAndSettle();
      expect(queries, disabledQueries);
    });
  }
}
