import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/system_volume_provider.dart';
import 'package:mornye/screens/settings/settings_tab.dart';
import 'package:mornye/services/app_remote_config_service.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart';
import 'package:mornye/widgets/desktop/desktop_downloads_button.dart';
import 'package:mornye/widgets/desktop/desktop_inspector.dart';
import 'package:mornye/widgets/desktop/desktop_navigation.dart';
import 'package:mornye/widgets/desktop/desktop_now_playing.dart';
import 'package:mornye/widgets/playback_seek_slider.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/desktop/desktop_shortcuts.dart';
import 'package:mornye/widgets/desktop/desktop_window.dart'
    show desktopWindowFullScreen;

class _Queue extends DownloadQueueNotifier {
  _Queue(this._items);

  final List<DownloadItem> _items;
  final cancelled = <String>[];

  @override
  DownloadQueueState build() => DownloadQueueState(items: _items);

  @override
  void cancelItem(String id) => cancelled.add(id);

  void replace(List<DownloadItem> items) =>
      state = DownloadQueueState(items: items);
}

DownloadItem _download(
  String id,
  String title,
  DownloadStatus status, {
  double progress = 0,
}) => DownloadItem(
  id: id,
  track: Track(
    id: id,
    name: title,
    artistName: 'An artist',
    albumName: 'An album',
    duration: 180,
  ),
  service: 'service',
  status: status,
  progress: progress,
  createdAt: DateTime(2026),
);

const _track = MediaItem(id: 'track', title: 'A song', artist: 'An artist');

ThemeData _theme(bool mornye) =>
    mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light();

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDesktopPlatformOverride = true;
    desktopNowPlayingOpen.value = false;
    desktopInspectorPanel.value = null;
    desktopSidebarCollapsed.value = false;
  });

  tearDown(() {
    debugDesktopPlatformOverride = null;
    desktopWindowFullScreen.value = false;
    desktopNowPlayingOpen.value = false;
    desktopInspectorPanel.value = null;
    desktopSidebarCollapsed.value = false;
  });

  Future<void> setWindow(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget app({
    required bool mornye,
    required Widget home,
    List<Override> overrides = const [],
    GlobalKey<NavigatorState>? navigatorKey,
  }) => ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      navigatorKey: navigatorKey,
      theme: _theme(mornye),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: navigatorKey == null
          ? null
          : (context, child) =>
                DesktopShortcuts(navigatorKey: navigatorKey, child: child!),
      home: home,
    ),
  );

  test('downloads summary matches the previous count and progress', () {
    const progress = [-0.2, 0.0, 1 / 3, 0.5, 1.4, 0.71, 0.1];
    final items = [
      for (var i = 0; i < 90; i++)
        _download(
          '$i',
          'Song $i',
          DownloadStatus.values[i * 5 % DownloadStatus.values.length],
          progress: progress[i % progress.length],
        ),
    ];
    for (var length = 0; length <= items.length; length++) {
      final active = activeDesktopDownloads(items.sublist(0, length));
      var total = 0.0;
      for (final item in active) {
        total += item.status == DownloadStatus.finalizing
            ? 1
            : item.status == DownloadStatus.downloading
            ? item.progress.clamp(0.0, 1.0)
            : 0;
      }
      expect(desktopDownloadsSummary(items.sublist(0, length)), (
        count: active.length,
        progress: active.isEmpty ? 0.0 : total / active.length,
      ));
    }
  });

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    group('$style settings', () {
      testWidgets('shows categories beside the selected page', (tester) async {
        final semantics = tester.ensureSemantics();
        await setWindow(tester, 1400);
        await tester.pumpWidget(
          app(
            mornye: mornye,
            home: Scaffold(
              body: SettingsTab(
                remoteConfigService: AppRemoteConfigService(
                  client: MockClient((_) async => http.Response('{}', 200)),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final list = find.byKey(const ValueKey('settings-category-list'));
        expect(list, findsOneWidget);
        final appearance = find.descendant(
          of: list,
          matching: find.byKey(const ValueKey('settings-category:Appearance')),
        );
        expect(appearance, findsOneWidget);
        // The first category opens in the detail pane, not as a route.
        expect(find.byType(Navigator), findsNWidgets(2));

        await tester.tap(appearance);
        await tester.pumpAndSettle();
        final detail = find.descendant(
          of: find.byType(Navigator).last,
          matching: find.text('Appearance'),
        );
        expect(detail, findsWidgets);
        expect(
          tester.getSemantics(
            find.descendant(of: appearance, matching: find.byType(InkWell)),
          ),
          isSemantics(isSelected: true, hasTapAction: true),
        );
        semantics.dispose();
        expect(list, findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('keeps the single list in narrow panes', (tester) async {
        await setWindow(tester, 600);
        await tester.pumpWidget(
          app(
            mornye: mornye,
            home: Scaffold(
              body: SettingsTab(
                remoteConfigService: AppRemoteConfigService(
                  client: MockClient((_) async => http.Response('{}', 200)),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('settings-category-list')),
          findsNothing,
        );
      });
    });

    group('$style inspector', () {
      List<Override> playerOverrides() => [
        currentMediaItemProvider.overrideWithBuild(
          (ref, notifier) => Stream.value(_track),
        ),
        playbackStateProvider.overrideWith(
          (ref) => Stream.value(PlaybackState()),
        ),
        playQueueProvider.overrideWith((ref) => Stream.value(const [_track])),
        systemVolumeProvider.overrideWith((ref) => Stream.value(0.5)),
        downloadQueueProvider.overrideWith(() => _Queue(const [])),
      ];

      Future<void> pumpShell(
        WidgetTester tester,
        double width, {
        Widget nowPlaying = const Center(child: Text('now playing')),
      }) async {
        await setWindow(tester, width);
        final navigatorKey = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          app(
            mornye: mornye,
            navigatorKey: navigatorKey,
            overrides: playerOverrides(),
            home: Scaffold(
              body: DesktopShellLayout(
                destinations: const [
                  DesktopDestination(
                    tab: ShellTab.home,
                    icon: Icons.circle_outlined,
                    selectedIcon: Icons.circle,
                    label: 'home',
                  ),
                ],
                selected: ShellTab.home,
                onSelected: (_) {},
                // Destinations live in nested navigators, like the shell's.
                body: Navigator(
                  onGenerateRoute: (_) => PageRouteBuilder<void>(
                    pageBuilder: (_, _, _) =>
                        const Center(child: Text('content')),
                  ),
                ),
                nowPlaying: nowPlaying,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> pressShortcut(
        WidgetTester tester,
        LogicalKeyboardKey key,
      ) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
        await tester.pumpAndSettle();
      }

      testWidgets('sits beside the content at 1400', (tester) async {
        await pumpShell(tester, 1400);
        final lyrics = find.byKey(const ValueKey('desktop-inspector-lyrics'));
        expect(lyrics, findsNothing);

        await tester.tap(find.byKey(const ValueKey('desktop-player-lyrics')));
        await tester.pumpAndSettle();
        expect(lyrics, findsOneWidget);
        expect(tester.getSize(lyrics).width, desktopInspectorWidth);
        final content = tester.getRect(find.text('content'));
        expect(content.right, lessThan(tester.getRect(lyrics).left));

        await pressShortcut(tester, LogicalKeyboardKey.keyU);
        expect(lyrics, findsNothing);
        expect(
          find.byKey(const ValueKey('desktop-inspector-upNext')),
          findsOneWidget,
        );
        // Escape leaves an inspector that sits beside the content open.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('desktop-inspector-upNext')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const ValueKey('desktop-player-up-next')));
        await tester.pumpAndSettle();
        expect(desktopInspectorPanel.value, isNull);
        expect(tester.takeException(), isNull);
      });

      testWidgets('floats over the content at 1000', (tester) async {
        await pumpShell(tester, 1000);
        await pressShortcut(tester, LogicalKeyboardKey.keyL);
        final lyrics = find.byKey(const ValueKey('desktop-inspector-lyrics'));
        expect(lyrics, findsOneWidget);
        final content = tester.getRect(
          find.ancestor(
            of: find.text('content'),
            matching: find.byType(Center),
          ),
        );
        expect(content.right, 1000);
        expect(tester.getRect(lyrics).right, 1000);
        expect(tester.getRect(lyrics).left, lessThan(content.right));

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(lyrics, findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('Now Playing covers the window and Escape returns', (
        tester,
      ) async {
        await pumpShell(tester, 1400);
        desktopNowPlayingOpen.value = true;
        await tester.pumpAndSettle();
        expect(find.text('now playing'), findsOneWidget);
        expect(find.text('content'), findsNothing);
        expect(find.text('home'), findsNothing);
        expect(
          tester.getSize(find.byKey(const ValueKey('desktop-now-playing'))),
          const Size(1400, 800),
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('now playing'), findsNothing);
        expect(find.text('content'), findsOneWidget);
      });

      testWidgets('Now Playing lines the timeline up with the cover', (
        tester,
      ) async {
        await pumpShell(tester, 1400, nowPlaying: const DesktopNowPlaying());
        desktopNowPlayingOpen.value = true;
        await tester.pumpAndSettle();
        // The Material backdrop blurs another copy of the artwork.
        final cover = tester.getRect(
          find.byWidgetPredicate(
            (widget) => widget is PlayerArtwork && widget.iconSize == 96,
          ),
        );
        final timeline = tester.getRect(find.byType(PlaybackSeekSlider));
        expect(timeline.left, cover.left);
        expect(timeline.right, cover.right);
      });

      testWidgets('full screen opens lyrics in Now Playing', (tester) async {
        bindDesktopFullScreenLyrics();
        await pumpShell(tester, 1400, nowPlaying: const DesktopNowPlaying());
        final player = find.byKey(const ValueKey('desktop-now-playing'));
        final inspectorLyrics = find.byKey(
          const ValueKey('desktop-inspector-lyrics'),
        );

        // A window that is not full screen shows lyrics in the panel.
        await tester.tap(find.byKey(const ValueKey('desktop-player-lyrics')));
        await tester.pumpAndSettle();
        expect(player, findsNothing);
        expect(inspectorLyrics, findsOneWidget);
        desktopInspectorPanel.value = null;

        desktopWindowFullScreen.value = true;
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('desktop-player-lyrics')));
        await tester.pumpAndSettle();
        expect(player, findsOneWidget);
        expect(
          find.byKey(const ValueKey('desktop-now-playing-lyrics')),
          findsOneWidget,
        );
        expect(find.text('content'), findsNothing);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(player, findsNothing);
        expect(desktopInspectorPanel.value, isNull);
        expect(find.text('content'), findsOneWidget);

        // Entering full screen with lyrics open moves them into the player.
        desktopWindowFullScreen.value = false;
        desktopInspectorPanel.value = DesktopInspectorPanel.lyrics;
        await tester.pumpAndSettle();
        expect(inspectorLyrics, findsOneWidget);
        desktopWindowFullScreen.value = true;
        await tester.pumpAndSettle();
        expect(player, findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey('desktop-now-playing-close')),
        );
        await tester.pumpAndSettle();
        expect(player, findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('nested navigators leave the chrome readable', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await pumpShell(tester, 1400);
        expect(find.bySemanticsLabel('content'), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp('home')), findsWidgets);
        semantics.dispose();
      });
    });

    testWidgets('$style downloads popover lists active downloads', (
      tester,
    ) async {
      await setWindow(tester, 1200);
      final queue = _Queue([
        _download(
          'a',
          'Running song',
          DownloadStatus.downloading,
          progress: 0.4,
        ),
        _download('b', 'Waiting song', DownloadStatus.queued),
        _download('c', 'Done song', DownloadStatus.completed, progress: 1),
      ]);
      final requested = <ShellTab>[];
      final links = <String>[];
      final owner = Object();
      ShellNavigationService.registerTabSelectionHandler(
        owner: owner,
        handler: requested.add,
        // Like the shell: only the Mornye sidebar has Library links.
        libraryLinkHandler: (id) {
          if (!mornye) return false;
          links.add(id);
          return true;
        },
      );
      addTearDown(
        () => ShellNavigationService.unregisterTabSelectionHandler(owner),
      );
      await tester.pumpWidget(
        app(
          mornye: mornye,
          overrides: [downloadQueueProvider.overrideWith(() => queue)],
          home: const Scaffold(body: Center(child: DesktopDownloadsButton())),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('desktop-downloads-progress')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('desktop-downloads-button')));
      await tester.pumpAndSettle();
      final popover = find.byKey(const ValueKey('desktop-downloads-popover'));
      expect(popover, findsOneWidget);
      expect(find.text('Running song'), findsOneWidget);
      expect(find.text('Waiting song'), findsOneWidget);
      expect(find.text('Done song'), findsNothing);
      expect(find.textContaining('40%'), findsOneWidget);

      await tester.tap(find.byTooltip('Cancel download').first);
      expect(queue.cancelled, ['a']);

      await tester.tap(
        find.byKey(const ValueKey('desktop-downloads-show-all')),
      );
      await tester.pumpAndSettle();
      // Mornye opens its Downloads page, not whichever Library page was
      // open last.
      expect(requested, mornye ? isEmpty : [ShellTab.library]);
      expect(links, mornye ? ['downloads'] : isEmpty);
      expect(popover, findsNothing);
    });

    testWidgets('$style downloads button rebuilds only for its ring', (
      tester,
    ) async {
      final done = _download('c', 'Done song', DownloadStatus.completed);
      final queue = _Queue([
        _download('a', 'Running song', DownloadStatus.downloading),
        done,
      ]);
      await tester.pumpWidget(
        app(
          mornye: mornye,
          overrides: [downloadQueueProvider.overrideWith(() => queue)],
          home: const Scaffold(body: Center(child: DesktopDownloadsButton())),
        ),
      );
      final ring = find.byKey(const ValueKey('desktop-downloads-progress'));
      final idle = tester.widget<AppProgressIndicator>(ring);

      // A failed item changes the queue but not the count or the ring.
      queue.replace([
        _download('a', 'Running song', DownloadStatus.downloading),
        done,
        _download('d', 'Failed song', DownloadStatus.failed),
      ]);
      await tester.pump();
      expect(identical(tester.widget(ring), idle), isTrue);

      queue.replace([
        _download('a', 'Running song', DownloadStatus.downloading, progress: 1),
        done,
      ]);
      await tester.pump();
      expect(tester.widget<AppProgressIndicator>(ring).value, 1);
    });

    for (final desktop in [true, false]) {
      testWidgets(
        '$style sheet helper shows a ${desktop ? 'dialog' : 'sheet'}',
        (tester) async {
          debugDesktopPlatformOverride = desktop;
          await setWindow(tester, 1200);
          await tester.pumpWidget(
            app(
              mornye: mornye,
              home: Scaffold(
                body: Builder(
                  builder: (context) => Center(
                    child: TextButton(
                      onPressed: () => showAppBottomSheet<void>(
                        context: context,
                        title: 'Sheet title',
                        builder: (_) => const Text('Sheet body'),
                      ),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
          expect(find.text('Sheet body'), findsOneWidget);
          final dialog = find.byKey(const ValueKey('app-sheet-dialog'));
          if (desktop) {
            expect(dialog, findsOneWidget);
            expect(find.byType(BottomSheet), findsNothing);
            final surface = find
                .descendant(of: dialog, matching: find.byType(Material))
                .first;
            expect(
              tester.getSize(surface).width,
              lessThanOrEqualTo(appSheetDialogMaxWidth),
            );
            final rect = tester.getRect(surface);
            expect(rect.center.dx, closeTo(600, 1));
          } else {
            expect(dialog, findsNothing);
            expect(find.byType(BottomSheet), findsOneWidget);
          }
        },
      );
    }
  }
}
