import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mini_player.dart';
import 'package:mornye/widgets/mornye_bottom_bar.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_liquid_backdrop.dart';

import 'performance_probe.dart';

void main() {
  final binding = PerformanceTestBinding.ensureInitialized();
  const focused = bool.fromEnvironment('MORNYE_GLASS_FOCUS');
  for (final clarity in focused ? [0.6, 1.0] : [0.0, 0.1, 0.6, 1.0]) {
    testWidgets('Mornye real rendering at clarity $clarity', (tester) async {
      final probe = PerformanceProbe(
        binding,
        tester,
        suite: 'mornye_chrome_${(clarity * 100).round()}',
      );
      final fixture = (await tester.runAsync(_Fixture.create))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => binding.endOfFrame);
        await fixture.dispose();
      });
      await tester.pumpWidget(fixture.app(clarity));
      await tester.runAsync(() async {
        await LiquidGlassShaders.ensureLoaded();
        await ui.FragmentProgram.fromAsset(
          'assets/shaders/mornye_selection_mask.frag',
        );
        await probe.wait(const Duration(milliseconds: 600));
      });
      expect(find.byType(MornyeBottomBar), findsOneWidget);
      expect(find.byType(MiniPlayer), findsOneWidget);
      final player = tester.state(find.byType(MiniPlayer));

      for (final compact in [false, true]) {
        // Returning to the top expands production chrome, including during a
        // programmatic scroll. Keep both scenarios above that boundary.
        fixture.scroll.jumpTo(300);
        fixture.chrome.value = compact;
        await probe.wait(const Duration(milliseconds: 450));
        await probe.measure(
          compact ? 'compact_scroll' : 'full_scroll',
          () async {
            await probe.scroll(fixture.scroll, distance: 1800);
            await probe.scroll(fixture.scroll, distance: -1800);
          },
        );
        expect(fixture.chrome.value, compact);
        expect(fixture.scroll.offset, closeTo(300, 0.1));
      }

      await probe.measure('collapse_expand', () async {
        fixture.chrome.value = true;
        await probe.wait(const Duration(milliseconds: 450));
        fixture.chrome.expand();
        await probe.wait(const Duration(milliseconds: 450));
      });
      expect(tester.state(find.byType(MiniPlayer)), same(player));
      expect(fixture.chrome.value, isFalse);

      if (!focused) {
        await probe.measure('tab_changes', () async {
          for (final label in ['Library', 'Repo', 'Search', 'Home']) {
            final tab = find.descendant(
              of: find.byType(MornyeTabBar),
              matching: find.text(label),
            );
            await tester.tapAt(tester.getCenter(tab.first));
            await probe.wait(const Duration(milliseconds: 300));
          }
        });
      }
      expect(fixture.activeTab.value, 0);

      if (clarity > 0.2) {
        await probe.measure('held_lens_drag', () async {
          final tabs = find.byType(MornyeTabBar);
          final home = tester.getCenter(
            find.descendant(of: tabs, matching: find.text('Home')).first,
          );
          final search = tester.getCenter(
            find.descendant(of: tabs, matching: find.text('Search')).first,
          );
          final gesture = await tester.startGesture(home);
          await probe.wait(const Duration(milliseconds: 280));
          final lens = find.byWidgetPredicate(
            (widget) => widget is MornyeLiquidBackdrop && widget.interaction,
          );
          if (ui.ImageFilter.isShaderFilterSupported) {
            // Await the final painted pose even if the emulator delays a frame.
            for (
              var attempt = 0;
              tester.widget<MornyeLiquidBackdrop>(lens).progress < 1 &&
                  attempt < 20;
              attempt++
            ) {
              await probe.wait(const Duration(milliseconds: 100));
            }
            expect(tester.widget<MornyeLiquidBackdrop>(lens).progress, 1);
          }
          for (var step = 1; step <= 60; step++) {
            final fraction = (1 - math.cos(step / 60 * math.pi * 2)) / 2;
            await gesture.moveTo(Offset.lerp(home, search, fraction)!);
            await probe.wait(const Duration(milliseconds: 16));
          }
          await gesture.up();
          await probe.wait(const Duration(milliseconds: 300));
        });
        expect(fixture.activeTab.value, 0);
      }

      fixture.setLongTitle(true);
      await probe.wait(const Duration(milliseconds: 100));
      await probe.measure('mini_player_marquee', () async {
        await probe.wait(const Duration(seconds: 4));
      });
      fixture.setLongTitle(false);
      await probe.wait(const Duration(milliseconds: 400));
      if (!focused) {
        await probe.measure('short_title_idle', () async {
          await probe.wait(const Duration(milliseconds: 1500));
        }, allowIdle: true);
      }
      expect(tester.takeException(), isNull);
      await probe.finish(
        metadata: {
          'glass_clarity': clarity,
          'glass_level': 'liquid',
          'focused': focused,
          'tracks': 2000,
          'unique_local_covers': fixture.covers.length,
          'scope':
              'production Mornye chrome and MiniPlayer over a fixture grid',
        },
      );
    });
  }
}

class _BenchmarkSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(motionArtworkEnabled: false);
}

class _Fixture {
  _Fixture(this.directory, this.covers, this.artUri);

  final Directory directory;
  final List<Uint8List> covers;
  final Uri artUri;
  final chrome = MornyeChromeController();
  final scroll = ScrollController();
  final activeTab = ValueNotifier<int>(0);
  final media = StreamController<MediaItem?>.broadcast(sync: true);

  static Future<_Fixture> create() async {
    final temp = await getTemporaryDirectory();
    final directory = await temp.createTemp('mornye-benchmark-art-');
    final covers = <Uint8List>[];
    for (var index = 0; index < 24; index++) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final hue = index * 137.5 % 360;
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 192, 192),
        Paint()
          ..shader = ui.Gradient.linear(Offset.zero, const Offset(192, 192), [
            HSLColor.fromAHSL(1, hue, 0.75, 0.25).toColor(),
            HSLColor.fromAHSL(1, (hue + 80) % 360, 0.85, 0.65).toColor(),
          ]),
      );
      for (var stripe = 0; stripe < 8; stripe++) {
        canvas.drawCircle(
          Offset(24.0 * stripe, (index * 13 + stripe * 23) % 192.0),
          10 + stripe * 4.0,
          Paint()..color = Colors.white.withValues(alpha: 0.12),
        );
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(192, 192);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      covers.add(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      image.dispose();
      picture.dispose();
    }
    final artwork = File('${directory.path}/cover.png');
    await artwork.writeAsBytes(covers.first);
    return _Fixture(directory, covers, artwork.uri);
  }

  MediaItem _item(bool longTitle) => MediaItem(
    id: longTitle ? 'benchmark-marquee' : 'benchmark-idle',
    title: longTitle
        ? 'A very long benchmark track title that keeps the production marquee moving'
        : 'Track 001',
    artist: longTitle
        ? 'Benchmark artist with an overflowing display name'
        : 'Artist',
    album: 'Fixture album',
    artUri: artUri,
    duration: const Duration(minutes: 4),
  );

  void setLongTitle(bool value) => media.add(_item(value));

  Widget app(double clarity) => ProviderScope(
    overrides: [
      settingsProvider.overrideWith(_BenchmarkSettings.new),
      currentMediaItemProvider.overrideWithBuild((ref, notifier) async* {
        yield _item(false);
        yield* media.stream;
      }),
      playbackStateProvider.overrideWith((ref) => const Stream.empty()),
      musicPlayerControllerProvider.overrideWithValue(MusicPlayerController()),
      lowEndDeviceProvider.overrideWithValue(false),
      backdropBlurEnabledProvider.overrideWithValue(true),
      mornyeGlassLevelProvider.overrideWithValue(MornyeGlassLevel.liquid),
    ],
    child: MaterialApp(
      theme: MornyeTheme.build(Brightness.dark, glassClarity: clarity),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        extendBody: true,
        body: NotificationListener<ScrollNotification>(
          onNotification: chrome.handleScroll,
          child: GridView.builder(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(16, 64, 16, 184),
            itemCount: 2000,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 0.80,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
            ),
            itemBuilder: (context, index) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(
                        covers[index % covers.length],
                        fit: BoxFit.cover,
                        cacheWidth: 192,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Track ${index + 1}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  'Artist ${index % 40}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: ListenableBuilder(
              listenable: Listenable.merge([chrome, activeTab]),
              builder: (context, child) => MornyeBottomBar(
                collapsed: chrome.value,
                destinations: const [
                  NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
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
                selectedIndex: activeTab.value,
                onSelected: (index) {
                  activeTab.value = index;
                  chrome.expand();
                },
                onHome: () {
                  activeTab.value = 0;
                  chrome.expand();
                },
                onSearch: () => activeTab.value = 3,
                blurEnabled: true,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> dispose() async {
    final imageCache = PaintingBinding.instance.imageCache;
    for (final image in [
      for (final cover in covers)
        ResizeImage.resizeIfNeeded(192, null, MemoryImage(cover)),
      ResizeImage.resizeIfNeeded(132, null, FileImage(File.fromUri(artUri))),
    ]) {
      final key = await image.obtainKey(ImageConfiguration.empty);
      expect(imageCache.statusForKey(key).live, isFalse);
      imageCache.evict(key);
      expect(imageCache.statusForKey(key).untracked, isTrue);
    }
    await media.close();
    chrome.dispose();
    scroll.dispose();
    activeTab.dispose();
    await directory.delete(recursive: true);
    debugPrint(
      'Mornye fixture cache after cleanup: ${imageCache.currentSizeBytes} bytes',
    );
  }
}
