import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mini_player.dart';
import 'package:mornye/widgets/mornye_bottom_bar.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_liquid_backdrop.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(motionArtworkEnabled: false);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native Mornye glass visual poses and attached layers', (
    tester,
  ) async {
    expect(Platform.isAndroid || Platform.isIOS, isTrue);
    expect(ui.ImageFilter.isShaderFilterSupported, isTrue);
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    final directory = (await tester.runAsync(() async {
      return (await getTemporaryDirectory()).createTemp('mornye-glass-visual-');
    }))!;
    final cover = File('${directory.path}/cover.png');
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      const _Pattern().paint(Canvas(recorder), const Size(192, 192));
      final picture = recorder.endRecording();
      final image = await picture.toImage(192, 192);
      try {
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await cover.writeAsBytes(bytes.buffer.asUint8List());
      } finally {
        image.dispose();
        picture.dispose();
      }
    });
    final chrome = MornyeChromeController();
    final selected = ValueNotifier(0);
    final runtime = MusicPlayerRuntime();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await runtime.dispose();
      await ResizeImage.resizeIfNeeded(132, null, FileImage(cover)).evict();
      chrome.dispose();
      selected.dispose();
      await directory.delete(recursive: true);
    });
    final item = MediaItem(
      id: 'glass-visual-fixture',
      title: 'Color study',
      artist: 'Fixture artist',
      duration: const Duration(minutes: 4),
      artUri: cover.uri,
    );
    final poses = <String, Object?>{};
    const flatBackdrop = bool.fromEnvironment('MORNYE_GLASS_FLAT_BACKDROP');
    Future<void> wait(int milliseconds) async {
      await tester.runAsync(
        () => Future<void>.delayed(Duration(milliseconds: milliseconds)),
      );
    }

    CurvedAnimation fold() {
      final builder = tester.widget<AnimatedBuilder>(
        find
            .descendant(
              of: find.byType(MornyeBottomBar),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is AnimatedBuilder &&
                    widget.animation is CurvedAnimation,
              ),
            )
            .first,
      );
      return builder.animation as CurvedAnimation;
    }

    Future<void> capture(
      String name, {
      required int reads,
      Map<String, Object?> details = const {},
    }) async {
      await tester.pump();
      // Android can acquire the previously displayed image before the new
      // Flutter frame reaches its image view. Prime that view, then capture the
      // frozen pose; discard the priming image from the exported report.
      await wait(250);
      await tester.runAsync(() => binding.takeScreenshot('settle_$name'));
      (binding.reportData!['screenshots']! as List<dynamic>).removeLast();
      final histogram = <String, int>{};
      void visit(Layer layer) {
        histogram.update(
          layer.runtimeType.toString(),
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        if (layer is ContainerLayer) {
          for (
            var child = layer.firstChild;
            child != null;
            child = child.nextSibling
          ) {
            visit(child);
          }
        }
      }

      // Profile builds need the retained layer, since debugLayer is debug-only.
      // ignore: invalid_use_of_protected_member
      visit(tester.binding.renderViews.first.layer!);
      // Batched lenses compose their blur, so no stock blur layer remains.
      // Each batch key costs one read; an excluded lens takes its own.
      final lensKeys = [
        for (final lens in find.byType(LiquidGlassLens).evaluate())
          LiquidGlassBatch.backdropIdOf(lens),
      ];
      expect(histogram['BackdropFilterLayer'] ?? 0, 0, reason: name);
      expect(
        lensKeys.nonNulls.toSet().length +
            lensKeys.where((key) => key == null).length,
        reads,
        reason: name,
      );
      poses[name] = {
        ...details,
        'collapseProgress': fold().value,
        'controllerProgress': fold().parent.value,
        'shaderBackdrops': histogram['_ImpellerShaderBackdropLayer'] ?? 0,
        'stockBlurLayers': histogram['BackdropFilterLayer'] ?? 0,
        'batchBlurLayers': histogram['LiquidGlassBatchBackdropLayer'] ?? 0,
        'lensBatchKeys': lensKeys,
        'attachedLayerTypes': histogram,
      };
      await tester.runAsync(() => binding.takeScreenshot(name));
    }

    Future<void> halfway(bool collapsed) async {
      chrome.value = collapsed;
      await tester.pump();
      (fold().parent as AnimationController)
        ..stop()
        ..value = 0.5;
      await tester.pump();
    }

    for (final (brightness, clarity, outlines) in [
      (Brightness.dark, 0.6, true),
      (Brightness.dark, 1.0, true),
      (Brightness.light, 0.75, true),
      (Brightness.light, 0.75, false),
      (Brightness.dark, 0.75, false),
    ]) {
      chrome.expand();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            currentMediaItemProvider.overrideWithBuild(
              (ref, notifier) => Stream.value(item),
            ),
            playbackStateProvider.overrideWith(
              (ref) => Stream.value(PlaybackState()),
            ),
            musicPlayerControllerProvider.overrideWithValue(
              MusicPlayerController(runtime: runtime),
            ),
            mornyeGlassLevelProvider.overrideWithValue(MornyeGlassLevel.liquid),
          ],
          child: MaterialApp(
            theme: MornyeTheme.build(
              brightness,
              glassClarity: clarity,
              glassOutlines: outlines,
            ),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              extendBody: true,
              body: flatBackdrop
                  ? ColoredBox(
                      color: brightness == Brightness.dark
                          ? Colors.black
                          : Colors.white,
                      child: const SizedBox.expand(),
                    )
                  : const CustomPaint(
                      painter: _Pattern(),
                      child: SizedBox.expand(),
                    ),
              bottomNavigationBar: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: ListenableBuilder(
                    listenable: Listenable.merge([chrome, selected]),
                    builder: (_, _) => MornyeBottomBar(
                      collapsed: chrome.value,
                      destinations: const [
                        NavigationDestination(
                          icon: Icon(Icons.home),
                          label: 'Home',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.music_note),
                          label: 'Library',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.grid_view),
                          label: 'Repo',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.search),
                          label: 'Search',
                        ),
                      ],
                      selectedIndex: selected.value,
                      onSelected: (value) => selected.value = value,
                      onHome: () => selected.value = 0,
                      onSearch: () => selected.value = 3,
                      blurEnabled: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await LiquidGlassShaders.ensureLoaded();
        await ui.FragmentProgram.fromAsset(
          'assets/shaders/mornye_selection_mask.frag',
        );
      });
      await wait(600);
      if (Platform.isAndroid && clarity == 0.6) {
        await binding.convertFlutterSurfaceToImage();
        await tester.pump();
      }
      expect(find.byType(MiniPlayer), findsOneWidget);
      final player = tester.state(find.byType(MiniPlayer));
      final prefix =
          '${brightness.name}_clarity_${(clarity * 100).round()}_outlines_$outlines';
      final lenses = tester.widgetList<LiquidGlassLens>(
        find.byType(LiquidGlassLens),
      );
      expect(lenses, isNotEmpty);
      for (final lens in lenses) {
        expect(lens.style.specular?.thickness, outlines ? 0.75 * 5.4 : 0);
      }
      // Folding capsules cross the tabs and sample on their own. At rest
      // they share the player's read.
      await capture('${prefix}_expanded', reads: 1);
      await halfway(true);
      await capture('${prefix}_folding_half', reads: 3);
      (fold().parent as AnimationController).forward();
      await wait(450);
      await capture('${prefix}_compact', reads: 1);
      await halfway(false);
      await capture('${prefix}_reopening_half', reads: 3);
      (fold().parent as AnimationController).reverse();
      await wait(450);
      Offset tab(String label) => tester.getCenter(
        find
            .descendant(
              of: find.byType(MornyeTabBar),
              matching: find.text(label),
            )
            .hitTestable(),
      );
      final home = tab('Home');
      final search = tab('Search');
      Rect capsule() => tester.getRect(
        find.descendant(
          of: find.byType(MornyeTabBar),
          matching: find.byType(MornyeGlass),
        ),
      );
      Map<String, Rect> foreground() => {
        for (final entry in const {
          'Home': Icons.home,
          'Library': Icons.music_note,
          'Repo': Icons.grid_view,
          'Search': Icons.search,
        }.entries) ...{
          '${entry.key}_icon': tester.getRect(
            find.descendant(
              of: find.byType(MornyeTabBar),
              matching: find.byIcon(entry.value),
            ),
          ),
          '${entry.key}_label': tester.getRect(
            find.descendant(
              of: find.byType(MornyeTabBar),
              matching: find.text(entry.key),
            ),
          ),
        },
      };
      List<double> bounds(Rect rect) => [
        rect.left,
        rect.top,
        rect.width,
        rect.height,
      ];
      final restingCapsule = capsule();
      final restingForeground = foreground();
      final touch = await tester.startGesture(home);
      try {
        await wait(320);
        await touch.moveTo(Offset.lerp(home, search, 0.5)!);
        await wait(100);
        final lens = find.byWidgetPredicate(
          (widget) => widget is MornyeLiquidBackdrop && widget.interaction,
        );
        for (
          var attempt = 0;
          tester.widget<MornyeLiquidBackdrop>(lens).progress < 1 &&
              attempt < 20;
          attempt++
        ) {
          await wait(100);
        }
        expect(tester.widget<MornyeLiquidBackdrop>(lens).progress, 1);
        final heldCapsule = capsule();
        expect(heldCapsule.width, closeTo(restingCapsule.width * 1.025, 0.01));
        expect(heldCapsule.height, closeTo(restingCapsule.height * 1.06, 0.01));
        expect(foreground(), restingForeground);
        final glass = tester.widget<MornyeLiquidBackdrop>(
          find.descendant(
            of: find.byType(MornyeTabBar),
            matching: find.byWidgetPredicate(
              (widget) => widget is MornyeLiquidBackdrop && !widget.interaction,
            ),
          ),
        );
        expect(glass.refractionDepth, closeTo(0.60, 0.001));
        await capture(
          '${prefix}_held_halfway',
          // The held selection lens refracts the bar, so it reads alone.
          reads: 2,
          details: {
            'restingCapsule': bounds(restingCapsule),
            'heldCapsule': bounds(heldCapsule),
            'fixedForegroundBounds': {
              for (final entry in restingForeground.entries)
                entry.key: bounds(entry.value),
            },
            'heldRefractionDepth': glass.refractionDepth,
          },
        );
      } finally {
        await touch.cancel();
      }
      await wait(300);
      // Live emulator frames can lag behind the release animation's duration.
      for (
        var attempt = 0;
        capsule() != restingCapsule && attempt < 20;
        attempt++
      ) {
        await wait(100);
        await tester.pump();
      }
      expect(capsule(), restingCapsule);
      expect(foreground(), restingForeground);
      expect(tester.state(find.byType(MiniPlayer)), same(player));
      expect(tester.takeException(), isNull);
    }
    binding.reportData!['mornye_glass_visual'] = {
      'scope':
          'Production MornyeBottomBar/MiniPlayer over '
          '${flatBackdrop ? 'flat light/dark surfaces' : 'generated stripes/grid'}; '
          'paused in-memory playback and settings, no persistent data or network.',
      'captureSurface':
          '${Platform.isAndroid ? 'Android converted Flutter image view' : 'iOS window'}; '
          'visual-only, no timings.',
      'halfPose':
          'Production animation controller stopped at linear progress 0.5.',
      'physicalSize': [
        tester.view.physicalSize.width,
        tester.view.physicalSize.height,
      ],
      'devicePixelRatio': tester.view.devicePixelRatio,
      'poses': poses,
    };
  });
}

class _Pattern extends CustomPainter {
  const _Pattern();

  @override
  void paint(Canvas canvas, Size size) {
    const colors = [Colors.deepPurple, Colors.cyan, Colors.amber, Colors.pink];
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xff102038),
    );
    for (var y = 0.0; y < size.height; y += 48) {
      for (var x = 0.0; x < size.width; x += 48) {
        final color = colors[((x + y) / 48).toInt() % colors.length];
        canvas.drawRect(
          Rect.fromLTWH(x, y, 47, 47),
          Paint()..color = color.withValues(alpha: 0.65),
        );
        canvas.drawRect(
          Rect.fromLTWH(x, y + 16, 47, 4),
          Paint()..color = Colors.white.withValues(alpha: 0.5),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_Pattern oldDelegate) => false;
}
