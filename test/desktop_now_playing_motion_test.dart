import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart' show RenderOpacity;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/system_volume_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/player_artwork_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/desktop/desktop_inspector.dart';
import 'package:mornye/widgets/desktop/desktop_now_playing.dart';
import 'package:mornye/widgets/mornye_player_queue.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/player_lyrics_section.dart';
import 'package:mornye/widgets/player_playback_controls.dart';

/// Hands out cover schemes without decoding images.
class _FakePalette extends PlayerArtworkPalette {
  final cached = <String, ColorScheme>{};

  @override
  ColorScheme? peek(String source, Brightness brightness) => cached[source];

  @override
  Future<ColorScheme?> resolve(String source, Brightness brightness) =>
      Future.value(cached[source]);
}

const _coverA = '/covers/a.jpg';
const _coverB = '/covers/b.jpg';

MediaItem _track(String id, String cover) => MediaItem(
  id: id,
  title: 'Song $id',
  artist: 'An artist',
  duration: const Duration(minutes: 4),
  artUri: Uri.file(cover),
  extras: const {'source': '/music/song.flac'},
);

void main() {
  late _FakePalette palette;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDesktopPlatformOverride = true;
    desktopInspectorPanel.value = null;
    palette = _FakePalette();
    PlayerArtworkTheme.debugPalette = palette;
  });

  tearDown(() {
    debugDesktopPlatformOverride = null;
    desktopInspectorPanel.value = null;
    PlayerArtworkTheme.debugPalette = null;
  });

  Future<void> pumpPage(
    WidgetTester tester,
    Stream<MediaItem?> items, {
    bool mornye = false,
  }) async {
    tester.view.physicalSize = const Size(1520, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentMediaItemProvider.overrideWithBuild((ref, notifier) => items),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(
              PlaybackState(processingState: AudioProcessingState.ready),
            ),
          ),
          playQueueProvider.overrideWith(
            (ref) => Stream.value([_track('a', _coverA)]),
          ),
          systemVolumeProvider.overrideWith((ref) => Stream.value(0.5)),
        ],
        child: MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: DesktopNowPlaying(
              metadataControllerFactory: () => PlayerMetadataController(
                readMetadata: (_) async => const {},
                parseLyrics: (raw) async => LyricsParser.parse(raw ?? ''),
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Widget controls(WidgetTester tester) =>
      tester.widget(find.byType(PlayerPlaybackControls));

  testWidgets('a Material skip swaps the scheme once and moves only the '
      'page background', (tester) async {
    final red = ColorScheme.fromSeed(
      seedColor: Colors.red,
      brightness: Brightness.dark,
    );
    final green = ColorScheme.fromSeed(
      seedColor: Colors.green,
      brightness: Brightness.dark,
    );
    palette.cached[_coverA] = red;
    palette.cached[_coverB] = green;
    final items = StreamController<MediaItem?>();
    addTearDown(items.close);
    items.add(_track('a', _coverA));
    await pumpPage(tester, items.stream);

    ColorScheme shown() => Theme.of(
      tester.element(find.byType(PlayerPlaybackControls)),
    ).colorScheme;
    Color background() => tester
        .widget<ColoredBox>(
          find
              .descendant(
                of: find.byType(PlayerArtworkSurface).first,
                matching: find.byType(ColoredBox),
              )
              .first,
        )
        .color;
    expect(shown(), red);
    expect(background(), red.surface);

    items.add(_track('b', _coverB));
    for (var i = 0; i < 5 && shown() != green; i++) {
      await tester.pump();
    }
    expect(shown(), green);
    final swapped = controls(tester);
    final backgrounds = <Color>[];
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(shown(), green, reason: 'frame $frame moved the scheme');
      expect(
        controls(tester),
        same(swapped),
        reason: 'frame $frame rebuilt the player column',
      );
      backgrounds.add(background());
    }
    expect(
      backgrounds.where(
        (color) => color != red.surface && color != green.surface,
      ),
      isNotEmpty,
      reason: 'the page background moves between the two surfaces',
    );
    expect(background(), green.surface);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a Material page without a track paints the moving background', (
    tester,
  ) async {
    await pumpPage(tester, Stream.value(null));
    expect(find.byType(PlayerArtworkSurface), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final mornye in [false, true]) {
    testWidgets('${mornye ? 'Mornye' : 'Material'} panel motion and window '
        'resize keep the column, lyrics and queue built', (tester) async {
      palette.cached[_coverA] = ColorScheme.fromSeed(
        seedColor: Colors.red,
        brightness: Brightness.dark,
      );
      await pumpPage(
        tester,
        Stream.value(_track('a', _coverA)),
        mornye: mornye,
      );
      final queueType = mornye ? MornyePlayerQueue : DesktopMaterialQueue;
      final column = controls(tester);
      final cover = find.byWidgetPredicate(
        (widget) => widget is PlayerArtwork && widget.iconSize == 96,
      );
      double panelOpacity() => tester
          .renderObject<RenderOpacity>(
            find
                .ancestor(
                  of: find.byType(PlayerLyricsSection),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity;

      desktopInspectorPanel.value = DesktopInspectorPanel.lyrics;
      await tester.pump();
      // Showing the lyrics builds them once.
      final lyrics = tester.widget(find.byType(PlayerLyricsSection));
      final opacities = <double>{};
      // Long enough for either style's open spring to settle.
      for (var frame = 0; frame < 40; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        opacities.add(panelOpacity());
        final coverSize = tester.getSize(cover);
        expect(coverSize.width, coverSize.height);
        expect(controls(tester), same(column), reason: 'open frame $frame');
        expect(
          tester.widget(find.byType(PlayerLyricsSection)),
          same(lyrics),
          reason: 'open frame $frame',
        );
      }
      expect(opacities.where((value) => value > 0 && value < 1), isNotEmpty);
      expect(panelOpacity(), 1);

      // A live window resize.
      for (var frame = 1; frame <= 10; frame++) {
        tester.view.physicalSize = Size(1520 - frame * 12, 1000 - frame * 8);
        await tester.pump();
        expect(controls(tester), same(column), reason: 'resize frame $frame');
        expect(
          tester.widget(find.byType(PlayerLyricsSection)),
          same(lyrics),
          reason: 'resize frame $frame',
        );
      }

      desktopInspectorPanel.value = DesktopInspectorPanel.upNext;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      desktopInspectorPanel.value = null;
      await tester.pump();
      final queue = tester.widget(find.byType(queueType));
      var closing = 0;
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        // The closed panel drops its queue once the motion ends.
        if (find.byType(queueType).evaluate().isEmpty) break;
        closing++;
        expect(controls(tester), same(column), reason: 'close frame $frame');
        expect(
          tester.widget(find.byType(queueType)),
          same(queue),
          reason: 'close frame $frame',
        );
      }
      expect(closing, greaterThan(5));
      expect(find.byType(queueType), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
