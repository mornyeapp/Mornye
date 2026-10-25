import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/system_volume_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart';
import 'package:mornye/widgets/desktop/desktop_player_bar.dart';
import 'package:mornye/widgets/desktop/desktop_shortcuts.dart';
import 'package:mornye/widgets/desktop/desktop_window.dart';
import 'package:mornye/widgets/desktop/desktop_window_controls.dart';

const _channel = MethodChannel('com.zarz.mornye/window');

class _Player implements MusicPlayerController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MountProbe extends StatefulWidget {
  const _MountProbe(this.onMount);
  final VoidCallback onMount;

  @override
  State<_MountProbe> createState() => _MountProbeState();
}

class _MountProbeState extends State<_MountProbe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: TextField());
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  late DesktopWindowMode nativeMode;
  late List<MethodCall> calls;
  var reject = false;

  Future<void> emitMode(DesktopWindowMode mode) async {
    nativeMode = mode;
    await messenger.handlePlatformMessage(
      _channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('windowModeChanged', mode.name),
      ),
      (_) {},
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    debugDesktopPlatformOverride = true;
    debugDesktopTitleBarInContentOverride = false;
    desktopWindowMode.value = DesktopWindowMode.windowed;
    desktopWindowFullScreen.value = false;
    desktopMiniPlayerOpen.value = false;
    nativeMode = DesktopWindowMode.windowed;
    calls = [];
    reject = false;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      if (call.method == 'getWindowMode') return nativeMode.name;
      if (call.method == 'setWindowMode') {
        if (reject) return false;
        final name = (call.arguments as Map)['mode'];
        await emitMode(
          DesktopWindowMode.values.singleWhere((mode) => mode.name == name),
        );
        return true;
      }
      return null;
    });
    listenDesktopWindowFullScreen();
    await Future<void>.delayed(Duration.zero);
    calls.clear();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    _channel.setMethodCallHandler(null);
    desktopWindowMode.value = DesktopWindowMode.windowed;
    desktopWindowFullScreen.value = false;
    desktopMiniPlayerOpen.value = false;
    debugDesktopPlatformOverride = null;
    debugDesktopTitleBarInContentOverride = null;
  });

  test(
    'native mode changes update fullscreen state on every desktop platform',
    () async {
      for (final mode in [
        DesktopWindowMode.borderless,
        DesktopWindowMode.fullscreen,
        DesktopWindowMode.windowed,
      ]) {
        expect(await setDesktopWindowMode(mode), isTrue);
        expect(desktopWindowMode.value, mode);
        expect(
          desktopWindowFullScreen.value,
          mode == DesktopWindowMode.fullscreen,
        );
      }
    },
  );

  test('leaving fullscreen restores the preceding borderless mode', () async {
    await setDesktopWindowMode(DesktopWindowMode.borderless);
    await toggleDesktopFullScreen();
    expect(desktopWindowFullScreen.value, isTrue);
    await toggleDesktopFullScreen();
    expect(desktopWindowMode.value, DesktopWindowMode.borderless);
    await leaveDesktopWindowMode();
    expect(desktopWindowMode.value, DesktopWindowMode.windowed);
  });

  test('a rejected native request leaves the current mode intact', () async {
    reject = true;
    expect(await setDesktopWindowMode(DesktopWindowMode.borderless), isFalse);
    expect(desktopWindowMode.value, DesktopWindowMode.windowed);
  });

  for (final actualMode in [
    DesktopWindowMode.windowed,
    DesktopWindowMode.fullscreen,
  ]) {
    testWidgets('a missing native event resyncs to $actualMode', (
      tester,
    ) async {
      messenger.setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'getWindowMode') return actualMode.name;
        return true;
      });
      final result = setDesktopWindowMode(DesktopWindowMode.fullscreen);
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(await result, actualMode == DesktopWindowMode.fullscreen);
      expect(desktopWindowMode.value, actualMode);
    });
  }

  test(
    'accepted requests await native state and serialize transitions',
    () async {
      messenger.setMockMethodCallHandler(_channel, (_) async => true);
      final work = setDesktopWindowMode(DesktopWindowMode.fullscreen);
      await Future<void>.delayed(Duration.zero);
      expect(desktopWindowMode.value, DesktopWindowMode.windowed);
      expect(await setDesktopWindowMode(DesktopWindowMode.borderless), isFalse);
      expect(await openDesktopMiniPlayerWindow(const Size(360, 180)), isFalse);
      await emitMode(DesktopWindowMode.fullscreen);
      expect(await work, isTrue);
    },
  );

  test(
    'a late startup snapshot cannot overwrite a newer native event',
    () async {
      final snapshot = Completer<String>();
      messenger.setMockMethodCallHandler(_channel, (_) => snapshot.future);
      listenDesktopWindowFullScreen();
      await emitMode(DesktopWindowMode.fullscreen);
      snapshot.complete('windowed');
      await Future<void>.delayed(Duration.zero);
      expect(desktopWindowMode.value, DesktopWindowMode.fullscreen);
    },
  );

  test('mode requests are desktop-only', () async {
    debugDesktopPlatformOverride = false;
    expect(await setDesktopWindowMode(DesktopWindowMode.borderless), isFalse);
    expect(calls, isEmpty);
  });

  test('fullscreen and borderless shortcuts follow each desktop platform', () {
    for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
      expect(
        desktopCommandShortcut(DesktopCommand.fullScreen, platform)!.trigger,
        LogicalKeyboardKey.f11,
      );
      final borderless = desktopCommandShortcut(
        DesktopCommand.borderless,
        platform,
      )!;
      expect(
        (borderless.trigger, borderless.control, borderless.shift),
        (LogicalKeyboardKey.keyB, true, true),
      );
    }
    final mac = desktopCommandShortcut(
      DesktopCommand.fullScreen,
      TargetPlatform.macOS,
    )!;
    expect(
      (mac.trigger, mac.control, mac.meta),
      (LogicalKeyboardKey.keyF, true, true),
    );
    final macF11 =
        desktopShortcutBindings(TargetPlatform.macOS)[const SingleActivator(
              LogicalKeyboardKey.f11,
            )]
            as DesktopCommandIntent;
    expect(macF11.command, DesktopCommand.fullScreen);
  });

  Future<void> pumpApp(
    WidgetTester tester, {
    required bool mornye,
    required Widget home,
    bool shortcuts = false,
    GlobalKey<NavigatorState>? navigator,
  }) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final navigatorKey = navigator ?? GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          musicPlayerControllerProvider.overrideWithValue(_Player()),
          playbackStateProvider.overrideWith(
            (_) => Stream.value(PlaybackState()),
          ),
          systemVolumeProvider.overrideWith((_) => Stream.value(0.5)),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: mornye
              ? MornyeTheme.build(Brightness.light)
              : AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => shortcuts
              ? DesktopShortcuts(navigatorKey: navigatorKey, child: child!)
              : DesktopWindowFrame(navigatorKey: navigatorKey, child: child!),
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final mornye in [false, true]) {
    testWidgets(
      'window mode changes preserve mounted content and text (Mornye: $mornye)',
      (tester) async {
        var mounts = 0;
        await pumpApp(
          tester,
          mornye: mornye,
          home: _MountProbe(() => mounts++),
        );
        await tester.enterText(find.byType(TextField), 'kept text');
        for (final mode in [
          DesktopWindowMode.borderless,
          DesktopWindowMode.fullscreen,
          DesktopWindowMode.windowed,
        ]) {
          await emitMode(mode);
          await tester.pumpAndSettle();
          expect(mounts, 1);
          expect(find.text('kept text'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      },
    );

    testWidgets(
      'borderless controls invoke native window actions (Mornye: $mornye)',
      (tester) async {
        await emitMode(DesktopWindowMode.borderless);
        await pumpApp(
          tester,
          mornye: mornye,
          home: const Scaffold(body: Text('content')),
        );
        for (final tooltip in [
          'Minimize window',
          'Maximize or restore window',
          'Close',
        ]) {
          await tester.tap(find.byTooltip(tooltip));
          await tester.pump();
        }
        expect(
          calls.map((call) => call.method),
          containsAllInOrder(['minimizeWindow', 'zoomWindow', 'closeWindow']),
        );
        await tester.drag(
          find.byKey(const ValueKey('desktop-window-resize')),
          const Offset(-20, -20),
        );
        expect(calls.last.method, 'startResize');
        await tester.tap(find.byTooltip('Window mode'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Full screen'));
        await tester.pumpAndSettle();
        expect(desktopWindowFullScreen.value, isTrue);
        expect(find.text('content'), findsOneWidget);
      },
    );

    testWidgets(
      'fullscreen fills the window and exits with F11 or Escape (Mornye: $mornye)',
      (tester) async {
        await pumpApp(
          tester,
          mornye: mornye,
          shortcuts: true,
          home: const Scaffold(body: DesktopWindowModeSetting()),
        );
        await tester.tap(find.text('Window mode'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Full screen'));
        await tester.pumpAndSettle();
        expect(desktopWindowFullScreen.value, isTrue);
        expect(find.byTooltip(RegExp(r'^Exit full screen')), findsNothing);
        expect(find.byTooltip('Window mode'), findsNothing);
        expect(tester.getTopLeft(find.byType(Scaffold)), Offset.zero);
        expect(tester.getSize(find.byType(Scaffold)), const Size(1000, 800));
        await tester.sendKeyEvent(LogicalKeyboardKey.f11);
        await tester.pumpAndSettle();
        expect(desktopWindowMode.value, DesktopWindowMode.windowed);
        await tester.sendKeyEvent(LogicalKeyboardKey.f11);
        await tester.pumpAndSettle();
        expect(desktopWindowFullScreen.value, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(desktopWindowMode.value, DesktopWindowMode.windowed);
      },
    );
  }

  testWidgets('Escape closes a page before leaving fullscreen', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await pumpApp(
      tester,
      mornye: false,
      shortcuts: true,
      navigator: navigator,
      home: const Scaffold(body: Text('home')),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    expect(desktopWindowFullScreen.value, isTrue);
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('details')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('details'), findsNothing);
    expect(desktopWindowFullScreen.value, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(desktopWindowMode.value, DesktopWindowMode.windowed);
  });

  testWidgets('macOS accepts F11 and Escape without fullscreen chrome', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(SystemChannels.menu, (_) async => null);
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.menu, null),
    );
    await pumpApp(
      tester,
      mornye: true,
      shortcuts: true,
      home: const Scaffold(body: Text('content')),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    expect(desktopWindowFullScreen.value, isTrue);
    expect(find.text('Full screen'), findsNothing);
    expect(tester.getTopLeft(find.byType(Scaffold)), Offset.zero);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    expect(desktopWindowMode.value, DesktopWindowMode.windowed);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(desktopWindowMode.value, DesktopWindowMode.windowed);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('fullscreen closes the mini player before changing mode', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await pumpApp(
      tester,
      mornye: false,
      shortcuts: true,
      navigator: navigator,
      home: const Scaffold(body: Text('home')),
    );
    desktopMiniPlayerOpen.value = true;
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    expect(desktopMiniPlayerOpen.value, isFalse);
    expect(
      calls.map((call) => call.method),
      containsAllInOrder(['closeMiniPlayer', 'setWindowMode']),
    );
    expect(desktopWindowFullScreen.value, isTrue);
  });
}
