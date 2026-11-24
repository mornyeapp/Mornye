import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/system_volume_provider.dart';
import 'package:mornye/screens/now_playing_screen.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/player_artwork_theme.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/desktop/desktop_downloads_button.dart';
import 'package:mornye/widgets/desktop/desktop_player_bar.dart';
import 'package:mornye/widgets/expressive_playback_transport.dart';
import 'package:mornye/widgets/mini_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hands out cover schemes without decoding images: [cached] answers a peek
/// at once, and any other cover waits until the test calls [complete].
class _FakePalette extends PlayerArtworkPalette {
  final cached = <String, ColorScheme>{};
  final requests = <String>[];
  final _pending = <String, Completer<ColorScheme?>>{};

  @override
  ColorScheme? peek(String source, Brightness brightness) => cached[source];

  @override
  Future<ColorScheme?> resolve(String source, Brightness brightness) {
    requests.add(source);
    final scheme = cached[source];
    if (scheme != null) return Future.value(scheme);
    return _pending.putIfAbsent(source, Completer.new).future;
  }

  void complete(String source, ColorScheme? scheme) {
    if (scheme != null) cached[source] = scheme;
    _pending.remove(source)!.complete(scheme);
  }
}

class _Controller implements MusicPlayerController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}

const _coverA = '/covers/a.jpg';
const _coverB = '/covers/b.jpg';

ColorScheme _seeded(Color seed, [Brightness brightness = Brightness.light]) =>
    ColorScheme.fromSeed(seedColor: seed, brightness: brightness);

void main() {
  late _FakePalette palette;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    palette = _FakePalette();
    PlayerArtworkTheme.debugPalette = palette;
  });

  tearDown(() => PlayerArtworkTheme.debugPalette = null);

  test('palette sources follow the artwork forms the player shows', () {
    expect(
      coverImageSource('https://example.test/a.jpg'),
      'https://example.test/a.jpg',
    );
    expect(coverImageSource(Uri.file(_coverA).toString()), _coverA);
    expect(coverImageSource(_coverA), _coverA);
    expect(coverImageSource('content://media/cover'), isNull);
    expect(coverImageSource('network://connection/cover.jpg'), isNull);
    expect(coverImageSource('file://host/covers/a.jpg'), isNull);
    expect(coverImageSource('covers/a.jpg'), isNull);
    expect(coverImageSource(null), isNull);
  });

  group('PlayerArtworkTheme', () {
    const probe = Key('probe');
    final red = _seeded(Colors.red);
    final green = _seeded(Colors.green);

    ColorScheme shown(WidgetTester tester) =>
        Theme.of(tester.element(find.byKey(probe))).colorScheme;

    Widget host(
      String? artUri,
      ThemeData theme, {
      bool reduceMotion = false,
      bool fadesSurfaceOnly = false,
      bool hidden = false,
      Widget child = const SizedBox(key: probe),
    }) => MaterialApp(
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: TickerMode(
        enabled: !hidden,
        child: PlayerArtworkTheme(
          artUri: artUri,
          fadesSurfaceOnly: fadesSurfaceOnly,
          child: child,
        ),
      ),
    );

    testWidgets('shows a cached cover scheme from the first frame', (
      tester,
    ) async {
      palette.cached[_coverA] = red;
      await tester.pumpWidget(host(_coverA, AppTheme.light()));
      expect(shown(tester), red);
      expect(palette.requests, [_coverA]);
    });

    testWidgets('keeps the previous scheme until the next cover resolves, '
        'then moves every role at once', (tester) async {
      final theme = AppTheme.light();
      palette.cached[_coverA] = red;
      await tester.pumpWidget(host(_coverA, theme));
      await tester.pumpWidget(host(_coverB, theme));
      await tester.pump(const Duration(seconds: 1));
      expect(shown(tester), red);

      palette.complete(_coverB, green);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final midway = shown(tester);
      for (final (from, to, now) in [
        (red.primary, green.primary, midway.primary),
        (red.surface, green.surface, midway.surface),
        (
          red.secondaryContainer,
          green.secondaryContainer,
          midway.secondaryContainer,
        ),
      ]) {
        expect(now, isNot(from));
        expect(now, isNot(to));
      }

      await tester.pumpAndSettle();
      expect(shown(tester), green);
      expect(palette.requests, [_coverA, _coverB]);
    });

    testWidgets('makes no animation while it only follows the app scheme, '
        'then moves to a cover', (tester) async {
      Listenable animation() => tester
          .widget<AnimatedBuilder>(
            find
                .descendant(
                  of: find.byType(PlayerArtworkTheme),
                  matching: find.byType(AnimatedBuilder),
                )
                .first,
          )
          .listenable;

      final theme = AppTheme.light();
      await tester.pumpWidget(host(null, theme));
      final element = tester.element(find.byKey(probe));
      expect(shown(tester), theme.colorScheme);
      expect(animation(), kAlwaysCompleteAnimation);

      palette.cached[_coverA] = red;
      await tester.pumpWidget(host(_coverA, theme));
      expect(animation(), isA<AnimationController>());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(shown(tester).primary, isNot(theme.colorScheme.primary));
      expect(shown(tester).primary, isNot(red.primary));
      await tester.pumpAndSettle();
      expect(shown(tester), red);
      expect(tester.element(find.byKey(probe)), same(element));
    });

    testWidgets('returns to the app scheme without readable artwork', (
      tester,
    ) async {
      final theme = AppTheme.light();
      palette.cached[_coverA] = red;
      await tester.pumpWidget(host(_coverA, theme));
      await tester.pumpWidget(host(null, theme));
      await tester.pumpAndSettle();
      expect(shown(tester), theme.colorScheme);

      await tester.pumpWidget(host(_coverA, theme));
      await tester.pumpAndSettle();
      expect(shown(tester), red);
      // A cover that cannot be decoded resolves to null.
      await tester.pumpWidget(host(_coverB, theme));
      palette.complete(_coverB, null);
      await tester.pumpAndSettle();
      expect(shown(tester), theme.colorScheme);
    });

    testWidgets('a cover that changed while hidden swaps as the scope shows', (
      tester,
    ) async {
      final theme = AppTheme.light();
      palette.cached[_coverA] = red;
      palette.cached[_coverB] = green;
      await tester.pumpWidget(host(_coverA, theme));
      await tester.pumpWidget(host(_coverA, theme, hidden: true));
      // A paused consumer hands over the next cover in the frame it shows.
      await tester.pumpWidget(host(_coverB, theme));
      expect(shown(tester), green);
      expect(tester.hasRunningAnimations, isFalse);

      await tester.pumpWidget(host(_coverA, theme));
      await tester.pump(const Duration(milliseconds: 40));
      expect(shown(tester).primary, isNot(green.primary));
      expect(shown(tester).primary, isNot(red.primary));
      await tester.pumpAndSettle();
      expect(shown(tester), red);
    });

    testWidgets('a scheme that resolves while hidden swaps in one step', (
      tester,
    ) async {
      final theme = AppTheme.light();
      palette.cached[_coverA] = red;
      await tester.pumpWidget(host(_coverA, theme));
      await tester.pumpWidget(host(_coverB, theme, hidden: true));
      palette.complete(_coverB, green);
      await tester.pump();
      await tester.pump();
      expect(shown(tester), green);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('reduced motion swaps the scheme in one step', (tester) async {
      final theme = AppTheme.light();
      palette.cached[_coverA] = red;
      await tester.pumpWidget(host(_coverA, theme, reduceMotion: true));
      await tester.pumpWidget(host(_coverB, theme, reduceMotion: true));
      palette.complete(_coverB, green);
      await tester.pump();
      await tester.pump();
      expect(shown(tester), green);
    });

    group('moving only the page background', () {
      var builds = 0;
      // Builds whenever the scheme it reads changes.
      final page = PlayerArtworkSurface(
        surface: Colors.pink,
        child: Builder(
          builder: (context) {
            builds++;
            Theme.of(context);
            return const SizedBox(key: probe);
          },
        ),
      );
      Color background(WidgetTester tester) => tester
          .widget<ColoredBox>(
            find.descendant(
              of: find.byType(PlayerArtworkSurface),
              matching: find.byType(ColoredBox),
            ),
          )
          .color;

      setUp(() => builds = 0);

      testWidgets('swaps the scheme in one step while the background moves', (
        tester,
      ) async {
        final theme = AppTheme.light();
        palette.cached[_coverA] = red;
        await tester.pumpWidget(
          host(_coverA, theme, fadesSurfaceOnly: true, child: page),
        );
        expect(shown(tester), red);
        expect(background(tester), red.surface);

        await tester.pumpWidget(
          host(_coverB, theme, fadesSurfaceOnly: true, child: page),
        );
        palette.complete(_coverB, green);
        await tester.pump();
        final before = builds;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        expect(shown(tester), green);
        final midway = background(tester);
        expect(midway, isNot(red.surface));
        expect(midway, isNot(green.surface));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.pumpAndSettle();
        // The page under the theme built only for the swap itself.
        expect(builds - before, lessThanOrEqualTo(1));
        expect(background(tester), green.surface);
      });

      testWidgets('a skip partway through starts from the colour on screen', (
        tester,
      ) async {
        final theme = AppTheme.light();
        palette.cached[_coverA] = red;
        palette.cached[_coverB] = green;
        await tester.pumpWidget(
          host(_coverA, theme, fadesSurfaceOnly: true, child: page),
        );
        await tester.pumpWidget(
          host(_coverB, theme, fadesSurfaceOnly: true, child: page),
        );
        await tester.pump(const Duration(milliseconds: 40));
        final midway = background(tester);
        expect(midway, isNot(green.surface));

        await tester.pumpWidget(
          host(_coverA, theme, fadesSurfaceOnly: true, child: page),
        );
        expect(shown(tester), red);
        expect(background(tester), midway);
        await tester.pumpAndSettle();
        expect(background(tester), red.surface);
      });

      testWidgets('reduced motion swaps the background with the scheme', (
        tester,
      ) async {
        final theme = AppTheme.light();
        palette.cached[_coverA] = red;
        palette.cached[_coverB] = green;
        await tester.pumpWidget(
          host(
            _coverA,
            theme,
            reduceMotion: true,
            fadesSurfaceOnly: true,
            child: page,
          ),
        );
        await tester.pumpWidget(
          host(
            _coverB,
            theme,
            reduceMotion: true,
            fadesSurfaceOnly: true,
            child: page,
          ),
        );
        expect(shown(tester), green);
        expect(background(tester), green.surface);
      });

      testWidgets('outside it the background is the given surface', (
        tester,
      ) async {
        palette.cached[_coverA] = red;
        await tester.pumpWidget(host(_coverA, AppTheme.light(), child: page));
        expect(background(tester), Colors.pink);
      });

      testWidgets('a whole-scheme scope inside it paints its own background', (
        tester,
      ) async {
        palette.cached[_coverA] = red;
        palette.cached[_coverB] = green;
        await tester.pumpWidget(
          host(
            _coverA,
            AppTheme.light(),
            fadesSurfaceOnly: true,
            child: PlayerArtworkTheme(artUri: _coverB, child: page),
          ),
        );
        await tester.pumpAndSettle();
        expect(background(tester), Colors.pink);
      });
    });

    testWidgets('AMOLED keeps the page background pure black', (tester) async {
      final amoled = _seeded(
        Colors.purple,
        Brightness.dark,
      ).copyWith(surface: Colors.black, surfaceContainerLowest: Colors.black);
      final cover = _seeded(Colors.orange, Brightness.dark);
      palette.cached[_coverA] = cover;
      await tester.pumpWidget(
        host(_coverA, AppTheme.dark(dynamicScheme: amoled, isAmoled: true)),
      );
      final theme = Theme.of(tester.element(find.byKey(probe)));
      expect(theme.colorScheme.surface, Colors.black);
      expect(theme.colorScheme.surfaceContainerLowest, Colors.black);
      expect(theme.scaffoldBackgroundColor, Colors.black);
      expect(theme.colorScheme.primary, cover.primary);
      expect(theme.colorScheme.surfaceContainer, cover.surfaceContainer);
    });
  });

  group('player surfaces', () {
    final track = MediaItem(
      id: 'song',
      title: 'Song',
      artist: 'Artist',
      duration: const Duration(minutes: 3),
      artUri: Uri.file(_coverA),
    );
    final cover = _seeded(Colors.teal);

    /// The fill the Material desktop player bar paints behind its controls.
    Color barFill(WidgetTester tester) => tester
        .widget<ColoredBox>(
          find
              .descendant(
                of: find
                    .descendant(
                      of: find.byType(DesktopPlayerBar),
                      matching: find.byType(PlayerArtworkSurface),
                    )
                    .first,
                matching: find.byType(ColoredBox),
              )
              .first,
        )
        .color;

    Widget app(
      Widget home, {
      required bool mornye,
      Stream<MediaItem?>? items,
    }) => ProviderScope(
      overrides: [
        currentMediaItemProvider.overrideWithBuild(
          (ref, notifier) => items ?? Stream.value(track),
        ),
        playbackStateProvider.overrideWith(
          (ref) => Stream.value(PlaybackState()),
        ),
        musicPlayerControllerProvider.overrideWithValue(_Controller()),
        mornyeLiquidGlassProvider.overrideWithValue(false),
        backdropBlurEnabledProvider.overrideWithValue(false),
        systemVolumeProvider.overrideWith((ref) => Stream.value(0.5)),
        systemVolumeWriterProvider.overrideWithValue((value) async {}),
        playerCollectionTrackProvider.overrideWith(
          (ref, item) async => Track(
            id: item.id,
            name: item.title,
            artistName: item.artist ?? '',
            albumName: item.album ?? '',
            duration: item.duration?.inSeconds ?? 0,
            source: 'local',
          ),
        ),
        libraryCollectionsProvider.overrideWith(_Collections.new),
        playQueueProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    );

    testWidgets('the Material player bar takes the cover scheme', (
      tester,
    ) async {
      palette.cached[_coverA] = cover;
      await tester.pumpWidget(
        app(
          const Scaffold(bottomNavigationBar: DesktopPlayerBar()),
          mornye: false,
        ),
      );
      await tester.pumpAndSettle();

      final bar = find.byType(DesktopPlayerBar);
      // Resting chrome keeps its container tier, now from the cover.
      expect(barFill(tester), cover.surfaceContainer);
      expect(Theme.of(tester.element(find.text('Song'))).colorScheme, cover);
      final transport = tester.widget<ExpressivePlaybackTransport>(
        find.descendant(
          of: bar,
          matching: find.byType(ExpressivePlaybackTransport),
        ),
      );
      expect(transport.colorScheme, cover);
      expect(transport.dense, isTrue);
      // Downloads are app chrome hosted in the bar.
      expect(
        Theme.of(
          tester.element(find.byType(DesktopDownloadsButton)),
        ).colorScheme,
        AppTheme.light().colorScheme,
      );
    });

    testWidgets('a song change swaps the Material player bar scheme at once '
        'and fades only its fill', (tester) async {
      final items = StreamController<MediaItem?>.broadcast();
      addTearDown(items.close);
      final red = _seeded(Colors.red);
      palette.cached[_coverA] = cover;
      palette.cached[_coverB] = red;
      await tester.pumpWidget(
        app(
          const Scaffold(bottomNavigationBar: DesktopPlayerBar()),
          mornye: false,
          items: items.stream,
        ),
      );
      items.add(track);
      await tester.pumpAndSettle();
      // The transport stays put while the title crossfades.
      ColorScheme scheme() => Theme.of(
        tester.element(find.byType(ExpressivePlaybackTransport)),
      ).colorScheme;
      expect(scheme(), cover);
      expect(barFill(tester), cover.surfaceContainer);

      items.add(track.copyWith(id: 'b', artUri: Uri.file(_coverB)));
      await tester.pump();
      await tester.pump();
      expect(scheme(), red);
      await tester.pump(const Duration(milliseconds: 48));
      expect(scheme(), red);
      final moving = barFill(tester);
      expect(moving, isNot(cover.surfaceContainer));
      expect(moving, isNot(red.surfaceContainer));
      await tester.pumpAndSettle();
      expect(barFill(tester), red.surfaceContainer);
    });

    testWidgets('the Material mini player takes the cover scheme', (
      tester,
    ) async {
      palette.cached[_coverA] = cover;
      await tester.pumpWidget(
        app(const Scaffold(bottomNavigationBar: MiniPlayer()), mornye: false),
      );
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(find.text('Song'))).colorScheme, cover);
    });

    for (final fadesSurfaceOnly in [false, true]) {
      testWidgets('the Material mini player uses the shell scope for its cover '
          '(${fadesSurfaceOnly ? 'surface only' : 'whole scheme'})', (
        tester,
      ) async {
        palette.cached[_coverA] = cover;
        await tester.pumpWidget(
          app(
            Scaffold(
              bottomNavigationBar: PlayerArtworkTheme(
                artUri: track.artUri.toString(),
                fadesSurfaceOnly: fadesSurfaceOnly,
                child: const MiniPlayer(),
              ),
            ),
            mornye: false,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(PlayerArtworkTheme), findsOneWidget);
        expect(palette.requests, [_coverA]);
        expect(Theme.of(tester.element(find.text('Song'))).colorScheme, cover);
      });
    }

    testWidgets('the Material mini player keeps its own scope under another '
        'cover', (tester) async {
      palette.cached[_coverA] = cover;
      palette.cached[_coverB] = _seeded(Colors.purple);
      await tester.pumpWidget(
        app(
          const Scaffold(
            bottomNavigationBar: PlayerArtworkTheme(
              artUri: _coverB,
              child: MiniPlayer(),
            ),
          ),
          mornye: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PlayerArtworkTheme), findsNWidgets(2));
      expect(Theme.of(tester.element(find.text('Song'))).colorScheme, cover);
    });

    testWidgets('under the shell scope the mini player moves with the bar '
        'on every frame of a skip', (tester) async {
      final items = StreamController<MediaItem?>.broadcast();
      addTearDown(items.close);
      final red = _seeded(Colors.red);
      palette.cached[_coverA] = cover;
      palette.cached[_coverB] = red;
      const probe = Key('bar');
      await tester.pumpWidget(
        app(
          Scaffold(
            bottomNavigationBar: Consumer(
              builder: (context, ref, child) => PlayerArtworkTheme(
                artUri: ref.watch(
                  currentMediaItemProvider.select(
                    (item) => item.value?.artUri?.toString(),
                  ),
                ),
                child: child!,
              ),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MiniPlayer(),
                  SizedBox(key: probe, height: 1),
                ],
              ),
            ),
          ),
          mornye: false,
          items: items.stream,
        ),
      );
      items.add(track);
      await tester.pumpAndSettle();
      expect(find.byType(PlayerArtworkTheme), findsOneWidget);

      ColorScheme bar() =>
          Theme.of(tester.element(find.byKey(probe))).colorScheme;
      ColorScheme mini() => Theme.of(
        tester.element(
          find
              .descendant(
                of: find.byType(MiniPlayer),
                matching: find.byType(InkWell),
              )
              .first,
        ),
      ).colorScheme;
      expect(mini(), cover);

      for (final (next, target) in [
        (track.copyWith(id: 'b', artUri: Uri.file(_coverB)), red),
        (MediaItem(id: 'none', title: 'Plain'), AppTheme.light().colorScheme),
      ]) {
        items.add(next);
        await tester.pump();
        var moving = 0;
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 8));
          if (bar() != target) moving++;
          expect(mini(), bar());
        }
        expect(moving, greaterThan(2));
        expect(mini(), target);
      }
    });

    testWidgets('the Material full player takes the cover scheme', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.zarz.mornye/backend'),
            (_) async => null,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('com.zarz.mornye/backend'),
              null,
            ),
      );
      palette.cached[_coverA] = cover;
      await tester.pumpWidget(app(const NowPlayingScreen(), mornye: false));
      // The card, whose page shows the scheme's surface.
      ProviderScope.containerOf(
        tester.element(find.byType(NowPlayingScreen)),
      ).read(settingsProvider.notifier).setPlayerCoverStyle('default');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      final background = tester.widget<ColoredBox>(
        find
            .descendant(
              of: find.byType(PlayerArtworkSurface),
              matching: find.byType(ColoredBox),
            )
            .first,
      );
      expect(background.color, cover.surface);
      expect(Theme.of(tester.element(find.text('Song'))).colorScheme, cover);
    });

    for (final (name, home) in [
      ('player bar', const Scaffold(bottomNavigationBar: DesktopPlayerBar())),
      ('mini player', const Scaffold(bottomNavigationBar: MiniPlayer())),
    ]) {
      testWidgets('the Mornye $name keeps its own theme', (tester) async {
        palette.cached[_coverA] = cover;
        await tester.pumpWidget(app(home, mornye: true));
        await tester.pumpAndSettle();
        expect(find.byType(PlayerArtworkTheme), findsNothing);
        expect(palette.requests, isEmpty);
        expect(
          Theme.of(tester.element(find.text('Song'))).colorScheme,
          isNot(cover),
        );
      });
    }
  });
}
