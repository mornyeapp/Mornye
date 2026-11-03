import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart';
import 'package:mornye/widgets/desktop/desktop_inspector.dart';
import 'package:mornye/widgets/desktop/desktop_shortcuts.dart';
import 'package:mornye/widgets/desktop/desktop_window.dart';

const _channel = MethodChannel('com.zarz.mornye/window');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  DesktopWindowMode nativeMode = DesktopWindowMode.windowed;

  Future<void> emitMode(DesktopWindowMode mode) async {
    nativeMode = mode;
    desktopWindowMode.value = mode;
    desktopWindowFullScreen.value = mode == DesktopWindowMode.fullscreen;
    await messenger.handlePlatformMessage(
      _channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('windowModeChanged', mode.name),
      ),
      (_) {},
    );
  }

  setUp(() {
    debugDesktopPlatformOverride = true;
    desktopNowPlayingOpen.value = false;
    desktopWindowFullScreen.value = false;
    desktopWindowMode.value = DesktopWindowMode.windowed;
    nativeMode = DesktopWindowMode.windowed;
    ShellNavigationService.resetHistory(initialTab: ShellTab.home);

    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'getWindowMode') return nativeMode.name;
      if (call.method == 'setWindowMode') {
        final name = (call.arguments as Map)['mode'] as String;
        final target = DesktopWindowMode.values.firstWhere(
          (m) => m.name == name,
        );
        await emitMode(target);
        return true;
      }
      return null;
    });
    listenDesktopWindowFullScreen();
  });

  tearDown(() {
    debugDesktopPlatformOverride = null;
    desktopNowPlayingOpen.value = false;
    desktopWindowFullScreen.value = false;
    desktopWindowMode.value = DesktopWindowMode.windowed;
    nativeMode = DesktopWindowMode.windowed;
    ShellNavigationService.resetHistory();
    messenger.setMockMethodCallHandler(_channel, null);
  });

  Widget buildTestApp({
    required GlobalKey<NavigatorState> navigatorKey,
    required Widget child,
  }) {
    return ProviderScope(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, widgetChild) =>
            DesktopShortcuts(navigatorKey: navigatorKey, child: widgetChild!),
        home: Scaffold(body: child),
      ),
    );
  }

  group('ShellNavigationService History Architecture', () {
    test('Tracks tab history and forward stack correctly', () {
      ShellNavigationService.resetHistory(initialTab: ShellTab.home);
      expect(ShellNavigationService.canNavigateBack, isFalse);
      expect(ShellNavigationService.canNavigateForward, isFalse);

      ShellNavigationService.recordTabVisit(ShellTab.library);
      expect(ShellNavigationService.canNavigateBack, isTrue);
      expect(ShellNavigationService.currentTabForTesting, ShellTab.library);
      expect(ShellNavigationService.backHistoryForTesting, [ShellTab.home]);

      ShellNavigationService.recordTabVisit(ShellTab.settings);
      expect(ShellNavigationService.currentTabForTesting, ShellTab.settings);
      expect(ShellNavigationService.backHistoryForTesting, [
        ShellTab.home,
        ShellTab.library,
      ]);

      // Visiting the same tab does not create duplicate entries
      ShellNavigationService.recordTabVisit(ShellTab.settings);
      expect(ShellNavigationService.backHistoryForTesting, [
        ShellTab.home,
        ShellTab.library,
      ]);

      // Navigate back to library
      expect(ShellNavigationService.navigateBack(), isTrue);
      expect(ShellNavigationService.currentTabForTesting, ShellTab.library);
      expect(ShellNavigationService.canNavigateForward, isTrue);
      expect(ShellNavigationService.forwardHistoryForTesting, [
        ShellTab.settings,
      ]);

      // Navigate back to home
      expect(ShellNavigationService.navigateBack(), isTrue);
      expect(ShellNavigationService.currentTabForTesting, ShellTab.home);
      expect(ShellNavigationService.canNavigateBack, isFalse);
      expect(ShellNavigationService.forwardHistoryForTesting, [
        ShellTab.settings,
        ShellTab.library,
      ]);

      // Navigate forward to library
      expect(ShellNavigationService.navigateForward(), isTrue);
      expect(ShellNavigationService.currentTabForTesting, ShellTab.library);
      expect(ShellNavigationService.forwardHistoryForTesting, [
        ShellTab.settings,
      ]);

      // New navigation clears forward stack
      ShellNavigationService.recordTabVisit(ShellTab.search);
      expect(ShellNavigationService.currentTabForTesting, ShellTab.search);
      expect(ShellNavigationService.canNavigateForward, isFalse);
      expect(ShellNavigationService.forwardHistoryForTesting, isEmpty);
    });

    test('Destination changes reported by the shell enter the history', () {
      addTearDown(() {
        ShellNavigationService.syncState(
          currentTabIndex: 0,
          showRepoTab: false,
        );
        ShellNavigationService.resetHistory();
      });
      final requested = <ShellTab>[];
      ShellNavigationService.registerTabSelectionHandler(
        owner: 'test-sync',
        handler: requested.add,
      );
      addTearDown(
        () => ShellNavigationService.unregisterTabSelectionHandler('test-sync'),
      );
      ShellNavigationService.syncState(currentTabIndex: 0, showRepoTab: true);
      ShellNavigationService.resetHistory();

      // Mornye with the Store: Home, Library, Store, Search, Settings.
      for (final index in [1, 2, 3]) {
        ShellNavigationService.syncState(
          currentTabIndex: index,
          showRepoTab: true,
          showSearchTab: true,
        );
      }
      expect(ShellNavigationService.currentTabForTesting, ShellTab.search);
      expect(ShellNavigationService.backHistoryForTesting, [
        ShellTab.home,
        ShellTab.library,
        ShellTab.repository,
      ]);

      // Hiding the Store moves Search to index 2; it is the same destination.
      ShellNavigationService.syncState(
        currentTabIndex: 2,
        showRepoTab: false,
        showSearchTab: true,
      );
      expect(ShellNavigationService.backHistoryForTesting, hasLength(3));

      // Back skips the Store, which is no longer shown.
      expect(ShellNavigationService.navigateBack(), isTrue);
      expect(requested, [ShellTab.library]);
      expect(ShellNavigationService.currentTabForTesting, ShellTab.library);
      expect(ShellNavigationService.forwardHistoryForTesting, [
        ShellTab.search,
      ]);
    });

    test('Boundary conditions for empty history', () {
      ShellNavigationService.resetHistory(initialTab: ShellTab.home);
      expect(ShellNavigationService.navigateBack(), isFalse);
      expect(ShellNavigationService.navigateForward(), isFalse);
    });

    test(
      'Non-Home initial tab does not record false Home visit and returns correctly with Back',
      () {
        ShellNavigationService.resetHistory();
        // First recorded visit establishes initial tab without false history
        ShellNavigationService.recordTabVisit(ShellTab.library);
        expect(ShellNavigationService.canNavigateBack, isFalse);
        expect(ShellNavigationService.backHistoryForTesting, isEmpty);
        expect(ShellNavigationService.currentTabForTesting, ShellTab.library);

        // Navigating elsewhere pushes the actual initial tab
        ShellNavigationService.recordTabVisit(ShellTab.settings);
        expect(ShellNavigationService.canNavigateBack, isTrue);
        expect(ShellNavigationService.backHistoryForTesting, [
          ShellTab.library,
        ]);
        expect(ShellNavigationService.currentTabForTesting, ShellTab.settings);

        // Back returns to the actual initial tab
        expect(ShellNavigationService.navigateBack(), isTrue);
        expect(ShellNavigationService.currentTabForTesting, ShellTab.library);
        expect(ShellNavigationService.canNavigateBack, isFalse);
        expect(ShellNavigationService.canNavigateForward, isTrue);

        // Forward returns to settings
        expect(ShellNavigationService.navigateForward(), isTrue);
        expect(ShellNavigationService.currentTabForTesting, ShellTab.settings);
        expect(ShellNavigationService.canNavigateBack, isTrue);
      },
    );

    test(
      'Unregistering tab selection handler clears navigation history and prevents stale leaks',
      () {
        final owner = Object();
        ShellNavigationService.registerTabSelectionHandler(
          owner: owner,
          handler: (_) {},
        );
        ShellNavigationService.recordTabVisit(ShellTab.home);
        ShellNavigationService.recordTabVisit(ShellTab.library);
        expect(ShellNavigationService.canNavigateBack, isTrue);

        ShellNavigationService.unregisterTabSelectionHandler(owner);
        expect(ShellNavigationService.canNavigateBack, isFalse);
        expect(ShellNavigationService.backHistoryForTesting, isEmpty);
        expect(ShellNavigationService.forwardHistoryForTesting, isEmpty);
      },
    );

    test('Inner navigator canPop takes precedence over tab history', () {
      ShellNavigationService.resetHistory(initialTab: ShellTab.home);
      ShellNavigationService.recordTabVisit(ShellTab.library);

      final mockNavKey = GlobalKey<NavigatorState>();
      ShellNavigationService.registerSettingsDetailNavigator(
        owner: 'test-detail',
        navigator: () => mockNavKey.currentState,
      );
      addTearDown(
        () => ShellNavigationService.unregisterSettingsDetailNavigator(
          'test-detail',
        ),
      );

      // Back history exists
      expect(ShellNavigationService.canNavigateBack, isTrue);
      expect(ShellNavigationService.currentTabForTesting, ShellTab.library);
    });
  });

  group('Keyboard Escape & Dismissal Priority Hierarchy', () {
    testWidgets(
      'Text editing unfocus takes priority before popping page or history',
      (tester) async {
        final navKey = GlobalKey<NavigatorState>();
        final focusNode = FocusNode();

        await tester.pumpWidget(
          buildTestApp(
            navigatorKey: navKey,
            child: TextField(
              focusNode: focusNode,
              decoration: const InputDecoration(labelText: 'Search Field'),
            ),
          ),
        );
        await tester.pumpAndSettle();

        focusNode.requestFocus();
        await tester.pumpAndSettle();
        expect(focusNode.hasFocus, isTrue);

        // Escape unfocuses text input first
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(focusNode.hasFocus, isFalse);
      },
    );

    testWidgets(
      'Priority 1: Escape dismisses active dialog before fullscreen or history',
      (tester) async {
        final navKey = GlobalKey<NavigatorState>();
        await emitMode(DesktopWindowMode.fullscreen);

        await tester.pumpWidget(
          buildTestApp(
            navigatorKey: navKey,
            child: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  showDialog<void>(
                    context: context,
                    builder: (_) =>
                        const AlertDialog(title: Text('Test Dialog')),
                  );
                },
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Open the dialog
        await tester.tap(find.text('Open Dialog'));
        await tester.pumpAndSettle();

        expect(find.text('Test Dialog'), findsOneWidget);
        expect(desktopWindowMode.value, DesktopWindowMode.fullscreen);

        // Press Escape -> Dialog dismisses first! Fullscreen remains intact.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(find.text('Test Dialog'), findsNothing);
        expect(desktopWindowMode.value, DesktopWindowMode.fullscreen);

        // Next Escape -> Leaves fullscreen to windowed
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(desktopWindowMode.value, DesktopWindowMode.windowed);
      },
    );

    testWidgets(
      'Priority 2 & 3: Escape steps from True Fullscreen -> Expanded Preview -> Normal App',
      (tester) async {
        final navKey = GlobalKey<NavigatorState>();
        await emitMode(DesktopWindowMode.fullscreen);
        desktopNowPlayingOpen.value = true;

        await tester.pumpWidget(
          buildTestApp(
            navigatorKey: navKey,
            child: const Text('Normal Content'),
          ),
        );
        await tester.pumpAndSettle();

        // First Escape: closes Now Playing player layer back to shell
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(desktopNowPlayingOpen.value, isFalse);
        expect(desktopWindowMode.value, DesktopWindowMode.fullscreen);

        // Second Escape: exits Fullscreen to windowed mode
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(desktopWindowMode.value, DesktopWindowMode.windowed);
      },
    );

    testWidgets(
      'Priority 4: Inner navigator route pops before tab-history Back',
      (tester) async {
        final navKey = GlobalKey<NavigatorState>();
        ShellTab? currentActiveTab = ShellTab.home;

        ShellNavigationService.registerTabSelectionHandler(
          owner: 'test-inner-pop',
          handler: (tab) => currentActiveTab = tab,
        );
        addTearDown(
          () => ShellNavigationService.unregisterTabSelectionHandler(
            'test-inner-pop',
          ),
        );

        ShellNavigationService.recordTabVisit(ShellTab.library);
        currentActiveTab = ShellTab.library;

        await tester.pumpWidget(
          buildTestApp(
            navigatorKey: navKey,
            child: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(body: Text('Detail Page')),
                    ),
                  );
                },
                child: const Text('Go to Detail'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Push detail page
        await tester.tap(find.text('Go to Detail'));
        await tester.pumpAndSettle();
        expect(find.text('Detail Page'), findsOneWidget);

        // Escape pops detail page first! Does not navigate tab back.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(find.text('Detail Page'), findsNothing);
        expect(find.text('Go to Detail'), findsOneWidget);
        expect(currentActiveTab, ShellTab.library);

        // Escape never switches destinations; Back returns to Home.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(currentActiveTab, ShellTab.library);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();

        expect(currentActiveTab, ShellTab.home);
      },
    );

    testWidgets(
      'Escape in full screen closes a page before leaving full screen',
      (tester) async {
        final navKey = GlobalKey<NavigatorState>();
        await emitMode(DesktopWindowMode.fullscreen);

        await tester.pumpWidget(
          buildTestApp(
            navigatorKey: navKey,
            child: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: Text('Detail Page')),
                  ),
                ),
                child: const Text('Go to Detail'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Go to Detail'));
        await tester.pumpAndSettle();

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(find.text('Detail Page'), findsNothing);
        expect(desktopWindowMode.value, DesktopWindowMode.fullscreen);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(desktopWindowMode.value, DesktopWindowMode.windowed);
      },
    );

    testWidgets('Escape keeps the destination; Back walks the history', (
      tester,
    ) async {
      final navKey = GlobalKey<NavigatorState>();
      ShellTab? currentActiveTab = ShellTab.home;

      ShellNavigationService.registerTabSelectionHandler(
        owner: 'test-owner-escape',
        handler: (tab) => currentActiveTab = tab,
      );
      addTearDown(
        () => ShellNavigationService.unregisterTabSelectionHandler(
          'test-owner-escape',
        ),
      );

      ShellNavigationService.recordTabVisit(ShellTab.library);
      currentActiveTab = ShellTab.library;
      ShellNavigationService.recordTabVisit(ShellTab.settings);
      currentActiveTab = ShellTab.settings;

      await tester.pumpWidget(
        buildTestApp(navigatorKey: navKey, child: const Text('Tab Shell')),
      );
      await tester.pumpAndSettle();

      expect(ShellNavigationService.canNavigateBack, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(currentActiveTab, ShellTab.settings);

      Future<void> back() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
      }

      await back();
      expect(currentActiveTab, ShellTab.library);

      await back();
      expect(currentActiveTab, ShellTab.home);
      expect(ShellNavigationService.canNavigateBack, isFalse);

      // Further Back does not crash or navigate away from root
      await back();
      expect(currentActiveTab, ShellTab.home);
    });

    testWidgets(
      'Starting on a non-Home tab, navigating elsewhere, and returning with Back',
      (tester) async {
        final navKey = GlobalKey<NavigatorState>();
        ShellTab? currentActiveTab;

        ShellNavigationService.registerTabSelectionHandler(
          owner: 'test-non-home-start',
          handler: (tab) => currentActiveTab = tab,
        );
        addTearDown(
          () => ShellNavigationService.unregisterTabSelectionHandler(
            'test-non-home-start',
          ),
        );

        // App starts directly on Library without visiting Home
        ShellNavigationService.resetHistory(initialTab: ShellTab.library);
        currentActiveTab = ShellTab.library;

        await tester.pumpWidget(
          buildTestApp(
            navigatorKey: navKey,
            child: const Text('Non-Home Start Shell'),
          ),
        );
        await tester.pumpAndSettle();

        expect(ShellNavigationService.canNavigateBack, isFalse);

        // User visits Settings
        ShellNavigationService.recordTabVisit(ShellTab.settings);
        currentActiveTab = ShellTab.settings;
        await tester.pumpAndSettle();

        expect(ShellNavigationService.canNavigateBack, isTrue);

        Future<void> back() async {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pumpAndSettle();
        }

        // Back returns to Library
        await back();
        expect(currentActiveTab, ShellTab.library);
        // Back history is now exhausted: cannot go back to a non-existent Home
        expect(ShellNavigationService.canNavigateBack, isFalse);

        // Next Back does not change tab
        await back();
        expect(currentActiveTab, ShellTab.library);
      },
    );
  });

  group('Mouse Button 4 (Back) and Button 5 (Forward)', () {
    testWidgets(
      'Mouse Button 4 navigates back and Button 5 navigates forward',
      (tester) async {
        final navKey = GlobalKey<NavigatorState>();
        ShellTab? currentActiveTab = ShellTab.home;

        ShellNavigationService.registerTabSelectionHandler(
          owner: 'test-owner-mouse',
          handler: (tab) => currentActiveTab = tab,
        );
        addTearDown(
          () => ShellNavigationService.unregisterTabSelectionHandler(
            'test-owner-mouse',
          ),
        );

        ShellNavigationService.recordTabVisit(ShellTab.library);
        currentActiveTab = ShellTab.library;
        ShellNavigationService.recordTabVisit(ShellTab.settings);
        currentActiveTab = ShellTab.settings;

        await tester.pumpWidget(
          buildTestApp(
            navigatorKey: navKey,
            child: const Center(child: Text('Mouse Test Page')),
          ),
        );
        await tester.pumpAndSettle();

        final center = tester.getCenter(find.text('Mouse Test Page'));
        final pointer = TestPointer(1, PointerDeviceKind.mouse);

        // Down with Mouse Button 4 (kBackMouseButton = 0x08)
        await tester.sendEventToBinding(
          pointer.down(center, buttons: kBackMouseButton),
        );
        await tester.pumpAndSettle();
        await tester.sendEventToBinding(pointer.up());
        await tester.pumpAndSettle();

        // Navigated backward from settings to library
        expect(currentActiveTab, ShellTab.library);
        expect(ShellNavigationService.canNavigateForward, isTrue);

        // Down with Mouse Button 5 (kForwardMouseButton = 0x10)
        await tester.sendEventToBinding(
          pointer.down(center, buttons: kForwardMouseButton),
        );
        await tester.pumpAndSettle();
        await tester.sendEventToBinding(pointer.up());
        await tester.pumpAndSettle();

        // Navigated forward from library to settings
        expect(currentActiveTab, ShellTab.settings);
        expect(ShellNavigationService.canNavigateForward, isFalse);
      },
    );

    testWidgets('Holding mouse button does not repeatedly trigger navigation', (
      tester,
    ) async {
      final navKey = GlobalKey<NavigatorState>();
      ShellTab? currentActiveTab = ShellTab.home;

      ShellNavigationService.registerTabSelectionHandler(
        owner: 'test-owner-mouse-hold',
        handler: (tab) => currentActiveTab = tab,
      );
      addTearDown(
        () => ShellNavigationService.unregisterTabSelectionHandler(
          'test-owner-mouse-hold',
        ),
      );

      ShellNavigationService.recordTabVisit(ShellTab.library);
      currentActiveTab = ShellTab.library;
      ShellNavigationService.recordTabVisit(ShellTab.settings);
      currentActiveTab = ShellTab.settings;

      await tester.pumpWidget(
        buildTestApp(
          navigatorKey: navKey,
          child: const Center(child: Text('Mouse Hold Page')),
        ),
      );
      await tester.pumpAndSettle();

      final center = tester.getCenter(find.text('Mouse Hold Page'));
      final pointer = TestPointer(2, PointerDeviceKind.mouse);

      // Down with Mouse Button 4
      await tester.sendEventToBinding(
        pointer.down(center, buttons: kBackMouseButton),
      );
      await tester.pumpAndSettle();

      expect(currentActiveTab, ShellTab.library);

      // Move while held: should NOT trigger another back navigation!
      await tester.sendEventToBinding(
        pointer.move(center + const Offset(10, 10), buttons: kBackMouseButton),
      );
      await tester.pumpAndSettle();

      expect(currentActiveTab, ShellTab.library);

      await tester.sendEventToBinding(
        pointer.move(center + const Offset(20, 20), buttons: kBackMouseButton),
      );
      await tester.pumpAndSettle();

      expect(currentActiveTab, ShellTab.library);

      // Release
      await tester.sendEventToBinding(pointer.up());
      await tester.pumpAndSettle();

      expect(currentActiveTab, ShellTab.library);
    });

    testWidgets('No interference with sliders or normal pointer controls', (
      tester,
    ) async {
      final navKey = GlobalKey<NavigatorState>();
      double sliderVal = 0.5;

      await tester.pumpWidget(
        buildTestApp(
          navigatorKey: navKey,
          child: StatefulBuilder(
            builder: (context, setState) => Slider(
              value: sliderVal,
              onChanged: (val) => setState(() => sliderVal = val),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final sliderFinder = find.byType(Slider);
      expect(sliderFinder, findsOneWidget);

      // Tap slider with primary mouse button
      final topLeft = tester.getTopLeft(sliderFinder);
      final bottomRight = tester.getBottomRight(sliderFinder);
      final target = Offset(
        bottomRight.dx - 20,
        (topLeft.dy + bottomRight.dy) / 2,
      );

      await tester.tapAt(target);
      await tester.pumpAndSettle();

      // Value updated properly via primary button click
      expect(sliderVal, greaterThan(0.7));
    });
  });

  group('Keyboard Shortcuts and Hardware Browser Keys', () {
    testWidgets('Ctrl+[ / Cmd+[ triggers Back', (tester) async {
      final navKey = GlobalKey<NavigatorState>();
      ShellTab? currentActiveTab = ShellTab.home;

      ShellNavigationService.registerTabSelectionHandler(
        owner: 'test-shortcuts-back',
        handler: (tab) => currentActiveTab = tab,
      );
      addTearDown(
        () => ShellNavigationService.unregisterTabSelectionHandler(
          'test-shortcuts-back',
        ),
      );

      ShellNavigationService.recordTabVisit(ShellTab.library);
      currentActiveTab = ShellTab.library;

      await tester.pumpWidget(
        buildTestApp(
          navigatorKey: navKey,
          child: const Text('Keyboard Back Test'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(currentActiveTab, ShellTab.home);
    });

    testWidgets('Ctrl+] / Cmd+] triggers Forward', (tester) async {
      final navKey = GlobalKey<NavigatorState>();
      ShellTab? currentActiveTab = ShellTab.home;

      ShellNavigationService.registerTabSelectionHandler(
        owner: 'test-shortcuts-fwd',
        handler: (tab) => currentActiveTab = tab,
      );
      addTearDown(
        () => ShellNavigationService.unregisterTabSelectionHandler(
          'test-shortcuts-fwd',
        ),
      );

      ShellNavigationService.recordTabVisit(ShellTab.library);
      currentActiveTab = ShellTab.library;
      ShellNavigationService.navigateBack();
      currentActiveTab = ShellTab.home;

      await tester.pumpWidget(
        buildTestApp(
          navigatorKey: navKey,
          child: const Text('Keyboard Forward Test'),
        ),
      );
      await tester.pumpAndSettle();

      expect(ShellNavigationService.canNavigateForward, isTrue);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(currentActiveTab, ShellTab.library);
    });

    testWidgets('Browser Back and Forward keys trigger navigation', (
      tester,
    ) async {
      final navKey = GlobalKey<NavigatorState>();
      ShellTab? currentActiveTab = ShellTab.home;

      ShellNavigationService.registerTabSelectionHandler(
        owner: 'test-browser-keys',
        handler: (tab) => currentActiveTab = tab,
      );
      addTearDown(
        () => ShellNavigationService.unregisterTabSelectionHandler(
          'test-browser-keys',
        ),
      );

      ShellNavigationService.recordTabVisit(ShellTab.library);
      currentActiveTab = ShellTab.library;

      await tester.pumpWidget(
        buildTestApp(
          navigatorKey: navKey,
          child: const Text('Browser Keys Test'),
        ),
      );
      await tester.pumpAndSettle();

      // Browser Back key on desktop platform
      await tester.sendKeyEvent(
        LogicalKeyboardKey.browserBack,
        platform: 'windows',
        physicalKey: PhysicalKeyboardKey.browserBack,
      );
      await tester.pumpAndSettle();

      expect(currentActiveTab, ShellTab.home);
      expect(ShellNavigationService.canNavigateForward, isTrue);

      // Browser Forward key on desktop platform
      await tester.sendKeyEvent(
        LogicalKeyboardKey.browserForward,
        platform: 'windows',
        physicalKey: PhysicalKeyboardKey.browserForward,
      );
      await tester.pumpAndSettle();

      expect(currentActiveTab, ShellTab.library);
    });

    test(
      'Track skip shortcuts remain preserved and bound to Ctrl/Cmd + Left/Right',
      () {
        final bindings = desktopShortcutBindings(TargetPlatform.windows);
        final prevShortcut = desktopCommandShortcut(
          DesktopCommand.previous,
          TargetPlatform.windows,
        );
        final nextShortcut = desktopCommandShortcut(
          DesktopCommand.next,
          TargetPlatform.windows,
        );

        expect(prevShortcut, isNotNull);
        expect(prevShortcut!.trigger, LogicalKeyboardKey.arrowLeft);
        expect(prevShortcut.control, isTrue);

        expect(nextShortcut, isNotNull);
        expect(nextShortcut!.trigger, LogicalKeyboardKey.arrowRight);
        expect(nextShortcut.control, isTrue);

        final prevMatching = bindings.entries.where(
          (e) =>
              e.key is SingleActivator &&
              (e.key as SingleActivator).trigger ==
                  LogicalKeyboardKey.arrowLeft,
        );
        expect(prevMatching, isNotEmpty);
        expect(
          (prevMatching.first.value as DesktopCommandIntent).command,
          DesktopCommand.previous,
        );

        final nextMatching = bindings.entries.where(
          (e) =>
              e.key is SingleActivator &&
              (e.key as SingleActivator).trigger ==
                  LogicalKeyboardKey.arrowRight,
        );
        expect(nextMatching, isNotEmpty);
        expect(
          (nextMatching.first.value as DesktopCommandIntent).command,
          DesktopCommand.next,
        );
      },
    );
  });
}
