import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/system_volume_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/screens/main_shell.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart';
import 'package:mornye/widgets/desktop/desktop_navigation.dart';
import 'package:mornye/widgets/desktop/desktop_window.dart';
import 'package:mornye/widgets/expressive_navigation_bar.dart';
import 'package:mornye/widgets/mornye_bottom_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(backend, (_) async => null);
    desktopSidebarCollapsed.value = false;
    desktopSidebarLink.value = null;
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(backend, null);
    debugDesktopPlatformOverride = null;
    debugDesktopTitleBarInContentOverride = null;
    desktopSidebarCollapsed.value = false;
    desktopSidebarLink.value = null;
  });

  late _Queue queue;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> pumpShell(
    WidgetTester tester, {
    required bool desktop,
    required bool mornye,
  }) async {
    debugDesktopPlatformOverride = desktop;
    debugDesktopTitleBarInContentOverride = false;
    tester.view.physicalSize = desktop
        ? const Size(1280, 800)
        : const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => const MainShell())],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          extensionProvider.overrideWith(_Extensions.new),
          exploreProvider.overrideWith(_Explore.new),
          downloadHistoryProvider.overrideWith(_History.new),
          recentAccessProvider.overrideWith(_Recent.new),
          localLibraryProvider.overrideWith(_Local.new),
          libraryCollectionsProvider.overrideWith(_Collections.new),
          downloadQueueProvider.overrideWith(() => queue = _Queue()),
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => Stream.value(null),
          ),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(PlaybackState()),
          ),
          systemVolumeProvider.overrideWith((ref) => Stream.value(0.5)),
          desktopSidebarPlaylistsProvider.overrideWithValue(const []),
          desktopSidebarProfileProvider.overrideWithValue(null),
        ],
        child: MaterialApp.router(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    // A second frame before any time passes: Mornye's tab preload waits as
    // an idle task, and the scheduler re-arms it with zero-delay timers
    // while a frame callback is pending, which fake time never gets past.
    await tester.pump();
    await settle(tester);
  }

  /// Opens Library, pushes a probe page there and returns to Home, so the
  /// Library tab is mounted, hidden and holds a pushed page.
  Future<List<int>> pushProbeInLibrary(WidgetTester tester) async {
    final builds = [0];
    ShellNavigationService.requestTab(ShellTab.library);
    await settle(tester);
    expect(find.byType(QueueTab), findsOneWidget);
    unawaited(
      ShellNavigationService.libraryTabNavigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => _ProbePage(builds)),
      ),
    );
    await settle(tester);
    ShellNavigationService.requestTab(ShellTab.home);
    await settle(tester);
    expect(builds.single, greaterThan(0));
    expect(
      ShellNavigationService.activeTabNavigator(),
      same(ShellNavigationService.homeTabNavigatorKey.currentState),
    );
    expect(find.byType(_ProbePage, skipOffstage: false), findsOneWidget);
    return builds;
  }

  /// The widgets MainShell creates on every build (its tab navigators),
  /// the Navigators those build, and the tab root pages the routes build.
  /// An unchanged instance means its parent did not build again.
  List<Widget> shellAndPages(WidgetTester tester) => [
    for (final key in const ['tab-home', 'tab-library'])
      tester.widget(find.byKey(ValueKey(key), skipOffstage: false).last),
    ...tester.widgetList(find.byType(Navigator, skipOffstage: false)),
    ...tester.widgetList(find.byType(HomeTab, skipOffstage: false)),
    tester.widget(find.byType(QueueTab, skipOffstage: false)),
  ];

  void expectSameInstances(List<Widget> before, List<Widget> after) {
    expect(after, hasLength(before.length));
    for (var i = 0; i < before.length; i++) {
      expect(after[i], same(before[i]), reason: '${before[i]}');
    }
  }

  for (final desktop in [true, false]) {
    for (final mornye in [false, true]) {
      final platform = desktop ? 'desktop' : 'phone';
      final style = mornye ? 'Mornye' : 'Material';

      testWidgets('resizing rebuilds no shell, route or page ($platform, '
          '$style)', (tester) async {
        await pumpShell(tester, desktop: desktop, mornye: mornye);
        final probeBuilds = await pushProbeInLibrary(tester);
        final builds = probeBuilds.single;
        final before = shellAndPages(tester);

        final start = tester.view.physicalSize;
        for (var frame = 1; frame <= 10; frame++) {
          tester.view.physicalSize = start + Offset(frame * 12, frame * -6);
          await tester.pump(const Duration(milliseconds: 16));
        }
        await settle(tester);

        expect(probeBuilds.single, builds);
        expectSameInstances(before, shellAndPages(tester));
        expect(tester.takeException(), isNull);
      });

      testWidgets('a download count change rebuilds only the badges '
          '($platform, $style)', (tester) async {
        await pumpShell(tester, desktop: desktop, mornye: mornye);
        final probeBuilds = await pushProbeInLibrary(tester);
        final builds = probeBuilds.single;
        final before = shellAndPages(tester);
        expect(find.text('3'), findsNothing);

        queue.setQueued(3);
        await settle(tester);
        expect(find.text('3'), findsWidgets);

        queue.setQueued(2);
        await settle(tester);
        expect(find.text('3'), findsNothing);
        expect(find.text('2'), findsWidgets);

        expect(probeBuilds.single, builds);
        expectSameInstances(before, shellAndPages(tester));
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final desktop in [true, false]) {
    for (final mornye in [false, true]) {
      testWidgets('Library learns each switch to and from its tab '
          '(${desktop ? 'desktop' : 'phone'}, '
          '${mornye ? 'Mornye' : 'Material'})', (tester) async {
        await pumpShell(tester, desktop: desktop, mornye: mornye);
        bool libraryActive() => tester
            .widget<QueueTab>(find.byType(QueueTab, skipOffstage: false))
            .isTabActive;

        for (var round = 0; round < 2; round++) {
          ShellNavigationService.requestTab(ShellTab.library);
          await settle(tester);
          expect(libraryActive(), isTrue);
          ShellNavigationService.requestTab(ShellTab.home);
          await settle(tester);
          expect(libraryActive(), isFalse);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final mornye in [false, true]) {
    testWidgets('a phone turned into a tablet still swaps the bar for the '
        'rail (${mornye ? 'Mornye' : 'Material'})', (tester) async {
      await pumpShell(tester, desktop: false, mornye: mornye);
      unawaited(
        ShellNavigationService.homeTabNavigatorKey.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => _ProbePage([0])),
        ),
      );
      await settle(tester);
      final probe = tester.element(find.byType(_ProbePage));
      final bar = find.byType(
        mornye ? MornyeBottomBar : ExpressiveNavigationBar,
      );
      expect(bar, findsOneWidget);
      expect(find.byType(ExpressiveNavigationRail), findsNothing);

      // Past both styles' rail breakpoints.
      tester.view.physicalSize = const Size(1500, 1000);
      await settle(tester);

      expect(find.byType(ExpressiveNavigationRail), findsOneWidget);
      expect(bar, findsNothing);
      // The tab pages moved with the tab view instead of starting over.
      expect(tester.element(find.byType(_ProbePage)), same(probe));
      expect(tester.takeException(), isNull);
    });
  }
}

/// A page that reads neither the window size nor the download queue, so it
/// builds again only when something above forces it.
class _ProbePage extends StatelessWidget {
  const _ProbePage(this.builds);

  final List<int> builds;

  @override
  Widget build(BuildContext context) {
    builds[0]++;
    return const SizedBox.expand();
  }
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() =>
      const AppSettings(searchProvider: 'example', hasSearchedBefore: true);
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(isInitialized: true);
}

class _Explore extends ExploreNotifier {
  @override
  ExploreState build() => const ExploreState();
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Recent extends RecentAccessNotifier {
  @override
  RecentAccessState build() => const RecentAccessState(isLoaded: true);
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
  DownloadQueueState build() => const DownloadQueueState();

  void setQueued(int count) => state = state.copyWith(
    items: [
      for (var i = 0; i < count; i++)
        DownloadItem(
          id: 'queued-$i',
          track: Track(
            id: 'track-$i',
            name: 'Song $i',
            artistName: 'Artist',
            albumName: 'Album',
            duration: 1000,
          ),
          service: 'example-provider',
          createdAt: DateTime(2026),
        ),
    ],
  );
}
