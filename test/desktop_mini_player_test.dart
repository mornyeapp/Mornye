import 'dart:async';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart';
import 'package:mornye/widgets/desktop/desktop_navigation.dart';
import 'package:mornye/widgets/desktop/desktop_player_bar.dart';
import 'package:mornye/widgets/desktop/desktop_window.dart';
import 'package:mornye/widgets/player_lyrics.dart';

const _track = MediaItem(
  id: 'track',
  title: 'A song',
  artist: 'An artist',
  duration: Duration(minutes: 4),
  extras: {'source': '/music/song.flac'},
);

const _lrc =
    '[00:00.00]First line\n[00:05.00]Second line\n[00:10.00]Third line';

const _ttml =
    '<tt xmlns="http://www.w3.org/ns/ttml"><body><div>'
    '<p begin="0s" end="4s"><span begin="0s" end="2s">First</span> '
    '<span begin="2s" end="4s">words</span></p>'
    '<p begin="5s" end="9s"><span begin="5s" end="7s">Second</span> '
    '<span begin="7s" end="9s">words</span></p>'
    '<p begin="10s" end="14s"><span begin="10s" end="12s">Third</span> '
    '<span begin="12s" end="14s">words</span></p>'
    '</div></body></tt>';

const _channel = MethodChannel('com.zarz.mornye/window');

Future<List<int>> _wordPixels(WidgetTester tester) async {
  final paint = find.descendant(
    of: find.byType(WordTimedLyricLine),
    matching: find.byType(CustomPaint),
  );
  final painter = tester.widget<CustomPaint>(paint).painter!;
  final size = tester.getSize(paint);
  return (await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.ceil(), size.height.ceil());
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final result = bytes.buffer.asUint8List().toList();
    image.dispose();
    picture.dispose();
    return result;
  }))!;
}

void main() {
  late List<MethodCall> calls;
  late bool windowOpens;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDesktopPlatformOverride = true;
    debugDesktopTitleBarInContentOverride = true;
    calls = [];
    windowOpens = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return call.method == 'openMiniPlayer' ? windowOpens : null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    debugDesktopPlatformOverride = null;
    debugDesktopTitleBarInContentOverride = null;
    desktopMiniPlayerOpen.value = false;
    desktopMiniPlayerLyrics.value = false;
    desktopPlayerDismissed.value = false;
  });

  test('shrinks the window and returns it', () async {
    await toggleDesktopMiniPlayer();
    expect(desktopMiniPlayerOpen.value, isTrue);
    expect(calls.single.method, 'openMiniPlayer');
    expect(calls.single.arguments, {'width': 360.0, 'height': 140.0});

    await toggleDesktopMiniPlayer();
    expect(desktopMiniPlayerOpen.value, isFalse);
    expect(calls.last.method, 'closeMiniPlayer');
  });

  test('stays in the full window when the window cannot shrink', () async {
    windowOpens = false;
    await setDesktopMiniPlayer(open: true);
    expect(desktopMiniPlayerOpen.value, isFalse);
  });

  test('does nothing outside the desktop app', () async {
    debugDesktopPlatformOverride = false;
    await setDesktopMiniPlayer(open: true);
    expect(desktopMiniPlayerOpen.value, isFalse);
    expect(calls, isEmpty);
  });

  test('shrinks the framed Windows and Linux window too', () async {
    debugDesktopTitleBarInContentOverride = false;
    desktopPlayerDismissed.value = true;
    await setDesktopMiniPlayer(open: true);
    expect(desktopMiniPlayerOpen.value, isTrue);
    expect(desktopPlayerDismissed.value, isFalse);
    expect(calls.single.method, 'openMiniPlayer');
  });

  test('has the Music shortcut on macOS and Ctrl+Shift+M elsewhere', () {
    final mac = desktopCommandShortcut(
      DesktopCommand.miniPlayer,
      TargetPlatform.macOS,
    )!;
    expect(mac.trigger, LogicalKeyboardKey.keyM);
    expect((mac.meta, mac.alt), (true, true));
    expect((mac.control, mac.shift), (false, false));
    for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
      final shortcut = desktopCommandShortcut(
        DesktopCommand.miniPlayer,
        platform,
      )!;
      expect(shortcut.trigger, LogicalKeyboardKey.keyM);
      expect((shortcut.control, shortcut.shift), (true, true));
      expect((shortcut.meta, shortcut.alt), (false, false));
    }
  });

  testWidgets('the panel moves a window without a title bar row', (
    tester,
  ) async {
    debugDesktopTitleBarInContentOverride = false;
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            Positioned.fill(child: DesktopWindowDragArea(frameless: true)),
          ],
        ),
      ),
    );
    await tester.drag(find.byType(DesktopWindowDragArea), const Offset(40, 0));
    expect(calls.map((call) => call.method), contains('startDrag'));

    calls.clear();
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            Positioned.fill(
              child: DesktopWindowDragArea(child: SizedBox.expand()),
            ),
          ],
        ),
      ),
    );
    await tester.drag(find.byType(DesktopWindowDragArea), const Offset(40, 0));
    expect(calls, isEmpty);
  });

  testWidgets('word-timed TTML lines advance while playing', (tester) async {
    tester.view.physicalSize = const Size(360, 248);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final playback = StreamController<PlaybackState>();
    addTearDown(playback.close);
    // Playing from the start; no further report arrives while it plays.
    playback.add(
      PlaybackState(processingState: AudioProcessingState.ready, playing: true),
    );
    desktopMiniPlayerOpen.value = true;
    desktopMiniPlayerLyrics.value = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => Stream.value(_track),
          ),
          playbackStateProvider.overrideWith((ref) => playback.stream),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DesktopMiniPlayer(
            metadataControllerFactory: () => PlayerMetadataController(
              readMetadata: (_) async => {'lyrics': _ttml},
              parseLyrics: (raw) async => LyricsParser.parse(raw!),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('Second'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('First'), findsNothing);
    expect(find.textContaining('Third'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('Second'), findsNothing);
    expect(find.byType(WordTimedLyricLine), findsOneWidget);
    expect(
      tester
          .widget<WordTimedLyricLine>(find.byType(WordTimedLyricLine))
          .line
          .text,
      'Third words',
    );
  });

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    for (final hiddenByLifecycle in [false, true]) {
      testWidgets(
        '$style compact lyrics suspend while hidden ($hiddenByLifecycle)',
        (tester) async {
          var now = DateTime(2026);
          await withClock(Clock(() => now), () async {
            tester.view.physicalSize = const Size(360, 248);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(
              () => tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.resumed,
              ),
            );
            final playback = StreamController<PlaybackState>();
            final visible = ValueNotifier(true);
            addTearDown(playback.close);
            addTearDown(visible.dispose);
            void report(int seconds, {bool playing = false}) => playback.add(
              PlaybackState(
                processingState: AudioProcessingState.ready,
                updatePosition: Duration(seconds: seconds),
                playing: playing,
              ),
            );
            report(1);
            desktopMiniPlayerLyrics.value = true;
            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  currentMediaItemProvider.overrideWithBuild(
                    (ref, notifier) => Stream.value(_track),
                  ),
                  playbackStateProvider.overrideWith((ref) => playback.stream),
                ],
                child: MaterialApp(
                  theme: mornye
                      ? MornyeTheme.build(Brightness.dark)
                      : AppTheme.dark(),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  home: ValueListenableBuilder<bool>(
                    valueListenable: visible,
                    builder: (context, visible, child) =>
                        TickerMode(enabled: visible, child: child!),
                    child: DesktopMiniPlayer(
                      metadataControllerFactory: () => PlayerMetadataController(
                        readMetadata: (_) async => {'lyrics': _lrc},
                        parseLyrics: (raw) async => LyricsParser.parse(raw!),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text('First line'), findsOneWidget);
            report(1, playing: true);
            await tester.pump();
            if (hiddenByLifecycle) {
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.paused,
              );
            } else {
              visible.value = false;
            }
            await tester.pump();
            now = now.add(const Duration(seconds: 11));
            await tester.pump(const Duration(seconds: 11));
            expect(find.text('First line'), findsOneWidget);
            expect(find.text('Third line'), findsNothing);
            if (hiddenByLifecycle) {
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.resumed,
              );
            } else {
              visible.value = true;
            }
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 500));
            expect(find.text('First line'), findsNothing);
            expect(find.text('Third line'), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          });
        },
      );
    }

    testWidgets(
      '$style TTML words follow pause and seeks during panel resizing',
      (tester) async {
        tester.view.physicalSize = const Size(360, 248);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final playback = StreamController<PlaybackState>();
        addTearDown(playback.close);
        void pauseAt(int seconds) => playback.add(
          PlaybackState(
            processingState: AudioProcessingState.ready,
            updatePosition: Duration(seconds: seconds),
          ),
        );
        pauseAt(1);
        desktopMiniPlayerOpen.value = true;
        desktopMiniPlayerLyrics.value = true;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              currentMediaItemProvider.overrideWithBuild(
                (ref, notifier) => Stream.value(_track),
              ),
              playbackStateProvider.overrideWith((ref) => playback.stream),
            ],
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.light)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: DesktopMiniPlayer(
                metadataControllerFactory: () => PlayerMetadataController(
                  readMetadata: (_) async => {'lyrics': _ttml},
                  parseLyrics: (raw) async => LyricsParser.parse(raw!),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final first = await _wordPixels(tester);
        pauseAt(3);
        await tester.pumpAndSettle();
        final second = await _wordPixels(tester);
        expect(second, isNot(orderedEquals(first)));
        await tester.pump(const Duration(seconds: 1));
        expect(await _wordPixels(tester), orderedEquals(second));
        pauseAt(1);
        await tester.pumpAndSettle();
        expect(await _wordPixels(tester), orderedEquals(first));

        pauseAt(6);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<WordTimedLyricLine>(find.byType(WordTimedLyricLine))
              .line
              .text,
          'Second words',
        );
        for (final height in [192.0, 140.0, 192.0, 248.0]) {
          tester.view.physicalSize = Size(360, height);
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
        pauseAt(1);
        await tester.pumpAndSettle();
        expect(await _wordPixels(tester), orderedEquals(first));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('$style switches the retained shell through native resizing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final navigatorKey = GlobalKey<NavigatorState>();
      final pageKey = GlobalKey();
      late Completer<Object?> transition;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            transition = Completer<Object?>();
            return transition.future;
          });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentMediaItemProvider.overrideWithBuild(
              (ref, notifier) => Stream.value(null),
            ),
            playbackStateProvider.overrideWith(
              (ref) => Stream.value(PlaybackState()),
            ),
          ],
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.light)
                : AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) {
                MediaQuery.sizeOf(context);
                return Scaffold(
                  body: DesktopShellLayout(
                    destinations: const [
                      DesktopDestination(
                        tab: ShellTab.home,
                        icon: Icons.home,
                        selectedIcon: Icons.home,
                        label: 'Home',
                      ),
                    ],
                    selected: ShellTab.home,
                    onSelected: (_) {},
                    body: KeyedSubtree(
                      key: pageKey,
                      child: Navigator(
                        key: navigatorKey,
                        onGenerateRoute: (_) => MaterialPageRoute<void>(
                          builder: (_) => const Scaffold(
                            body: Center(child: Text('Retained page')),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final navigator = navigatorKey.currentState;
      final pageSize = tester.getSize(find.byKey(pageKey));
      double opacity(String key) => tester
          .widget<Opacity>(find.byKey(ValueKey(key), skipOffstage: false))
          .opacity;
      for (var attempt = 0; attempt < 3; attempt++) {
        await tester.tap(find.byKey(const ValueKey('desktop-player-mini')));
        await tester.pump();
        expect(opacity('desktop-mini-player-fade'), 0);
        expect(opacity('desktop-mini-player-shell-fade'), 1);
        var previous = 0.0;
        for (final size in [
          const Size(1000, 650),
          const Size(640, 390),
          const Size(360, 140),
        ]) {
          tester.view.physicalSize = size;
          await tester.pump();
          final fade = opacity('desktop-mini-player-fade');
          expect(fade, greaterThan(previous));
          expect(opacity('desktop-mini-player-shell-fade'), 1 - fade);
          expect(
            tester.getSize(find.byKey(pageKey, skipOffstage: false)),
            pageSize,
          );
          expect(tester.takeException(), isNull);
          previous = fade;
        }
        transition.complete(true);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(DesktopMiniPlayer), findsOneWidget);
        expect(find.text('Retained page'), findsNothing);
        expect(navigatorKey.currentState, same(navigator));
        await tester.tap(
          find.byKey(const ValueKey('desktop-mini-player-expand')),
        );
        await tester.pump();
        previous = 1;
        for (final size in [
          const Size(640, 390),
          const Size(1000, 650),
          const Size(1280, 800),
        ]) {
          tester.view.physicalSize = size;
          await tester.pump();
          final fade = opacity('desktop-mini-player-fade');
          expect(fade, lessThan(previous));
          expect(opacity('desktop-mini-player-shell-fade'), 1 - fade);
          expect(navigatorKey.currentState, same(navigator));
          expect(tester.takeException(), isNull);
          previous = fade;
        }
        expect(desktopMiniPlayerOpen.value, isTrue);
        transition.complete(null);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Retained page'), findsOneWidget);
        expect(navigatorKey.currentState, same(navigator));
      }
    });

    testWidgets('$style panel follows the lyrics and grows for them', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 248);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final playback = StreamController<PlaybackState>();
      addTearDown(playback.close);
      PlaybackState pausedAt(int seconds) => PlaybackState(
        processingState: AudioProcessingState.ready,
        updatePosition: Duration(seconds: seconds),
      );
      playback.add(pausedAt(6));
      desktopMiniPlayerOpen.value = true;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentMediaItemProvider.overrideWithBuild(
              (ref, notifier) => Stream.value(_track),
            ),
            playbackStateProvider.overrideWith((ref) => playback.stream),
          ],
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.light)
                : AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DesktopMiniPlayer(
              metadataControllerFactory: () => PlayerMetadataController(
                readMetadata: (_) async => {'lyrics': _lrc},
                parseLyrics: (raw) async => LyricsParser.parse(raw!),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('A song'), findsOneWidget);
      expect(find.text('Second line'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('desktop-mini-player-lyrics')),
      );
      await tester.pumpAndSettle();
      expect(desktopMiniPlayerLyrics.value, isTrue);
      expect(calls.last.arguments, {'width': 360.0, 'height': 248.0});
      expect(find.text('Second line'), findsOneWidget);
      expect(find.text('Third line'), findsOneWidget);

      playback.add(pausedAt(11));
      await tester.pumpAndSettle();
      expect(find.text('Second line'), findsNothing);
      expect(find.text('Third line'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('desktop-mini-player-expand')),
      );
      await tester.pumpAndSettle();
      expect(calls.last.method, 'closeMiniPlayer');
      expect(desktopMiniPlayerOpen.value, isFalse);
    });
  }
}
