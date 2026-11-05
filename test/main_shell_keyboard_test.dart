import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/routes/now_playing_route.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/screens/main_shell.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/tv_navigation.dart';
import 'package:mornye/widgets/tv_shell.dart';
import 'package:mornye/widgets/expressive_navigation_bar.dart';
import 'package:mornye/widgets/mornye_bottom_bar.dart';
import 'package:mornye/widgets/mini_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final languageTags = <Object?>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    languageTags.clear();
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method == 'setMetadataLanguage') {
        languageTags.add((call.arguments as Map)['tag']);
      }
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(backend, null));

  Future<ValueNotifier<Locale>> pumpShell(
    WidgetTester tester, {
    bool tv = false,
    bool mornye = true,
    bool externalPlayer = false,
    bool search = false,
    Stream<MediaItem?>? media,
  }) async {
    debugAndroidTvOverride = tv;
    addTearDown(() => debugAndroidTvOverride = null);
    tester.view.physicalSize = tv ? const Size(960, 540) : const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final locale = ValueNotifier(const Locale('en'));
    addTearDown(locale.dispose);
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => const MainShell())],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(
            () => _Settings(externalPlayer: externalPlayer),
          ),
          if (media != null)
            currentMediaItemProvider.overrideWithBuild(
              (ref, notifier) => media,
            ),
          if (externalPlayer) ...[
            currentMediaItemProvider.overrideWithBuild(
              (ref, notifier) => Stream.value(
                const MediaItem(id: 'old', title: 'Old internal song'),
              ),
            ),
            playbackResumeProvider.overrideWith(
              (ref) async => (
                media: const PlayableMedia(
                  id: 'saved',
                  source: '/music/saved.flac',
                  title: 'Saved song',
                  artist: 'Artist',
                ),
                position: const Duration(seconds: 23),
              ),
            ),
          ],
          extensionProvider.overrideWith(() => _Extensions(search: search)),
          exploreProvider.overrideWith(_Explore.new),
          downloadHistoryProvider.overrideWith(_History.new),
          recentAccessProvider.overrideWith(_Recent.new),
        ],
        child: ValueListenableBuilder(
          valueListenable: locale,
          builder: (context, value, _) => MaterialApp.router(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark)
                : AppTheme.dark(),
            builder: tv
                ? (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(navigationMode: NavigationMode.directional),
                    child: AdaptiveUiScaler(
                      child: SafeArea(
                        minimum: const EdgeInsets.symmetric(
                          horizontal: 40,
                          vertical: 24,
                        ),
                        child: TvNavigation(child: child!),
                      ),
                    ),
                  )
                : null,
            locale: value,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    return locale;
  }

  bool collapsed(WidgetTester tester) =>
      tester.widget<MornyeBottomBar>(find.byType(MornyeBottomBar)).collapsed;

  testWidgets(
    'Material Home restores its viewport and navigation after the player',
    (tester) async {
      Future<void> settleFrames() async {
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
      }

      final media = StreamController<MediaItem?>();
      addTearDown(media.close);
      await pumpShell(tester, mornye: false, search: true, media: media.stream);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
      media.add(
        const MediaItem(id: 'song', title: 'Current song', artist: 'Artist'),
      );
      await settleFrames();
      final scroll = find.descendant(
        of: find.byType(HomeTab),
        matching: find.byType(CustomScrollView),
      );
      expect(find.text('Continue listening'), findsOneWidget);
      expect(find.text('Shortcuts'), findsOneWidget);
      expect(tester.getRect(scroll).bottom, 932);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      expect(tester.getRect(scroll).bottom, 632);
      final home = tester.element(find.byType(HomeTab));
      final navigator = Navigator.of(home, rootNavigator: true);
      unawaited(navigator.push(NowPlayingRoute(child: const Scaffold())));
      await settleFrames();
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      navigator.pop();
      await settleFrames();
      expect(tester.testTextInput.isVisible, isFalse);
      final bar = find.byType(ExpressiveNavigationBar);
      Finder destination(String label) =>
          find.descendant(of: bar, matching: find.text(label));
      await tester.tap(destination('Home'));
      await settleFrames();
      expect(find.text('Shortcuts'), findsOneWidget);
      expect(tester.getRect(scroll).bottom, 932);
      final player = tester.getRect(find.byType(MiniPlayer));
      final viewport = tester.state<ScrollableState>(
        find.descendant(of: scroll, matching: find.byType(Scrollable)).first,
      );
      await tester.dragFrom(
        Offset(player.center.dx, player.top - 20),
        const Offset(0, -120),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(viewport.position.pixels, greaterThan(0));
      await tester.tap(destination('Settings'));
      await settleFrames();
      expect(tester.widget<ExpressiveNavigationBar>(bar).selectedIndex, 3);
      await tester.tap(destination('Home'));
      await settleFrames();
      expect(tester.widget<ExpressiveNavigationBar>(bar).selectedIndex, 0);
      expect(tester.getRect(scroll).bottom, 932);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mornye in [false, true]) {
    testWidgets('external mode hides Home playback and mini player ($mornye)', (
      tester,
    ) async {
      await pumpShell(tester, mornye: mornye, externalPlayer: true);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Continue Listening'), findsNothing);
      expect(find.text('Old internal song'), findsNothing);
      expect(find.text('Saved song'), findsNothing);
      for (final player in find.byType(MiniPlayer).evaluate()) {
        expect(tester.getSize(find.byWidget(player.widget)).height, 0);
      }
      expect(tester.takeException(), isNull);
    });
  }

  void scrollHome(WidgetTester tester, {required double pixels}) {
    ScrollUpdateNotification(
      metrics: FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 2000,
        pixels: pixels,
        viewportDimension: 800,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      ),
      context: tester.element(find.byType(HomeTab).first),
      scrollDelta: 40,
      dragDetails: DragUpdateDetails(globalPosition: Offset.zero),
    ).dispatch(tester.element(find.byType(HomeTab).first));
  }

  testWidgets('keyboard frames do not re-run the shell side effects', (
    tester,
  ) async {
    await pumpShell(tester);
    expect(languageTags, ['en']);
    // A back press at a tab root checks the keyboard too.
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('Press back again to exit'), findsOneWidget);
    final homeTab = find.byKey(const ValueKey('tab-home')).first;
    final tabs = tester.widget(homeTab);

    for (final inset in [80.0, 160.0, 240.0, 300.0, 150.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(languageTags, ['en']);
    // The shell did not rebuild its tab navigators.
    expect(tester.widget(homeTab), same(tabs));
    // Lets the back press snack bar time out.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a locale change still re-runs the shell side effects', (
    tester,
  ) async {
    final locale = await pumpShell(tester);
    locale.value = const Locale('id');
    await tester.pump();
    await tester.pump();

    expect(languageTags, ['en', 'id']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the tab bar stays expanded while the keyboard is up', (
    tester,
  ) async {
    await pumpShell(tester);
    expect(collapsed(tester), isFalse);

    scrollHome(tester, pixels: 400);
    await tester.pump();
    expect(collapsed(tester), isTrue);

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    expect(collapsed(tester), isFalse);

    // Scrolling back to the top with the keyboard up does not reach the bar.
    scrollHome(tester, pixels: 0);
    await tester.pump();
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    expect(collapsed(tester), isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final mornye in [false, true]) {
    testWidgets(
      'TV remote opens Settings and Back returns Home, Mornye: $mornye',
      (tester) async {
        await pumpShell(tester, tv: true, mornye: mornye);
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byType(MornyeBottomBar), findsNothing);
        final tvShell = tester.widget<TvShell>(find.byType(TvShell));
        for (var i = 1; i < tvShell.destinations.length; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.widget<TvShell>(find.byType(TvShell)).selectedIndex,
          tvShell.destinations.length - 1,
        );
        final back = tester.binding.handlePopRoute();
        await tester.pump();
        await back;
        await tester.pump();
        expect(tester.widget<TvShell>(find.byType(TvShell)).selectedIndex, 0);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 1));
      },
    );
  }
}

class _Settings extends SettingsNotifier {
  _Settings({this.externalPlayer = false});

  final bool externalPlayer;

  @override
  AppSettings build() => AppSettings(
    searchProvider: 'example',
    hasSearchedBefore: true,
    playerMode: externalPlayer ? 'external' : 'internal',
  );
}

class _Extensions extends ExtensionNotifier {
  _Extensions({this.search = false});

  final bool search;

  @override
  ExtensionState build() => ExtensionState(
    isInitialized: true,
    extensions: [
      if (search)
        const Extension(
          id: 'example',
          name: 'example',
          displayName: 'Example',
          version: '1.0.0',
          description: '',
          enabled: true,
          status: 'loaded',
          searchBehavior: SearchBehavior(enabled: true),
        ),
    ],
  );
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
