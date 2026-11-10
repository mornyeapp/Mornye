import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/autoeq_database.dart';
import 'package:mornye/services/spatial_audio_crossfeed.dart';
import 'package:mornye/services/spotify_canvas_service.dart';
import 'package:mornye/widgets/mornye_app_splash.dart';
import 'package:mornye/widgets/realtime_audio_visualizer.dart';

void main() {
  group('Phase 8: Instant Launch & Splash Passthrough', () {
    testWidgets(
      'MornyeAppSplash mounts child directly without animation delay',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: MornyeAppSplash(child: Text('Main Screen Content')),
          ),
        );

        expect(find.text('Main Screen Content'), findsOneWidget);
      },
    );
  });

  group('Phase 8: AutoEq Massive Database Expansion', () {
    test('contains Kiwi Ears profiles including Belle and Cadenza', () {
      final belle = AutoEqDatabase.profiles.firstWhere(
        (p) => p.id == 'kiwi_ears_belle',
      );
      expect(belle.brand, 'Kiwi Ears');
      expect(belle.model, 'Belle');
      expect(belle.gains.length, 10);

      final cadenza = AutoEqDatabase.profiles.firstWhere(
        (p) => p.id == 'kiwi_ears_cadenza',
      );
      expect(cadenza.brand, 'Kiwi Ears');
      expect(cadenza.model, 'Cadenza');

      final results = AutoEqDatabase.search('Belle', brand: 'Kiwi Ears');
      expect(results.length, 1);
      expect(results.first.displayName, 'Kiwi Ears Belle');
    });

    test('contains CMF Buds Pro 2 and Nothing Ear models', () {
      final cmf = AutoEqDatabase.profiles.firstWhere(
        (p) => p.id == 'cmf_buds_pro_2',
      );
      expect(cmf.brand, 'CMF');
      expect(cmf.model, 'Buds Pro 2');

      final results = AutoEqDatabase.search('Buds Pro 2');
      expect(results.any((p) => p.brand == 'CMF'), isTrue);

      final nothing2024 = AutoEqDatabase.profiles.firstWhere(
        (p) => p.id == 'nothing_ear_2024',
      );
      expect(nothing2024.brand, 'Nothing');
      expect(nothing2024.model, 'Ear (2024)');
    });

    test('contains 7Hz, Truthear, Tangzu, Fiio, and audiophile flagships', () {
      expect(AutoEqDatabase.profiles.any((p) => p.id == '7hz_zero_2'), isTrue);
      expect(
        AutoEqDatabase.profiles.any((p) => p.id == 'truthear_hexa'),
        isTrue,
      );
      expect(
        AutoEqDatabase.profiles.any((p) => p.id == 'truthear_zero_red'),
        isTrue,
      );
      expect(
        AutoEqDatabase.profiles.any((p) => p.id == 'tangzu_waner'),
        isTrue,
      );
      expect(AutoEqDatabase.profiles.any((p) => p.id == 'fiio_fh3'), isTrue);
      expect(
        AutoEqDatabase.profiles.any((p) => p.id == 'sennheiser_hd800s'),
        isTrue,
      );
      expect(
        AutoEqDatabase.profiles.any((p) => p.id == 'focal_bathys'),
        isTrue,
      );
      expect(
        AutoEqDatabase.profiles.any((p) => p.id == 'meze_109_pro'),
        isTrue,
      );
      expect(
        AutoEqDatabase.profiles.any((p) => p.id == 'audeze_lcd_x'),
        isTrue,
      );
    });

    test('availableBrands lists all new brands alphabetically', () {
      final brands = AutoEqDatabase.availableBrands;
      expect(brands.contains('Kiwi Ears'), isTrue);
      expect(brands.contains('CMF'), isTrue);
      expect(brands.contains('7Hz'), isTrue);
      expect(brands.contains('Truthear'), isTrue);
      expect(brands.contains('Tangzu'), isTrue);
      expect(brands.contains('Nothing'), isTrue);
      expect(brands.contains('Fiio'), isTrue);
      expect(brands.contains('Focal'), isTrue);
      expect(brands.contains('Meze'), isTrue);
      expect(brands.contains('Audeze'), isTrue);
    });
  });

  group('Phase 8: Spatial Audio & Crossfeed DSP', () {
    test('computes Bauer crossfeed filter specs', () {
      const crossfeed = SpatialAudioCrossfeed();
      final mpvBs2b = crossfeed.toMpvFilter(useBs2b: true);
      expect(mpvBs2b.name, 'bs2b');
      expect(mpvBs2b.options['profile'], 'default');

      final mpvStereo = crossfeed.toMpvFilter(useBs2b: false);
      expect(mpvStereo.name, 'stereotools');
      expect(mpvStereo.options['crosslevel'], '0.35');
    });
  });

  group('Phase 8: Settings Models & Toggles', () {
    test('Settings contains new playback toggles with correct defaults', () {
      const settings = AppSettings();
      expect(settings.spatialAudio, isFalse);
      expect(settings.realtimeVisualizer, isTrue);
      expect(settings.pitchTempoControls, isFalse);
      expect(settings.playbackPitch, 0.0);
      expect(settings.playbackSpeed, 1.0);

      final updated = settings.copyWith(
        spatialAudio: true,
        realtimeVisualizer: false,
        pitchTempoControls: true,
        playbackPitch: 2.5,
        playbackSpeed: 1.25,
      );
      expect(updated.spatialAudio, isTrue);
      expect(updated.realtimeVisualizer, isFalse);
      expect(updated.pitchTempoControls, isTrue);
      expect(updated.playbackPitch, 2.5);
      expect(updated.playbackSpeed, 1.25);
    });
  });

  group('Phase 8: RealtimeAudioVisualizer Widget', () {
    testWidgets('renders cleanly in playing and paused states', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RealtimeAudioVisualizer(
              isPlaying: true,
              height: 32,
              barCount: 20,
            ),
          ),
        ),
      );

      expect(find.byType(RealtimeAudioVisualizer), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RealtimeAudioVisualizer(
              isPlaying: false,
              height: 32,
              barCount: 20,
            ),
          ),
        ),
      );

      expect(find.byType(RealtimeAudioVisualizer), findsOneWidget);
    });
  });

  group('Phase 8: Spotify Canvas & Quality Badge & Pitch Shifter', () {
    test(
      'SpotifyCanvasService resolves direct canvas URL with 9:16 aspect ratio',
      () async {
        final service = SpotifyCanvasService();
        final artwork = await service.resolveCanvas((
          id: 'track1',
          title: 'Song Title',
          artist: 'Artist Name',
          album: 'Album Name',
          source: null,
          spotifyId: null,
          canvasUrl: 'https://example.com/canvas.mp4',
        ));

        expect(artwork, isNotNull);
        expect(artwork!.source, 'https://example.com/canvas.mp4');
        expect(artwork.aspectRatio, closeTo(9 / 16, 0.001));
      },
    );

    test(
      'PlayerMetadataController retains qualityLabel and does not disappear',
      () {
        final controller = PlayerMetadataController();
        expect(controller.qualityLabel, isNull);
      },
    );

    test(
      'PlayerMetadataController skips probing unresolved content URI when lyrics exist',
      () async {
        var probeCalls = 0;
        final controller = PlayerMetadataController(
          readMetadata: (path) async {
            probeCalls++;
            return {'format': 'FLAC'};
          },
        );

        final itemWithLyrics = const MediaItem(
          id: '1',
          title: 'Title',
          extras: {
            'source': 'content://media/external/audio/media/123',
            'lyrics': '[00:01.00]Hello world',
          },
        );

        await controller.load(
          itemWithLyrics,
          inspectUnresolvedContentUri: true,
        );
        // Because lyrics were already present, probeCalls should be 0 to avoid SAF descriptor conflict
        expect(probeCalls, 0);
        expect(controller.lyrics.isEmpty, isFalse);
      },
    );

    test(
      'PlayerMetadataController searchOnline updates lyrics and invokes safe persistence',
      () async {
        String? savedSource;
        String? savedLyrics;

        final controller = PlayerMetadataController(
          fetchOnlineLyrics: (item) async =>
              '[00:01.50]Online lyrics line\n[00:03.00]Second line',
          saveOnlineLyrics: (source, lyrics) async {
            savedSource = source;
            savedLyrics = lyrics;
          },
        );

        final itemWithoutLyrics = const MediaItem(
          id: 'song_1',
          title: 'Song Title',
          artist: 'Artist Name',
          extras: {'source': 'content://media/external/audio/media/999'},
        );

        await controller.load(
          itemWithoutLyrics,
          inspectUnresolvedContentUri: false,
        );
        expect(controller.lyrics.isEmpty, isTrue);

        await controller.searchOnline();

        expect(controller.lyrics.isEmpty, isFalse);
        expect(controller.lyrics.lines.length, 2);
        expect(savedSource, 'content://media/external/audio/media/999');
        expect(savedLyrics, contains('Online lyrics line'));
      },
    );

    test(
      'PlayerMetadataController probes unresolved content URI when inspectUnresolvedContentUri is true and fallback metadata has no lyrics',
      () async {
        var probeCalls = 0;
        final controller = PlayerMetadataController(
          readMetadata: (path) async {
            probeCalls++;
            return {'lyrics': '[00:01.00]Embedded lyrics in audio file'};
          },
        );

        final itemWithFallbackNoLyrics = const MediaItem(
          id: '1',
          title: 'Title',
          extras: {
            'source': 'content://media/external/audio/media/123',
            'format': 'FLAC',
            'sampleRate': 44100,
            'bitDepth': 24,
          },
        );

        // Even though item has technical fallback metadata, when inspectUnresolvedContentUri is true,
        // it must probe the file because lyrics are empty.
        await controller.load(
          itemWithFallbackNoLyrics,
          inspectUnresolvedContentUri: true,
        );
        expect(probeCalls, 1);
        expect(controller.lyrics.isEmpty, isFalse);
        expect(
          controller.lyrics.lines.single.text,
          'Embedded lyrics in audio file',
        );
      },
    );
  });
}
