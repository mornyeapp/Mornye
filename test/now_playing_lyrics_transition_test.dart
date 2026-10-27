import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderParagraph, RenderRepaintBoundary, debugOnProfilePaint;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/components/progress_indicators/components/m3e_linear_progress_painter.dart';
import 'package:material_3_expressive/material_3_expressive.dart'
    show M3EIconButton;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/player_artwork_video_provider.dart';
import 'package:mornye/services/motion_artwork_store.dart';
import 'package:mornye/services/network_metadata_service.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:video_player/video_player.dart';
import 'package:mornye/screens/now_playing_screen.dart';
import 'package:mornye/screens/lyrics_share_screen.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';
import 'package:mornye/widgets/expressive_playback_transport.dart';
import 'package:mornye/widgets/expressive_seek_track.dart';
import 'package:mornye/widgets/player_volume_control.dart';
import 'package:mornye/widgets/lyric_blur.dart';
import 'package:mornye/widgets/lyric_gap_indicator.dart';
import 'package:mornye/widgets/mornye_player_queue.dart';
import 'package:mornye/widgets/mornye_playback_button.dart';
import 'package:mornye/widgets/mornye_playback_time.dart';
import 'package:mornye/widgets/mornye_player_actions_sheet.dart';
import 'package:mornye/widgets/mornye_player_favorite_button.dart';
import 'package:mornye/widgets/mornye_player_details_sheet.dart';
import 'package:mornye/widgets/mornye_metadata_row.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_player_background.dart';
import 'package:mornye/widgets/mornye_player_artwork.dart';
import 'package:mornye/widgets/mornye_artwork_contrast.dart';
import 'package:mornye/widgets/mini_player.dart';
import 'package:mornye/widgets/material_player_layout.dart';
import 'package:mornye/widgets/material_player_backdrop.dart';
import 'package:mornye/widgets/mornye_player_layout.dart';
import 'package:mornye/widgets/player_lyrics.dart';
import 'package:mornye/widgets/player_lyrics_controls.dart';
import 'package:mornye/widgets/player_metadata_title.dart';
import 'package:mornye/widgets/player_playback_controls.dart';
import 'package:mornye/widgets/playback_seek_slider.dart';
import 'package:mornye/widgets/player_artwork.dart';

import 'support/app_icon_finder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backendChannel = MethodChannel('com.zarz.mornye/backend');
  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  late StreamController<MediaItem?> mediaItems;
  late List<double> volumeWrites;
  late Map<String, dynamic> metadataOverrides;
  late List<String> metadataReads;
  late List<({String? raw, Completer<ParsedLyrics> completion})> lyricsRequests;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mediaItems = StreamController<MediaItem?>.broadcast();
    volumeWrites = [];
    metadataOverrides = {};
    metadataReads = [];
    lyricsRequests = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, (call) async {
          if (call.method == 'setScreenAwake') return null;
          if (call.method == 'runNativeDataJob') {
            final arguments = (call.arguments as Map).cast<String, dynamic>();
            final request =
                jsonDecode(arguments['request_json'] as String) as Map;
            expect(request['operation'], 'parse_lyrics');
            final raw = utf8.decode(arguments['bytes'] as List<int>);
            return jsonEncode(_lyricsDto(LyricsParser.parse(raw)));
          }
          if (call.method != 'readFileMetadata') {
            fail('Unexpected platform call: ${call.method}');
          }
          final arguments = (call.arguments as Map).cast<String, dynamic>();
          final path = arguments['file_path']?.toString() ?? '';
          metadataReads.add(path);
          final lyrics = path.endsWith('/timed.flac')
              ? '''<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="00:00.000" end="00:02.000"><span begin="00:00.000">Short</span></p></div></body></tt>'''
              : path.endsWith('/many.flac')
              ? '[00:00.00]First line\n[00:02.00]Second line\n[00:04.00]Third line\n[00:06.00]Fourth line'
              : path.endsWith('/second.flac')
              ? '[00:01.00]Second lyric'
              : '[00:01.00]First lyric';
          return jsonEncode({
            'title': path.endsWith('/second.flac') ? 'Second' : 'First',
            'lyrics': lyrics,
            ...metadataOverrides,
          });
        });
  });

  tearDown(() async {
    await mediaItems.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  MediaItem item(String id) => MediaItem(
    id: id,
    title: id == 'first' ? 'First' : 'Second',
    artist: 'Artist',
    album: 'Album',
    duration: const Duration(minutes: 3),
    extras: {'source': 'content://library/$id.flac'},
  );

  Rect seekTrackBounds(WidgetTester tester) {
    final track = find.descendant(
      of: find.descendant(
        of: find.byType(PlaybackSeekSlider),
        matching: find.byType(Slider),
      ),
      matching: find.byWidgetPredicate(
        (widget) => widget is LeafRenderObjectWidget,
      ),
    );
    final box = tester.renderObject<RenderBox>(track);
    final theme = SliderTheme.of(tester.element(track));
    final rect = theme.trackShape!.getPreferredRect(
      parentBox: box,
      sliderTheme: theme,
      isEnabled: true,
    );
    return Rect.fromPoints(
      box.localToGlobal(rect.topLeft),
      box.localToGlobal(rect.bottomRight),
    );
  }

  NowPlayingScreen playerScreen() => NowPlayingScreen(
    metadataControllerFactory: () => PlayerMetadataController(
      parseLyrics: (raw) {
        final completion = Completer<ParsedLyrics>();
        lyricsRequests.add((raw: raw, completion: completion));
        return completion.future;
      },
    ),
  );

  Future<void> pumpNowPlaying(
    WidgetTester tester, {
    ThemeData? theme,
    Size size = const Size(1080, 1920),
    PlaybackState? playback,
    Stream<PlaybackState>? playbackEvents,
    Widget Function(Widget)? wrapPlayer,
    MotionArtwork? motionArtwork,
    MusicPlayerController? controller,
    List<MediaItem> queue = const [],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          if (controller != null)
            musicPlayerControllerProvider.overrideWithValue(controller),
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => mediaItems.stream,
          ),
          playerMotionArtworkProvider.overrideWith(
            (ref, album) async => motionArtwork,
          ),
          playerArtworkVideoProvider.overrideWith(
            (ref, source) => Completer<VideoPlayerController>().future,
          ),
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
          libraryCollectionsProvider.overrideWith(_TestCollections.new),
          playbackStateProvider.overrideWith(
            (ref) =>
                playbackEvents ??
                (playback == null
                    ? const Stream.empty()
                    : Stream.value(playback)),
          ),
          playQueueProvider.overrideWith((ref) => Stream.value(queue)),
          systemVolumeProvider.overrideWith((ref) => Stream.value(0.5)),
          systemVolumeWriterProvider.overrideWith(
            (ref) =>
                (value) async => volumeWrites.add(value),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: theme,
          home: wrapPlayer?.call(playerScreen()) ?? playerScreen(),
        ),
      ),
    );
  }

  Future<void> completeLyrics(WidgetTester tester) async {
    await tester.pump();
    // Start the actual encode/native DTO/hydration pipeline in the real async
    // zone: futures started under FakeAsync cannot finish isolate messages.
    while (lyricsRequests.isNotEmpty) {
      final pending = List.of(lyricsRequests);
      lyricsRequests.clear();
      await tester.runAsync(() async {
        for (final request in pending) {
          try {
            request.completion.complete(
              await LyricsParser.parseAsyncNative(request.raw),
            );
          } catch (error, stack) {
            request.completion.completeError(error, stack);
          }
        }
      });
      await tester.pump();
    }
  }

  Future<int> settlePlayer(
    WidgetTester tester, [
    Duration duration = const Duration(milliseconds: 100),
  ]) async {
    final deadline = tester.binding.clock.fromNowBy(
      const Duration(minutes: 10),
    );
    var frames = 0;
    do {
      if (tester.binding.clock.now().isAfter(deadline)) {
        fail('Player animations did not settle');
      }
      // A track change may start another metadata read during a later frame.
      await completeLyrics(tester);
      await tester.pump(duration);
      frames++;
    } while (tester.binding.hasScheduledFrame || lyricsRequests.isNotEmpty);
    return frames;
  }

  for (final mornye in [false, true]) {
    testWidgets(
      'late duration refreshes the open player without reopening ($mornye)',
      (tester) async {
        await pumpNowPlaying(
          tester,
          theme: mornye ? MornyeTheme.build(Brightness.dark) : null,
          playback: PlaybackState(
            processingState: AudioProcessingState.ready,
            updatePosition: const Duration(seconds: 30),
          ),
          wrapPlayer: (player) => Column(
            children: [
              Expanded(child: player),
              const HeroMode(enabled: false, child: MiniPlayer()),
            ],
          ),
        );
        final initial = item('first').copyWith(duration: Duration.zero);
        mediaItems.add(initial);
        await settlePlayer(tester);
        final originalState = tester.state(find.byType(NowPlayingScreen));
        expect(
          tester
              .widget<PlaybackSeekSlider>(find.byType(PlaybackSeekSlider))
              .duration,
          Duration.zero,
        );
        double miniProgress() => tester
            .widgetList<CustomPaint>(
              find.descendant(
                of: find.byType(MiniPlayer),
                matching: find.byType(CustomPaint),
              ),
            )
            .map((paint) => paint.painter)
            .whereType<M3ELinearProgressPainter>()
            .single
            .value!;
        if (!mornye) expect(miniProgress(), 0);
        final readsBefore = metadataReads.length;

        mediaItems.add(initial.copyWith(duration: const Duration(minutes: 3)));
        await settlePlayer(tester);
        expect(
          tester.state(find.byType(NowPlayingScreen)),
          same(originalState),
        );
        expect(
          tester
              .widget<PlaybackSeekSlider>(find.byType(PlaybackSeekSlider))
              .duration,
          const Duration(minutes: 3),
        );
        if (!mornye) expect(miniProgress(), closeTo(1 / 6, 0.001));
        expect(metadataReads.length, readsBefore);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Material track titles never overlap during rapid skips', (
    tester,
  ) async {
    await pumpNowPlaying(tester);
    mediaItems.add(item('first'));
    await settlePlayer(tester);
    mediaItems.add(item('second'));
    await tester.pump();
    var sawOutgoingTitle = false;
    var visible = 0;
    for (var frame = 0; frame < 60; frame++) {
      if (frame == 7) mediaItems.add(item('third'));
      await tester.pump(const Duration(milliseconds: 16));
      final titles = find.descendant(
        of: find.byType(MaterialPlayerLayout),
        matching: find.byType(PlayerMetadataTitle),
      );
      expect(titles, findsAtLeast(1));
      sawOutgoingTitle |= titles.evaluate().length > 1;
      visible = 0;
      for (final title in titles.evaluate()) {
        var opacity = 1.0;
        title.visitAncestorElements((element) {
          final widget = element.widget;
          if (widget is FadeTransition) opacity *= widget.opacity.value;
          if (widget is Opacity) opacity *= widget.opacity;
          return true;
        });
        if (opacity > 0.01) visible++;
      }
      expect(visible, lessThanOrEqualTo(1), reason: 'frame $frame');
    }
    expect(sawOutgoingTitle, isTrue);
    expect(visible, 1);
    await settlePlayer(tester);
    expect(tester.takeException(), isNull);
  });

  for (final (size, textScale) in [
    (const Size(844, 390), 1.0),
    (const Size(720, 320), 1.0),
    (const Size(640, 360), 1.0),
    (const Size(1280, 720), 1.6),
  ]) {
    testWidgets('Material landscape offers artwork beside lyrics at $size '
        'with text scale $textScale', (tester) async {
      await pumpNowPlaying(
        tester,
        theme: AppTheme.light(),
        size: size,
        wrapPlayer: (player) => Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: player,
          ),
        ),
      );
      mediaItems.add(item('first'));
      await settlePlayer(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(NowPlayingScreen)),
      );
      container.read(settingsProvider.notifier).setLandscapeLyricsArtwork(true);
      await settlePlayer(tester);
      final layout = find.byKey(
        const ValueKey('material-landscape-artwork-lyrics'),
      );
      final artwork = find.descendant(
        of: layout,
        matching: find.byType(PlayerArtwork),
      );
      final coverHero = find.ancestor(of: artwork, matching: find.byType(Hero));
      final artworkBounds = tester.getRect(coverHero);
      final artworkState = tester.renderObject(artwork);
      final lyricsToggle = find.byKey(const ValueKey('material-lyrics-toggle'));
      await tester.tap(lyricsToggle);
      await settlePlayer(tester);
      expect(layout, findsOneWidget);
      expect(find.byType(PlayerMetadataTitle), findsOneWidget);
      expect(find.byType(PlayerPlaybackControls), findsNothing);
      expect(artwork, findsOneWidget);
      expect(tester.getRect(coverHero), artworkBounds);
      expect(tester.renderObject(artwork), same(artworkState));
      expect(artworkBounds.shortestSide, greaterThan(96));
      expect(
        tester.getRect(artwork).center.dx,
        lessThan(tester.getRect(find.byType(SyncedLyricsView)).center.dx),
      );
      expect(
        tester.getRect(find.byType(PlayerMetadataTitle)).center.dx,
        greaterThan(artworkBounds.center.dx),
      );
      expect(tester.takeException(), isNull);

      await tester.tap(lyricsToggle);
      await settlePlayer(tester);
      expect(find.byType(PlayerPlaybackControls), findsOneWidget);
      expect(find.byType(SyncedLyricsView), findsNothing);
      expect(tester.getRect(coverHero), artworkBounds);
      expect(tester.renderObject(artwork), same(artworkState));
      await tester.tap(lyricsToggle);
      await settlePlayer(tester);

      tester.view.physicalSize = Size(size.height, size.width);
      await settlePlayer(tester);
      expect(layout, findsNothing);
      expect(find.byType(PlayerMetadataTitle), findsOneWidget);
      tester.view.physicalSize = size;
      await settlePlayer(tester);
      expect(layout, findsOneWidget);

      container
          .read(settingsProvider.notifier)
          .setLandscapeLyricsArtwork(false);
      await settlePlayer(tester);
      expect(layout, findsNothing);
      expect(find.byType(PlayerMetadataTitle), findsOneWidget);
      expect(find.byType(SyncedLyricsView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (size, kept) in [
    (const Size(430, 932), true),
    (const Size(320, 568), false),
  ]) {
    testWidgets('Material portrait keeps an empty Playing on row ($size)', (
      tester,
    ) async {
      await pumpNowPlaying(tester, theme: AppTheme.light(), size: size);
      mediaItems.add(item('first'));
      await settlePlayer(tester);
      expect(find.byKey(const ValueKey('link-playing-on')), findsNothing);
      final row = find.byKey(const ValueKey('link-playing-on-row'));
      if (kept) {
        expect(tester.getSize(row).height, 36);
      } else {
        expect(row, findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('landscape artwork preference leaves a wide portrait player '
      'unchanged', (tester) async {
    await pumpNowPlaying(
      tester,
      theme: AppTheme.light(),
      size: const Size(900, 1000),
    );
    mediaItems.add(item('first'));
    await settlePlayer(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(NowPlayingScreen)),
    );
    container.read(settingsProvider.notifier).setLandscapeLyricsArtwork(true);
    await tester.tap(find.byKey(const ValueKey('material-lyrics-toggle')));
    await settlePlayer(tester);
    expect(
      find.byKey(const ValueKey('material-landscape-artwork-lyrics')),
      findsNothing,
    );
    expect(find.byType(PlayerMetadataTitle), findsOneWidget);
    expect(find.byType(SyncedLyricsView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final mornye in [false, true]) {
    testWidgets('cover style switches live and survives rotation ($mornye)', (
      tester,
    ) async {
      await pumpNowPlaying(
        tester,
        theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.light(),
        size: const Size(390, 844),
      );
      mediaItems.add(item('first'));
      await settlePlayer(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(NowPlayingScreen)),
      );
      container
          .read(settingsProvider.notifier)
          .setPlayerCoverStyle('fullscreen');
      await settlePlayer(tester);
      if (mornye) {
        expect(
          tester
              .widget<MornyePlayerLayout>(find.byType(MornyePlayerLayout))
              .insetArtwork,
          isFalse,
        );
        expect(
          tester
              .widget<MornyePlayerBackground>(
                find.byType(MornyePlayerBackground),
              )
              .artwork,
          isNotNull,
        );
      } else {
        expect(find.byType(MaterialPlayerBackdrop), findsOneWidget);
        expect(
          tester
              .widget<MaterialPlayerLayout>(find.byType(MaterialPlayerLayout))
              .fullScreenArtwork,
          isTrue,
        );
      }
      tester.view.physicalSize = const Size(844, 390);
      await settlePlayer(tester);
      if (!mornye) {
        expect(find.byType(MaterialPlayerBackdrop), findsOneWidget);
        expect(
          tester
              .widget<MaterialPlayerBackdrop>(
                find.byType(MaterialPlayerBackdrop),
              )
              .showArtwork,
          isFalse,
        );
        expect(
          tester
              .widget<MaterialPlayerLayout>(find.byType(MaterialPlayerLayout))
              .fullScreenArtwork,
          isFalse,
        );
        final playerScaffold = tester.widget<Scaffold>(
          find.descendant(
            of: find.byType(NowPlayingScreen),
            matching: find.byType(Scaffold),
          ),
        );
        expect(playerScaffold.backgroundColor, Colors.transparent);
        final playerAppBar = tester.widget<AppBar>(
          find.descendant(
            of: find.byType(NowPlayingScreen),
            matching: find.byType(AppBar),
          ),
        );
        expect(playerAppBar.backgroundColor, Colors.transparent);
        final lyricsToggle = find.byKey(
          const ValueKey('material-lyrics-toggle'),
        );
        await tester.tap(lyricsToggle);
        await settlePlayer(tester);
        expect(find.byType(SyncedLyricsView), findsOneWidget);
        expect(find.byType(MaterialPlayerBackdrop), findsOneWidget);
        await tester.tap(lyricsToggle);
        await settlePlayer(tester);
      }
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(390, 844);
      await settlePlayer(tester);
      container.read(settingsProvider.notifier).setPlayerCoverStyle('default');
      await settlePlayer(tester);
      expect(find.byType(MaterialPlayerBackdrop), findsNothing);
      if (mornye) {
        expect(
          tester
              .widget<MornyePlayerLayout>(find.byType(MornyePlayerLayout))
              .insetArtwork,
          isTrue,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Material seek wave follows playback, buffering and pause', (
    tester,
  ) async {
    final playback = StreamController<PlaybackState>.broadcast();
    addTearDown(playback.close);
    await pumpNowPlaying(tester, playbackEvents: playback.stream);
    mediaItems.add(item('first'));
    await settlePlayer(tester);

    for (final state in [
      PlaybackState(playing: true, processingState: AudioProcessingState.ready),
      PlaybackState(
        playing: true,
        processingState: AudioProcessingState.buffering,
      ),
      PlaybackState(playing: true, processingState: AudioProcessingState.ready),
      PlaybackState(
        playing: false,
        processingState: AudioProcessingState.ready,
      ),
    ]) {
      playback.add(state);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final track = tester.widget<ExpressiveSeekTrack>(
        find.byType(ExpressiveSeekTrack),
      );
      expect(
        track.playing,
        state.playing && state.processingState == AudioProcessingState.ready,
      );
    }
    await settlePlayer(tester);
    expect(tester.takeException(), isNull);
  });

  for (final page in ['player', 'lyrics', 'queue']) {
    testWidgets('cover swipe changes the track in the Mornye $page', (
      tester,
    ) async {
      final queue = [item('first'), item('second')];
      final controller = _QueueController(
        (index) => mediaItems.add(queue[index]),
      );
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.dark),
        size: const Size(393, 852),
        queue: queue,
        controller: controller,
        playback: PlaybackState(queueIndex: 0),
      );
      mediaItems.add(queue.first);
      await settlePlayer(tester);
      if (page != 'player') {
        await tester.tap(
          findAppIcon(
            page == 'lyrics'
                ? CupertinoIcons.quote_bubble
                : CupertinoIcons.list_bullet,
          ),
        );
        await settlePlayer(tester);
      }
      final cover = find
          .byKey(
            ValueKey(
              page == 'player'
                  ? 'full-player-artwork'
                  : 'compact-player-artwork',
            ),
          )
          .hitTestable();
      final rect = tester.getRect(cover);
      final gesture = await tester.startGesture(rect.center);
      await gesture.moveBy(const Offset(-110, 0));
      await tester.pump();
      expect(tester.getRect(cover), rect);
      await gesture.up();
      await settlePlayer(tester);
      expect(controller.selected, [1]);
      expect(find.text('Second').hitTestable(), findsOneWidget);
      await tester.drag(cover, const Offset(110, 0));
      await settlePlayer(tester);
      expect(controller.selected, [1, 0]);
      expect(find.text('First').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'portrait motion cover keeps the raised square-cover control positions',
    (tester) async {
      Future<(double, double)> positions(MotionArtwork? artwork) async {
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: const Size(393, 852),
          motionArtwork: artwork,
        );
        mediaItems.add(item('first'));
        await settlePlayer(tester);
        final title = tester.getTopLeft(find.text('First').hitTestable()).dy;
        final transport = tester
            .getCenter(
              find.byWidgetPredicate(
                (widget) =>
                    widget is MornyePlaybackButton &&
                    widget.icon == CupertinoIcons.play_fill,
              ),
            )
            .dy;
        expect(title, lessThan(852 * 0.64));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        return (title, transport);
      }

      final square = await positions(null);
      final portrait = await positions(
        const MotionArtwork('file:///cover.mp4', aspectRatio: 0.75),
      );
      expect(portrait.$1, closeTo(square.$1, 1));
      expect(portrait.$2, closeTo(square.$2, 1));
    },
  );

  testWidgets('custom glass keeps live lyrics under the finger on reversal', (
    tester,
  ) async {
    metadataOverrides['lyrics'] = List.generate(
      20,
      (index) =>
          '[00:${(index * 3).toString().padLeft(2, '0')}.00]Live lyric $index with several words on this line',
    ).join('\n');
    final playback = StreamController<PlaybackState>.broadcast();
    addTearDown(playback.close);
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark, glassClarity: 0.5),
      size: const Size(393, 852),
      playbackEvents: playback.stream,
    );
    mediaItems.add(item('many'));
    playback.add(
      PlaybackState(
        playing: true,
        processingState: AudioProcessingState.ready,
        updatePosition: const Duration(seconds: 30),
      ),
    );
    await settlePlayer(tester);
    await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
    await settlePlayer(tester);
    final list = find.byType(ListView);
    final bounds = tester.getRect(list);
    final scroll = tester.widget<ListView>(list).controller!;
    final initial = scroll.offset;
    final pause = find.widgetWithIcon(
      MornyePlaybackButton,
      CupertinoIcons.pause_fill,
    );
    final touch = await tester.startGesture(
      Offset(bounds.center.dx, bounds.top + 180),
    );
    await touch.moveBy(const Offset(0, -20));
    await tester.pump();
    await touch.moveBy(const Offset(0, -100));
    await tester.pump();
    final hidden = scroll.offset;
    expect(hidden, greaterThan(initial));
    expect(pause.hitTestable(), findsNothing);

    playback.add(
      PlaybackState(
        playing: true,
        processingState: AudioProcessingState.ready,
        updatePosition: const Duration(seconds: 33),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(scroll.offset, closeTo(hidden, 0.01));
    await touch.moveBy(const Offset(0, 24));
    await tester.pump();
    expect(scroll.offset, closeTo(hidden - 24, 0.01));
    expect(pause.hitTestable(), findsOneWidget);
    for (var frame = 0; frame < 15; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(scroll.offset, closeTo(hidden - 24, 0.01));
      expect(tester.getRect(list), bounds);
    }
    await touch.up();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  for (final reducedMotion in [false, true]) {
    testWidgets(
      'static cover shrinks on pause without moving controls (reduced motion: $reducedMotion)',
      (tester) async {
        const longTitle =
            'I Do Not Want to Talk About It (A Long Album Version)';
        tester.view.padding = FakeViewPadding(top: 59, bottom: 34);
        tester.view.viewPadding = FakeViewPadding(top: 59, bottom: 34);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        final playbackEvents = StreamController<PlaybackState>.broadcast();
        addTearDown(playbackEvents.close);
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: const Size(393, 852),
          playbackEvents: playbackEvents.stream,
          wrapPlayer: (player) => Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: reducedMotion),
              child: player,
            ),
          ),
        );
        mediaItems.add(item('first').copyWith(title: longTitle));
        await settlePlayer(tester);
        playbackEvents.add(PlaybackState(playing: true));
        await settlePlayer(tester);

        final cover = find.byType(MornyePlayerArtwork);
        final playingCover = tester.getRect(cover);
        final titleFinder = find
            .text(longTitle)
            .hitTestable(at: Alignment.centerLeft)
            .first;
        final title = tester.getRect(titleFinder);
        final volume = tester.getRect(find.byType(PlayerVolumeControl));
        expect(playingCover.width, playingCover.height);
        expect(playingCover.width, greaterThanOrEqualTo(393 * 0.84));
        expect(playingCover.left, greaterThan(0));
        expect(playingCover.bottom, lessThan(title.top));
        expect(
          find.descendant(
            of: find.byType(MornyePlayerBackground),
            matching: cover,
          ),
          findsNothing,
        );

        playbackEvents.add(PlaybackState(playing: false));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        if (!reducedMotion) {
          expect(
            tester.getRect(cover).width,
            inExclusiveRange(playingCover.width * 0.73, playingCover.width),
          );
        }
        await settlePlayer(tester);
        final pausedCover = tester.getRect(cover);
        expect(pausedCover.width, closeTo(playingCover.width * 0.73, 0.01));
        expect(pausedCover.center.dx, closeTo(playingCover.center.dx, 0.01));
        expect(pausedCover.center.dy, closeTo(playingCover.center.dy, 0.01));
        expect(tester.getRect(titleFinder), title);
        expect(tester.getRect(find.byType(PlayerVolumeControl)), volume);

        playbackEvents.add(PlaybackState(playing: true));
        await settlePlayer(tester);
        expect(tester.getRect(cover).width, closeTo(playingCover.width, 0.01));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('video contrast updates controls without rebuilding artwork', (
    tester,
  ) async {
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 852),
      motionArtwork: const MotionArtwork(
        'file:///cover.mp4',
        aspectRatio: 0.75,
      ),
    );
    mediaItems.add(item('first'));
    await settlePlayer(tester);
    final background = tester.widget<MornyePlayerBackground>(
      find.byType(MornyePlayerBackground),
    );
    final title = find.text('First').hitTestable();
    final bounds = tester.getRect(title);
    final contrast = tester.widget<MornyeArtworkContrast>(
      find.byType(MornyeArtworkContrast),
    );
    for (final color in [Colors.black, Colors.white]) {
      contrast.onChanged({'header': color, 'controls': color, 'volume': color});
      await tester.pump();
      expect(
        tester.widget<MornyePlayerBackground>(
          find.byType(MornyePlayerBackground),
        ),
        same(background),
      );
      expect(tester.getRect(title), bounds);
      expect(
        tester
            .widgetList<MornyePlaybackButton>(find.byType(MornyePlaybackButton))
            .where(
              (button) => [
                CupertinoIcons.backward_fill,
                CupertinoIcons.play_fill,
                CupertinoIcons.forward_fill,
              ].contains(button.icon),
            )
            .map((button) => button.color),
        everyElement(color),
      );
      expect(
        tester
            .widget<PlayerVolumeControl>(find.byType(PlayerVolumeControl))
            .foreground,
        color,
      );
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Mornye lyrics keep wrapped, first and last lines at upper focus', (
    tester,
  ) async {
    final lyrics = List.generate(100, (index) {
      final seconds = index * 2;
      final time =
          '${(seconds ~/ 60).toString().padLeft(2, '0')}:'
          '${(seconds % 60).toString().padLeft(2, '0')}.00';
      return '[$time]Line $index with enough words to wrap across several rows';
    }).join('\n');
    metadataOverrides = {'lyrics': lyrics};
    final playback = StreamController<PlaybackState>();
    addTearDown(playback.close);
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 780),
      playbackEvents: playback.stream,
    );
    mediaItems.add(item('many'));
    playback.add(PlaybackState(updatePosition: const Duration(seconds: 140)));
    await settlePlayer(tester);
    await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
    await settlePlayer(tester);
    final current = find.text(
      'Line 70 with enough words to wrap across several rows',
    );
    expect(current, findsOneWidget);
    final list = find.byType(ListView);
    void expectUpperFocus(Finder line) {
      final bounds = tester.getRect(line);
      final viewport = tester.getRect(list);
      expect(bounds.top, closeTo(viewport.top + 16 + 780 * 0.06, 2));
    }

    expectUpperFocus(current);
    await tester.drag(list, const Offset(0, 200));
    await settlePlayer(tester);
    await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
    await settlePlayer(tester);
    await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
    await settlePlayer(tester);
    expectUpperFocus(current);
    for (final index in [99, 0]) {
      playback.add(PlaybackState(updatePosition: Duration(seconds: index * 2)));
      await settlePlayer(tester);
      expectUpperFocus(
        find.text('Line $index with enough words to wrap across several rows'),
      );
    }
    expect(tester.takeException(), isNull);
  });

  for (final width in [393.0, 768.0]) {
    testWidgets('Mornye lyrics fit the timeline without rewrapping ($width)', (
      tester,
    ) async {
      const original =
          'A longer lyric with words that already wrap onto another row';
      const pronunciation = 'Pronunciation follows the same layout as before';
      const translation =
          'The translated words also keep their existing line breaks';
      metadataOverrides['lyrics'] =
          '[x-romaji:1000:${base64.encode(utf8.encode(pronunciation))}]\n'
          '[x-translation:1000:${base64.encode(utf8.encode(translation))}]\n'
          '[00:01.000]$original\n[00:15.000]Next line';
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.dark),
        size: Size(width, 1024),
        playback: PlaybackState(updatePosition: const Duration(seconds: 2)),
      );
      mediaItems.add(item('first'));
      await settlePlayer(tester);
      await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
      await settlePlayer(tester);

      final track = seekTrackBounds(tester);
      for (final text in [original, pronunciation, translation]) {
        final finder = find.text(text);
        final paragraph = tester.renderObject<RenderParagraph>(finder);
        final previousLayout = TextPainter(
          text: paragraph.text,
          textDirection: paragraph.textDirection,
          textAlign: paragraph.textAlign,
          textScaler: paragraph.textScaler,
          locale: paragraph.locale,
        )..layout(maxWidth: width - 48);
        final selection = TextSelection(
          baseOffset: 0,
          extentOffset: text.length,
        );
        expect(
          paragraph.getBoxesForSelection(selection).map((box) => box.toRect()),
          previousLayout
              .getBoxesForSelection(selection)
              .map((box) => box.toRect()),
        );
        final bounds = tester.getRect(finder);
        expect(bounds.left, closeTo(track.left, 0.01));
        expect(bounds.right, closeTo(track.right, 0.01));
        expect(bounds.height, lessThan(previousLayout.height));
        previousLayout.dispose();
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [const Size(393, 852), const Size(768, 1024)]) {
    for (final reducedMotion in [false, true]) {
      testWidgets(
        'slider scrubs lyrics both ways before seeking (size: $size, reduced motion: $reducedMotion)',
        (tester) async {
          metadataOverrides['lyrics'] = List.generate(
            18,
            (index) =>
                '[${(index ~/ 6).toString().padLeft(2, '0')}:'
                '${(index % 6 * 10).toString().padLeft(2, '0')}.00]'
                'Line $index with enough words to wrap across several rows',
          ).join('\n');
          final playback = StreamController<PlaybackState>.broadcast();
          addTearDown(playback.close);
          final controller = _SeekController();
          await pumpNowPlaying(
            tester,
            theme: MornyeTheme.build(Brightness.dark),
            size: size,
            playbackEvents: playback.stream,
            controller: controller,
            wrapPlayer: (player) => Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(disableAnimations: reducedMotion),
                child: player,
              ),
            ),
          );
          mediaItems.add(item('first'));
          playback.add(
            PlaybackState(updatePosition: const Duration(seconds: 1)),
          );
          await settlePlayer(tester);
          await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
          await settlePlayer(tester);
          final slider = find.descendant(
            of: find.byType(PlaybackSeekSlider),
            matching: find.byType(Slider),
          );
          final bounds = tester.getRect(slider);
          Offset point(double fraction) => Offset(
            bounds.left + 8 + (bounds.width - 16) * fraction,
            bounds.center.dy,
          );
          final list = find.byType(ListView);
          double offset() => tester.widget<ListView>(list).controller!.offset;
          void expectFocus() {
            final seconds = tester.widget<Slider>(slider).value / 1000;
            final index = seconds ~/ 10;
            final line = find.text(
              'Line $index with enough words to wrap across several rows',
            );
            final focus = (size.height * 0.06).clamp(16, 48);
            expect(
              tester.getTopLeft(line).dy,
              closeTo(tester.getTopLeft(list).dy + focus + 16, 2),
            );
            final label = tester.widget<MornyePlaybackTime>(
              find.byKey(const ValueKey('elapsed:first')),
            );
            expect(label.seconds, seconds.floor());
          }

          final gesture = await tester.startGesture(point(0.02));
          await settlePlayer(tester);
          final initial = offset();
          await gesture.moveTo(point(0.82));
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 70));
          final intermediate = offset();
          expect(intermediate, greaterThan(initial));
          await settlePlayer(tester);
          if (!reducedMotion) expect(offset(), greaterThan(intermediate));
          expectFocus();
          expect(controller.seeks, isEmpty);

          final forward = offset();
          await gesture.moveTo(point(0.19));
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 70));
          expect(offset(), lessThan(forward));
          await settlePlayer(tester);
          expectFocus();
          final held = offset();
          // Neither playback ticks nor the automatic next-line timer may
          // move the user's preview while the finger is still down.
          playback.add(
            PlaybackState(
              processingState: AudioProcessingState.ready,
              playing: true,
              updatePosition: const Duration(seconds: 151),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(seconds: 10));
          expect(offset(), closeTo(held, 0.01));
          expectFocus();
          expect(controller.seeks, isEmpty);

          await gesture.up();
          await tester.pump();
          expect(controller.seeks, hasLength(1));
          playback.add(PlaybackState(updatePosition: controller.seeks.single));
          await tester.pump();
          controller.completions.single.complete();
          await settlePlayer(tester);
          expect(offset(), closeTo(held, 0.01));
          expectFocus();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('scrubbing previews word fills and instrumental dots exactly', (
    tester,
  ) async {
    metadataOverrides['lyrics'] = '''
<tt xmlns="http://www.w3.org/ns/ttml"><body><div>
<p begin="00:10.000" end="00:30.000"><span begin="00:10.000" end="00:20.000">First </span><span begin="00:20.000" end="00:30.000">second</span></p>
<p begin="00:40.000" end="00:50.000">Last vocal</p>
</div></body></tt>
''';
    final playback = StreamController<PlaybackState>.broadcast();
    addTearDown(playback.close);
    final controller = _SeekController();
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 852),
      playbackEvents: playback.stream,
      controller: controller,
    );
    mediaItems.add(item('first'));
    playback.add(PlaybackState(updatePosition: const Duration(seconds: 1)));
    await settlePlayer(tester);
    await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
    await settlePlayer(tester);
    final sliderFinder = find.descendant(
      of: find.byType(PlaybackSeekSlider),
      matching: find.byType(Slider),
    );
    Slider slider() => tester.widget<Slider>(sliderFinder);
    // Exact millisecond targets let this check word fills independently of
    // the gesture/scroll integration test above.
    slider().onChangeStart!(1000);
    Future<void> preview(int milliseconds) async {
      slider().onChanged!(milliseconds.toDouble());
      await settlePlayer(tester);
    }

    Future<List<int>> wordPixels() async {
      final paint = find.descendant(
        of: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.label == 'First second',
        ),
        matching: find.byType(CustomPaint),
      );
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.ancestor(of: paint, matching: find.byType(RepaintBoundary)).first,
      );
      return (await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final result = bytes.buffer.asUint8List().toList();
        image.dispose();
        return result;
      }))!;
    }

    await preview(15000);
    final firstWord = await wordPixels();
    await preview(25000);
    expect(await wordPixels(), isNot(firstWord));
    await preview(15000);
    expect(await wordPixels(), firstWord);
    playback.add(
      PlaybackState(
        processingState: AudioProcessingState.ready,
        playing: true,
        updatePosition: const Duration(seconds: 45),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(await wordPixels(), firstWord);

    for (final (milliseconds, alpha) in [(33333, 0.25), (36667, 1.0)]) {
      await preview(milliseconds);
      final dot = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey('lyric-gap-dot-1')),
      );
      expect(
        (dot.decoration! as BoxDecoration).color!.a,
        closeTo(alpha, 0.001),
      );
    }
    await preview(170000);
    expect(find.byType(LyricGapIndicator), findsNothing);
    expect(controller.seeks, isEmpty);
    await preview(15000);
    slider().onChangeEnd!(15000);
    await tester.pump();
    expect(controller.seeks, [const Duration(seconds: 15)]);

    // A pending old seek must not leave the next track at the preview time.
    metadataOverrides['lyrics'] = '[00:02.00]New track start\n[00:14.00]Later';
    mediaItems.add(item('second'));
    playback.add(PlaybackState(updatePosition: Duration.zero));
    await settlePlayer(tester);
    expect(slider().value, 0);
    expect(find.text('New track start'), findsOneWidget);
    expect(find.byType(LyricGapIndicator), findsNothing);
    slider().onChangeStart!(0);
    await preview(35000);
    await preview(0);
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.controller!.offset, 0);
    controller.completions.single.complete();
    await settlePlayer(tester);
    expect(slider().value, 0);
    expect(
      tester
          .widget<PlaybackSeekSlider>(find.byType(PlaybackSeekSlider))
          .preview!
          .value,
      Duration.zero,
    );
    slider().onChangeEnd!(0);
    controller.completions.last.complete();
    await settlePlayer(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mornye landscape has no top handle or reserved toolbar height', (
    tester,
  ) async {
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(
        Brightness.dark,
      ).copyWith(platform: TargetPlatform.android),
      size: const Size(900, 420),
    );
    mediaItems.add(item('first'));
    await settlePlayer(tester);
    final bar = tester.widget<AppBar>(find.byType(AppBar));
    expect(bar.toolbarHeight, 0);
    expect(bar.title, isNull);
  });

  for (final height in [780.0, 520.0]) {
    testWidgets(
      'manual lyric scrolling keeps its viewport stable while controls animate (height: $height)',
      (tester) async {
        final clarity = ValueNotifier(0.5);
        addTearDown(clarity.dispose);
        metadataOverrides['lyrics'] = List.generate(
          20,
          (index) =>
              '[00:${(index * 3).toString().padLeft(2, '0')}.00]Lyric $index with several words on this line',
        ).join('\n');
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: Size(393, height),
          playback: PlaybackState(updatePosition: const Duration(seconds: 30)),
          wrapPlayer: (player) => ValueListenableBuilder<double>(
            valueListenable: clarity,
            builder: (context, value, child) => Theme(
              data: MornyeTheme.build(Brightness.dark, glassClarity: value),
              child: child!,
            ),
            child: player,
          ),
        );
        mediaItems.add(item('many'));
        await settlePlayer(tester);
        await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
        await settlePlayer(tester);
        final list = find.byType(ListView);
        final bounds = tester.getRect(list);
        final scrollable = find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        );
        final state = tester.state<ScrollableState>(scrollable);
        final initialOffset = state.position.pixels;
        final headerTop = tester.getTopLeft(find.text('Second')).dy;
        final transport = find.byWidgetPredicate(
          (widget) =>
              widget is MornyePlaybackButton &&
              const [
                CupertinoIcons.play_fill,
                CupertinoIcons.backward_fill,
                CupertinoIcons.forward_fill,
              ].contains(widget.icon),
        );
        expect(transport.hitTestable(), findsNWidgets(3));
        final touch = await tester.startGesture(
          Offset(bounds.center.dx, bounds.top + 100),
        );
        await touch.moveBy(const Offset(0, -20));
        await tester.pump();
        await touch.moveBy(const Offset(0, -60));
        await tester.pump();
        final hiddenOffset = state.position.pixels;
        expect(hiddenOffset, greaterThan(initialOffset));
        expect(transport.hitTestable(), findsNothing);
        // An inherited appearance update must not reset playback following
        // while the user owns the scroll position.
        clarity.value = 0.6;
        await tester.pump();
        await tester.pump();
        expect(state.position.pixels, closeTo(hiddenOffset, 0.01));
        for (var frame = 0; frame < 3; frame++) {
          await tester.pump(const Duration(milliseconds: 40));
          expect(tester.getRect(list), bounds);
          expect(tester.state<ScrollableState>(scrollable), same(state));
          expect(state.position.pixels, closeTo(hiddenOffset, 0.01));
        }

        // A held drag must not expire the manual-scroll pause, even if the
        // finger has not changed direction for longer than its idle timeout.
        await tester.pump(const Duration(seconds: 5));
        await tester.pump(const Duration(milliseconds: 400));
        expect(state.position.pixels, closeTo(hiddenOffset, 0.01));

        // Continue the same drag and reverse while controls reappear.
        await touch.moveBy(const Offset(0, -32));
        await tester.pump();
        expect(state.position.pixels, closeTo(hiddenOffset + 32, 0.01));
        await touch.moveBy(const Offset(0, 48));
        await tester.pump();
        final restoredOffset = state.position.pixels;
        expect(restoredOffset, closeTo(hiddenOffset - 16, 0.01));
        for (var frame = 0; frame < 10; frame++) {
          await tester.pump(const Duration(milliseconds: 40));
          expect(tester.getRect(list), bounds);
          expect(tester.state<ScrollableState>(scrollable), same(state));
          expect(state.position.pixels, closeTo(restoredOffset, 0.01));
        }
        expect(tester.getTopLeft(find.text('Second')).dy, headerTop);
        expect(transport.hitTestable(), findsNWidgets(3));
        await touch.up();
        await settlePlayer(tester);
        final releasedOffset = state.position.pixels;
        clarity.value = 0.5;
        await tester.pump();
        await settlePlayer(tester);
        expect(state.position.pixels, closeTo(releasedOffset, 0.01));
        await tester.pump(const Duration(seconds: 3));

        // Starting another drag cancels the previous idle timeout. It must
        // remain paused through further scrolling in the same direction.
        final nextTouch = await tester.startGesture(
          Offset(bounds.center.dx, bounds.top + 100),
        );
        await nextTouch.moveBy(const Offset(0, -20));
        await tester.pump();
        await nextTouch.moveBy(const Offset(0, -40));
        await tester.pump();
        final nextOffset = state.position.pixels;
        await tester.pump(const Duration(seconds: 5));
        await tester.pump(const Duration(milliseconds: 400));
        expect(state.position.pixels, closeTo(nextOffset, 0.01));
        await nextTouch.up();
        await settlePlayer(tester);
        await tester.pump(const Duration(seconds: 4));
        await settlePlayer(tester);
        expect(state.position.pixels, closeTo(initialOffset, 0.01));
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final reducedMotion in [false, true]) {
    testWidgets(
      'lyrics hide controls after five idle seconds and restore on tap (reduced motion: $reducedMotion)',
      (tester) async {
        const lyric = 'First lyric with several words on this line';
        metadataOverrides['lyrics'] = '[00:00.00]$lyric\n[01:00.00]Second line';
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: const Size(393, 852),
          playback: PlaybackState(playing: true),
          wrapPlayer: (player) => Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: reducedMotion),
              child: player,
            ),
          ),
        );
        mediaItems.add(item('many'));
        await settlePlayer(tester);
        final lyricsButton = findAppIcon(CupertinoIcons.quote_bubble);
        final queueButton = findAppIcon(CupertinoIcons.list_bullet);
        final play = find.widgetWithIcon(
          MornyePlaybackButton,
          CupertinoIcons.pause_fill,
        );
        final volume = find.byType(PlayerVolumeControl);
        await tester.tap(lyricsButton);
        await tester.pump();
        await completeLyrics(tester);
        await tester.pump(const Duration(milliseconds: 4900));
        expect(play.hitTestable(), findsOneWidget);
        final list = find.byType(ListView);
        final originalHeight = tester.getSize(list).height;
        final originalTop = tester.getTopLeft(find.text(lyric)).dy;
        await tester.pump(const Duration(milliseconds: 100));
        for (var frame = 0; frame < 10; frame++) {
          await tester.pump(const Duration(milliseconds: 40));
          expect(
            tester.getTopLeft(find.text(lyric)).dy,
            closeTo(originalTop, 1),
          );
        }
        await settlePlayer(tester);
        expect(play.hitTestable(), findsNothing);
        expect(volume.hitTestable(), findsNothing);
        expect(lyricsButton.hitTestable(), findsNothing);
        expect(queueButton.hitTestable(), findsNothing);
        expect(tester.getSize(list).height, originalHeight);
        expect(
          find.byKey(const ValueKey('player-track-header')).hitTestable(),
          findsOneWidget,
        );

        Future<void> reveal() async {
          final bounds = tester.getRect(list);
          await tester.tapAt(Offset(bounds.right - 6, bounds.top + 10));
          for (var frame = 0; frame < 10; frame++) {
            await tester.pump(const Duration(milliseconds: 40));
            expect(
              tester.getTopLeft(find.text(lyric)).dy,
              closeTo(originalTop, 1),
            );
          }
          await settlePlayer(tester);
          expect(play.hitTestable(), findsOneWidget);
          expect(lyricsButton.hitTestable(), findsOneWidget);
        }

        await reveal();
        final slider = find.descendant(
          of: volume,
          matching: find.byType(Slider),
        );
        final touch = await tester.startGesture(tester.getCenter(slider));
        await tester.pump(const Duration(seconds: 5));
        expect(volume.hitTestable(), findsOneWidget);
        await touch.up();
        await tester.pump(const Duration(milliseconds: 4900));
        expect(volume.hitTestable(), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 100));
        await settlePlayer(tester);
        expect(volume.hitTestable(), findsNothing);

        await reveal();
        await tester.tap(queueButton.hitTestable());
        await settlePlayer(tester);
        await tester.pump(const Duration(seconds: 6));
        expect(play.hitTestable(), findsOneWidget);
        expect(queueButton.hitTestable(), findsOneWidget);
        await tester.tap(queueButton.hitTestable());
        await settlePlayer(tester);
        await tester.pump(const Duration(seconds: 6));
        expect(play.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final landscape in [false, true]) {
    testWidgets(
      'paused lyrics keep controls visible and resume gets five seconds (landscape: $landscape)',
      (tester) async {
        final playback = StreamController<PlaybackState>();
        addTearDown(playback.close);
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: landscape ? const Size(852, 393) : const Size(393, 852),
          playbackEvents: playback.stream,
        );
        playback.add(PlaybackState(playing: false));
        mediaItems.add(item('many'));
        await settlePlayer(tester);
        final lyricsButton = findAppIcon(CupertinoIcons.quote_bubble);
        await tester.tap(lyricsButton);
        await settlePlayer(tester);
        await tester.pump(const Duration(seconds: 6));
        expect(lyricsButton.hitTestable(), findsOneWidget);

        playback.add(PlaybackState(playing: true));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 4900));
        expect(lyricsButton.hitTestable(), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 100));
        await settlePlayer(tester);
        expect(lyricsButton.hitTestable(), findsNothing);

        playback.add(PlaybackState(playing: false));
        await settlePlayer(tester);
        expect(lyricsButton.hitTestable(), findsOneWidget);
        await tester.pump(const Duration(seconds: 6));
        expect(lyricsButton.hitTestable(), findsOneWidget);

        // Pausing during the countdown must cancel the pending hide too.
        playback.add(PlaybackState(playing: true));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 3));
        playback.add(PlaybackState(playing: false));
        await settlePlayer(tester);
        await tester.pump(const Duration(seconds: 6));
        expect(lyricsButton.hitTestable(), findsOneWidget);

        playback.add(PlaybackState(playing: true));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 4900));
        expect(lyricsButton.hitTestable(), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 100));
        await settlePlayer(tester);
        expect(lyricsButton.hitTestable(), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final landscape in [false, true]) {
    testWidgets(
      'Material lyrics fill the player while idle (landscape: $landscape)',
      (tester) async {
        metadataOverrides['lyrics'] =
            '[00:00.00]First lyric\n[01:00.00]Second line';
        await pumpNowPlaying(
          tester,
          theme: AppTheme.light(),
          size: landscape ? const Size(852, 393) : const Size(393, 852),
          playback: PlaybackState(playing: true),
        );
        mediaItems.add(item('many'));
        await settlePlayer(tester);
        final lyricsToggle = find.byKey(
          const ValueKey('material-lyrics-toggle'),
        );
        final transport = find.byType(ExpressivePlaybackTransport);
        final minimize = find.byKey(const ValueKey('now-playing-minimize'));
        await tester.tap(lyricsToggle);
        await tester.pump();
        await completeLyrics(tester);
        await tester.pump(const Duration(milliseconds: 4900));
        expect(lyricsToggle.hitTestable(), findsOneWidget);
        final list = find.byType(ListView);
        final height = tester.getSize(list).height;
        await tester.pump(const Duration(milliseconds: 100));
        await settlePlayer(tester);
        if (landscape) {
          // Two panes keep the controls beside the lyrics.
          expect(lyricsToggle.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          return;
        }
        expect(lyricsToggle.hitTestable(), findsNothing);
        expect(transport.hitTestable(), findsNothing);
        expect(minimize.hitTestable(), findsNothing);
        // The controls fold away and the lyrics take their room.
        expect(tester.getSize(list).height, greaterThan(height + 200));

        final bounds = tester.getRect(list);
        await tester.tapAt(Offset(bounds.right - 6, bounds.top + 10));
        await settlePlayer(tester);
        expect(lyricsToggle.hitTestable(), findsOneWidget);
        expect(transport.hitTestable(), findsOneWidget);
        expect(minimize.hitTestable(), findsOneWidget);
        expect(tester.getSize(list).height, closeTo(height, 1));

        // Leaving the lyrics shows the cover with its controls.
        await tester.pump(const Duration(seconds: 6));
        await settlePlayer(tester);
        expect(lyricsToggle.hitTestable(), findsNothing);
        await tester.tapAt(Offset(bounds.right - 6, bounds.top + 10));
        await settlePlayer(tester);
        await tester.tap(lyricsToggle);
        await settlePlayer(tester);
        expect(find.byType(ListView), findsNothing);
        await tester.pump(const Duration(seconds: 6));
        expect(transport.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Material landscape artwork beside lyrics hides idle controls', (
    tester,
  ) async {
    metadataOverrides['lyrics'] =
        '[00:00.00]First lyric\n[01:00.00]Second line';
    await pumpNowPlaying(
      tester,
      theme: AppTheme.light(),
      size: const Size(852, 393),
      playback: PlaybackState(playing: true),
    );
    mediaItems.add(item('many'));
    await settlePlayer(tester);
    ProviderScope.containerOf(
      tester.element(find.byType(NowPlayingScreen)),
    ).read(settingsProvider.notifier).setLandscapeLyricsArtwork(true);
    await settlePlayer(tester);
    final lyricsToggle = find.byKey(const ValueKey('material-lyrics-toggle'));
    final minimize = find.byKey(const ValueKey('now-playing-minimize'));
    await tester.tap(lyricsToggle);
    await tester.pump();
    await completeLyrics(tester);
    final list = find.byType(ListView);
    final height = tester.getSize(list).height;
    await tester.pump(const Duration(seconds: 5));
    await settlePlayer(tester);
    expect(lyricsToggle.hitTestable(), findsNothing);
    expect(minimize.hitTestable(), findsNothing);
    // The toolbar fades and the actions row folds away for the lyrics.
    expect(tester.getSize(list).height, greaterThan(height + 40));

    final bounds = tester.getRect(list);
    await tester.tapAt(Offset(bounds.right - 6, bounds.top + 10));
    await settlePlayer(tester);
    expect(lyricsToggle.hitTestable(), findsOneWidget);
    expect(minimize.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'accessible navigation keeps lyric controls available while idle',
    (tester) async {
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.dark),
        size: const Size(393, 852),
        playback: PlaybackState(playing: true),
        wrapPlayer: (player) => Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(accessibleNavigation: true),
            child: player,
          ),
        ),
      );
      mediaItems.add(item('many'));
      await settlePlayer(tester);
      await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
      await settlePlayer(tester);
      await tester.pump(const Duration(seconds: 6));
      expect(find.byType(PlayerVolumeControl).hitTestable(), findsOneWidget);
      expect(
        findAppIcon(CupertinoIcons.quote_bubble).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Mornye player background does not reveal the page below', (
    tester,
  ) async {
    final background = ValueNotifier<Color>(Colors.white);
    addTearDown(background.dispose);
    final capture = GlobalKey();
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.light),
      size: const Size(393, 780),
      wrapPlayer: (player) => RepaintBoundary(
        key: capture,
        child: ValueListenableBuilder<Color>(
          valueListenable: background,
          child: player,
          builder: (context, color, child) => Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: color),
              child!,
            ],
          ),
        ),
      ),
    );
    mediaItems.add(item('first'));
    await settlePlayer(tester);

    Future<List<int>?> edgePixel() => tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(capture),
      );
      final image = await boundary.toImage();
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final offset = (image.width + 1) * 4;
      final pixel = List<int>.generate(4, (i) => bytes.getUint8(offset + i));
      image.dispose();
      return pixel;
    });

    final onWhite = await edgePixel();
    background.value = Colors.red;
    await settlePlayer(tester);
    expect(await edgePixel(), onWhite);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Mornye player menu floats above its button and retains dark colors',
    (tester) async {
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.light),
        size: const Size(393, 780),
      );
      mediaItems.add(item('first'));
      await settlePlayer(tester);
      final moreButton = findAppIcon(CupertinoIcons.ellipsis).hitTestable();
      final anchor = tester.getRect(moreButton);
      await tester.tap(moreButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final panel = find.byType(MornyePlayerActionsSheet);
      final enteringWidth = tester.getSize(panel).width;
      await settlePlayer(tester);
      expect(tester.getSize(panel).width, enteringWidth);
      expect(tester.getRect(panel).bottom, lessThan(anchor.top));
      expect(tester.getRect(panel).width, 280);
      expect(find.byType(BottomSheet), findsNothing);
      expect(Theme.of(tester.element(panel)).brightness, Brightness.dark);
      expect(
        tester.widget<Text>(find.text('Go to Album')).style?.color,
        Colors.white,
      );
      expect(findAppIcon(CupertinoIcons.square_stack), findsOneWidget);
      expect(findAppIcon(CupertinoIcons.moon_zzz), findsOneWidget);
      expect(findAppIcon(CupertinoIcons.gear_alt), findsNothing);
      expect(
        find.text(
          AppLocalizations.of(tester.element(panel)).collectionAddToPlaylist,
        ),
        findsOneWidget,
      );
      expect(find.text('Go to Artist'), findsOneWidget);
      expect(find.text('Favorite'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      expect(tester.widget<Text>(find.text('Go to Album')).style?.fontSize, 16);
      await tester.ensureVisible(find.text('Sleep timer'));
      await tester.tap(find.text('Sleep timer'));
      await settlePlayer(tester);
      expect(
        Theme.of(tester.element(find.text('15 minutes'))).brightness,
        Brightness.dark,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Mornye title opens artist and album destinations with subtitles',
    (tester) async {
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.dark),
        size: const Size(393, 780),
      );
      mediaItems.add(item('first'));
      await settlePlayer(tester);
      await tester.tap(find.text('First').hitTestable());
      await settlePlayer(tester);
      expect(find.text('Go to Artist'), findsOneWidget);
      expect(find.text('Go to Album'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(MornyePlayerNavigationMenu),
          matching: find.text('Artist'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(MornyePlayerNavigationMenu),
          matching: find.text('Album'),
        ),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(5, 770));
      await settlePlayer(tester);
      expect(find.byType(MornyePlayerNavigationMenu), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Android Details reads full tags from a restored content URI', (
    tester,
  ) async {
    metadataOverrides = {
      'album_artist': 'Album Artist',
      'genre': 'Pop/Rock',
      'composer': 'Composer Name',
      'date': '2025-04-16',
      'track_number': 4,
    };
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(
        Brightness.dark,
      ).copyWith(platform: TargetPlatform.android),
      size: const Size(393, 852),
    );
    mediaItems.add(item('first'));
    await settlePlayer(tester);
    expect(metadataReads, isEmpty);

    await tester.tap(findAppIcon(CupertinoIcons.ellipsis).hitTestable());
    await settlePlayer(tester);
    await tester.tap(find.text('Details'));
    await settlePlayer(tester);

    expect(metadataReads, ['content://library/first.flac']);
    final details = tester.widget<MornyePlayerDetailsSheet>(
      find.byType(MornyePlayerDetailsSheet),
    );
    expect(
      details.rows,
      containsAll([
        ('Title', 'First'),
        ('Album', 'Album'),
        ('Album Artist', 'Album Artist'),
        ('Genre', 'Pop/Rock'),
        ('Composer', 'Composer Name'),
        ('Date', '2025-04-16'),
        ('Track #', '4'),
      ]),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Mornye Details keeps long values readable and Done visible while scrolling',
    (tester) async {
      final rights = List.filled(10, 'A long copyright value').join(' ');
      metadataOverrides = {
        'title': 'First',
        'artist': 'Artist',
        'album': 'Album',
        'genre': 'Rock',
        'composer': 'Composer',
        'isrc': 'USAAA2600001',
        'copyright': rights,
        'format': 'flac',
        'sample_rate': 96000,
        'bit_depth': 24,
      };
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.light),
        size: const Size(393, 780),
      );
      mediaItems.add(
        item('first').copyWith(extras: {'source': '/library/first.flac'}),
      );
      await settlePlayer(tester);
      await tester.tap(findAppIcon(CupertinoIcons.ellipsis).hitTestable());
      await settlePlayer(tester);
      await tester.tap(find.text('Details'));
      await settlePlayer(tester);
      final sheet = find.byType(MornyePlayerDetailsSheet);
      expect(sheet, findsOneWidget);
      expect(Theme.of(tester.element(sheet)).brightness, Brightness.dark);
      expect(
        find.descendant(of: sheet, matching: find.byType(Card)),
        findsNothing,
      );
      expect(
        find.descendant(of: sheet, matching: find.byType(MornyeGlass)),
        findsOneWidget,
      );
      final titleRow = find.widgetWithText(MornyeMetadataRow, 'Title');
      expect(
        tester
            .getTopLeft(
              find.descendant(of: titleRow, matching: find.text('First')),
            )
            .dy,
        greaterThan(tester.getBottomLeft(find.text('Title')).dy),
      );
      await tester.scrollUntilVisible(
        find.text(rights),
        200,
        scrollable: find.descendant(
          of: sheet,
          matching: find.byType(Scrollable),
        ),
      );
      expect(tester.getSize(find.text(rights)).height, greaterThan(40));
      expect(find.text('Done').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Done'));
      await settlePlayer(tester);
      expect(sheet, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Mornye star shares Library favorites across tracks and compact headers',
    (tester) async {
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.light),
        size: const Size(393, 780),
      );
      mediaItems.add(item('first'));
      await settlePlayer(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(NowPlayingScreen)),
      );
      final star = findAppIcon(CupertinoIcons.star).hitTestable();
      expect(star, findsOneWidget);
      await tester.tap(star);
      await settlePlayer(tester);
      expect(
        findAppIcon(CupertinoIcons.star_fill).hitTestable(),
        findsOneWidget,
      );
      expect(
        container.read(libraryCollectionsProvider).loved.single.track.id,
        'first',
      );
      await tester.tap(findAppIcon(CupertinoIcons.ellipsis).hitTestable());
      await settlePlayer(tester);
      await tester.tap(find.text('Favorited'));
      await settlePlayer(tester);
      expect(container.read(libraryCollectionsProvider).loved, isEmpty);
      expect(star, findsOneWidget);
      await tester.tap(findAppIcon(CupertinoIcons.ellipsis).hitTestable());
      await settlePlayer(tester);
      await tester.tap(find.text('Favorite'));
      await settlePlayer(tester);
      expect(
        container.read(libraryCollectionsProvider).loved.single.track.id,
        'first',
      );
      await tester.tap(findAppIcon(CupertinoIcons.list_bullet));
      await settlePlayer(tester);
      expect(
        findAppIcon(CupertinoIcons.star_fill).hitTestable(),
        findsOneWidget,
      );
      mediaItems.add(item('second'));
      await settlePlayer(tester);
      expect(findAppIcon(CupertinoIcons.star).hitTestable(), findsOneWidget);
      mediaItems.add(item('first'));
      await settlePlayer(tester);
      expect(
        findAppIcon(CupertinoIcons.star_fill).hitTestable(),
        findsOneWidget,
      );

      // A change from Library must also update the player, without reopening it.
      final track = container
          .read(libraryCollectionsProvider)
          .loved
          .single
          .track;
      await container
          .read(libraryCollectionsProvider.notifier)
          .toggleLoved(track);
      await settlePlayer(tester);
      expect(findAppIcon(CupertinoIcons.star).hitTestable(), findsOneWidget);
      expect(
        find.byType(MornyePlayerFavoriteButton).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final layout in ['material', 'portrait', 'landscape']) {
    testWidgets('instrumental dots follow intro, break and seeks ($layout)', (
      tester,
    ) async {
      metadataOverrides['lyrics'] = '''
[00:09.00]First vocal
[00:12.00]
[00:21.00]Last vocal
[00:25.00]
''';
      final playback = StreamController<PlaybackState>.broadcast();
      addTearDown(playback.close);
      await pumpNowPlaying(
        tester,
        theme: layout == 'material' ? null : MornyeTheme.build(Brightness.dark),
        size: layout == 'landscape'
            ? const Size(852, 393)
            : const Size(393, 852),
        playbackEvents: playback.stream,
      );
      mediaItems.add(item('first'));
      await settlePlayer(tester);
      if (layout == 'material') {
        await tester.tap(find.byKey(const ValueKey('material-lyrics-toggle')));
      } else {
        await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
      }
      await settlePlayer(tester);

      Future<void> positionAt(
        int seconds, {
        bool playing = false,
        AudioProcessingState state = AudioProcessingState.ready,
      }) async {
        playback.add(
          PlaybackState(
            processingState: state,
            playing: playing,
            updatePosition: Duration(seconds: seconds),
          ),
        );
        if (state == AudioProcessingState.ready && !playing) {
          await settlePlayer(tester);
        } else {
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
        }
      }

      List<double> dotAlphas() => List.generate(3, (index) {
        final dot = tester.widget<AnimatedContainer>(
          find.byKey(ValueKey('lyric-gap-dot-$index')),
        );
        return (dot.decoration! as BoxDecoration).color!.a;
      });

      if (layout != 'material') {
        // Before playback, the countdown must reserve no blank row. Its
        // entrance pushes the upcoming vocal down instead of jumping it.
        expect(find.byType(LyricGapIndicator), findsNothing);
        final firstVocal = find.text('First vocal');
        final before = tester.getTopLeft(firstVocal).dy;
        playback.add(
          PlaybackState(
            processingState: AudioProcessingState.ready,
            updatePosition: const Duration(seconds: 3),
          ),
        );
        await tester.pump();
        await tester.pump();
        var previous = before;
        for (var frame = 0; frame < 4; frame++) {
          await tester.pump(const Duration(milliseconds: 80));
          final top = tester.getTopLeft(firstVocal).dy;
          expect(top, greaterThan(previous));
          expect(top - before, lessThan(56));
          previous = top;
        }
        await settlePlayer(tester);
        expect(tester.getTopLeft(firstVocal).dy - before, closeTo(56, 0.1));
      }

      for (final (seconds, expected) in [
        (3, [1.0, 0.25, 0.25]),
        (6, [1.0, 1.0, 0.25]),
        (15, [1.0, 0.25, 0.25]),
        (18, [1.0, 1.0, 0.25]),
        (6, [1.0, 1.0, 0.25]),
      ]) {
        await positionAt(seconds);
        expect(find.byType(LyricGapIndicator).hitTestable(), findsOneWidget);
        expect(dotAlphas(), expected);
        if (layout != 'material') {
          final blur = tester.widget<LyricBlur>(
            find
                .ancestor(
                  of: find.text(seconds >= 12 ? 'Last vocal' : 'First vocal'),
                  matching: find.byType(LyricBlur),
                )
                .first,
          );
          expect(blur.sigma, greaterThan(0));
        }
      }

      final firstDot = find.byKey(const ValueKey('lyric-gap-dot-0'));
      double dotWidth([int index = 0]) {
        final dot = find.byKey(ValueKey('lyric-gap-dot-$index'));
        return (tester.getBottomRight(dot) - tester.getTopLeft(dot)).dx;
      }

      void expectSynchronizedDots() {
        for (var index = 1; index < 3; index++) {
          expect(dotWidth(index), closeTo(dotWidth(), 0.001));
        }
      }

      final restingWidth = dotWidth();
      final restingCenter = tester.getCenter(firstDot);
      final rowSize = tester.getSize(find.byType(LyricGapIndicator));
      // Leave enough intro time for the slower pulse to grow and shrink.
      await positionAt(3, playing: true);
      await tester.pump(const Duration(milliseconds: 800));
      final filling = dotAlphas();
      final growingWidth = dotWidth();
      expect(growingWidth, greaterThan(restingWidth));
      expectSynchronizedDots();
      await tester.pump(const Duration(milliseconds: 700));
      final peakWidth = dotWidth();
      expect(peakWidth, greaterThan(growingWidth));
      expectSynchronizedDots();
      await tester.pump(const Duration(milliseconds: 1500));
      expect(dotWidth(), lessThan(peakWidth));
      expectSynchronizedDots();
      expect(tester.getCenter(firstDot), restingCenter);
      expect(tester.getSize(find.byType(LyricGapIndicator)), rowSize);
      expect(dotAlphas(), filling);

      // Pause mid-pulse: both the size and countdown must hold their place.
      await tester.pump(const Duration(milliseconds: 900));
      await positionAt(6);
      final pausedWidth = dotWidth();
      await tester.pump(const Duration(seconds: 2));
      expect(dotWidth(), pausedWidth);
      expect(dotAlphas(), [1.0, 1.0, 0.25]);

      await positionAt(6, playing: true, state: AudioProcessingState.buffering);
      expect(find.byType(LyricGapIndicator), findsNothing);
      await positionAt(6);
      expect(dotAlphas(), [1.0, 1.0, 0.25]);
      await tester.pump(const Duration(seconds: 2));
      expect(dotAlphas(), [1.0, 1.0, 0.25]);

      for (final seconds in [9, 21, 25, 40]) {
        await positionAt(seconds);
        expect(find.byType(LyricGapIndicator), findsNothing);
      }
      await positionAt(6);
      expect(find.byType(LyricGapIndicator), findsOneWidget);
      metadataOverrides.clear();
      mediaItems.add(item('second'));
      await settlePlayer(tester);
      expect(find.byType(LyricGapIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Mornye lyrics stay blurred until playback starts', (
    tester,
  ) async {
    final playback = StreamController<PlaybackState>();
    addTearDown(playback.close);
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 780),
      playbackEvents: playback.stream,
    );
    mediaItems.add(item('many'));
    playback.add(
      PlaybackState(
        processingState: AudioProcessingState.loading,
        playing: true,
        updatePosition: const Duration(seconds: 2),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
    await tester.pump();
    await completeLyrics(tester);
    await tester.pump(const Duration(milliseconds: 400));

    void expectLine(String text, {required bool active}) {
      final line = find.text(text);
      final blur = tester.widget<LyricBlur>(
        find.ancestor(of: line, matching: find.byType(LyricBlur)).first,
      );
      final opacity = tester.widget<AnimatedOpacity>(
        find.ancestor(of: line, matching: find.byType(AnimatedOpacity)).first,
      );
      expect(opacity.opacity, active ? 1 : 0.48);
      expect(blur.sigma > 0, !active, reason: '$text: ${blur.sigma}');
    }

    expectLine('First line', active: false);
    expectLine('Second line', active: false);
    expectLine('Third line', active: false);

    playback.add(PlaybackState(processingState: AudioProcessingState.ready));
    await settlePlayer(tester);
    expectLine('First line', active: false);

    playback.add(
      PlaybackState(
        processingState: AudioProcessingState.ready,
        playing: true,
        updatePosition: const Duration(seconds: 2),
      ),
    );
    await tester.pump();
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump(const Duration(milliseconds: 160));
    }
    expectLine('First line', active: false);
    expectLine('Second line', active: true);
    expectLine('Third line', active: false);

    playback.add(
      PlaybackState(
        processingState: AudioProcessingState.ready,
        updatePosition: const Duration(seconds: 2),
      ),
    );
    await settlePlayer(tester);
    expectLine('Second line', active: true);

    playback.add(
      PlaybackState(
        processingState: AudioProcessingState.buffering,
        playing: true,
        updatePosition: const Duration(seconds: 2),
      ),
    );
    await tester.pump();
    for (var frame = 0; frame < 3; frame++) {
      await tester.pump(const Duration(milliseconds: 160));
    }
    expectLine('First line', active: false);
    expectLine('Second line', active: false);
    expectLine('Third line', active: false);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Mornye lyrics keep the active line sharp with bold leading-aligned text',
    (tester) async {
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.light),
        size: const Size(393, 780),
        playback: PlaybackState(updatePosition: const Duration(seconds: 2)),
      );
      mediaItems.add(item('many'));
      await settlePlayer(tester, const Duration(milliseconds: 16));
      await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
      await settlePlayer(tester, const Duration(milliseconds: 16));
      final active = find.text('Second line');
      final inactive = find.text('Third line');
      final activeText = tester.widget<Text>(active);
      expect(activeText.textAlign, TextAlign.start);
      expect(activeText.style?.fontWeight, FontWeight.bold);
      expect(activeText.style?.fontSize, 34);
      expect(tester.getTopLeft(active).dx, tester.getTopLeft(inactive).dx);
      expect(tester.getTopLeft(active).dx, seekTrackBounds(tester).left);
      LyricBlur blur(Finder line) => tester.widget<LyricBlur>(
        find.ancestor(of: line, matching: find.byType(LyricBlur)),
      );
      RenderLyricBlurSnapshot snapshot(Finder line) =>
          tester.renderObject<RenderLyricBlurSnapshot>(
            find.ancestor(
              of: line,
              matching: find.byElementPredicate(
                (element) =>
                    element is RenderObjectElement &&
                    element.renderObject is RenderLyricBlurSnapshot,
              ),
            ),
          );
      expect(blur(active).sigma, 0);
      expect(snapshot(active).debugSnapshot, isNull);
      // The settled defocused line draws one cached blur instead of a filter.
      expect(blur(inactive).sigma, 2.4);
      expect(blur(inactive).settled, isTrue);
      expect(snapshot(inactive).debugSnapshot, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Mornye queue replaces artwork while volume and playback stay in place',
    (tester) async {
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.light),
        size: const Size(393, 780),
      );
      mediaItems.add(item('first'));
      await settlePlayer(tester, const Duration(milliseconds: 16));
      await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
      await settlePlayer(tester, const Duration(milliseconds: 16));
      expect(find.text('First lyric').hitTestable(), findsOneWidget);
      final volume = tester.getRect(find.byType(PlayerVolumeControl));
      await tester.tap(findAppIcon(CupertinoIcons.list_bullet));
      await settlePlayer(tester, const Duration(milliseconds: 16));
      expect(find.byType(MornyePlayerQueue), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.getRect(find.byType(PlayerVolumeControl)), volume);
      expect(tester.takeException(), isNull);
      await tester.tap(findAppIcon(CupertinoIcons.list_bullet));
      await tester.pump();
      expect(find.text('First lyric'), findsNothing);
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.text('First lyric'), findsNothing);
      expect(find.byType(MornyePlayerQueue), findsOneWidget);
      expect(find.byType(MornyePlayerQueue).hitTestable(), findsNothing);
      await settlePlayer(tester, const Duration(milliseconds: 16));
      expect(find.byType(MornyePlayerQueue), findsNothing);
      expect(tester.getRect(find.byType(PlayerVolumeControl)), volume);
    },
  );

  for (final landscape in [false, true]) {
    testWidgets(
      'paused play glyph is smaller without moving controls (landscape: $landscape)',
      (tester) async {
        final playback = StreamController<PlaybackState>();
        addTearDown(playback.close);
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: landscape ? const Size(852, 393) : const Size(393, 852),
          playbackEvents: playback.stream,
        );
        playback.add(PlaybackState(playing: true));
        mediaItems.add(item('first'));
        await settlePlayer(tester);
        final pause = find.widgetWithIcon(
          MornyePlaybackButton,
          CupertinoIcons.pause_fill,
        );
        final pauseBounds = tester.getRect(pause);
        final pauseSize = tester.getSize(
          findAppIcon(CupertinoIcons.pause_fill),
        );
        final previous = findAppIcon(CupertinoIcons.backward_fill);
        final next = findAppIcon(CupertinoIcons.forward_fill);
        final previousBounds = tester.getRect(previous);
        final nextBounds = tester.getRect(next);
        final volumeBounds = tester.getRect(find.byType(PlayerVolumeControl));

        playback.add(PlaybackState(playing: false));
        await settlePlayer(tester);
        final play = find.widgetWithIcon(
          MornyePlaybackButton,
          CupertinoIcons.play_fill,
        );
        final playSize = tester.getSize(findAppIcon(CupertinoIcons.play_fill));
        expect(playSize.width, lessThan(pauseSize.width));
        expect(playSize.width / pauseSize.width, inInclusiveRange(0.85, 0.95));
        expect(tester.getRect(play), pauseBounds);
        expect(tester.getRect(previous), previousBounds);
        expect(tester.getRect(next), nextBounds);
        expect(tester.getRect(find.byType(PlayerVolumeControl)), volumeBounds);

        playback.add(PlaybackState(playing: true));
        await settlePlayer(tester);
        expect(
          tester.getSize(findAppIcon(CupertinoIcons.pause_fill)),
          pauseSize,
        );
        expect(tester.getRect(pause), pauseBounds);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [320.0, 430.0]) {
    testWidgets('Material transport fits a $width dp phone', (tester) async {
      await pumpNowPlaying(
        tester,
        theme: AppTheme.light(),
        size: Size(width, 900),
      );
      mediaItems.add(item('first'));
      await settlePlayer(tester);
      // Previous, play-pause and next form the expressive transport row;
      // shuffle and repeat share the footer's toolbar with the lyrics toggle.
      final transport = find.descendant(
        of: find.byType(ExpressivePlaybackTransport),
        matching: find.byType(M3EIconButton),
      );
      final modes = find.descendant(
        of: find.byType(PlayerPlaybackModeToolbar),
        matching: find.byType(InkWell),
      );
      final lyricsToggle = find.byKey(const ValueKey('material-lyrics-toggle'));
      expect(transport, findsNWidgets(3));
      expect(modes, findsNWidgets(2));
      expect(lyricsToggle, findsOneWidget);
      for (final element in [
        ...transport.evaluate(),
        ...modes.evaluate(),
        ...lyricsToggle.evaluate(),
      ]) {
        final bounds = tester.getRect(find.byWidget(element.widget));
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(width));
        expect(bounds.width, greaterThanOrEqualTo(48));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a selected Material playback mode keeps its connected shape', (
    tester,
  ) async {
    await pumpNowPlaying(
      tester,
      theme: AppTheme.light(),
      playback: PlaybackState(shuffleMode: AudioServiceShuffleMode.all),
    );
    mediaItems.add(item('first'));
    await settlePlayer(tester);
    final segments = tester
        .widgetList<Material>(
          find.descendant(
            of: find.byType(PlayerPlaybackModeToolbar),
            matching: find.byType(Material),
          ),
        )
        .toList();
    expect(segments, hasLength(2));
    BorderRadius corners(Material segment) =>
        (segment.shape! as RoundedRectangleBorder).borderRadius.resolve(
          TextDirection.ltr,
        );
    // Round outer ends and small inner corners, selected or not.
    expect(
      corners(segments.first),
      const BorderRadius.horizontal(
        left: Radius.circular(24),
        right: Radius.circular(8),
      ),
    );
    expect(
      corners(segments.last),
      const BorderRadius.horizontal(
        left: Radius.circular(8),
        right: Radius.circular(24),
      ),
    );
    // Shuffle is on and repeat is off.
    expect(segments.first.color, isNot(segments.last.color));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Material cover replacement honors reduced motion immediately', (
    tester,
  ) async {
    await pumpNowPlaying(
      tester,
      theme: AppTheme.dark(),
      wrapPlayer: (player) => MediaQuery(
        data: const MediaQueryData(
          size: Size(1080, 1920),
          disableAnimations: true,
        ),
        child: player,
      ),
    );
    mediaItems.add(item('first'));
    await settlePlayer(tester);
    // The card; full screen also draws the cover behind the player.
    ProviderScope.containerOf(
      tester.element(find.byType(NowPlayingScreen)),
    ).read(settingsProvider.notifier).setPlayerCoverStyle('default');
    await settlePlayer(tester);
    mediaItems.add(item('second'));
    await completeLyrics(tester);
    await tester.pump();
    final covers = find.descendant(
      of: find.byType(MaterialPlayerLayout),
      matching: find.byType(PlayerArtwork),
    );
    expect(covers, findsOneWidget);
    expect(tester.widget<PlayerArtwork>(covers).key, const ValueKey('second'));
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(320, 568),
    const Size(430, 932),
    const Size(852, 393),
  ]) {
    testWidgets(
      'Material lyrics share the player and keep controls fixed ($size)',
      (tester) async {
        final controller = _SeekController();
        metadataOverrides.addAll({
          'format': 'flac',
          'bit_depth': 16,
          'sample_rate': 44100,
        });
        await pumpNowPlaying(
          tester,
          theme: AppTheme.dark(),
          size: size,
          controller: controller,
          wrapPlayer: (player) => MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(1.3),
            ),
            child: player,
          ),
        );
        mediaItems.add(
          item('first').copyWith(
            title: 'A longer track title that needs more than one line',
            extras: {'source': '/music/first.flac'},
          ),
        );
        await settlePlayer(tester);
        expect(find.byType(PageView), findsNothing);
        final slider = find.byType(PlaybackSeekSlider);
        final play = find.byTooltip('Play');
        final toggle = find.byKey(const ValueKey('material-lyrics-toggle'));
        final sliderState = tester.state(slider);
        final sliderBounds = tester.getRect(slider);
        final playBounds = tester.getRect(play);
        expect(sliderBounds.bottom, lessThan(size.height));
        expect(play.hitTestable(), findsOneWidget);

        await tester.tap(toggle);
        await tester.pump();
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getRect(slider), sliderBounds);
          expect(tester.getRect(play), playBounds);
          expect(tester.state(slider), same(sliderState));
        }
        await settlePlayer(tester);
        expect(find.text('First lyric').hitTestable(), findsOneWidget);
        expect(
          find.byKey(const ValueKey('material-player-cover')),
          findsNothing,
        );
        expect(play.hitTestable(), findsOneWidget);
        await tester.tapAt(seekTrackBounds(tester).center);
        await tester.pump();
        expect(controller.seeks, hasLength(1));
        expect(controller.seeks.single.inSeconds, closeTo(90, 1));
        controller.completions.single.complete();
        await settlePlayer(tester);

        await tester.tap(toggle);
        await settlePlayer(tester);
        expect(
          find.byKey(const ValueKey('material-player-cover')),
          findsOneWidget,
        );
        expect(find.text('First lyric').hitTestable(), findsNothing);
        expect(tester.getRect(slider), sliderBounds);
        expect(tester.getRect(play), playBounds);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [320.0, 430.0]) {
    testWidgets('Material queue shows covers and selected controls at $width', (
      tester,
    ) async {
      final queue = [item('first'), item('second')];
      final controller = _QueueController(
        (index) => mediaItems.add(queue[index]),
      );
      await pumpNowPlaying(
        tester,
        theme: AppTheme.dark(),
        size: Size(width, 852),
        queue: queue,
        controller: controller,
        playback: PlaybackState(
          queueIndex: 0,
          shuffleMode: AudioServiceShuffleMode.all,
          repeatMode: AudioServiceRepeatMode.all,
        ),
      );
      mediaItems.add(queue.first);
      await settlePlayer(tester);
      await tester.tap(findAppIcon(Icons.queue_music));
      await settlePlayer(tester);
      final rows = find.descendant(
        of: find.byType(ReorderableListView),
        matching: find.byType(ListTile),
      );
      expect(rows, findsNWidgets(2));
      expect(
        find.descendant(of: rows, matching: find.byType(PlayerArtwork)),
        findsNWidgets(2),
      );
      expect(tester.widgetList<ListTile>(rows).map((row) => row.selected), [
        true,
        false,
      ]);
      final toggles = tester.widgetList<ExpressiveIconButton>(
        find.descendant(
          of: find.byType(DraggableScrollableSheet),
          matching: find.byType(ExpressiveIconButton),
        ),
      );
      expect(
        toggles.where((button) => button.selected == true).length,
        greaterThanOrEqualTo(2),
      );
      expect(
        toggles
            .where((button) => button.selected == true)
            .every((button) => button.backgroundColor != null),
        isTrue,
      );
      await tester.tap(
        find.descendant(of: rows, matching: find.text('Second')),
      );
      await settlePlayer(tester);
      expect(controller.selected, [1]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Mornye player renders Apple-style transport controls', (
    tester,
  ) async {
    await pumpNowPlaying(tester, theme: MornyeTheme.build(Brightness.light));
    mediaItems.add(item('first'));
    await settlePlayer(tester);

    expect(findAppIcon(CupertinoIcons.play_fill), findsOneWidget);
    expect(findAppIcon(CupertinoIcons.backward_fill), findsOneWidget);
    expect(findAppIcon(CupertinoIcons.forward_fill), findsOneWidget);
    expect(find.byType(PlayerVolumeControl), findsOneWidget);
    expect(tester.takeException(), isNull);

    final nextButton = find.widgetWithIcon(
      MornyePlaybackButton,
      CupertinoIcons.forward_fill,
    );
    final nextState = tester.state(nextButton);
    mediaItems.add(item('second'));
    await settlePlayer(tester);
    expect(tester.state(nextButton), same(nextState));
  });

  testWidgets('Mornye elapsed and remaining times roll on the same second', (
    tester,
  ) async {
    final playbackEvents = StreamController<PlaybackState>();
    addTearDown(playbackEvents.close);
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 780),
      playbackEvents: playbackEvents.stream,
    );
    mediaItems.add(
      item(
        'first',
      ).copyWith(duration: const Duration(seconds: 180, milliseconds: 600)),
    );

    Future<void> positionAt(int milliseconds) async {
      playbackEvents.add(
        PlaybackState(
          processingState: AudioProcessingState.ready,
          playing: false,
          updatePosition: Duration(milliseconds: milliseconds),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    final elapsed = find.byKey(const ValueKey('elapsed:first'));
    final remaining = find.byKey(const ValueKey('remaining:first'));
    void expectTimes(int elapsedSeconds, int remainingSeconds) {
      expect(
        tester.widget<MornyePlaybackTime>(elapsed).seconds,
        elapsedSeconds,
      );
      expect(
        tester.widget<MornyePlaybackTime>(remaining).seconds,
        remainingSeconds,
      );
    }

    await positionAt(34200);
    await settlePlayer(tester);
    expectTimes(34, 146);
    final transport = tester
        .widgetList<MornyePlaybackButton>(find.byType(MornyePlaybackButton))
        .toList();
    await positionAt(34800);
    expectTimes(34, 146);
    final updatedTransport = tester
        .widgetList<MornyePlaybackButton>(find.byType(MornyePlaybackButton))
        .toList();
    for (var i = 0; i < transport.length; i++) {
      expect(updatedTransport[i], same(transport[i]));
    }

    await positionAt(35000);
    await tester.pump(const Duration(milliseconds: 80));
    expectTimes(35, 145);
    double incomingOffset(Finder label) => tester
        .widget<SlideTransition>(
          find
              .ancestor(
                of: find.descendant(of: label, matching: find.text('5')),
                matching: find.byType(SlideTransition),
              )
              .first,
        )
        .position
        .value
        .dy;
    expect(incomingOffset(elapsed), greaterThan(0));
    expect(incomingOffset(remaining), -incomingOffset(elapsed));

    // Another position report within this second must not restart either roll.
    await positionAt(35200);
    await tester.pump(const Duration(milliseconds: 200));
    expect(incomingOffset(elapsed), 0);
    expect(incomingOffset(remaining), 0);
    await positionAt(35900);
    expectTimes(35, 145);
    await positionAt(36000);
    expectTimes(36, 144);
    await settlePlayer(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mornye position ticks and lyric control fades stay local', (
    tester,
  ) async {
    metadataOverrides['lyrics'] = List.generate(
      20,
      (index) => '[0${index ~/ 3}:${index % 3 * 2}0.00]Lyric $index',
    ).join('\n');
    final playbackEvents = StreamController<PlaybackState>();
    addTearDown(playbackEvents.close);
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 780),
      playbackEvents: playbackEvents.stream,
    );
    mediaItems.add(item('many'));
    Future<void> positionAt(int milliseconds, {bool playing = false}) async {
      playbackEvents.add(
        PlaybackState(
          processingState: AudioProcessingState.ready,
          playing: playing,
          updatePosition: Duration(milliseconds: milliseconds),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    await positionAt(10000);
    await settlePlayer(tester);
    // The header and transport do not change with the position.
    final unchanged = {
      ...tester.renderObjectList(find.text('Second')),
      ...tester.renderObjectList(find.byType(MornyePlaybackButton)),
    };
    var unchangedPaints = 0;
    var lyricBuilds = 0;
    debugOnProfilePaint = (object) {
      if (unchanged.contains(object)) unchangedPaints++;
    };
    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is SyncedLyricsView) lyricBuilds++;
    };
    try {
      await positionAt(10500);
      expect(unchangedPaints, 0);
      // A new second lays out the digits once, then rolls them in place.
      await positionAt(11000);
      await tester.pump(const Duration(milliseconds: 16));
      unchangedPaints = 0;
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(unchangedPaints, 0);

      // Synced lyrics ignore the covered height that animates while the
      // controls fade out, so only the hiding rebuild reaches the list.
      await positionAt(20000, playing: true);
      await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
      await settlePlayer(tester);
      final hidden = find.byWidgetPredicate(
        (widget) => widget is PlayerLyricsControlsVisibility && widget.hidden,
      );
      expect(hidden, findsNothing);
      lyricBuilds = 0;
      await tester.pump(const Duration(seconds: 5));
      for (var frame = 0; frame < 16; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(hidden, findsWidgets);
      expect(lyricBuilds, lessThanOrEqualTo(1));
    } finally {
      debugOnProfilePaint = null;
      debugOnRebuildDirtyWidget = null;
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mornye volume stays above the bottom actions on a phone', (
    tester,
  ) async {
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 700),
    );
    mediaItems.add(item('first'));
    await settlePlayer(tester);

    final volume = find.byType(PlayerVolumeControl);
    final lyricsButton = findAppIcon(CupertinoIcons.quote_bubble);
    final slider = find.descendant(of: volume, matching: find.byType(Slider));
    expect(
      tester.getRect(volume).bottom,
      lessThan(tester.getRect(lyricsButton).top),
    );
    expect(tester.getSize(slider).height, greaterThanOrEqualTo(44));
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump(const Duration(milliseconds: 16));
    expect(volumeWrites, isNotEmpty);
    expect(volumeWrites.last, greaterThan(0.5));
    await gesture.up();
    await settlePlayer(tester, const Duration(milliseconds: 16));
    expect(volumeWrites, isNotEmpty);
    expect(volumeWrites.last, greaterThan(0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Mornye landscape opens the player and reveals hidden lyric actions on a bottom tap',
    (tester) async {
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.dark),
        size: const Size(393, 852),
        playback: PlaybackState(playing: true),
      );
      mediaItems.add(item('first'));
      await settlePlayer(tester);

      tester.view.physicalSize = const Size(852, 393);
      tester.view.padding = FakeViewPadding(left: 59, right: 59, bottom: 21);
      addTearDown(tester.view.resetPadding);
      await settlePlayer(tester);

      final artwork = find.byType(Hero);
      final volume = find.byType(PlayerVolumeControl);
      final artRect = tester.getRect(artwork);
      expect(artRect.width, closeTo(artRect.height, 0.1));
      expect(artRect.width, greaterThan(140));
      expect(artRect.top, greaterThanOrEqualTo(36));
      final header = find.text('First').hitTestable();
      final lyric = find.text('First lyric').hitTestable();
      expect(header, findsOneWidget);
      expect(lyric, findsNothing);
      expect(tester.getRect(header).left, greaterThan(artRect.right));
      expect(volume.hitTestable(), findsOneWidget);
      expect(
        findAppIcon(CupertinoIcons.quote_bubble).hitTestable(),
        findsOneWidget,
      );
      expect(
        findAppIcon(CupertinoIcons.list_bullet).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      expect(
        findAppIcon(CupertinoIcons.pause_fill).hitTestable(),
        findsOneWidget,
      );
      final volumeSlider = find.descendant(
        of: volume,
        matching: find.byType(Slider),
      );
      final drag = await tester.startGesture(tester.getCenter(volumeSlider));
      await drag.moveBy(const Offset(30, 0));
      await tester.pump(const Duration(seconds: 5));
      expect(volume.hitTestable(), findsOneWidget);
      expect(volumeWrites, isNotEmpty);
      await drag.up();
      await tester.pump(const Duration(seconds: 4));
      await settlePlayer(tester);
      expect(volume.hitTestable(), findsOneWidget);

      await tester.tap(findAppIcon(CupertinoIcons.quote_bubble).hitTestable());
      await settlePlayer(tester);
      expect(volume, findsNothing);
      expect(find.text('First lyric').hitTestable(), findsOneWidget);
      expect(tester.getRect(lyric).left, greaterThan(artRect.right));
      expect(
        tester.getRect(lyric).top,
        greaterThan(tester.getRect(header).bottom),
      );
      await tester.pump(const Duration(seconds: 5));
      await settlePlayer(tester);
      expect(
        findAppIcon(CupertinoIcons.quote_bubble).hitTestable(),
        findsNothing,
      );
      expect(
        findAppIcon(CupertinoIcons.list_bullet).hitTestable(),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('landscape-actions-reveal')));
      await settlePlayer(tester);
      expect(
        findAppIcon(CupertinoIcons.quote_bubble).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(findAppIcon(CupertinoIcons.quote_bubble).hitTestable());
      await settlePlayer(tester);
      expect(volume.hitTestable(), findsOneWidget);
      expect(lyric, findsNothing);
      await tester.tap(findAppIcon(CupertinoIcons.quote_bubble).hitTestable());
      await settlePlayer(tester);

      mediaItems.add(item('second'));
      await settlePlayer(tester);
      expect(find.text('Second lyric').hitTestable(), findsOneWidget);
      expect(find.text('First lyric'), findsNothing);
      tester.view.physicalSize = const Size(393, 852);
      tester.view.resetPadding();
      await settlePlayer(tester);
      expect(
        findAppIcon(CupertinoIcons.quote_bubble).hitTestable(),
        findsOneWidget,
      );
      expect(
        findAppIcon(CupertinoIcons.list_bullet).hitTestable(),
        findsOneWidget,
      );
      expect(
        tester.getRect(artwork).bottom,
        lessThan(tester.getRect(volume).top),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Mornye motion cover stays attached throughout opening and closing',
    (tester) async {
      tester.view.padding = FakeViewPadding(top: 59, bottom: 34);
      tester.view.viewPadding = FakeViewPadding(top: 59, bottom: 34);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.dark),
        size: const Size(393, 852),
        motionArtwork: const MotionArtwork('file:///cover.mp4', aspectRatio: 1),
        wrapPlayer: (_) => Consumer(
          builder: (context, ref, _) {
            ref.watch(currentMediaItemProvider);
            return Scaffold(
              body: Align(
                alignment: Alignment.bottomLeft,
                child: TextButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).push(NowPlayingRoute(child: playerScreen())),
                  child: const Hero(
                    tag: kNowPlayingArtworkHeroTag,
                    child: SizedBox.square(dimension: 38, child: Text('Open')),
                  ),
                ),
              ),
            );
          },
        ),
      );
      mediaItems.add(item('first'));
      await settlePlayer(tester);
      await tester.tap(find.text('Open'));
      await tester.pump();

      void expectAttached() {
        final panel = tester.getRect(find.byType(MornyePlayerBackground));
        final artwork = tester.getRect(
          find.descendant(
            of: find.byType(MornyePlayerBackground),
            matching: find.byType(MornyePlayerArtwork),
          ),
        );
        expect(artwork.left, closeTo(panel.left, 0.01));
        expect(artwork.top, closeTo(panel.top, 0.01));
        expect(artwork.width, closeTo(393, 0.01));
        expect(artwork.height, closeTo(393, 0.01));
      }

      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 40));
        expectAttached();
      }
      await settlePlayer(tester);
      expectAttached();
      Navigator.of(tester.element(find.byType(NowPlayingScreen))).pop();
      await tester.pump();
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 40));
        expectAttached();
        expect(
          tester.getTopLeft(find.byType(MornyePlayerBackground)).dy,
          greaterThan(0),
        );
      }
      await settlePlayer(tester);
      expect(find.byType(NowPlayingScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final motion in [false, true]) {
    for (final drag in [false, true]) {
      testWidgets(
        'Mornye minimizes into the current mini player (motion: $motion, drag: $drag)',
        (tester) async {
          await pumpNowPlaying(
            tester,
            theme: MornyeTheme.build(Brightness.dark),
            size: const Size(393, 852),
            playback: PlaybackState(playing: true),
            motionArtwork: motion
                ? const MotionArtwork('file:///cover.mp4', aspectRatio: 1)
                : null,
            wrapPlayer: (_) => const Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(12, 0, 12, 90),
                  child: MiniPlayer(),
                ),
              ),
            ),
          );
          mediaItems.add(item('first'));
          await settlePlayer(tester);
          final mini = find.byType(MiniPlayer);
          final miniCover = find.descendant(
            of: mini,
            matching: find.byType(Hero),
          );
          final destination = tester.getRect(miniCover);
          await tester.tap(
            find.descendant(of: mini, matching: find.text('First')),
          );
          await settlePlayer(tester);
          final player = find.byType(NowPlayingScreen);
          final route =
              ModalRoute.of(tester.element(player))! as NowPlayingRoute;
          final fullCover = find.descendant(
            of: player,
            matching: find.byType(MornyePlayerArtwork),
          );
          if (drag) {
            route.startDrag();
            route.updateDrag(
              DragUpdateDetails(
                globalPosition: const Offset(0, 300),
                delta: const Offset(0, 300),
                primaryDelta: 300,
              ),
              852,
            );
            await tester.pump();
          }
          final releasedCover = tester.getRect(fullCover);
          final releasedPanel = tester.getRect(
            find.byType(MornyePlayerBackground),
          );
          if (drag) {
            route.endDrag(DragEndDetails(primaryVelocity: 0), 852);
          } else {
            Navigator.of(tester.element(player)).pop();
          }
          await tester.pump();
          final flyingCover = find.byKey(
            const ValueKey('player-minimize-artwork'),
          );
          final surface = find.byKey(const ValueKey('player-minimize-surface'));
          expect(tester.getRect(flyingCover), releasedCover);
          expect(tester.getRect(surface), releasedPanel);
          var previousDistance =
              (releasedCover.center - destination.center).distance;
          for (var frame = 0; frame < 5; frame++) {
            await tester.pump(const Duration(milliseconds: 25));
            final bounds = tester.getRect(flyingCover);
            final distance = (bounds.center - destination.center).distance;
            expect(distance, lessThan(previousDistance));
            expect(
              bounds.width,
              inExclusiveRange(destination.width, releasedCover.width),
            );
            previousDistance = distance;
          }
          await settlePlayer(tester);
          expect(player, findsNothing);
          expect(tester.getRect(miniCover), destination);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final mornye in [false, true]) {
    testWidgets('swiping up the mini player opens the player '
        '(Mornye: $mornye)', (tester) async {
      await pumpNowPlaying(
        tester,
        theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
        size: const Size(393, 852),
        // Paused, so the Material progress bar lets the frames settle.
        wrapPlayer: (_) => const Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 90),
              child: MiniPlayer(),
            ),
          ),
        ),
      );
      mediaItems.add(item('first'));
      await settlePlayer(tester);
      final title = find.descendant(
        of: find.byType(MiniPlayer),
        matching: find.text('First'),
      );
      final player = find.byType(NowPlayingScreen);

      // A downward drag never opens the player.
      await tester.drag(title, const Offset(0, 120));
      await settlePlayer(tester);
      expect(player, findsNothing);

      // A nudge, or a pull taken back down, leaves it closed.
      for (final moves in [
        [const Offset(0, -30)],
        [const Offset(0, -120), const Offset(0, 110)],
      ]) {
        final gesture = await tester.startGesture(tester.getCenter(title));
        for (final move in moves) {
          await gesture.moveBy(move);
        }
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.up();
        await settlePlayer(tester);
        expect(player, findsNothing);
      }

      // A slow pull that stops before release opens it.
      final gesture = await tester.startGesture(tester.getCenter(title));
      await gesture.moveBy(const Offset(0, -150));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.up();
      await settlePlayer(tester);
      expect(player, findsOneWidget);
      expect(tester.getTopLeft(player).dy, 0);
      Navigator.of(tester.element(player)).pop();
      await settlePlayer(tester);
      expect(player, findsNothing);

      await tester.fling(title, const Offset(0, -60), 1500);
      await settlePlayer(tester);
      expect(player, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final lyrics in [true, false]) {
    testWidgets(
      'tapping the compact motion cover returns from ${lyrics ? 'lyrics' : 'queue'}',
      (tester) async {
        tester.view.padding = FakeViewPadding(top: 59, bottom: 34);
        tester.view.viewPadding = FakeViewPadding(top: 59, bottom: 34);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: const Size(393, 852),
          motionArtwork: const MotionArtwork(
            'file:///cover.mp4',
            aspectRatio: 0.75,
          ),
        );
        mediaItems.add(item('first'));
        await settlePlayer(tester);
        final fullCover = find.descendant(
          of: find.byType(MornyePlayerBackground),
          matching: find.byType(MornyePlayerArtwork),
        );
        final fullBounds = tester.getRect(fullCover);
        final toggle = findAppIcon(
          lyrics ? CupertinoIcons.quote_bubble : CupertinoIcons.list_bullet,
        );
        final compact = find.byKey(const ValueKey('compact-player-artwork'));
        final playback = find.widgetWithIcon(
          MornyePlaybackButton,
          CupertinoIcons.play_fill,
        );
        await tester.tap(toggle);
        await tester.pump();
        expect(tester.getRect(compact), fullBounds);
        var previous = fullBounds;
        for (var frame = 0; frame < 3; frame++) {
          await tester.pump(const Duration(milliseconds: 80));
          final bounds = tester.getRect(compact);
          expect(bounds.width, lessThan(previous.width));
          expect(bounds.center.dy, lessThan(previous.center.dy));
          expect(playback.hitTestable(), findsOneWidget);
          previous = bounds;
        }
        await settlePlayer(tester);
        final compactBounds = tester.getRect(compact);
        expect(compactBounds.size, const Size(72, 72));
        final header = find.byKey(const ValueKey('player-track-header'));
        expect(tester.getRect(header).left, compactBounds.right + 12);
        expect(tester.getRect(header).center.dy, compactBounds.center.dy);
        await tester.tap(compact);
        await tester.pump();
        expect(tester.getRect(compact), compactBounds);
        previous = compactBounds;
        for (var frame = 0; frame < 3; frame++) {
          await tester.pump(const Duration(milliseconds: 80));
          final bounds = tester.getRect(compact);
          expect(bounds.width, greaterThan(previous.width));
          expect(bounds.center.dy, greaterThan(previous.center.dy));
          expect(playback.hitTestable(), findsOneWidget);
          previous = bounds;
        }
        await settlePlayer(tester);
        expect(compact, findsNothing);
        expect(tester.getRect(fullCover), fullBounds);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'one header travels to and from ${lyrics ? 'lyrics' : 'queue'} beside the cover',
      (tester) async {
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: const Size(393, 852),
        );
        mediaItems.add(item('first'));
        await settlePlayer(tester);
        final toggle = findAppIcon(
          lyrics ? CupertinoIcons.quote_bubble : CupertinoIcons.list_bullet,
        );
        final header = find.byKey(const ValueKey('player-track-header'));
        final element = tester.element(header);
        final expandedBounds = tester.getRect(header);
        final play = find.widgetWithIcon(
          MornyePlaybackButton,
          CupertinoIcons.play_fill,
        );
        final controlsBounds = tester.getRect(play);
        final favorite = find.byType(MornyePlayerFavoriteButton);
        final favoriteState = tester.state(favorite);
        for (var visit = 0; visit < 2; visit++) {
          await tester.tap(toggle);
          await tester.pump();
          expect(tester.getRect(header), expandedBounds);
          var previous = expandedBounds;
          for (var frame = 0; frame < 3; frame++) {
            await tester.pump(const Duration(milliseconds: 80));
            final bounds = tester.getRect(header);
            expect(bounds.top, lessThan(previous.top));
            expect(bounds.left, greaterThan(previous.left));
            expect(header.hitTestable(), findsOneWidget);
            expect(tester.element(header), same(element));
            expect(tester.state(favorite), same(favoriteState));
            expect(tester.getRect(play), controlsBounds);
            previous = bounds;
          }
          await settlePlayer(tester);
          final cover = tester.getRect(
            find.byKey(const ValueKey('compact-player-artwork')),
          );
          final compactBounds = tester.getRect(header);
          expect(compactBounds.left, cover.right + 12);
          expect(compactBounds.center.dy, cover.center.dy);
          final track = seekTrackBounds(tester);
          expect(cover.left, closeTo(track.left, 0.01));
          final more = find.descendant(
            of: header,
            matching: findAppIcon(CupertinoIcons.ellipsis),
          );
          expect(tester.getRect(more).right, closeTo(track.right, 0.01));
          final moreButton = find.ancestor(
            of: more,
            matching: find.byType(IconButton),
          );
          expect(tester.getSize(moreButton), const Size(48, 48));
          await tester.tap(toggle);
          await tester.pump();
          expect(tester.getRect(header), compactBounds);
          previous = compactBounds;
          for (var frame = 0; frame < 3; frame++) {
            await tester.pump(const Duration(milliseconds: 80));
            final bounds = tester.getRect(header);
            expect(bounds.top, greaterThan(previous.top));
            expect(bounds.left, lessThan(previous.left));
            expect(header.hitTestable(), findsOneWidget);
            expect(tester.element(header), same(element));
            expect(tester.state(favorite), same(favoriteState));
            expect(tester.getRect(play), controlsBounds);
            previous = bounds;
          }
          await settlePlayer(tester);
          expect(tester.getRect(header), expandedBounds);
          expect(
            find.byKey(const ValueKey('full-player-artwork')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  for (final playing in [false, true]) {
    testWidgets(
      'tapping the lyrics cover returns to its resting size (playing: $playing)',
      (tester) async {
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: const Size(393, 852),
          playback: PlaybackState(
            playing: playing,
            processingState: AudioProcessingState.ready,
            updatePosition: const Duration(seconds: 2),
          ),
        );
        mediaItems.add(item('first'));
        await settlePlayer(tester);
        final artwork = find.byType(MornyePlayerArtwork);
        final restingBounds = tester.getRect(artwork);
        final lyrics = findAppIcon(CupertinoIcons.quote_bubble);
        final compact = find.byKey(const ValueKey('compact-player-artwork'));
        await tester.tap(lyrics);
        await settlePlayer(tester);
        final compactBounds = tester.getRect(compact);
        await tester.tap(compact);
        await tester.pump();
        expect(tester.getRect(artwork), compactBounds);
        var previous = compactBounds;
        for (var frame = 0; frame < 4; frame++) {
          await tester.pump(const Duration(milliseconds: 80));
          final bounds = tester.getRect(artwork);
          expect(bounds.width, greaterThan(previous.width));
          expect(bounds.width, lessThanOrEqualTo(restingBounds.width));
          expect(tester.getRect(compact), bounds);
          previous = bounds;
        }
        await settlePlayer(tester);
        expect(tester.getRect(artwork), restingBounds);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final landscape in [false, true]) {
    testWidgets(
      'outgoing lyrics keep their scroll state while queue fades in (landscape: $landscape)',
      (tester) async {
        metadataOverrides['lyrics'] = List.generate(
          16,
          (index) =>
              '[00:${(index * 2).toString().padLeft(2, '0')}.00]Line $index',
        ).join('\n');
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: landscape ? const Size(852, 393) : const Size(393, 852),
          playback: PlaybackState(
            processingState: AudioProcessingState.ready,
            updatePosition: const Duration(seconds: 20),
          ),
        );
        mediaItems.add(item('first'));
        await settlePlayer(tester);
        await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
        await settlePlayer(tester);
        final scrollable = find
            .ancestor(
              of: find.text('Line 10'),
              matching: find.byType(Scrollable),
            )
            .first;
        final state = tester.state<ScrollableState>(scrollable);
        final offset = state.position.pixels;
        expect(offset, greaterThan(0));
        await tester.tap(findAppIcon(CupertinoIcons.list_bullet));
        await tester.pump();
        for (var frame = 0; frame < 3; frame++) {
          expect(state.mounted, isTrue);
          expect(tester.state<ScrollableState>(scrollable), same(state));
          expect(state.position.pixels, offset);
          await tester.pump(const Duration(milliseconds: 50));
        }
        await settlePlayer(tester);
        expect(state.mounted, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('header reverses in place and stays beside cover across panels', (
    tester,
  ) async {
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 852),
    );
    mediaItems.add(item('first'));
    await settlePlayer(tester);
    final header = find.byKey(const ValueKey('player-track-header'));
    final element = tester.element(header);
    final expandedBounds = tester.getRect(header);
    final lyrics = findAppIcon(CupertinoIcons.quote_bubble);
    final queue = findAppIcon(CupertinoIcons.list_bullet);
    await tester.tap(lyrics);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    final interruptedBounds = tester.getRect(header);
    await tester.tap(lyrics);
    await tester.pump();
    expect(tester.getRect(header), interruptedBounds);
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getRect(header).top, greaterThan(interruptedBounds.top));
    expect(tester.getRect(header).left, lessThan(interruptedBounds.left));
    await settlePlayer(tester);
    expect(tester.getRect(header), expandedBounds);

    await tester.tap(lyrics);
    await settlePlayer(tester);
    final compactBounds = tester.getRect(header);
    await tester.tap(queue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.getRect(header), compactBounds);
    expect(tester.element(header), same(element));
    await settlePlayer(tester);
    expect(tester.getRect(header), compactBounds);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shared header respects reduced motion and large text', (
    tester,
  ) async {
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 852),
      wrapPlayer: (player) => Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            textScaler: const TextScaler.linear(1.6),
          ),
          child: player,
        ),
      ),
    );
    mediaItems.add(item('first'));
    await settlePlayer(tester);
    final header = find.byKey(const ValueKey('player-track-header'));
    final expandedBounds = tester.getRect(header);
    final lyrics = findAppIcon(CupertinoIcons.quote_bubble);
    await tester.tap(lyrics);
    await tester.pump();
    final compactBounds = tester.getRect(header);
    final cover = tester.getRect(
      find.byKey(const ValueKey('compact-player-artwork')),
    );
    expect(compactBounds.left, cover.right + 12);
    expect(compactBounds.top, cover.top);
    expect(compactBounds.top, lessThan(expandedBounds.top));
    await tester.tap(lyrics);
    await tester.pump();
    expect(tester.getRect(header), expandedBounds);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mornye lyrics replace artwork while controls stay in place', (
    tester,
  ) async {
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 700),
    );
    mediaItems.add(item('first'));
    await settlePlayer(tester);

    final artwork = find.byType(Hero);
    final fullArtwork = tester.getRect(artwork);
    expect(fullArtwork.height, fullArtwork.width);
    final volume = find.byType(PlayerVolumeControl);
    final volumeRect = tester.getRect(volume);
    final play = findAppIcon(CupertinoIcons.play_fill);
    final playRect = tester.getRect(play);
    final lyricsButton = findAppIcon(CupertinoIcons.quote_bubble);
    await tester.tap(lyricsButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final fullCover = find.byKey(const ValueKey('full-player-artwork'));
    double fullCoverOpacity() => tester
        .widget<FadeTransition>(
          find
              .ancestor(of: fullCover, matching: find.byType(FadeTransition))
              .first,
        )
        .opacity
        .value;
    expect(fullCover, findsOneWidget);
    expect(fullCoverOpacity(), inExclusiveRange(0.0, 1.0));
    await settlePlayer(tester);

    expect(find.byType(PageView), findsNothing);
    expect(find.text('First lyric').hitTestable(), findsOneWidget);
    expect(tester.getSize(artwork).width, lessThan(fullArtwork.width));
    expect(fullArtwork.top, greaterThan(0));
    expect(fullArtwork.width, lessThan(393));
    expect(tester.getRect(volume), volumeRect);
    expect(tester.getRect(play), playRect);

    mediaItems.add(item('second'));
    await settlePlayer(tester);
    expect(find.text('Second lyric').hitTestable(), findsOneWidget);
    expect(find.text('First lyric'), findsNothing);

    await tester.tap(lyricsButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(fullCoverOpacity(), inExclusiveRange(0.0, 1.0));
    expect(
      find.descendant(of: fullCover, matching: find.byType(Hero)),
      findsOneWidget,
    );
    await settlePlayer(tester);
    expect(tester.getRect(artwork), fullArtwork);
    expect(find.text('Second lyric').hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sharing reads document lyrics before opening the lyrics page', (
    tester,
  ) async {
    await pumpNowPlaying(tester);
    mediaItems.add(item('first'));
    await settlePlayer(tester);
    expect(metadataReads, isEmpty);

    await tester.tap(findAppIcon(Icons.more_vert));
    await settlePlayer(tester);
    await tester.tap(find.text('Share lyrics'));
    await settlePlayer(tester);

    expect(metadataReads, ['content://library/first.flac']);
    expect(find.byType(LyricsShareScreen), findsOneWidget);
    expect(find.text('First lyric'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a track change cancels a pending lyrics share', (tester) async {
    await pumpNowPlaying(tester);
    mediaItems.add(item('first'));
    await settlePlayer(tester);

    await tester.tap(findAppIcon(Icons.more_vert));
    await settlePlayer(tester);
    await tester.tap(find.text('Share lyrics'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(lyricsRequests, isNotEmpty);

    mediaItems.add(item('second'));
    await tester.pump();
    await settlePlayer(tester);

    expect(find.byType(LyricsShareScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('network lyrics use shared metadata instead of the audio URL', (
    tester,
  ) async {
    final storage = NetworkStorageService.instance;
    final source = NetworkStorageService.source('lyrics-test', 'song.flac');
    await tester.runAsync(() async {
      await storage.save(
        const NetworkConnection(
          id: 'lyrics-test',
          name: 'Lyrics test',
          protocol: NetworkProtocol.http,
          address: 'https://nas.test/music/',
        ),
      );
      await NetworkMetadataService.instance.read(source);
    });
    addTearDown(() async {
      await storage.remove('lyrics-test');
      await storage.dispose();
    });
    expect(metadataReads, hasLength(1));
    await pumpNowPlaying(tester);
    mediaItems.add(
      MediaItem(
        id: source,
        title: 'Network song',
        extras: {
          'source': source,
          'resolvedSource': 'http://127.0.0.1:9999/playback-only',
        },
      ),
    );
    await settlePlayer(tester);
    await tester.tap(find.byKey(const ValueKey('material-lyrics-toggle')));
    await settlePlayer(tester);
    expect(find.text('First lyric'), findsOneWidget);
    expect(metadataReads, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'automatic SAF track change refreshes lyrics while Lyrics page is active',
    (tester) async {
      await pumpNowPlaying(tester);

      mediaItems.add(item('first'));
      await settlePlayer(tester);
      await tester.tap(find.byKey(const ValueKey('material-lyrics-toggle')));
      await settlePlayer(tester);
      expect(find.text('First lyric'), findsOneWidget);

      mediaItems.add(item('second'));
      await settlePlayer(tester);

      expect(find.text('Second lyric'), findsOneWidget);
      expect(find.text('First lyric'), findsNothing);
    },
  );

  testWidgets(
    'lyrics end with writer and provider credits and clear them on track change',
    (tester) async {
      metadataOverrides['composer'] = 'Example Composer';
      metadataOverrides['lyrics'] =
          '[by:SpotiFLAC-Mobile via Example Lyrics API (source: upstream)]\n[00:01]Last lyric';
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.dark),
        size: const Size(390, 844),
      );
      mediaItems.add(item('first'));
      await settlePlayer(tester);
      await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
      await settlePlayer(tester);
      final credit = find.text(
        'Written by: Example Composer\nLyrics: Example Lyrics',
      );
      expect(credit, findsOneWidget);
      expect(
        tester.getTopLeft(credit).dy,
        greaterThan(tester.getBottomLeft(find.text('Last lyric')).dy),
      );
      metadataOverrides.clear();
      mediaItems.add(item('second'));
      await settlePlayer(tester);
      expect(credit, findsNothing);
      expect(find.text('Second lyric'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('language toggles keep a later active lyric anchored in every frame', (
    tester,
  ) async {
    metadataOverrides['lyrics'] = [
      for (var i = 0; i < 12; i++) ...[
        '[x-romaji:${(i + 1) * 10000}:${base64.encode(utf8.encode('Pronunciation $i'))}]',
        '[x-translation:${(i + 1) * 10000}:${base64.encode(utf8.encode('Translation $i'))}]',
        '[${((i + 1) * 10 ~/ 60).toString().padLeft(2, '0')}:${((i + 1) * 10 % 60).toString().padLeft(2, '0')}.000]Original $i',
      ],
    ].join('\n');
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(390, 844),
      playback: PlaybackState(
        processingState: AudioProcessingState.ready,
        updatePosition: const Duration(seconds: 45),
      ),
    );
    mediaItems.add(item('anchored-supplements'));
    await settlePlayer(tester);
    await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
    await settlePlayer(tester);
    final original = find.text('Original 3');
    final anchor = tester.getTopLeft(original).dy;
    for (final action in [
      'Hide Pronunciation',
      'Show Pronunciation',
      'Hide Translation',
      'Show Translation',
    ]) {
      await tester.tap(find.byKey(const ValueKey('lyrics-language-options')));
      await settlePlayer(tester);
      await tester.tap(find.text(action));
      await tester.pump();
      for (var frame = 0; frame < 32; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.getTopLeft(original).dy,
          closeTo(anchor, 1),
          reason: '$action frame $frame',
        );
      }
    }
    expect(tester.takeException(), isNull);
  });

  for (final supplement in ['none', 'pronunciation', 'translation']) {
    testWidgets('language menu only offers available $supplement', (
      tester,
    ) async {
      metadataOverrides['lyrics'] =
          '${supplement == 'pronunciation' ? '[x-romaji:1009:${base64.encode(utf8.encode('Pronunciation'))}]\n' : ''}'
          '${supplement == 'translation' ? '[x-translation:1009:${base64.encode(utf8.encode('Translation'))}]\n' : ''}'
          '[00:01.009]Original';
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.dark),
        size: const Size(390, 844),
      );
      mediaItems.add(item('first'));
      await settlePlayer(tester);
      await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
      await settlePlayer(tester);
      final options = find.byKey(const ValueKey('lyrics-language-options'));
      if (supplement == 'none') {
        expect(options, findsNothing);
      } else {
        await tester.tap(options);
        await settlePlayer(tester);
        final glass = tester.widget<MornyeGlassPanel>(
          find.byType(MornyeGlassPanel).last,
        );
        expect(
          find.descendant(
            of: find.byType(MornyeGlassPanel).last,
            matching: find.byType(BackdropFilter),
          ),
          findsOneWidget,
        );
        expect(glass.tintOpacity, inExclusiveRange(0, 1));
        expect(
          find.text('Hide Pronunciation'),
          supplement == 'pronunciation' ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('Hide Translation'),
          supplement == 'translation' ? findsOneWidget : findsNothing,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final landscape in [false, true]) {
    testWidgets(
      'language menu respects reduced motion and idle controls (landscape: $landscape)',
      (tester) async {
        metadataOverrides['lyrics'] =
            '[x-romaji:1009:${base64.encode(utf8.encode('Pronunciation'))}]\n'
            '[00:01.009]Original';
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: landscape ? const Size(844, 390) : const Size(390, 844),
          playback: PlaybackState(playing: true),
          wrapPlayer: (player) => Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: player,
            ),
          ),
        );
        mediaItems.add(item('first'));
        await settlePlayer(tester);
        await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
        await settlePlayer(tester);
        final options = find.byKey(const ValueKey('lyrics-language-options'));
        await tester.tap(options);
        await settlePlayer(tester);
        await tester.pump(const Duration(seconds: 6));
        expect(find.text('Hide Pronunciation').hitTestable(), findsOneWidget);
        await tester.tap(find.text('Hide Pronunciation'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Pronunciation'), findsNothing);
        expect(options.hitTestable(), findsOneWidget);

        await tester.pump(const Duration(seconds: 5));
        await settlePlayer(tester);
        expect(options.hitTestable(), findsNothing);
        if (landscape) {
          await tester.tap(
            find.byKey(const ValueKey('landscape-actions-reveal')),
          );
        } else {
          final bounds = tester.getRect(find.byType(ListView));
          await tester.tapAt(Offset(bounds.right - 6, bounds.top + 10));
        }
        await settlePlayer(tester);
        await tester.tap(options);
        await settlePlayer(tester);
        await tester.tap(find.text('Show Pronunciation'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Pronunciation'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final mornye in [false, true]) {
    testWidgets(
      'TTML V3 without group metadata keeps the primary side ($mornye)',
      (tester) async {
        metadataOverrides['lyrics'] = '''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:m="http://www.w3.org/ns/ttml#metadata">
<head><metadata><m:agent xml:id="v1" type="person"/><m:agent xml:id="v3" type="person"/><m:agent xml:id="v2" type="person"/></metadata></head>
<body><p begin="1s" end="3s" m:agent="v2">Guest</p><p begin="3s" end="6s" m:agent="v3">Together</p><p begin="6s" end="9s" m:agent="v2">Guest returns</p></body></tt>
''';
        final playback = StreamController<PlaybackState>.broadcast();
        addTearDown(playback.close);
        await pumpNowPlaying(
          tester,
          theme: mornye ? MornyeTheme.build(Brightness.dark) : null,
          size: const Size(390, 1100),
          playbackEvents: playback.stream,
        );
        mediaItems.add(item('first'));
        await settlePlayer(tester);
        if (mornye) {
          await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
        } else {
          await tester.tap(
            find.byKey(const ValueKey('material-lyrics-toggle')),
          );
        }
        await settlePlayer(tester);
        for (final seconds in [0, 2, 4, 7, 4]) {
          playback.add(
            PlaybackState(
              playing: false,
              processingState: AudioProcessingState.ready,
              updatePosition: Duration(seconds: seconds),
            ),
          );
          await settlePlayer(tester);
          expect(
            tester.widget<Text>(find.text('Together')).textAlign,
            TextAlign.start,
          );
          expect(
            tester.widget<Text>(find.text('Guest returns')).textAlign,
            TextAlign.end,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );

    for (final ttml in [false, true]) {
      testWidgets(
        'backing vocals stay smaller under the lead with independent timing (Mornye: $mornye, TTML: $ttml)',
        (tester) async {
          metadataOverrides['lyrics'] = ttml
              ? '''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:m="http://www.w3.org/ns/ttml#metadata">
<head><metadata><m:agent xml:id="v1" type="person"/><m:agent xml:id="v2" type="person"/></metadata></head>
<body><p begin="1s" end="7s" m:agent="v2"><span begin="1s" end="6s">Lead</span><span m:role="x-bg" m:agent="v1" begin="3s" end="7s">Echo</span></p><p begin="8s" end="10s">Next</p></body></tt>
'''
              : '''
[00:01.00]v2:<00:01.00>Lead<00:06.00>
[bg:v1:<00:03.00>Echo<00:07.00>]
[00:08.00]<00:08.00>Next<00:10.00>
''';
          final playback = StreamController<PlaybackState>.broadcast();
          addTearDown(playback.close);
          await pumpNowPlaying(
            tester,
            theme: mornye ? MornyeTheme.build(Brightness.dark) : null,
            size: const Size(390, 1100),
            playbackEvents: playback.stream,
          );
          mediaItems.add(item('first'));
          await settlePlayer(tester);
          if (mornye) {
            await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
          } else {
            await tester.tap(
              find.byKey(const ValueKey('material-lyrics-toggle')),
            );
          }
          await settlePlayer(tester);
          final lead = tester.widget<Text>(find.text('Lead'));
          expect(find.text('Echo'), findsNothing);
          expect(find.textContaining('[bg:'), findsNothing);
          expect(find.textContaining('v1:'), findsNothing);

          Finder timed(String text) => find.descendant(
            of: find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics && widget.properties.label == text,
            ),
            matching: find.byType(CustomPaint),
          );
          Future<void> seek(int milliseconds) async {
            playback.add(
              PlaybackState(
                playing: false,
                processingState: AudioProcessingState.ready,
                updatePosition: Duration(milliseconds: milliseconds),
              ),
            );
            await settlePlayer(tester);
          }

          double offset() =>
              tester.widget<ListView>(find.byType(ListView)).controller!.offset;

          await seek(2000);
          expect(timed('Lead'), findsOneWidget);
          expect(timed('Echo'), findsNothing);
          expect(find.text('Echo'), findsNothing);
          final leadOffset = offset();
          final leadTop = tester.getTopLeft(timed('Lead')).dy;
          var nextTop = tester.getTopLeft(find.text('Next')).dy;
          playback.add(
            PlaybackState(
              processingState: AudioProcessingState.ready,
              updatePosition: const Duration(seconds: 3),
            ),
          );
          await tester.pump();
          await tester.pump();
          for (var frame = 0; frame < 4; frame++) {
            await tester.pump(const Duration(milliseconds: 80));
            expect(tester.getTopLeft(timed('Lead')).dy, closeTo(leadTop, 0.1));
            final top = tester.getTopLeft(find.text('Next')).dy;
            expect(top, greaterThan(nextTop));
            nextTop = top;
          }
          await seek(4000);
          expect(timed('Lead'), findsOneWidget);
          expect(timed('Echo'), findsOneWidget);
          expect(offset(), closeTo(leadOffset, 0.1));
          expect(
            tester.getSize(timed('Echo')).height,
            lessThan(tester.getSize(timed('Lead')).height * 0.8),
          );
          await seek(6500);
          expect(timed('Lead'), findsOneWidget);
          expect(timed('Echo'), findsOneWidget);
          expect(offset(), closeTo(leadOffset, 0.1));
          await seek(7500);
          final backing = tester.widget<Text>(find.text('Echo'));
          expect(
            backing.style!.fontSize,
            lessThan(lead.style!.fontSize! * 0.85),
          );
          expect(backing.textAlign, TextAlign.end);
          if (mornye) {
            // Inactive vocals shrink around their center. Check the row gap
            // before that paint transform, rather than the scaled text bounds.
            Finder lyricScale(Finder content) => find
                .ancestor(of: content, matching: find.byType(AnimatedScale))
                .first;
            expect(
              tester.getTopLeft(lyricScale(find.text('Echo'))).dy -
                  tester.getBottomLeft(lyricScale(timed('Lead'))).dy,
              closeTo(6, 0.1),
            );
          }
          await seek(2000);
          expect(timed('Lead'), findsOneWidget);
          expect(timed('Echo'), findsNothing);
          expect(find.text('Echo'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'simultaneous wrapped lyrics stay inside the viewport ($mornye)',
      (tester) async {
        const lead =
            'The first singer has a long line that wraps across several rows';
        const guest = 'The second singer starts at exactly the same timestamp';
        metadataOverrides['lyrics'] =
            '[00:01.00]v1:$lead\n[00:01.00]v2:$guest\n[00:08.00]Next';
        final playback = StreamController<PlaybackState>.broadcast();
        addTearDown(playback.close);
        await pumpNowPlaying(
          tester,
          theme: mornye ? MornyeTheme.build(Brightness.dark) : null,
          size: const Size(390, 1100),
          playbackEvents: playback.stream,
        );
        mediaItems.add(item('first'));
        await settlePlayer(tester);
        await tester.tap(
          mornye
              ? findAppIcon(CupertinoIcons.quote_bubble)
              : find.byKey(const ValueKey('material-lyrics-toggle')),
        );
        await settlePlayer(tester);
        playback.add(
          PlaybackState(
            processingState: AudioProcessingState.ready,
            playing: false,
            updatePosition: const Duration(seconds: 2),
          ),
        );
        await settlePlayer(tester);
        final scrollable = find
            .ancestor(of: find.text(lead), matching: find.byType(Scrollable))
            .first;
        final viewport = tester.getRect(scrollable);
        for (final text in [lead, guest]) {
          final bounds = tester.getRect(find.text(text));
          expect(bounds.top, greaterThanOrEqualTo(viewport.top));
          expect(bounds.bottom, lessThanOrEqualTo(viewport.bottom));
          final opacity = tester.widget<AnimatedOpacity>(
            find
                .ancestor(
                  of: find.text(text),
                  matching: find.byType(AnimatedOpacity),
                )
                .first,
          );
          expect(opacity.opacity, 1);
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'singers keep their side before and during overlapping vocals ($mornye)',
      (tester) async {
        metadataOverrides['lyrics'] =
            '[x-romaji:2000:${base64.encode(utf8.encode('Guest reading'))}]\n'
            '[x-translation:2000:${base64.encode(utf8.encode('Guest translation'))}]\n'
            '[00:01.00]v1:<00:01.00>Lead<00:08.00>\n'
            '[00:02.00]v2:<00:02.00>Guest<00:06.00>';
        final playback = StreamController<PlaybackState>.broadcast();
        addTearDown(playback.close);
        await pumpNowPlaying(
          tester,
          theme: mornye ? MornyeTheme.build(Brightness.dark) : null,
          size: const Size(390, 1100),
          playbackEvents: playback.stream,
        );
        mediaItems.add(item('first'));
        await settlePlayer(tester);
        if (mornye) {
          await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
        } else {
          await tester.tap(
            find.byKey(const ValueKey('material-lyrics-toggle')),
          );
        }
        await settlePlayer(tester);
        expect(
          tester.widget<Text>(find.text('Lead')).textAlign,
          TextAlign.start,
        );
        for (final text in ['Guest', 'Guest reading', 'Guest translation']) {
          expect(tester.widget<Text>(find.text(text)).textAlign, TextAlign.end);
        }
        expect(find.textContaining('v1:'), findsNothing);
        expect(find.textContaining('v2:'), findsNothing);

        Finder timed(String text) => find.descendant(
          of: find.byWidgetPredicate(
            (widget) => widget is Semantics && widget.properties.label == text,
          ),
          matching: find.byType(CustomPaint),
        );
        playback.add(
          PlaybackState(
            processingState: AudioProcessingState.ready,
            playing: false,
            updatePosition: const Duration(seconds: 3),
          ),
        );
        await settlePlayer(tester);
        for (final text in ['Lead', 'Guest']) {
          final paint = timed(text);
          expect(
            paint,
            findsOneWidget,
            reason: 'Both overlapping parts stay highlighted',
          );
          final painter = tester.widget<CustomPaint>(paint).painter!;
          final size = tester.getSize(paint);
          final bounds = await tester.runAsync(() async {
            final recorder = ui.PictureRecorder();
            painter.paint(Canvas(recorder), size);
            final picture = recorder.endRecording();
            final image = await picture.toImage(
              size.width.ceil(),
              size.height.ceil(),
            );
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            var left = image.width;
            var right = 0;
            for (var y = 0; y < image.height; y++) {
              for (var x = 0; x < image.width; x++) {
                if (bytes.getUint8((y * image.width + x) * 4 + 3) > 10) {
                  if (x < left) left = x;
                  if (x > right) right = x;
                }
              }
            }
            image.dispose();
            picture.dispose();
            return (left, right);
          });
          if (text == 'Lead') {
            expect(bounds!.$1, lessThan(5));
          } else {
            expect(bounds!.$2, greaterThan(size.width - 5));
          }
        }
        expect(
          tester.widget<Text>(find.text('Guest translation')).textAlign,
          TextAlign.end,
        );
        playback.add(
          PlaybackState(
            processingState: AudioProcessingState.ready,
            playing: false,
            updatePosition: const Duration(seconds: 7),
          ),
        );
        await settlePlayer(tester);
        expect(timed('Guest'), findsOneWidget);
        expect(find.text('Lead'), findsNothing);
        playback.add(
          PlaybackState(
            processingState: AudioProcessingState.ready,
            playing: false,
            updatePosition: const Duration(seconds: 9),
          ),
        );
        await settlePlayer(tester);
        expect(find.text('Lead'), findsOneWidget);
        expect(timed('Guest'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('player shows original, romanization and English ($mornye)', (
      tester,
    ) async {
      metadataOverrides['lyrics'] =
          '[x-romaji:1009:${base64.encode(utf8.encode('Romanized text'))}]\n'
          '[x-translation:1009:${base64.encode(utf8.encode('English text'))}]\n'
          '[00:01.01]Original text';
      await pumpNowPlaying(
        tester,
        theme: mornye ? MornyeTheme.build(Brightness.dark) : null,
        size: const Size(390, 844),
      );
      mediaItems.add(item('first'));
      await settlePlayer(tester);
      if (mornye) {
        await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
      } else {
        await tester.tap(find.byKey(const ValueKey('material-lyrics-toggle')));
      }
      await settlePlayer(tester);
      for (final text in ['Original text', 'Romanized text', 'English text']) {
        expect(find.text(text), findsOneWidget);
      }
      if (mornye) {
        final pronunciation = tester.widget<Text>(find.text('Romanized text'));
        final translation = tester.widget<Text>(find.text('English text'));
        expect(pronunciation.style?.fontSize, 22);
        expect(pronunciation.style?.fontWeight, FontWeight.bold);
        expect(translation.style?.fontSize, 18);
      }
      expect(
        tester.getTopLeft(find.text('Romanized text')).dy,
        greaterThan(tester.getBottomLeft(find.text('Original text')).dy),
      );
      expect(
        tester.getTopLeft(find.text('English text')).dy,
        greaterThan(tester.getBottomLeft(find.text('Romanized text')).dy),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'lyric language toggles fade, resize and remember choices ($mornye)',
      (tester) async {
        metadataOverrides['lyrics'] =
            '[x-romaji:1009:${base64.encode(utf8.encode('Romanized text'))}]\n'
            '[x-translation:1009:${base64.encode(utf8.encode('English text'))}]\n'
            '[00:01.009]Original text\n[00:10.000]Next line';
        Future<void> openPlayer(String id) async {
          await pumpNowPlaying(
            tester,
            theme: mornye ? MornyeTheme.build(Brightness.dark) : null,
            size: const Size(390, 844),
            playback: PlaybackState(
              processingState: AudioProcessingState.ready,
              updatePosition: const Duration(milliseconds: 1500),
            ),
          );
          mediaItems.add(item(id));
          await settlePlayer(tester);
          if (mornye) {
            await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
          } else {
            await tester.tap(
              find.byKey(const ValueKey('material-lyrics-toggle')),
            );
          }
          await settlePlayer(tester);
        }

        final options = find.byKey(const ValueKey('lyrics-language-options'));
        Future<void> choose(String label) async {
          await tester.tap(options);
          await settlePlayer(tester);
          await tester.tap(find.text(label));
          await tester.pump();
        }

        double gap() =>
            tester.getTopLeft(find.text('Next line')).dy -
            tester.getTopLeft(find.text('Original text')).dy;
        double pronunciationOpacity() => tester
            .widget<Opacity>(
              find
                  .ancestor(
                    of: find.text('Romanized text'),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity;

        await openPlayer('first');
        final expandedGap = gap();
        await choose('Hide Pronunciation');
        await tester.pump(const Duration(milliseconds: 100));
        expect(pronunciationOpacity(), inExclusiveRange(0, 1));
        final intermediateGap = gap();
        expect(intermediateGap, lessThan(expandedGap));
        await settlePlayer(tester);
        expect(find.text('Romanized text'), findsNothing);
        expect(find.text('English text'), findsOneWidget);
        expect(gap(), lessThan(intermediateGap));

        await choose('Show Pronunciation');
        await tester.pump(const Duration(milliseconds: 100));
        expect(pronunciationOpacity(), inExclusiveRange(0, 1));
        await settlePlayer(tester);
        expect(gap(), closeTo(expandedGap, 1));
        await choose('Hide Translation');
        await settlePlayer(tester);
        expect(find.text('English text'), findsNothing);
        expect(find.text('Romanized text'), findsOneWidget);
        await choose('Hide Pronunciation');
        await settlePlayer(tester);
        expect(find.text('Original text'), findsOneWidget);
        expect(find.text('Romanized text'), findsNothing);
        expect(options.hitTestable(), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
        await openPlayer('second');
        expect(find.text('English text'), findsNothing);
        expect(find.text('Romanized text'), findsNothing);
        await choose('Show Translation');
        await settlePlayer(tester);
        expect(find.text('English text'), findsOneWidget);
        expect(find.text('Romanized text'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('finished lyric stays bright until the next lead ($mornye)', (
      tester,
    ) async {
      metadataOverrides['lyrics'] =
          '[00:01.00]v1:<00:01.00>Held<00:02.00>\n'
          '[00:07.00]v2:<00:07.00>Next<00:08.00>';
      final playback = StreamController<PlaybackState>.broadcast();
      addTearDown(playback.close);
      await pumpNowPlaying(
        tester,
        theme: mornye ? MornyeTheme.build(Brightness.dark) : null,
        size: const Size(390, 844),
        playbackEvents: playback.stream,
      );
      mediaItems.add(item('first'));
      await settlePlayer(tester);
      await tester.tap(
        mornye
            ? findAppIcon(CupertinoIcons.quote_bubble)
            : find.byKey(const ValueKey('material-lyrics-toggle')),
      );
      await settlePlayer(tester);

      Finder timed(String text) => find.descendant(
        of: find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.label == text,
        ),
        matching: find.byType(CustomPaint),
      );
      for (final milliseconds in [1500, 2500, 6999, 7000, 8000, 6999]) {
        playback.add(
          PlaybackState(
            playing: false,
            processingState: AudioProcessingState.ready,
            updatePosition: Duration(milliseconds: milliseconds),
          ),
        );
        await settlePlayer(tester);
        final text = milliseconds < 7000 ? 'Held' : 'Next';
        expect(timed(text), findsOneWidget);
        final opacity = tester.widget<AnimatedOpacity>(
          find
              .ancestor(of: timed(text), matching: find.byType(AnimatedOpacity))
              .first,
        );
        expect(opacity.opacity, 1, reason: 'At $milliseconds ms');
        expect(timed(text == 'Held' ? 'Next' : 'Held'), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('an unfinished line holds the view while the next starts '
        '($mornye)', (tester) async {
      metadataOverrides['lyrics'] =
          '[00:01.00]<00:01.00>Long <00:02.00>held<00:06.00>\n'
          '[00:04.00]<00:04.00>Next<00:05.00>\n'
          '[00:09.00]<00:09.00>Later<00:10.00>';
      final playback = StreamController<PlaybackState>.broadcast();
      addTearDown(playback.close);
      await pumpNowPlaying(
        tester,
        theme: mornye ? MornyeTheme.build(Brightness.dark) : null,
        size: const Size(390, 844),
        playbackEvents: playback.stream,
      );
      mediaItems.add(item('first'));
      await settlePlayer(tester);
      await tester.tap(
        mornye
            ? findAppIcon(CupertinoIcons.quote_bubble)
            : find.byKey(const ValueKey('material-lyrics-toggle')),
      );
      await settlePlayer(tester);

      Finder timed(String text) => find.descendant(
        of: find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.label == text,
        ),
        matching: find.byType(CustomPaint),
      );
      Future<void> seek(int milliseconds) async {
        playback.add(
          PlaybackState(
            playing: false,
            processingState: AudioProcessingState.ready,
            updatePosition: Duration(milliseconds: milliseconds),
          ),
        );
        await settlePlayer(tester);
      }

      await seek(3500);
      final held = tester.getTopLeft(timed('Long held')).dy;
      await seek(4500);
      // Both lines keep their word sweep, and the view does not move.
      expect(timed('Long held'), findsOneWidget);
      expect(timed('Next'), findsOneWidget);
      expect(tester.getTopLeft(timed('Long held')).dy, held);
      await seek(6500);
      expect(timed('Long held'), findsNothing);
      expect(timed('Next'), findsOneWidget);
      expect(tester.getTopLeft(timed('Next')).dy, lessThan(held + 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'original and romanization follow word timing and pauses ($mornye)',
      (tester) async {
        final romanizationWords = base64.encode(
          utf8.encode(
            jsonEncode([
              {'text': 'Firsu ', 'startTimeMs': 1009, 'endTimeMs': 1307},
              {'text': 'secondu', 'startTimeMs': 2003, 'endTimeMs': 2497},
            ]),
          ),
        );
        metadataOverrides['lyrics'] =
            '[x-romaji:1009:${base64.encode(utf8.encode('Firsu secondu'))}]\n'
            '[x-romaji-words:1009:$romanizationWords]\n'
            '[00:01.009]<00:01.009>First <00:01.307>'
            '<00:02.003>second<00:02.497>';
        final playback = StreamController<PlaybackState>.broadcast();
        addTearDown(playback.close);
        await pumpNowPlaying(
          tester,
          theme: mornye ? MornyeTheme.build(Brightness.dark) : null,
          size: const Size(390, 844),
          playbackEvents: playback.stream,
        );
        mediaItems.add(item('first'));
        await settlePlayer(tester);
        if (mornye) {
          await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
        } else {
          await tester.tap(
            find.byKey(const ValueKey('material-lyrics-toggle')),
          );
        }
        await settlePlayer(tester);

        Future<List<int>> pixelsAt(int milliseconds, String text) async {
          playback.add(
            PlaybackState(
              processingState: AudioProcessingState.ready,
              playing: false,
              updatePosition: Duration(milliseconds: milliseconds),
            ),
          );
          await settlePlayer(tester);
          final pixels = <int>[];
          for (final phrase in mornye ? text.split(' ') : [text]) {
            final paint = find.descendant(
              of: find.byWidgetPredicate(
                (widget) =>
                    widget is Semantics && widget.properties.label == phrase,
              ),
              matching: find.byType(CustomPaint),
            );
            expect(
              paint,
              findsOneWidget,
              reason: '$phrase at $milliseconds ms',
            );
            final painter = tester.widget<CustomPaint>(paint).painter!;
            final size = tester.getSize(paint);
            pixels.addAll(
              (await tester.runAsync(() async {
                final recorder = ui.PictureRecorder();
                painter.paint(Canvas(recorder), size);
                final picture = recorder.endRecording();
                final image = await picture.toImage(
                  size.width.ceil(),
                  size.height.ceil(),
                );
                final bytes = (await image.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                ))!;
                final result = bytes.buffer.asUint8List().toList();
                image.dispose();
                picture.dispose();
                return result;
              }))!,
            );
          }
          return pixels;
        }

        for (final text in ['First second', 'Firsu secondu']) {
          final singingFirst = await pixelsAt(1100, text);
          final moves = mornye && text == 'First second';
          final firstEnded = await pixelsAt(moves ? 1800 : 1307, text);
          expect(firstEnded, isNot(orderedEquals(singingFirst)));
          if (moves) {
            expect(
              await pixelsAt(1307, text),
              isNot(orderedEquals(firstEnded)),
              reason: 'Movement trails the finished color sweep',
            );
          }
          expect(await pixelsAt(1820, text), orderedEquals(firstEnded));
          final singingLast = await pixelsAt(2150, text);
          final lastEnded = await pixelsAt(moves ? 3100 : 2497, text);
          expect(lastEnded, isNot(orderedEquals(singingLast)));
          expect(await pixelsAt(3400, text), orderedEquals(lastEnded));
          expect(await pixelsAt(1100, text), orderedEquals(singingFirst));
        }
        final originalPixels = await pixelsAt(1100, 'First second');
        final options = find.byKey(const ValueKey('lyrics-language-options'));
        if (mornye && options.hitTestable().evaluate().isEmpty) {
          final bounds = tester.getRect(find.byType(ListView));
          await tester.tapAt(Offset(bounds.right - 6, bounds.top + 10));
          await settlePlayer(tester);
        }
        await tester.tap(options);
        await settlePlayer(tester);
        await tester.tap(find.text('Hide Pronunciation'));
        await settlePlayer(tester);
        expect(find.bySemanticsLabel('Firsu secondu'), findsNothing);
        expect(
          await pixelsAt(1100, 'First second'),
          orderedEquals(originalPixels),
        );
        await tester.tap(options);
        await settlePlayer(tester);
        await tester.tap(find.text('Show Pronunciation'));
        await settlePlayer(tester);
        await pixelsAt(2150, 'Firsu secondu');
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final reducedMotion in [false, true]) {
    testWidgets(
      'timed words lift and settle without moving layout (reduced motion: $reducedMotion)',
      (tester) async {
        const text = 'AAAA BBBB';
        metadataOverrides['lyrics'] =
            '[00:00.500]<00:01.000>AAAA <00:01.500>'
            '<00:03.000>BBBB<00:06.000>';
        final playback = StreamController<PlaybackState>.broadcast();
        addTearDown(playback.close);
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: const Size(390, 844),
          playbackEvents: playback.stream,
          wrapPlayer: (player) => Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: reducedMotion),
              child: player,
            ),
          ),
        );
        mediaItems.add(item('first'));
        await settlePlayer(tester);
        await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
        await settlePlayer(tester);
        final paintFinder = find.descendant(
          of: find.bySemanticsLabel(text),
          matching: find.byType(CustomPaint),
        );

        Future<(double, double)> paintedHeights({
          bool firstWordLetters = false,
        }) async {
          final painter = tester.widget<CustomPaint>(paintFinder).painter!;
          final size = tester.getSize(paintFinder);
          return (await tester.runAsync(() async {
            final recorder = ui.PictureRecorder();
            final canvas = Canvas(recorder)..translate(0, 8);
            painter.paint(canvas, size);
            final picture = recorder.endRecording();
            final image = await picture.toImage(
              size.width.ceil(),
              size.height.ceil() + 16,
            );
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            double centerFor(int from, int to) {
              var top = image.height;
              var bottom = -1;
              for (var y = 0; y < image.height; y++) {
                for (var x = from; x < to; x++) {
                  if (bytes.getUint8((y * image.width + x) * 4 + 3) < 16) {
                    continue;
                  }
                  if (y < top) top = y;
                  if (y > bottom) bottom = y;
                }
              }
              expect(bottom, greaterThan(top));
              return (top + bottom) / 2;
            }

            final result = firstWordLetters
                ? (
                    centerFor(0, (image.width * 0.1).floor()),
                    centerFor(
                      (image.width * 0.31).ceil(),
                      (image.width * 0.39).floor(),
                    ),
                  )
                : (
                    centerFor(0, (image.width * 0.4).floor()),
                    centerFor((image.width * 0.6).ceil(), image.width),
                  );
            image.dispose();
            picture.dispose();
            return result;
          }))!;
        }

        Future<(double, double)> seek(int milliseconds) async {
          playback.add(
            PlaybackState(
              processingState: AudioProcessingState.ready,
              updatePosition: Duration(milliseconds: milliseconds),
            ),
          );
          await settlePlayer(tester);
          return paintedHeights();
        }

        final pending = await seek(800);
        final bounds = tester.getRect(paintFinder);
        await seek(1300);
        final letters = await paintedHeights(firstWordLetters: true);
        expect(
          letters.$1,
          letters.$2,
          reason: 'Letters in one timed word must rise together',
        );
        final firstEnded = await seek(1900);
        expect(firstEnded.$2, pending.$2);
        if (reducedMotion) {
          expect(firstEnded, pending);
        } else {
          expect(pending.$1 - firstEnded.$1, inInclusiveRange(1, 2.5));
        }
        final held = await seek(5500);
        final settled = await seek(6000);
        expect(held.$1, firstEnded.$1);
        if (reducedMotion) {
          expect(held, pending);
          expect(settled, pending);
        } else {
          expect(settled.$2 - held.$2, greaterThan(0));
          expect(pending.$2 - settled.$2, inInclusiveRange(1, 2.5));
        }
        expect(tester.getRect(paintFinder), bounds);
        expect(await seek(5500), held);
        await tester.pump(const Duration(seconds: 1));
        expect(
          await paintedHeights(),
          held,
          reason: 'Paused words must stay still',
        );
        expect(await seek(800), pending);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('timed lyric fills text fragments in reading order', (
    tester,
  ) async {
    const lyricText = 'AAAA BBBB CCCC DDDD EEEE FFFF GGGG HHHH';
    metadataOverrides['lyrics'] =
        '<tt xmlns="http://www.w3.org/ns/ttml"><body><div>'
        '<p begin="00:00.000" end="00:08.000">'
        '<span begin="00:00.000">$lyricText</span>'
        '</p></div></body></tt>';
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(320, 844),
      playback: PlaybackState(
        processingState: AudioProcessingState.ready,
        playing: false,
        updatePosition: const Duration(seconds: 2),
      ),
    );
    mediaItems.add(item('first'));
    await settlePlayer(tester);
    await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
    await settlePlayer(tester);

    final paintFinder = find.descendant(
      of: find.bySemanticsLabel(lyricText),
      matching: find.byType(CustomPaint),
    );
    final painter = tester.widget<CustomPaint>(paintFinder).painter!;
    final size = tester.getSize(paintFinder);
    final highlightedPixels = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), size);
      final picture = recorder.endRecording();
      final image = await picture.toImage(
        size.width.ceil(),
        size.height.ceil(),
      );
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      var upper = 0;
      var lower = 0;
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          if (bytes.getUint8((y * image.width + x) * 4 + 3) < 230) continue;
          if (y < image.height ~/ 2) {
            upper++;
          } else {
            lower++;
          }
        }
      }
      image.dispose();
      picture.dispose();
      return (upper, lower);
    });
    expect(highlightedPixels!.$1, greaterThan(0));
    expect(highlightedPixels.$2, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short timed lyric starts at the lyrics inset', (tester) async {
    await pumpNowPlaying(tester);

    mediaItems.add(item('timed'));
    await settlePlayer(tester);
    await tester.tap(find.byKey(const ValueKey('material-lyrics-toggle')));
    await settlePlayer(tester);

    // Material lines start-align as Mornye's do, at Material's own inset.
    final lyric = find.bySemanticsLabel('Short');
    expect(lyric, findsOneWidget);
    expect(tester.getRect(lyric).left, closeTo(24, 1));
  });

  testWidgets('Now Playing menu exposes Go to Album when album is known', (
    tester,
  ) async {
    await pumpNowPlaying(tester);
    mediaItems.add(item('first'));
    await settlePlayer(tester);

    await tester.tap(findAppIcon(Icons.more_vert));
    await settlePlayer(tester);

    expect(find.text('Go to Album'), findsOneWidget);
    expect(findAppIcon(Icons.album_outlined), findsOneWidget);
  });

  testWidgets('Now Playing menu exposes sleep timer duration choices', (
    tester,
  ) async {
    await pumpNowPlaying(tester);
    mediaItems.add(item('first'));
    await settlePlayer(tester);

    await tester.tap(findAppIcon(Icons.more_vert));
    await settlePlayer(tester);
    await tester.tap(find.text('Sleep timer'));
    await settlePlayer(tester);

    expect(find.text('15 minutes'), findsOneWidget);
    expect(find.text('30 minutes'), findsOneWidget);
    expect(find.text('45 minutes'), findsOneWidget);
    expect(find.text('60 minutes'), findsOneWidget);
    expect(find.text('Turn off sleep timer'), findsNothing);
  });

  testWidgets('Now Playing menu hides and restores the volume', (tester) async {
    await pumpNowPlaying(tester);
    mediaItems.add(item('first'));
    await settlePlayer(tester);
    expect(find.byType(PlayerVolumeControl), findsOneWidget);

    await tester.tap(findAppIcon(Icons.more_vert));
    await settlePlayer(tester);
    await tester.tap(find.text('Hide volume'));
    await settlePlayer(tester);
    expect(find.byType(PlayerVolumeControl), findsNothing);
    expect(find.byType(PlayerPlaybackControls), findsOneWidget);

    await tester.tap(findAppIcon(Icons.more_vert));
    await settlePlayer(tester);
    await tester.tap(find.text('Show volume'));
    await settlePlayer(tester);
    expect(find.byType(PlayerVolumeControl), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mornye player menu hides the volume in both orientations', (
    tester,
  ) async {
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 780),
    );
    mediaItems.add(item('first'));
    await settlePlayer(tester);
    expect(find.byType(PlayerVolumeControl), findsOneWidget);

    await tester.tap(findAppIcon(CupertinoIcons.ellipsis).hitTestable());
    await settlePlayer(tester);
    await tester.ensureVisible(find.text('Hide volume'));
    await tester.tap(find.text('Hide volume'));
    await settlePlayer(tester);
    expect(find.byType(PlayerVolumeControl), findsNothing);
    final transport = find.byType(PlayerPlaybackControls);
    expect(
      tester.getRect(transport).bottom,
      lessThan(tester.getRect(findAppIcon(CupertinoIcons.quote_bubble)).top),
    );

    tester.view.physicalSize = const Size(844, 390);
    await settlePlayer(tester);
    expect(find.byType(PlayerVolumeControl), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Map<String, dynamic> _lyricsDto(ParsedLyrics value) => {
  'synced': value.synced,
  'wordSynced': value.wordSynced,
  'plainText': value.plainText,
  'writers': value.writers,
  'provider': value.provider,
  'lines': [
    for (final line in value.lines)
      {
        'timeMs': line.time.inMilliseconds,
        'endMs': line.end?.inMilliseconds,
        'text': line.text,
        'words': [for (final word in line.words) _wordDto(word)],
        'romanization': line.romanization,
        'romanizationWords': [
          for (final word in line.romanizationWords) _wordDto(word),
        ],
        'translation': line.translation,
        'voice': line.voice == null
            ? null
            : {
                'id': line.voice!.id,
                'index': line.voice!.index,
                'isGroup': line.voice!.isGroup,
              },
        'isBackground': line.isBackground,
        'vocalGroup': line.vocalGroup,
      },
  ],
};

Map<String, dynamic> _wordDto(LyricWord word) => {
  'timeMs': word.time.inMilliseconds,
  'endMs': word.end?.inMilliseconds,
  'text': word.text,
};

class _QueueController extends MusicPlayerController {
  _QueueController(this.onSelected);
  final void Function(int) onSelected;
  final selected = <int>[];

  @override
  Future<void> jumpTo(int index) async {
    selected.add(index);
    onSelected(index);
  }
}

class _SeekController extends MusicPlayerController {
  final seeks = <Duration>[];
  final completions = <Completer<void>>[];

  @override
  Future<void> seek(Duration position) {
    seeks.add(position);
    final completion = Completer<void>();
    completions.add(completion);
    return completion.future;
  }
}

class _TestCollections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);

  @override
  Future<bool> toggleLoved(Track track) async {
    final key = trackCollectionKey(track);
    final added = !state.isLoved(track);
    state = state.copyWith(
      loved: added
          ? [
              ...state.loved,
              CollectionTrackEntry(
                key: key,
                track: track,
                addedAt: DateTime.now(),
              ),
            ]
          : state.loved.where((entry) => entry.key != key).toList(),
    );
    return added;
  }
}
