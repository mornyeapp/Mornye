import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/player_artwork_theme.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/mini_player.dart';
import 'package:mornye/widgets/material_player_backdrop.dart';
import 'package:mornye/widgets/mornye_player_background.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

class _StaticPalette extends PlayerArtworkPalette {
  @override
  ColorScheme peek(String source, Brightness brightness) =>
      ColorScheme.fromSeed(seedColor: Colors.teal, brightness: brightness);

  @override
  Future<ColorScheme?> resolve(String source, Brightness brightness) async =>
      peek(source, brightness);
}

Widget _player(
  Stream<MediaItem?> items, {
  ValueListenable<bool>? shown,
  bool mornye = true,
  String coverStyle = 'default',
}) => ProviderScope(
  overrides: [
    currentMediaItemProvider.overrideWithBuild((ref, notifier) => items),
    playbackStateProvider.overrideWith((ref) => const Stream.empty()),
    mornyeLiquidGlassProvider.overrideWithValue(false),
    backdropBlurEnabledProvider.overrideWithValue(false),
    settingsProvider.overrideWith(
      () => FixedSettingsNotifier(AppSettings(playerCoverStyle: coverStyle)),
    ),
  ],
  child: MaterialApp(
    theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      bottomNavigationBar: ValueListenableBuilder(
        valueListenable: shown ?? const AlwaysStoppedAnimation(true),
        builder: (context, shown, _) => shown
            ? const SizedBox(width: 360, child: MiniPlayer())
            : Consumer(
                builder: (context, ref, _) {
                  ref.watch(currentMediaItemProvider);
                  return const SizedBox.shrink();
                },
              ),
      ),
    ),
  ),
);

Future<File> _writeCover(WidgetTester tester, Color color) async {
  final directory = Directory.systemTemp.createTempSync('mini-cover-');
  addTearDown(() => directory.deleteSync(recursive: true));
  final cover = File('${directory.path}/cover.png');
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(color, BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(32, 32);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    await cover.writeAsBytes(bytes!.buffer.asUint8List());
  });
  return cover;
}

/// Lets background work finish without starting any palette job.
Future<Color?> _settledColor(WidgetTester tester, File cover) async {
  for (var i = 0; i < 100; i++) {
    final color = CoverPalette.peekSourceColor(cover.path);
    if (color != null) return color;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  return null;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final coverStyle in ['default', 'fullscreen']) {
    testWidgets('Material $coverStyle prepares only the needed artwork '
        'before opening', (tester) async {
      PlayerArtworkTheme.debugPalette = _StaticPalette();
      addTearDown(() => PlayerArtworkTheme.debugPalette = null);
      tester.view.physicalSize = const Size(720, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final cover = await _writeCover(tester, Colors.teal);
      final item = MediaItem(
        id: 'track',
        title: 'Track',
        artUri: Uri.file(cover.path),
      );
      final fullProvider = coverImageProvider(
        item.artUri.toString(),
        cacheWidth: 720,
      )!;
      final key = await fullProvider.obtainKey(ImageConfiguration.empty);
      final miniKey = await coverImageProvider(
        item.artUri.toString(),
        cacheWidth: PlayerArtwork.miniCacheWidth,
      )!.obtainKey(ImageConfiguration.empty);
      final cache = PaintingBinding.instance.imageCache;
      await tester.pumpWidget(
        _player(Stream.value(item), mornye: false, coverStyle: coverStyle),
      );
      for (
        var i = 0;
        i < 100 &&
            (!cache.statusForKey(miniKey).keepAlive ||
                (coverStyle == 'fullscreen' &&
                    !cache.statusForKey(key).keepAlive));
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      expect(cache.statusForKey(miniKey).keepAlive, isTrue);
      expect(cache.statusForKey(key).keepAlive, coverStyle == 'fullscreen');
      if (coverStyle == 'fullscreen') {
        await tester.pumpWidget(
          MaterialApp(
            home: MaterialPlayerBackdrop(
              mediaItem: item,
              colorScheme: AppTheme.light().colorScheme,
              showArtwork: true,
            ),
          ),
        );
        // Both the sharp cover (drawn above and inside its fade) and blur
        // render on the first player frame.
        expect(find.byType(ImageFiltered), findsNothing);
        expect(find.byIcon(Icons.music_note), findsNothing);
        expect(
          find.byWidgetPredicate(
            (widget) => widget is RawImage && widget.image != null,
          ),
          findsNWidgets(3),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('Mornye mini player resolves the cover colour on track change', (
    tester,
  ) async {
    final teal = await _writeCover(tester, Colors.teal);
    final orange = await _writeCover(tester, Colors.deepOrange);
    final items = StreamController<MediaItem?>();
    addTearDown(items.close);
    await tester.pumpWidget(_player(items.stream));
    for (final (index, cover) in [teal, orange].indexed) {
      expect(CoverPalette.peekSourceColor(cover.path), isNull);
      items.add(
        MediaItem(
          id: 'track $index',
          title: 'Track $index',
          artUri: Uri.file(cover.path),
        ),
      );
      await tester.pump();
      expect(await _settledColor(tester, cover), isNotNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Mornye mini player resolves the cover colour of the track it '
      'mounts with', (tester) async {
    final cover = await _writeCover(tester, Colors.teal);
    final shown = ValueNotifier(false);
    addTearDown(shown.dispose);
    await tester.pumpWidget(
      _player(
        Stream.value(
          MediaItem(id: 'track', title: 'Track', artUri: Uri.file(cover.path)),
        ),
        shown: shown,
      ),
    );
    await tester.pump();
    expect(await _settledColor(tester, cover), isNull);

    shown.value = true;
    await tester.pump();
    expect(find.text('Track'), findsOneWidget);
    expect(await _settledColor(tester, cover), isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the full player then opens on the cover colour', (tester) async {
    final cover = await _writeCover(tester, Colors.teal);
    final artUri = Uri.file(cover.path);
    await tester.pumpWidget(
      _player(
        Stream.value(MediaItem(id: 'track', title: 'Track', artUri: artUri)),
      ),
    );
    final source = await _settledColor(tester, cover);
    expect(source, isNotNull);

    await tester.pumpWidget(
      MaterialApp(
        theme: MornyeTheme.build(Brightness.dark),
        home: MornyePlayerBackground(artUri: artUri),
      ),
    );
    final dominant = HSLColor.fromColor(source!);
    final muted = dominant.withSaturation(dominant.saturation.clamp(0.0, 0.34));
    final decoration =
        tester
                .widget<DecoratedBox>(
                  find
                      .descendant(
                        of: find.byType(MornyePlayerBackground),
                        matching: find.byType(DecoratedBox),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    final gradient = decoration.gradient! as LinearGradient;
    expect(
      gradient.colors.first.toARGB32(),
      muted
          .withLightness(0.28 + dominant.lightness * 0.24)
          .toColor()
          .toARGB32(),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
