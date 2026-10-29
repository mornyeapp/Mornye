import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/player_artwork_video_provider.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/screens/downloaded_album_screen.dart';
import 'package:mornye/screens/local_album_screen.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/motion_artwork_store.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_player_artwork.dart';
import 'package:mornye/widgets/motion_header_banner.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _VideoPlatform extends VideoPlayerPlatform {
  bool playing = false;
  int playCalls = 0;
  bool looping = false;
  double volume = 1;
  DataSource? source;
  int creations = 0;
  int disposals = 0;
  Map<int, StreamController<VideoEvent>>? events;
  Completer<void>? disposalPending;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    source = options.dataSource;
    final id = ++creations;
    events?[id] = StreamController<VideoEvent>();
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) =>
      events?[playerId]?.stream ??
      Stream.value(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 30),
          size: const Size(320, 180),
        ),
      );

  @override
  Future<void> play(int playerId) async {
    playing = true;
    playCalls++;
  }

  @override
  Future<void> pause(int playerId) async => playing = false;

  @override
  Future<void> setLooping(int playerId, bool looping) async =>
      this.looping = looping;

  @override
  Future<void> setVolume(int playerId, double volume) async =>
      this.volume = volume;

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox();

  @override
  Future<void> dispose(int playerId) async {
    disposals++;
    await disposalPending?.future;
    await events?[playerId]?.close();
  }
}

class _MotionSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final prepared in [false, true]) {
    testWidgets(
      'failed video is disposed while its owner stays mounted ($prepared)',
      (tester) async {
        final previous = VideoPlayerPlatform.instance;
        final platform = _VideoPlatform()
          ..events = {}
          ..disposalPending = Completer<void>();
        VideoPlayerPlatform.instance = platform;
        addTearDown(() => VideoPlayerPlatform.instance = previous);
        final container = ProviderContainer(
          overrides: [settingsProvider.overrideWith(_MotionSettings.new)],
        );
        const source = 'file:///failed-cover.mp4';
        final failure = PlatformException(
          code: 'video',
          message: 'Invalid cover',
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: prepared
                  ? Consumer(
                      builder: (context, ref, _) {
                        final video = ref.watch(
                          playerArtworkVideoProvider(source),
                        );
                        return Text(
                          video.hasError ? 'Failed cover' : 'Preparing',
                        );
                      },
                    )
                  : const MotionHeaderBanner(
                      videoUrl: source,
                      fallback: Text('Failed cover'),
                    ),
            ),
          ),
        );
        await tester.pump();
        expect(platform.creations, 1);
        platform.events![1]!.addError(failure);
        await tester.pump();
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        expect(find.text('Failed cover'), findsOneWidget);
        expect(platform.disposals, 1);
        // Tear down before platform disposal completes to cover concurrent calls.
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        await tester.pump();
        expect(platform.disposals, 1);
        platform.disposalPending!.complete();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        expect(platform.disposals, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('artwork switch prevents decoding and disposes active video', (
    tester,
  ) async {
    final previous = VideoPlayerPlatform.instance;
    final platform = _VideoPlatform();
    VideoPlayerPlatform.instance = platform;
    addTearDown(() => VideoPlayerPlatform.instance = previous);
    final container = ProviderContainer(
      overrides: [settingsProvider.overrideWith(_MotionSettings.new)],
    );
    addTearDown(container.dispose);
    container.read(settingsProvider.notifier).setMotionArtworkEnabled(false);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: MotionHeaderBanner(
            videoUrl: 'file:///cover.mp4',
            fallback: Text('Still artwork'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(platform.creations, 0);
    expect(find.text('Still artwork'), findsOneWidget);
    container.read(settingsProvider.notifier).setMotionArtworkEnabled(true);
    await tester.pumpAndSettle();
    expect(platform.creations, 1);
    expect(platform.playing, isTrue);
    container.read(settingsProvider.notifier).setMotionArtworkEnabled(false);
    await tester.pumpAndSettle();
    expect(find.text('Still artwork'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Controller disposal awaits cancellation of the platform event stream.
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    expect(platform.disposals, 1);
    await tester.pumpWidget(const SizedBox());
  });
  for (final downloaded in [false, true]) {
    for (final mode in ['saved', 'missing', 'reduced motion']) {
      testWidgets(
        'local album uses saved motion with fallback (downloaded: $downloaded, $mode)',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final previous = VideoPlayerPlatform.instance;
          final platform = _VideoPlatform();
          VideoPlayerPlatform.instance = platform;
          addTearDown(() => VideoPlayerPlatform.instance = previous);
          const channel = MethodChannel('com.zarz.mornye/backend');
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(channel, (_) async => null);
          addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
          var lookups = 0;
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                playerMotionArtworkProvider.overrideWith((ref, album) async {
                  lookups++;
                  expect(album, (album: 'Album', artist: 'Track Artist'));
                  return mode == 'missing'
                      ? null
                      : const MotionArtwork('file:///album-cover.mp4');
                }),
                downloadedAlbumTracksProvider(
                  const DownloadedAlbumTracksRequest(
                    albumName: 'Album',
                    artistName: 'Album Artist',
                  ),
                ).overrideWith(
                  (ref) async => [
                    DownloadHistoryItem(
                      id: 'track',
                      trackName: 'Track',
                      artistName: 'Track Artist',
                      albumName: 'Album',
                      albumArtist: 'Album Artist',
                      filePath: 'content://library/track.flac',
                      service: 'provider-a',
                      downloadedAt: DateTime(2026),
                    ),
                  ],
                ),
              ],
              child: MaterialApp(
                theme: MornyeTheme.build(Brightness.light),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: mode == 'reduced motion'),
                  child: child!,
                ),
                home: downloaded
                    ? const DownloadedAlbumScreen(
                        albumName: 'Album',
                        artistName: 'Album Artist',
                      )
                    : LocalAlbumScreen(
                        albumName: 'Album',
                        artistName: 'Album Artist',
                        tracks: [
                          LocalLibraryItem(
                            id: 'track',
                            trackName: 'Track',
                            artistName: 'Track Artist',
                            albumName: 'Album',
                            albumArtist: 'Album Artist',
                            filePath: 'content://library/track.flac',
                            scannedAt: DateTime(2026),
                          ),
                        ],
                      ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(lookups, mode == 'reduced motion' ? 0 : 1);
          if (mode == 'saved') {
            expect(find.byType(MotionHeaderBanner), findsOneWidget);
            expect(platform.source?.sourceType, DataSourceType.file);
            expect(platform.playing, isTrue);
            expect(platform.looping, isTrue);
            expect(platform.volume, 0);
          } else {
            expect(find.byType(MotionHeaderBanner), findsNothing);
            expect(platform.creations, 0);
          }
          expect(find.text('Album Artist'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        },
      );
    }
  }

  testWidgets(
    'prepared player video opens without a new decoder or cover fade',
    (tester) async {
      final previous = VideoPlayerPlatform.instance;
      final platform = _VideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      final show = ValueNotifier(false);
      addTearDown(show.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                ref.watch(playerArtworkVideoProvider('file:///cover.mp4'));
                return ValueListenableBuilder(
                  valueListenable: show,
                  builder: (_, visible, _) => visible
                      ? const MornyePlayerArtwork(
                          mediaItem: MediaItem(id: 'song', title: 'Song'),
                          videoUrl: 'file:///cover.mp4',
                        )
                      : const SizedBox(),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(platform.creations, 1);
      expect(platform.playing, isFalse);
      show.value = true;
      await tester.pump();
      expect(platform.creations, 1);
      expect(platform.playing, isTrue);
      final banner = tester.widget<MotionHeaderBanner>(
        find.byType(MotionHeaderBanner),
      );
      expect(banner.controller!.value.isInitialized, isTrue);
      expect(banner.fadeDuration, Duration.zero);
      show.value = false;
      await tester.pump();
      expect(platform.playing, isFalse);
      expect(platform.disposals, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(platform.disposals, 1);
    },
  );

  testWidgets('an outgoing cover leaves the shared video playing', (
    tester,
  ) async {
    final previous = VideoPlayerPlatform.instance;
    final platform = _VideoPlatform();
    VideoPlayerPlatform.instance = platform;
    addTearDown(() => VideoPlayerPlatform.instance = previous);
    // Rotating the player fades the portrait cover out while the landscape
    // cover borrows the same video.
    final covers = ValueNotifier({'portrait'});
    addTearDown(covers.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              ref.watch(playerArtworkVideoProvider('file:///cover.mp4'));
              return ValueListenableBuilder(
                valueListenable: covers,
                builder: (_, shown, _) => Column(
                  children: [
                    for (final cover in shown)
                      SizedBox(
                        key: ValueKey(cover),
                        height: 100,
                        child: const MornyePlayerArtwork(
                          mediaItem: MediaItem(id: 'song', title: 'Song'),
                          videoUrl: 'file:///cover.mp4',
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(platform.playing, isTrue);
    covers.value = {'portrait', 'landscape'};
    await tester.pump();
    expect(platform.playing, isTrue);
    covers.value = {'landscape'};
    await tester.pump();
    expect(platform.playing, isTrue);
    covers.value = {};
    await tester.pump();
    expect(platform.playing, isFalse);
    expect(platform.disposals, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  });

  testWidgets('changing tracks retains video until the new frame is ready', (
    tester,
  ) async {
    final previous = VideoPlayerPlatform.instance;
    final platform = _VideoPlatform()..events = {};
    VideoPlayerPlatform.instance = platform;
    addTearDown(() => VideoPlayerPlatform.instance = previous);
    final source = ValueNotifier('file:///first.mp4');
    addTearDown(source.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ValueListenableBuilder(
            valueListenable: source,
            builder: (_, url, _) => MornyePlayerArtwork(
              mediaItem: MediaItem(id: url, title: 'Song'),
              videoUrl: url,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    void ready(int id) => platform.events![id]!.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 10),
        size: const Size(300, 400),
      ),
    );
    ready(1);
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<MotionHeaderBanner>(find.byType(MotionHeaderBanner))
          .videoUrl,
      source.value,
    );
    source.value = 'file:///second.mp4';
    await tester.pump();
    expect(
      tester
          .widget<MotionHeaderBanner>(find.byType(MotionHeaderBanner))
          .videoUrl,
      'file:///first.mp4',
    );
    expect(platform.disposals, 0);
    ready(2);
    await tester.pump();
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(platform.disposals, 1, reason: 'Release the outgoing decoder');
    expect(
      tester
          .widget<MotionHeaderBanner>(find.byType(MotionHeaderBanner))
          .videoUrl,
      source.value,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'offline cover uses a silent looping file and reports its ratio',
    (tester) async {
      final previousPlatform = VideoPlayerPlatform.instance;
      final platform = _VideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previousPlatform);
      double? ratio;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [settingsProvider.overrideWith(_MotionSettings.new)],
          child: MaterialApp(
            home: SizedBox(
              width: 320,
              height: 180,
              child: MotionHeaderBanner(
                videoUrl: 'file:///app/motion_artwork/cover.mp4',
                fallback: const ColoredBox(color: Colors.black),
                onAspectRatioChanged: (value) => ratio = value,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(platform.source?.sourceType, DataSourceType.file);
      expect(platform.looping, isTrue);
      expect(platform.volume, 0);
      expect(platform.playing, isTrue);
      expect(ratio, closeTo(320 / 180, 0.001));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('collapsed headers pause video and visible headers resume', (
    tester,
  ) async {
    final previousPlatform = VideoPlayerPlatform.instance;
    final platform = _VideoPlatform();
    VideoPlayerPlatform.instance = platform;
    addTearDown(() => VideoPlayerPlatform.instance = previousPlatform);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);

    Widget app({bool active = true}) => ProviderScope(
      overrides: [settingsProvider.overrideWith(_MotionSettings.new)],
      child: MaterialApp(
        home: Scaffold(
          body: TickerMode(
            enabled: active,
            child: CustomScrollView(
              controller: scroll,
              slivers: const [
                SliverAppBar(
                  pinned: true,
                  expandedHeight: 300,
                  flexibleSpace: FlexibleSpaceBar(
                    background: MotionHeaderBanner(
                      videoUrl: 'https://example.com/banner.m3u8',
                      fallback: ColoredBox(color: Colors.blue),
                    ),
                  ),
                ),
                SliverToBoxAdapter(child: SizedBox(height: 2000)),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(app());
    await tester.pump();
    expect(platform.playing, isTrue);
    expect(platform.looping, isTrue);
    expect(platform.volume, 0);
    final initialPlayCalls = platform.playCalls;

    scroll.jumpTo(50);
    await tester.pump();
    expect(platform.playCalls, initialPlayCalls);
    scroll.jumpTo(400);
    await tester.pump();
    expect(platform.playing, isFalse);

    scroll.jumpTo(0);
    await tester.pump();
    expect(platform.playing, isTrue);
    await tester.pumpWidget(app(active: false));
    await tester.pump();
    expect(platform.playing, isFalse);
    await tester.pumpWidget(app());
    await tester.pump();
    expect(platform.playing, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(platform.playing, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(platform.playing, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
