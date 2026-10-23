import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/system_volume_provider.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/services/user_profile_store.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart';
import 'package:mornye/widgets/desktop/desktop_downloads_button.dart';
import 'package:mornye/widgets/desktop/desktop_navigation.dart';
import 'package:mornye/widgets/desktop/desktop_player_bar.dart';
import 'package:mornye/widgets/desktop/desktop_shortcuts.dart';
import 'package:mornye/widgets/desktop/desktop_window.dart';
import 'package:mornye/widgets/expressive_navigation_bar.dart';
import 'package:mornye/widgets/mini_player.dart';
import 'package:mornye/widgets/mornye_bottom_bar.dart';

class _FakeController implements MusicPlayerController {
  final calls = <String>[];

  @override
  Future<void> togglePlayPause(bool isPlaying) async =>
      calls.add(isPlaying ? 'pause' : 'play');

  @override
  Future<void> next() async => calls.add('next');

  @override
  Future<void> previous() async => calls.add('previous');

  @override
  Future<void> seek(Duration position) async => calls.add('seek');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _track = MediaItem(
  id: 'track',
  title: 'A song',
  artist: 'An artist',
  duration: Duration(minutes: 3),
);

final _playlist = UserPlaylistCollection(
  id: 'mix',
  name: 'Road trip',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  tracks: const [],
);

const _libraryLinks = [
  DesktopSidebarLink(
    id: 'recent',
    icon: Icons.schedule,
    label: 'Recently Added',
  ),
  DesktopSidebarLink(id: 'albums', icon: Icons.album, label: 'Albums'),
];

List<DesktopDestination> _destinations({required bool mornye}) => [
  for (final tab in desktopDestinationTabs(mornye: mornye, showStore: true))
    DesktopDestination(
      tab: tab,
      icon: Icons.circle_outlined,
      selectedIcon: Icons.circle,
      label: tab.name,
      badgeCount: tab == ShellTab.library ? 2 : 0,
    ),
];

void main() {
  late _FakeController controller;
  late List<double> volumeWrites;
  late List<ShellTab> selections;

  setUp(() {
    debugDesktopPlatformOverride = true;
    debugDesktopTitleBarInContentOverride = false;
    desktopSidebarCollapsed.value = false;
    desktopSidebarLink.value = null;
    controller = _FakeController();
    volumeWrites = [];
    selections = [];
  });

  tearDown(() {
    debugDesktopPlatformOverride = null;
    debugDesktopTitleBarInContentOverride = null;
    desktopSidebarCollapsed.value = false;
    desktopSidebarLink.value = null;
  });

  List<Override> overrides({MediaItem? item = _track, bool playing = false}) =>
      [
        currentMediaItemProvider.overrideWithBuild(
          (ref, notifier) => Stream.value(item),
        ),
        playbackStateProvider.overrideWith(
          (ref) => Stream.value(PlaybackState(playing: playing)),
        ),
        musicPlayerControllerProvider.overrideWithValue(controller),
        systemVolumeProvider.overrideWith((ref) => Stream.value(0.5)),
        systemVolumeWriterProvider.overrideWithValue((value) async {
          volumeWrites.add(value);
        }),
        desktopSidebarPlaylistsProvider.overrideWithValue([_playlist]),
        desktopSidebarProfileProvider.overrideWithValue(
          const UserProfile(name: 'Ada Lovelace'),
        ),
      ];

  Future<void> pumpShell(
    WidgetTester tester, {
    required bool mornye,
    required double width,
    MediaItem? item = _track,
    List<DesktopSidebarLink> libraryLinks = const [],
    ValueChanged<String>? onOpenLibraryLink,
    VoidCallback? onOpenProfile,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(item: item),
        child: MaterialApp(
          theme: mornye
              ? MornyeTheme.build(Brightness.light)
              : AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: DesktopShellLayout(
              destinations: _destinations(mornye: mornye),
              selected: ShellTab.home,
              onSelected: selections.add,
              libraryLinks: libraryLinks,
              onOpenLibraryLink: onOpenLibraryLink,
              onOpenProfile: onOpenProfile,
              body: const Center(child: Text('content')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The page shown in the content pane.
  Finder contentPage() => find
      .ancestor(of: find.text('content'), matching: find.byType(Center))
      .first;

  void expectNoTouchNavigation() {
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(ExpressiveNavigationBar), findsNothing);
    expect(find.byType(MornyeBottomBar), findsNothing);
    expect(find.byType(MiniPlayer), findsNothing);
  }

  group('Material shell', () {
    testWidgets('collapses the rail at 900 and shows the player bar', (
      tester,
    ) async {
      await pumpShell(tester, mornye: false, width: 900);

      expect(find.byType(DesktopNavigationRail), findsOneWidget);
      // Narrow windows keep the rail collapsed even when it was expanded.
      expect(
        tester.getSize(find.byType(DesktopNavigationRail)).width,
        closeTo(desktopCollapsedRailWidth, 0.5),
      );
      expect(find.byType(DesktopSidebar), findsNothing);
      expectNoTouchNavigation();
      expect(find.byType(DesktopPlayerBar), findsOneWidget);
      expect(
        tester.getSize(find.byType(DesktopPlayerBar)).height,
        DesktopPlayerBar.materialHeight,
      );
      expect(find.text('A song'), findsOneWidget);
      expect(find.text('content'), findsOneWidget);
    });

    testWidgets('expanded rail at 1400 keeps Settings at the bottom', (
      tester,
    ) async {
      await pumpShell(tester, mornye: false, width: 1400);

      expect(
        tester.getSize(find.byType(DesktopNavigationRail)).width,
        desktopSidebarWidth,
      );
      expectNoTouchNavigation();
      final home = tester.getTopLeft(find.text('home'));
      final settings = tester.getTopLeft(find.text('settings'));
      // Settings sits at the bottom of the rail, just above the player bar,
      // aligned with the destinations above it.
      expect(settings.dy, greaterThan(600));
      expect(settings.dx, closeTo(home.dx, 1));

      await tester.tap(find.text('settings'));
      await tester.tap(find.text('library'));
      expect(selections, [ShellTab.settings, ShellTab.library]);
    });

    testWidgets('player bar names its shortcuts and runs the transport', (
      tester,
    ) async {
      await pumpShell(tester, mornye: false, width: 1400);

      expect(find.byTooltip('Next track (Ctrl+Right)'), findsOneWidget);
      expect(find.byTooltip('Previous track (Ctrl+Left)'), findsOneWidget);
      expect(find.byTooltip('Play (Space)'), findsOneWidget);
      expect(find.byTooltip('Lyrics (Ctrl+Shift+L)'), findsOneWidget);
      expect(find.byTooltip('Up next (Ctrl+Shift+U)'), findsOneWidget);

      await tester.tap(find.byTooltip('Next track (Ctrl+Right)'));
      await tester.tap(find.byTooltip('Play (Space)'));
      expect(controller.calls, ['next', 'play']);
    });

    testWidgets('idle player bar stays in place with disabled controls', (
      tester,
    ) async {
      await pumpShell(tester, mornye: false, width: 900, item: null);

      expect(find.byType(DesktopPlayerBar), findsOneWidget);
      expect(find.text('Not playing'), findsOneWidget);
      await tester.tap(find.byTooltip('Next track (Ctrl+Right)'));
      expect(controller.calls, isEmpty);
    });

    testWidgets('pages start at the top with no shell search bar', (
      tester,
    ) async {
      await pumpShell(tester, mornye: false, width: 1400);

      // Home and Library bring their own search fields, so the shell adds
      // no second one above them.
      expect(tester.getRect(contentPage()).top, 0);
      // Downloads live in the player bar on every page.
      expect(find.byType(DesktopDownloadsButton), findsOneWidget);
    });

    testWidgets('expanded rail keeps a gap between indicators', (tester) async {
      await pumpShell(tester, mornye: false, width: 1400);

      final home = tester.getRect(find.text('home'));
      final library = tester.getRect(find.text('library'));
      // 56dp indicators with an 8dp gap: label centers 64dp apart.
      expect(library.center.dy - home.center.dy, closeTo(56 + 8, 0.5));
    });

    testWidgets('rail starts collapsed with no menu button', (tester) async {
      desktopSidebarCollapsed.value = true;
      await pumpShell(tester, mornye: false, width: 1400);
      double railWidth() =>
          tester.getSize(find.byType(DesktopNavigationRail)).width;
      expect(railWidth(), closeTo(desktopCollapsedRailWidth, 0.5));
      for (final icon in [Icons.menu, Icons.menu_open]) {
        expect(
          find.byWidgetPredicate((w) => w is AppIcon && w.icon == icon),
          findsNothing,
        );
      }

      // The sidebar shortcut expands it; halfway, the rail is between its
      // widths with one label showing.
      desktopSidebarCollapsed.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(railWidth(), greaterThan(desktopCollapsedRailWidth));
      expect(railWidth(), lessThan(desktopSidebarWidth));
      expect(find.text('library'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(railWidth(), closeTo(desktopSidebarWidth, 0.5));
    });

    testWidgets('expanded rail pills hug their labels and take the clicks', (
      tester,
    ) async {
      await pumpShell(tester, mornye: false, width: 1400);

      final library = tester.getRect(find.text('library'));
      final settings = tester.getRect(find.text('settings'));
      // Beside a pill, inside the rail: nothing happens.
      final rail = tester.getRect(find.byType(DesktopNavigationRail));
      await tester.tapAt(Offset(rail.right - 12, library.center.dy));
      await tester.tapAt(Offset(rail.right - 12, settings.center.dy));
      expect(selections, isEmpty);

      // On the pill, just past the label: selects.
      await tester.tapAt(Offset(library.right + 8, library.center.dy));
      await tester.tapAt(Offset(settings.right + 8, settings.center.dy));
      expect(selections, [ShellTab.library, ShellTab.settings]);
    });
  });

  group('Mornye shell', () {
    for (final width in [900.0, 1400.0]) {
      testWidgets('shows the sidebar and player bar at $width', (tester) async {
        await pumpShell(tester, mornye: true, width: width);

        expect(find.byType(DesktopSidebar), findsOneWidget);
        expect(
          tester.getSize(find.byType(DesktopSidebar)).width,
          DesktopSidebar.footprint,
        );
        // The Material rail must not appear in the Mornye style.
        expect(find.byType(DesktopNavigationRail), findsNothing);
        expect(find.byType(NavigationRail), findsNothing);
        expectNoTouchNavigation();
        expect(find.byType(DesktopPlayerBar), findsOneWidget);
        expect(find.text('A song'), findsOneWidget);
        expect(find.byKey(const ValueKey('desktop-sidebar-search')), findsOne);
      });
    }

    testWidgets('player capsule floats centered over the content pane', (
      tester,
    ) async {
      await pumpShell(tester, mornye: true, width: 1235);

      final player = tester.getRect(find.byType(DesktopPlayerBar));
      final pane = tester.getRect(
        find.byKey(const ValueKey('desktop-content')),
      );
      expect(player.height, DesktopPlayerBar.mornyeHeight);
      expect(player.bottom, 800 - DesktopPlayerBar.floatingMargin);
      expect(player.center.dx, closeTo(pane.center.dx, 0.5));
      expect(
        player.width,
        closeTo(DesktopPlayerBar.floatingWidth(pane.width), 0.01),
      );
      expect(player.width, inInclusiveRange(650, 750));
      // Pages scroll under it, so the pane reaches the window bottom.
      expect(pane.bottom, 800);
      expect(DesktopPlayerBar.floatingWidth(700), 520);
      expect(DesktopPlayerBar.floatingWidth(500), 476);
      expect(DesktopPlayerBar.floatingWidth(2000), 900);
    });

    testWidgets('player capsule keeps volume in a popover', (tester) async {
      await pumpShell(tester, mornye: true, width: 1400);

      expect(find.byType(Slider), findsOneWidget, reason: 'seek bar only');
      playbackOutputVolume.value = 0.5;
      addTearDown(() => playbackOutputVolume.value = 1);
      tester.binding.handlePointerEvent(
        PointerScrollEvent(
          position: tester.getCenter(
            find.byKey(const ValueKey('desktop-player-volume')),
          ),
          scrollDelta: const Offset(0, -20),
        ),
      );
      await tester.pump();
      expect(volumeWrites.single, closeTo(0.55, 0.000001));
      expect(
        find.byKey(const ValueKey('desktop-player-volume-popover')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('desktop-player-volume')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('desktop-player-volume-popover')),
        findsOneWidget,
      );
      expect(find.byType(Slider), findsNWidgets(2));
    });

    testWidgets('idle capsule shows the glyph and dims its controls', (
      tester,
    ) async {
      await pumpShell(tester, mornye: true, width: 1400, item: null);

      expect(find.bySemanticsLabel('Not playing'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('desktop-player-shuffle')));
      await tester.tap(find.byTooltip('Next track (Ctrl+Right)'));
      expect(controller.calls, isEmpty);
    });

    testWidgets('sidebar rows select destinations and name shortcuts', (
      tester,
    ) async {
      await pumpShell(tester, mornye: true, width: 1400);

      expect(find.byTooltip('library (Ctrl+2)'), findsOneWidget);
      expect(find.byTooltip('settings (Ctrl+5)'), findsOneWidget);
      await tester.tap(find.text('library'));
      await tester.tap(find.byKey(const ValueKey('desktop-sidebar-settings')));
      expect(selections, [ShellTab.library, ShellTab.settings]);

      final home = tester.getRect(
        find.ancestor(of: find.text('home'), matching: find.byType(InkWell)),
      );
      expect(home.height, 32);
      // Music's measurements: rows inset 6pt in a panel inset 8pt.
      expect(home.left, DesktopSidebar.margin + 6);
    });

    testWidgets('sidebar lists Library pages and playlists', (tester) async {
      final opened = <String>[];
      await pumpShell(
        tester,
        mornye: true,
        width: 1400,
        libraryLinks: _libraryLinks,
        onOpenLibraryLink: opened.add,
      );

      expect(find.text('Library'), findsOneWidget);
      expect(find.text('Playlists'), findsOneWidget);
      expect(find.text('library'), findsNothing);
      // The first Library page stands for Library and takes its shortcut.
      expect(find.byTooltip('Recently Added (Ctrl+2)'), findsOneWidget);
      await tester.tap(find.text('Albums'));
      await tester.tap(find.text('All Playlists'));
      await tester.tap(find.text('Road trip'));
      expect(opened, [
        'albums',
        DesktopSidebarLink.allPlaylistsId,
        DesktopSidebarLink.playlistId('mix'),
      ]);
    });

    testWidgets('account row opens the profile', (tester) async {
      var profileOpened = 0;
      await pumpShell(
        tester,
        mornye: true,
        width: 1400,
        onOpenProfile: () => profileOpened++,
      );

      expect(find.text('Ada Lovelace'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('desktop-sidebar-account')));
      expect(profileOpened, 1);
      expect(selections, isEmpty);
    });

    testWidgets('sidebar stays in narrow windows and ignores the shortcut', (
      tester,
    ) async {
      await pumpShell(tester, mornye: true, width: 820);
      desktopSidebarCollapsed.value = true;
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate(
          (w) => w is AppIcon && w.icon == CupertinoIcons.sidebar_left,
        ),
        findsNothing,
      );
      expect(
        tester.getSize(find.byType(DesktopSidebar)).width,
        DesktopSidebar.footprint,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('desktop-content'))).left,
        DesktopSidebar.footprint,
      );
    });
  });

  group('desktop shortcuts', () {
    final navigatorKey = GlobalKey<NavigatorState>();
    late Object owner;
    late List<ShellTab> requested;

    setUp(() {
      owner = Object();
      requested = [];
      ShellNavigationService.registerTabSelectionHandler(
        owner: owner,
        handler: requested.add,
      );
    });

    tearDown(() => ShellNavigationService.unregisterTabSelectionHandler(owner));

    Future<void> pumpApp(WidgetTester tester, {bool playing = false}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides(playing: playing),
          child: MaterialApp(
            navigatorKey: navigatorKey,
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) =>
                DesktopShortcuts(navigatorKey: navigatorKey, child: child!),
            home: const Scaffold(
              body: Column(children: [Text('home'), TextField()]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> press(
      WidgetTester tester,
      LogicalKeyboardKey key, {
      bool control = false,
    }) async {
      if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(key);
      if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pump();
    }

    testWidgets('control playback and volume', (tester) async {
      await pumpApp(tester, playing: true);

      await press(tester, LogicalKeyboardKey.space);
      await press(tester, LogicalKeyboardKey.arrowRight, control: true);
      await press(tester, LogicalKeyboardKey.arrowLeft, control: true);
      expect(controller.calls, ['pause', 'next', 'previous']);

      await press(tester, LogicalKeyboardKey.arrowUp, control: true);
      await press(tester, LogicalKeyboardKey.arrowDown, control: true);
      expect(volumeWrites, [closeTo(0.55, 1e-9), closeTo(0.45, 1e-9)]);
    });

    testWidgets('leave Space and arrows to a focused text field', (
      tester,
    ) async {
      await pumpApp(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();

      await press(tester, LogicalKeyboardKey.space);
      await press(tester, LogicalKeyboardKey.arrowRight, control: true);
      expect(controller.calls, isEmpty);

      // Escape first leaves the field, then Space plays again.
      await press(tester, LogicalKeyboardKey.escape);
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorStateOfType<EditableTextState>(),
        isNull,
      );
      await press(tester, LogicalKeyboardKey.space);
      expect(controller.calls, ['play']);
    });

    testWidgets('select destinations, search and settings', (tester) async {
      await pumpApp(tester);

      await press(tester, LogicalKeyboardKey.digit2, control: true);
      await press(tester, LogicalKeyboardKey.digit1, control: true);
      await press(tester, LogicalKeyboardKey.comma, control: true);
      await press(tester, LogicalKeyboardKey.keyF, control: true);
      expect(requested, [
        ShellTab.library,
        ShellTab.home,
        ShellTab.settings,
        ShellTab.search,
      ]);
    });

    testWidgets('Escape and Back close the top page', (tester) async {
      await pumpApp(tester);
      for (final close in [
        () => press(tester, LogicalKeyboardKey.escape),
        () => press(tester, LogicalKeyboardKey.bracketLeft, control: true),
      ]) {
        unawaited(
          navigatorKey.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('page')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('page'), findsOneWidget);

        await close();
        await tester.pumpAndSettle();
        expect(find.text('page'), findsNothing);
        expect(find.text('home'), findsOneWidget);
      }
    });
  });

  test('shortcut labels follow the platform', () {
    final next = desktopCommandShortcut(
      DesktopCommand.next,
      TargetPlatform.macOS,
    )!;
    expect(next.meta, isTrue);
    expect(desktopShortcutLabel(next, TargetPlatform.macOS), '⌘→');
    expect(
      desktopShortcutLabel(
        desktopCommandShortcut(DesktopCommand.lyrics, TargetPlatform.windows)!,
        TargetPlatform.windows,
      ),
      'Ctrl+Shift+L',
    );
    expect(
      desktopShortcutLabel(
        desktopCommandShortcut(
          DesktopCommand.toggleSidebar,
          TargetPlatform.macOS,
        )!,
        TargetPlatform.macOS,
      ),
      '⌃⌘S',
    );
    expect(
      desktopCommandShortcut(
        DesktopCommand.toggleSidebar,
        TargetPlatform.linux,
      ),
      isNull,
    );
  });

  testWidgets('desktop mini player drops the touch gestures', (tester) async {
    Future<void> pump() => tester.pumpWidget(
      ProviderScope(
        overrides: overrides(),
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: Center(child: MiniPlayer())),
        ),
      ),
    );

    await pump();
    await tester.pumpAndSettle();
    expect(find.byType(Dismissible), findsNothing);
    Finder touchGestures() => find.descendant(
      of: find.byType(MiniPlayer),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is GestureDetector && widget.onHorizontalDragEnd != null,
      ),
    );
    expect(touchGestures(), findsNothing);

    debugDesktopPlatformOverride = false;
    await tester.pumpWidget(const SizedBox());
    await pump();
    await tester.pumpAndSettle();
    expect(touchGestures(), findsOneWidget);
  });
}
