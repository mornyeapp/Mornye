import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/home_recommendations_provider.dart';
import 'package:mornye/providers/home_status_provider.dart';
import 'package:mornye/providers/home_top_picks_provider.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/weekly_releases_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/services/weekly_releases.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

DownloadHistoryItem _entry(String id, DateTime at) => DownloadHistoryItem(
  id: id,
  trackName: 'Song $id',
  artistName: 'Artist',
  albumName: 'Album',
  filePath: '/music/$id.flac',
  service: 'example-provider',
  downloadedAt: at,
);

DownloadItem _item(String id, DownloadStatus status, {double progress = 0}) =>
    DownloadItem(
      id: id,
      track: Track(
        id: 'track-$id',
        name: 'Song $id',
        artistName: 'Example artist',
        albumName: 'Album',
        duration: 200,
      ),
      service: 'example-provider',
      status: status,
      progress: progress,
      createdAt: DateTime(2026, 11, 23),
    );

class _Queue extends DownloadQueueNotifier {
  _Queue(this.initial);

  final DownloadQueueState initial;

  @override
  DownloadQueueState build() => initial;

  void put(List<DownloadItem> items) => state = state.copyWith(items: items);
}

class _History extends DownloadHistoryNotifier {
  _History([this.items = const []]);

  final List<DownloadHistoryItem> items;

  @override
  DownloadHistoryState build() =>
      DownloadHistoryState(items: items, totalCount: items.length);
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

class _Recent extends RecentAccessNotifier {
  @override
  RecentAccessState build() => const RecentAccessState(isLoaded: true);
}

/// Home with nothing else to show, its status and queue as given.
Widget _home({
  required bool mornye,
  bool player = true,
  HomeArrivals arrivals = (count: 0, sinceYesterday: false),
  int downloading = 0,
  HomeQueueSummary queue = (
    currentId: null,
    active: 0,
    waiting: 0,
    failed: 0,
    paused: false,
  ),
  List<DownloadItem> items = const [],
  int finishedToday = 0,
}) => ProviderScope(
  overrides: [
    homeRecommendationsProvider.overrideWith((ref) async => const <Track>[]),
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
    homeLibraryAlbumsProvider.overrideWith((ref) async => const []),
    playerUiEnabledProvider.overrideWithValue(player),
    currentMediaItemProvider.overrideWithBuild(
      (ref, notifier) => Stream<MediaItem?>.value(null),
    ),
    playbackResumeProvider.overrideWith((ref) async => null),
    homeArrivalsProvider.overrideWithValue(arrivals),
    homeActiveDownloadsProvider.overrideWithValue(downloading),
    homeQueueSummaryProvider.overrideWithValue(queue),
    homeFinishedTodayProvider.overrideWithValue(finishedToday),
    downloadQueueLookupProvider.overrideWithValue(
      DownloadQueueLookup.fromItems(items),
    ),
  ],
  child: MaterialApp(
    theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const HomeTab(mode: HomeTabMode.browse),
  ),
);

Future<void> _open(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(home);
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('status data', () {
    final now = DateTime(2026, 11, 23, 9);

    test('arrivals count only the window between the two visits', () {
      final items = [
        _entry('before', DateTime(2026, 11, 22, 7)),
        _entry('one', DateTime(2026, 11, 22, 21)),
        _entry('two', DateTime(2026, 11, 23, 8, 59)),
        _entry('after', DateTime(2026, 11, 23, 9, 30)),
      ];
      expect(
        countHomeArrivals(items, since: DateTime(2026, 11, 22, 20), until: now),
        2,
      );
    });

    test('finished today follows the local calendar day', () {
      final items = [
        _entry('yesterday', DateTime(2026, 11, 22, 23, 59)),
        _entry('morning', DateTime(2026, 11, 23, 0, 1)),
        _entry('later', DateTime(2026, 11, 23, 8)),
      ];
      expect(countFinishedOnDay(items, now), 2);
    });

    test('a visit the day before reads as yesterday', () {
      expect(isDayBefore(DateTime(2026, 11, 22, 23), now), isTrue);
      expect(isDayBefore(DateTime(2026, 11, 23, 1), now), isFalse);
      expect(isDayBefore(DateTime(2026, 11, 20), now), isFalse);
      expect(
        isDayBefore(DateTime(2026, 2, 28, 12), DateTime(2026, 3, 1, 8)),
        isTrue,
      );
    });

    test('the queue summary leads with the song downloading now', () {
      final summary = homeQueueSummary(
        DownloadQueueState(
          items: [
            _item('done', DownloadStatus.completed),
            _item('now', DownloadStatus.downloading, progress: 0.4),
            _item('next', DownloadStatus.queued),
            _item('later', DownloadStatus.queued),
            _item('broken', DownloadStatus.failed),
          ],
          lookup: DownloadQueueLookup.fromItems([
            _item('done', DownloadStatus.completed),
            _item('now', DownloadStatus.downloading, progress: 0.4),
            _item('next', DownloadStatus.queued),
            _item('later', DownloadStatus.queued),
            _item('broken', DownloadStatus.failed),
          ]),
        ),
      );
      expect(summary, (
        currentId: 'now',
        active: 3,
        waiting: 2,
        failed: 1,
        paused: false,
      ));
    });

    test('a progress sample within a percent changes nothing', () {
      final lookup = DownloadQueueLookup.fromItems([
        _item('now', DownloadStatus.downloading, progress: 0.421),
      ]);
      final later = DownloadQueueLookup.fromItems([
        _item('now', DownloadStatus.downloading, progress: 0.428),
      ]);
      expect(
        homeDownloadingSong(lookup, 'now'),
        homeDownloadingSong(later, 'now'),
      );
      expect(homeDownloadingSong(lookup, 'now')?.percent, 42);
      expect(homeDownloadingSong(lookup, 'missing'), isNull);
    });

    test('Home sections do not hear progress samples', () async {
      final queue = _Queue(
        DownloadQueueState(
          items: [_item('now', DownloadStatus.downloading, progress: 0.1)],
          lookup: DownloadQueueLookup.fromItems([
            _item('now', DownloadStatus.downloading, progress: 0.1),
          ]),
        ),
      );
      final container = ProviderContainer(
        overrides: [downloadQueueProvider.overrideWith(() => queue)],
      );
      addTearDown(container.dispose);
      var summaries = 0;
      var counts = 0;
      container.listen(homeQueueSummaryProvider, (_, _) => summaries++);
      container.listen(homeActiveDownloadsProvider, (_, _) => counts++);
      Future<void> settle() => Future<void>.delayed(Duration.zero);
      queue.put([_item('now', DownloadStatus.downloading, progress: 0.5)]);
      await settle();
      queue.put([_item('now', DownloadStatus.downloading, progress: 0.9)]);
      await settle();
      expect(summaries, 0);
      expect(counts, 0);
      queue.put([
        _item('now', DownloadStatus.downloading, progress: 0.9),
        _item('next', DownloadStatus.queued),
      ]);
      await settle();
      expect(summaries, 1);
      expect(counts, 1);
    });

    test('the visit window reads the previous session and records this '
        'one', () async {
      SharedPreferences.setMockInitialValues({});
      DateTime Function() clock(DateTime at) =>
          () => at;
      final first = ProviderContainer(
        overrides: [
          homeStatusClockProvider.overrideWithValue(
            clock(DateTime(2026, 11, 22, 20)),
          ),
        ],
      );
      addTearDown(first.dispose);
      expect(await first.read(homeVisitWindowProvider.future), (
        previous: null,
        current: DateTime(2026, 11, 22, 20),
      ));

      final second = ProviderContainer(
        overrides: [
          homeStatusClockProvider.overrideWithValue(clock(now)),
          downloadHistoryProvider.overrideWith(
            () => _History([
              _entry('old', DateTime(2026, 11, 21)),
              _entry('one', DateTime(2026, 11, 22, 22)),
              _entry('two', DateTime(2026, 11, 23, 6)),
            ]),
          ),
        ],
      );
      addTearDown(second.dispose);
      final window = await second.read(homeVisitWindowProvider.future);
      expect(window.previous, DateTime(2026, 11, 22, 20));
      expect(second.read(homeArrivalsProvider), (
        count: 2,
        sinceYesterday: true,
      ));
    });

    test('a first visit counts nothing', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          downloadHistoryProvider.overrideWith(
            () => _History([_entry('one', DateTime.now())]),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(homeVisitWindowProvider.future);
      expect(container.read(homeArrivalsProvider).count, 0);
    });
  });

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('the status line joins what is true under the title '
        '($style)', (tester) async {
      final requested = <ShellTab>[];
      final links = <String>[];
      final owner = Object();
      ShellNavigationService.registerTabSelectionHandler(
        owner: owner,
        handler: requested.add,
        libraryLinkHandler: (id) {
          links.add(id);
          return true;
        },
      );
      addTearDown(
        () => ShellNavigationService.unregisterTabSelectionHandler(owner),
      );
      await _open(
        tester,
        _home(
          mornye: mornye,
          arrivals: (count: 12, sinceYesterday: true),
          downloading: 3,
        ),
      );
      expect(tester.takeException(), isNull);

      final added = find.text('12 songs added since yesterday');
      final downloading = find.text('3 downloading');
      expect(added, findsOneWidget);
      expect(downloading, findsOneWidget);
      expect(find.text(' · '), findsOneWidget);
      // One line, right under the header.
      final header = tester.getRect(
        find.descendant(
          of: find.byType(AppSliverHeader),
          matching: find.byType(FlexibleSpaceBar),
        ),
      );
      final line = tester.getRect(added);
      expect(line.top, greaterThanOrEqualTo(header.bottom));
      expect(line.top - header.bottom, lessThan(16));
      expect(tester.getRect(downloading).top, line.top);
      expect(
        tester.getRect(downloading).left,
        greaterThan(tester.getRect(added).left),
      );

      await tester.tap(added);
      expect(requested, [ShellTab.library]);
      await tester.tap(downloading);
      expect(links, ['downloads']);
    });

    testWidgets('a long status line stays on one line ($style)', (
      tester,
    ) async {
      // Narrower than the two parts at their own widths.
      tester.view.physicalSize = const Size(300, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _home(
          mornye: mornye,
          arrivals: (count: 1200, sinceYesterday: false),
          downloading: 300,
        ),
      );
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
      final added = find.text('1200 songs added since your last visit');
      final downloading = find.text('300 downloading');
      expect(added, findsOneWidget);
      expect(downloading, findsOneWidget);
      expect(tester.getRect(downloading).top, tester.getRect(added).top);
      expect(tester.getRect(downloading).right, lessThanOrEqualTo(300));
    });

    testWidgets('nothing true leaves no status line ($style)', (tester) async {
      await _open(tester, _home(mornye: mornye));
      expect(tester.takeException(), isNull);
      expect(find.text(' · '), findsNothing);
      expect(find.textContaining('downloading'), findsNothing);
    });

    testWidgets('Home with the built-in player has no downloads section '
        '($style)', (tester) async {
      await _open(tester, _home(mornye: mornye, finishedToday: 4));
      expect(tester.takeException(), isNull);
      expect(find.text('Downloads'), findsNothing);
      expect(find.text('Nothing downloading'), findsNothing);
    });

    testWidgets('download focus leads Home with the song downloading now '
        '($style)', (tester) async {
      final links = <String>[];
      final owner = Object();
      ShellNavigationService.registerTabSelectionHandler(
        owner: owner,
        handler: (_) {},
        libraryLinkHandler: (id) {
          links.add(id);
          return true;
        },
      );
      addTearDown(
        () => ShellNavigationService.unregisterTabSelectionHandler(owner),
      );
      await _open(
        tester,
        _home(
          mornye: mornye,
          player: false,
          downloading: 4,
          queue: (
            currentId: 'now',
            active: 3,
            waiting: 2,
            failed: 1,
            paused: false,
          ),
          items: [_item('now', DownloadStatus.downloading, progress: 0.42)],
          finishedToday: 12,
        ),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('Downloads'), findsOneWidget);
      expect(find.text('Song now'), findsOneWidget);
      expect(find.text('Example artist · 42%'), findsOneWidget);
      expect(
        find.text('2 waiting · 12 finished today · 1 failed'),
        findsOneWidget,
      );
      final progress = tester.widget<AppProgressIndicator>(
        find.byType(AppProgressIndicator),
      );
      expect(progress.value, closeTo(0.42, 0.001));
      // The section shows the queue, so the status line leaves it out.
      expect(find.text('4 downloading'), findsNothing);
      // It comes before the Material Shortcuts.
      if (!mornye) {
        expect(
          tester.getRect(find.text('Downloads')).top,
          lessThan(tester.getRect(find.text('Shortcuts')).top),
        );
      }

      await tester.tap(find.text('Song now'));
      expect(links, ['downloads']);
    });

    testWidgets('an idle download focus is one compact row ($style)', (
      tester,
    ) async {
      await _open(
        tester,
        _home(mornye: mornye, player: false, finishedToday: 5),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Downloads'), findsOneWidget);
      expect(find.text('Nothing downloading'), findsOneWidget);
      expect(find.text('5 finished today'), findsOneWidget);
      expect(find.byType(AppProgressIndicator), findsNothing);
    });

    testWidgets('a queue that only waits leads with the wait ($style)', (
      tester,
    ) async {
      await _open(
        tester,
        _home(
          mornye: mornye,
          player: false,
          queue: (
            currentId: null,
            active: 2,
            waiting: 2,
            failed: 0,
            paused: true,
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Downloads paused'), findsOneWidget);
      expect(find.text('2 waiting'), findsOneWidget);
      expect(find.text('Nothing downloading'), findsNothing);
    });
  }
}
