import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/mornye_playback_time.dart';
import 'package:mornye/widgets/mornye_player_layout.dart';
import 'package:mornye/widgets/playback_seek_slider.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/player_lyric_preview.dart';

import 'support/fixed_settings.dart';

class _TestCurrentMediaItemNotifier extends CurrentMediaItemNotifier {
  _TestCurrentMediaItemNotifier(this._item);
  final MediaItem _item;
  @override
  Stream<MediaItem?> build() => Stream.value(_item);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const lrc = '''
[00:00.00]
[00:05.00]paisa mera dialect par -
[00:10.00]Next line of rap
''';

  group('Mornye Motion Artwork Immersive Layout Tests', () {
    testWidgets(
      'renders non-animated cover thumbnail, title, sleek seekbar and lyric preview in motion immersive mode',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final parsedLyrics = LyricsParser.parse(lrc);
        final metadata = PlayerMetadataController(
          parseLyrics: (_) async => parsedLyrics,
          readMetadata: (_) async => {
            'title': 'Vibrate',
            'artist': 'KR\$NA',
            'lyrics': lrc,
          },
        );
        final item = MediaItem(
          id: 'vibrate',
          title: 'Vibrate',
          artist: 'KR\$NA, Badshah, Phenom',
          duration: const Duration(seconds: 180),
          extras: const {'source': '/music/vibrate.flac'},
        );
        await metadata.load(item);

        final seekPreview = PlaybackSeekPreview();
        final positionController = StreamController<PlaybackState>.broadcast();
        addTearDown(positionController.close);

        var toggledMotionControls = false;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              currentMediaItemProvider.overrideWith(
                () => _TestCurrentMediaItemNotifier(item),
              ),
              playbackStateProvider.overrideWith(
                (ref) => positionController.stream,
              ),
              settingsProvider.overrideWith(
                () => FixedSettingsNotifier(
                  const AppSettings(playerShowLyricSnippet: true),
                ),
              ),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: ThemeData(useMaterial3: true),
              home: Scaffold(
                body: MornyePlayerLayout(
                  mediaItem: item,
                  metadata: metadata,
                  seekPreview: seekPreview,
                  colorScheme: const ColorScheme.dark(),
                  page: 0,
                  motionArtwork: const SizedBox.expand(),
                  artworkAspectRatio: 9 / 16,
                  hasMotionArtwork: true,
                  motionControlsHidden: true,
                  onToggleMotionControls: () {
                    toggledMotionControls = true;
                  },
                  insetArtwork: false,
                  artworkTopInset: 0,
                  artworkKeys: (
                    header: GlobalKey(),
                    controls: GlobalKey(),
                    volume: GlobalKey(),
                    expanded: GlobalKey(),
                    compact: GlobalKey(),
                  ),
                  lyricsControlsHidden: false,
                  lyricsOptionsOpen: false,
                  lyricsBuilder: (_) => const SizedBox.shrink(),
                  lyricsOptions: null,
                  onPageChanged: (_) {},
                  onTrackNavigation: (_, _) async {},
                  onMoreActions: (_, _, _) async {},
                ),
              ),
            ),
          ),
        );

        positionController.add(
          PlaybackState(
            playing: true,
            processingState: AudioProcessingState.ready,
            updatePosition: const Duration(seconds: 7),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(PlayerArtwork), findsOneWidget);
        expect(find.text('Vibrate'), findsAtLeast(1));
        expect(find.text('KR\$NA, Badshah, Phenom'), findsAtLeast(1));
        expect(find.byType(PlayerLyricPreview), findsOneWidget);
        expect(find.byType(PlaybackSeekSlider), findsOneWidget);

        final times = tester.widgetList<MornyePlaybackTime>(
          find.byType(MornyePlaybackTime),
        );
        expect(times.length, 2);
        expect(times.first.seconds, 7);
        expect(times.last.seconds, 173);

        await tester.tap(find.byType(GestureDetector).first);
        expect(toggledMotionControls, isTrue);
      },
    );
  });
}
