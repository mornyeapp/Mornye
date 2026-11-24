import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
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
import 'package:mornye/providers/repo_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/system_volume_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/screens/main_shell.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/player_artwork_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart';
import 'package:mornye/widgets/desktop/desktop_navigation.dart';
import 'package:mornye/widgets/desktop/desktop_window.dart';
import 'package:mornye/widgets/expressive_navigation_bar.dart';
import 'package:mornye/widgets/mini_player.dart';
import 'package:mornye/widgets/mornye_bottom_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SchedulingStrategy schedulingStrategy;

  setUp(() {
    schedulingStrategy = SchedulerBinding.instance.schedulingStrategy;
    // Idle tab preloads otherwise poll between frames under fake time.
    SchedulerBinding.instance.schedulingStrategy =
        ({required priority, required scheduler}) => true;
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(backend, (_) async => null);
    desktopSidebarCollapsed.value = false;
    desktopSidebarLink.value = null;
  });
  tearDown(() {
    SchedulerBinding.instance.schedulingStrategy = schedulingStrategy;
    messenger.setMockMethodCallHandler(backend, null);
    debugDesktopPlatformOverride = null;
    debugDesktopTitleBarInContentOverride = null;
    desktopSidebarCollapsed.value = false;
    desktopSidebarLink.value = null;
  });

  late _Queue queue;
  late _Repo repo;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> pumpShell(
    WidgetTester tester, {
    required bool desktop,
    required bool mornye,
    Stream<MediaItem?>? items,
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
          repoProvider.overrideWith(() => repo = _Repo()),
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => items ?? Stream.value(null),
          ),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(PlaybackState()),
          ),
          if (items != null)
            musicPlayerControllerProvider.overrideWithValue(_Controller()),
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

      testWidgets('switching tabs rebuilds no page of a tab ($platform, '
          '$style)', (tester) async {
        await pumpShell(tester, desktop: desktop, mornye: mornye);
        final probeBuilds = await pushProbeInLibrary(tester);
        final builds = probeBuilds.single;
        List<Widget> pages() => [
          ...tester.widgetList(find.byType(HomeTab, skipOffstage: false)),
          tester.widget(find.byType(_ProbePage, skipOffstage: false)),
        ];
        final before = pages();

        for (final tab in [
          ShellTab.library,
          ShellTab.settings,
          ShellTab.home,
        ]) {
          ShellNavigationService.requestTab(tab);
          await settle(tester);
        }

        expect(probeBuilds.single, builds);
        expectSameInstances(before, pages());
        expect(tester.takeException(), isNull);
      });

      for (final (badge, setCount) in <(String, void Function(int))>[
        ('download', (count) => queue.setQueued(count)),
        ('Store update', (count) => repo.setUpdates(count)),
      ]) {
        testWidgets('a $badge count change rebuilds only the badges '
            '($platform, $style)', (tester) async {
          await pumpShell(tester, desktop: desktop, mornye: mornye);
          final probeBuilds = await pushProbeInLibrary(tester);
          final builds = probeBuilds.single;
          final before = shellAndPages(tester);
          expect(find.text('3'), findsNothing);

          setCount(3);
          await settle(tester);
          expect(find.text('3'), findsWidgets);

          setCount(2);
          await settle(tester);
          expect(find.text('3'), findsNothing);
          expect(find.text('2'), findsWidgets);

          expect(probeBuilds.single, builds);
          expectSameInstances(before, shellAndPages(tester));
          expect(tester.takeException(), isNull);
        });
      }
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
            .tabActive!
            .value;

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

  /// The tab view's fade and the page it shows. The shell's PageView is the
  /// first in the tree; Library holds its own.
  Finder tabView() => find.byType(PageView).first;
  double tabOpacity(WidgetTester tester) => tester
      .widget<FadeTransition>(
        find
            .ancestor(of: tabView(), matching: find.byType(FadeTransition))
            .first,
      )
      .opacity
      .value;
  double? tabPage(WidgetTester tester) =>
      tester.widget<PageView>(tabView()).controller!.page;

  for (final desktop in [true, false]) {
    final platform = desktop ? 'desktop' : 'phone';
    testWidgets('Material destinations fade through instead of sliding '
        '($platform)', (tester) async {
      await pumpShell(tester, desktop: desktop, mornye: false);
      expect(tabOpacity(tester), 1);

      ShellNavigationService.requestTab(ShellTab.library);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      // The page shown fades out first.
      expect(tabPage(tester), 0.0);
      final leaving = tabOpacity(tester);
      expect(leaving, inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 32));
      expect(tabPage(tester), 0.0);
      expect(tabOpacity(tester), lessThan(leaving));
      // Then the new page fades in.
      await tester.pump(const Duration(milliseconds: 60));
      expect(tabPage(tester), 1.0);
      final entering = tabOpacity(tester);
      expect(entering, lessThan(1));
      await tester.pump(const Duration(milliseconds: 32));
      expect(tabPage(tester), 1.0);
      expect(tabOpacity(tester), greaterThan(entering));
      await settle(tester);
      expect(tabPage(tester), 1.0);
      expect(tabOpacity(tester), 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a destination change during the fade in fades out from '
        'where it is ($platform)', (tester) async {
      await pumpShell(tester, desktop: desktop, mornye: false);
      ShellNavigationService.requestTab(ShellTab.library);
      await tester.pump();
      // Past the fade out and partly into the fade in.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 48));
      expect(tabPage(tester), 1.0);
      final shown = tabOpacity(tester);
      expect(shown, inExclusiveRange(0.05, 1));

      ShellNavigationService.requestTab(ShellTab.home);
      await tester.pump();
      // The page does not start again from nothing, nor jump yet.
      expect(tabPage(tester), 1.0);
      expect(tabOpacity(tester), closeTo(shown, 0.001));
      await tester.pump(const Duration(milliseconds: 16));
      expect(tabOpacity(tester), lessThan(shown));
      await settle(tester);
      expect(tabPage(tester), 0.0);
      expect(tabOpacity(tester), 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reduced motion switches Material destinations at once '
        '($platform)', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await pumpShell(tester, desktop: desktop, mornye: false);

      ShellNavigationService.requestTab(ShellTab.library);
      await tester.pump();
      expect(tabPage(tester), 1.0);
      expect(tabOpacity(tester), 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('rapid Material destination changes settle on the last one '
        '($platform)', (tester) async {
      await pumpShell(tester, desktop: desktop, mornye: false);
      ShellNavigationService.requestTab(ShellTab.library);
      await settle(tester);
      final home = tester.state(find.byType(HomeTab, skipOffstage: false));
      final library = tester.state(find.byType(QueueTab, skipOffstage: false));

      // Two requests in one frame, then one per frame mid-fade.
      ShellNavigationService.requestTab(ShellTab.settings);
      ShellNavigationService.requestTab(ShellTab.home);
      await tester.pump();
      for (final tab in [ShellTab.library, ShellTab.settings, ShellTab.home]) {
        ShellNavigationService.requestTab(tab);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await settle(tester);

      expect(tabPage(tester), 0.0);
      expect(tabOpacity(tester), 1);
      // One page paints at rest; the others keep their state offstage.
      expect(find.byType(HomeTab), findsOneWidget);
      expect(find.byType(QueueTab), findsNothing);
      expect(
        tester.state(find.byType(HomeTab, skipOffstage: false)),
        same(home),
      );
      expect(
        tester.state(find.byType(QueueTab, skipOffstage: false)),
        same(library),
      );
      expect(tester.takeException(), isNull);
    });
  }

  /// The widget [type]'s state built last; a new instance means its state
  /// built again.
  Widget builtBy(WidgetTester tester, Type type) {
    late Widget child;
    tester
        .element(find.byType(type, skipOffstage: false).first)
        .visitChildElements((element) => child = element.widget);
    return child;
  }

  for (final desktop in [true, false]) {
    for (final mornye in [false, true]) {
      testWidgets('a switch of tab builds neither Home nor Library again '
          '(${desktop ? 'desktop' : 'phone'}, '
          '${mornye ? 'Mornye' : 'Material'})', (tester) async {
        await pumpShell(tester, desktop: desktop, mornye: mornye);
        ShellNavigationService.requestTab(ShellTab.library);
        await settle(tester);
        ShellNavigationService.requestTab(ShellTab.home);
        await settle(tester);
        final home = builtBy(tester, HomeTab);
        final library = builtBy(tester, QueueTab);

        for (final tab in [
          ShellTab.library,
          ShellTab.settings,
          ShellTab.home,
        ]) {
          ShellNavigationService.requestTab(tab);
          await settle(tester);
        }

        expect(builtBy(tester, HomeTab), same(home));
        expect(builtBy(tester, QueueTab), same(library));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('desktop Material width changes rebuild neither Home nor a '
      'hidden Library', (tester) async {
    await pumpShell(tester, desktop: true, mornye: false);
    ShellNavigationService.requestTab(ShellTab.library);
    await settle(tester);
    ShellNavigationService.requestTab(ShellTab.home);
    await settle(tester);
    final home = builtBy(tester, HomeTab);
    final library = builtBy(tester, QueueTab);
    Size librarySize() => MediaQuery.sizeOf(
      tester.element(find.byType(QueueTab, skipOffstage: false).first),
    );
    final hiddenSize = librarySize();

    // Width-only frames, as in a live edge drag or the rail expanding.
    for (var frame = 1; frame <= 10; frame++) {
      tester.view.physicalSize = Size(1280.0 + frame * 12, 800);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await settle(tester);
    expect(builtBy(tester, HomeTab), same(home));
    expect(builtBy(tester, QueueTab), same(library));

    // Home follows a height change; the hidden Library keeps its size.
    tester.view.physicalSize = const Size(1400, 760);
    await settle(tester);
    expect(builtBy(tester, HomeTab), isNot(same(home)));
    expect(builtBy(tester, QueueTab), same(library));
    expect(librarySize(), hiddenSize);

    // Library takes the new size when it shows again.
    ShellNavigationService.requestTab(ShellTab.library);
    await settle(tester);
    expect(librarySize(), isNot(hiddenSize));
    expect(
      librarySize().height,
      MediaQuery.sizeOf(
        tester.element(find.byType(HomeTab, skipOffstage: false).first),
      ).height,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a Material rail playlist link fades in like a destination', (
    tester,
  ) async {
    await pumpShell(tester, desktop: true, mornye: false);
    ShellNavigationService.requestTab(ShellTab.library);
    await settle(tester);
    expect(tabOpacity(tester), 1);

    tester
        .widget<DesktopShellLayout>(find.byType(DesktopShellLayout))
        .onOpenLibraryLink!(DesktopSidebarLink.allPlaylistsId);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(desktopSidebarLink.value, DesktopSidebarLink.allPlaylistsId);
    expect(tabOpacity(tester), inExclusiveRange(0, 1));
    await settle(tester);
    expect(tabOpacity(tester), 1);
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('a song change swaps the Material bar scheme at once and fades '
      'only its fills', (tester) async {
    final a = ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: Brightness.dark,
    );
    final b = ColorScheme.fromSeed(
      seedColor: Colors.red,
      brightness: Brightness.dark,
    );
    PlayerArtworkTheme.debugPalette = _Palette({
      '/covers/a.jpg': a,
      '/covers/b.jpg': b,
    });
    addTearDown(() => PlayerArtworkTheme.debugPalette = null);
    final items = StreamController<MediaItem?>.broadcast();
    addTearDown(items.close);
    await pumpShell(tester, desktop: false, mornye: false, items: items.stream);
    MediaItem song(String id) => MediaItem(
      id: id,
      title: 'Song $id',
      artist: 'Artist',
      duration: const Duration(minutes: 3),
      artUri: Uri.file('/covers/$id.jpg'),
    );
    items.add(song('a'));
    await settle(tester);

    final bar = find.byType(ExpressiveNavigationBar);
    final mini = find
        .descendant(of: find.byType(MiniPlayer), matching: find.byType(InkWell))
        .first;
    ColorScheme scheme() => Theme.of(tester.element(bar)).colorScheme;
    // The fills of the navigation bar and of the mini player above it.
    List<Color> fills() => [
      for (final part in [bar, mini])
        tester
            .widget<ColoredBox>(
              find
                  .descendant(
                    of: find
                        .ancestor(
                          of: part,
                          matching: find.byType(PlayerArtworkSurface),
                        )
                        .first,
                    matching: find.byType(ColoredBox),
                  )
                  .first,
            )
            .color,
    ];
    expect(scheme(), a);
    final from = fills();

    items.add(song('b'));
    // The first frame takes the new track, the next one builds with it.
    await tester.pump();
    await tester.pump();
    expect(scheme(), b);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(scheme(), b);
    }
    final moving = fills();
    await settle(tester);
    final to = fills();
    for (var i = 0; i < 2; i++) {
      expect(to[i], isNot(from[i]));
      expect(moving[i], isNot(from[i]));
      expect(moving[i], isNot(to[i]));
    }
    // At rest both are the dark group tint over the new cover's surface, at
    // the bar's opacity.
    final tinted = Color.alphaBlend(
      Colors.white.withValues(alpha: 0.08),
      b.surface,
    );
    expect(to, everyElement(tinted.withValues(alpha: tinted.a * 0.72)));
    expect(tester.takeException(), isNull);
  });
}

/// Answers each cover's scheme at once, without decoding an image.
class _Palette extends PlayerArtworkPalette {
  const _Palette(this.schemes);

  final Map<String, ColorScheme> schemes;

  @override
  ColorScheme? peek(String source, Brightness brightness) => schemes[source];

  @override
  Future<ColorScheme?> resolve(String source, Brightness brightness) =>
      Future.value(schemes[source]);
}

class _Controller implements MusicPlayerController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

class _Repo extends RepoNotifier {
  @override
  RepoState build() => const RepoState(isInitialized: true);

  @override
  Future<void> initialize(String cacheDir) async {}

  void setUpdates(int count) => state = state.copyWith(
    extensions: [
      for (var i = 0; i < count; i++)
        RepoExtension(
          id: 'extension-$i',
          name: 'extension-$i',
          displayName: 'Extension $i',
          version: '1.0.0',
          description: '',
          category: RepoCategory.metadata,
          updatedAt: '2026-01-01',
          isInstalled: true,
          hasUpdate: true,
        ),
    ],
  );
}
