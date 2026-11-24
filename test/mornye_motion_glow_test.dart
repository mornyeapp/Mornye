import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/widgets/mornye_motion_glow.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _VideoPlatform extends VideoPlayerPlatform {
  final events = <int, StreamController<VideoEvent>>{};
  int creations = 0;

  void ready(int id) => events[id]!.add(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 10),
      size: const Size(300, 400),
    ),
  );

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = ++creations;
    events[id] = StreamController<VideoEvent>();
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => events[playerId]!.stream;

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox();

  @override
  Future<void> dispose(int playerId) async => events[playerId]?.close();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late _VideoPlatform platform;

  Future<void> pumpGlow(
    WidgetTester tester, {
    required ValueNotifier<String?> source,
    ValueNotifier<bool>? visible,
    bool resolving = false,
    bool blurBudget = true,
    bool reducedMotion = false,
  }) async {
    final previous = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = platform = _VideoPlatform();
    addTearDown(() => VideoPlayerPlatform.instance = previous);
    addTearDown(source.dispose);
    final shown = visible ?? ValueNotifier(true);
    addTearDown(shown.dispose);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [mornyeLiquidGlassProvider.overrideWithValue(blurBudget)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: reducedMotion),
              child: ListenableBuilder(
                listenable: Listenable.merge([source, shown]),
                builder: (_, _) => MornyeMotionGlow(
                  videoUrl: source.value,
                  visible: shown.value,
                  resolvingVideo: resolving,
                  squareArtwork: false,
                  artworkAspectRatio: 0.75,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> ready(WidgetTester tester, int id) async {
    platform.ready(id);
    await tester.pump();
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  Iterable<ui.ImageFilter> blurs(WidgetTester tester) => tester
      .widgetList<ImageFiltered>(find.byType(ImageFiltered))
      .map((filtered) => filtered.imageFilter);

  double opacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find.descendant(
          of: find.byType(MornyeMotionGlow),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  testWidgets('a playing video ends in a soft copy and one colour', (
    tester,
  ) async {
    final source = ValueNotifier<String?>('file:///cover.mp4');
    await pumpGlow(tester, source: source);

    expect(find.byType(VideoPlayer), findsNothing);
    expect(opacity(tester), 0);

    await ready(tester, 1);

    expect(opacity(tester), 1);
    expect(find.byType(VideoPlayer), findsNWidgets(2));
    expect(blurs(tester), [
      // The one colour: drawn small, blurred wider than itself with mirrored
      // edges, then stretched back over its box.
      ui.ImageFilter.compose(
        outer: ui.ImageFilter.matrix(
          Matrix4.diagonal3Values(8.25, 8.25, 1).storage,
          filterQuality: FilterQuality.low,
        ),
        inner: ui.ImageFilter.blur(
          sigmaX: 50,
          sigmaY: 50,
          tileMode: TileMode.mirror,
        ),
      ),
      ui.ImageFilter.blur(
        sigmaX: MornyeMotionGlow.softSigma,
        sigmaY: MornyeMotionGlow.softSigma,
        tileMode: TileMode.clamp,
      ),
    ]);
    // A 3:4 video on a 400 dp page is 533 dp tall and fades from 58% of it.
    final soft = tester.getRect(find.byType(ShaderMask));
    expect(soft.top, closeTo(533.33 * 0.58, 0.01));
    expect(soft.bottom, closeTo(533.33, 0.01));
    // The colour starts inside the soft copy and runs to the end of the page.
    final colour = tester.getRect(find.byType(ImageFiltered).first);
    expect(colour.top, greaterThan(soft.top));
    expect(colour.top, lessThan(soft.bottom));
    expect(colour.left, 0);
    expect(colour.width, 400 / 8);
    expect(colour.height, closeTo((800 - colour.top) / 8, 0.01));
    await unmount(tester);
  });

  testWidgets('it leaves with the artwork behind lyrics', (tester) async {
    final source = ValueNotifier<String?>('file:///cover.mp4');
    final visible = ValueNotifier(true);
    await pumpGlow(tester, source: source, visible: visible);
    await ready(tester, 1);
    expect(opacity(tester), 1);

    visible.value = false;
    await tester.pump();

    expect(opacity(tester), 0);
    await unmount(tester);
  });

  testWidgets('the outgoing video keeps its layers until the next is ready', (
    tester,
  ) async {
    final source = ValueNotifier<String?>('file:///first.mp4');
    await pumpGlow(tester, source: source);
    await ready(tester, 1);
    VideoPlayerController shown() =>
        tester.widget<VideoPlayer>(find.byType(VideoPlayer).first).controller;
    final first = shown();

    source.value = 'file:///second.mp4';
    await tester.pump();

    expect(shown(), same(first));
    expect(opacity(tester), 1);

    await ready(tester, 2);

    expect(shown(), isNot(same(first)));
    expect(opacity(tester), 1);

    source.value = null;
    await tester.pump();

    expect(find.byType(VideoPlayer), findsNothing);
    expect(opacity(tester), 0);
    await unmount(tester);
  });

  testWidgets('a lookup in progress keeps the video on screen', (tester) async {
    final source = ValueNotifier<String?>('file:///cover.mp4');
    await pumpGlow(tester, source: source, resolving: true);
    await ready(tester, 1);

    source.value = null;
    await tester.pump();

    expect(find.byType(VideoPlayer), findsNWidgets(2));
    await unmount(tester);
  });

  testWidgets('a device without filtered effects keeps the plain fade', (
    tester,
  ) async {
    final source = ValueNotifier<String?>('file:///cover.mp4');
    await pumpGlow(tester, source: source, blurBudget: false);
    await tester.pump();

    expect(platform.creations, 0);
    expect(find.byType(ImageFiltered), findsNothing);
    await unmount(tester);
  });

  testWidgets('reduced motion keeps the plain fade', (tester) async {
    final source = ValueNotifier<String?>('file:///cover.mp4');
    await pumpGlow(tester, source: source, reducedMotion: true);
    await tester.pump();

    expect(platform.creations, 0);
    expect(find.byType(ImageFiltered), findsNothing);
    await unmount(tester);
  });
}
