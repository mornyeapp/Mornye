import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
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
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/desktop/desktop_downloads_button.dart';
import 'package:mornye/widgets/desktop/desktop_player_bar.dart';
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

    Widget host(String? artUri, ThemeData theme, {bool reduceMotion = false}) =>
        MaterialApp(
          theme: theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reduceMotion),
            child: child!,
          ),
          home: PlayerArtworkTheme(
            artUri: artUri,
            child: const SizedBox(key: probe),
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

    Widget app(Widget home, {required bool mornye}) => ProviderScope(
      overrides: [
        currentMediaItemProvider.overrideWithBuild(
          (ref, notifier) => Stream.value(track),
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
      final surface = tester.widget<Material>(
        find.descendant(of: bar, matching: find.byType(Material)).first,
      );
      expect(surface.color, cover.surfaceContainer);
      expect(Theme.of(tester.element(find.text('Song'))).colorScheme, cover);
      final play = tester
          .widgetList<AppIconButton>(
            find.descendant(of: bar, matching: find.byType(AppIconButton)),
          )
          .singleWhere((button) => button.style?.backgroundColor != null);
      expect(play.style!.backgroundColor!.resolve({}), cover.primary);
      expect(play.style!.foregroundColor!.resolve({}), cover.onPrimary);
      // Downloads are app chrome hosted in the bar.
      expect(
        Theme.of(
          tester.element(find.byType(DesktopDownloadsButton)),
        ).colorScheme,
        AppTheme.light().colorScheme,
      );
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
      // The card, whose scaffold shows the scheme's surface.
      ProviderScope.containerOf(
        tester.element(find.byType(NowPlayingScreen)),
      ).read(settingsProvider.notifier).setPlayerCoverStyle('default');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      final scaffold = tester.widget<Scaffold>(
        find
            .descendant(
              of: find.byType(NowPlayingScreen),
              matching: find.byType(Scaffold),
            )
            .first,
      );
      expect(scaffold.backgroundColor, cover.surface);
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
