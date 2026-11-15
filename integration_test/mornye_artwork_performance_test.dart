import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/mornye_player_artwork.dart';
import 'package:mornye/widgets/mornye_player_layout.dart';
import 'package:mornye/widgets/material_player_layout.dart';
import 'package:mornye/widgets/player_volume_control.dart';

import 'performance_probe.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(motionArtworkEnabled: false);
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}

void main() => runArtworkPerformanceTests(mornye: true);

/// The same source image and panel gestures exercise both player layouts.
void runArtworkPerformanceTests({required bool mornye}) {
  final binding = PerformanceTestBinding.ensureInitialized();
  final style = mornye ? 'mornye' : 'material';
  testWidgets('$style player panel transitions and artwork cache', (
    tester,
  ) async {
    final probe = PerformanceProbe(binding, tester, suite: '$style-artwork');
    final directory = await tester.runAsync(getTemporaryDirectory);
    final cover = File('${directory!.path}/$style-performance-cover.png');
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      const bounds = Rect.fromLTWH(0, 0, 2400, 2400);
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = const LinearGradient(
            colors: [Colors.deepPurple, Colors.orange, Colors.cyan],
          ).createShader(bounds),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(2400, 2400);
      try {
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await cover.writeAsBytes(bytes.buffer.asUint8List());
      } finally {
        image.dispose();
        picture.dispose();
      }
    });
    addTearDown(() async {
      if (await cover.exists()) await cover.delete();
    });
    final item = MediaItem(
      id: 'performance-cover',
      title: 'Performance track',
      artist: 'Fixture artist',
      duration: const Duration(minutes: 4),
      artUri: cover.uri,
    );
    final theme = mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark();
    final page = ValueNotifier(0);
    final metadata = PlayerMetadataController();
    final seek = PlaybackSeekPreview();
    addTearDown(page.dispose);
    addTearDown(metadata.dispose);
    addTearDown(seek.dispose);
    final keys = (
      header: GlobalKey(),
      controls: GlobalKey(),
      volume: GlobalKey(),
      expanded: GlobalKey(),
      compact: GlobalKey(),
    );
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
    Map<String, Object> snapshot() => {
      'cache_bytes': cache.currentSizeBytes,
      'cache_count': cache.currentSize,
      'live_images': cache.liveImageCount,
      'rss_bytes': ProcessInfo.currentRss,
    };
    final snapshots = <String, Map<String, Object>>{'empty': snapshot()};
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          libraryCollectionsProvider.overrideWith(_Collections.new),
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => Stream.value(item),
          ),
          playQueueProvider.overrideWith((ref) => Stream.value([item])),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(PlaybackState(queueIndex: 0)),
          ),
          playerCollectionTrackProvider.overrideWith(
            (ref, item) async => Track(
              id: item.id,
              name: item.title,
              artistName: item.artist ?? '',
              albumName: '',
              duration: item.duration?.inSeconds ?? 0,
            ),
          ),
          systemVolumeProvider.overrideWith((ref) => Stream.value(0.5)),
        ],
        child: MaterialApp(
          theme: theme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SafeArea(
              child: ValueListenableBuilder<int>(
                valueListenable: page,
                builder: (context, value, _) => !mornye
                    ? MaterialPlayerLayout(
                        mediaItem: item,
                        metadata: metadata,
                        seekPreview: seek,
                        colorScheme: theme.colorScheme,
                        showLyrics: value == 1,
                        lyricsBuilder: (_) => ListView.builder(
                          itemCount: 200,
                          itemBuilder: (_, index) => Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text('Lyric line $index'),
                          ),
                        ),
                        onOpenQueue: () {},
                      )
                    : MornyePlayerLayout(
                        mediaItem: item,
                        metadata: metadata,
                        seekPreview: seek,
                        colorScheme: theme.colorScheme,
                        page: value,
                        motionArtwork: MornyePlayerArtwork(mediaItem: item),
                        insetArtwork: true,
                        artworkTopInset: 0,
                        artworkKeys: keys,
                        lyricsControlsHidden: false,
                        lyricsOptionsOpen: false,
                        lyricsBuilder: (_) => ListView.builder(
                          itemCount: 200,
                          itemBuilder: (_, index) => Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text('Lyric line $index'),
                          ),
                        ),
                        lyricsOptions: null,
                        onPageChanged: (value) => page.value = value,
                        onTrackNavigation: (_, _) async {},
                        onMoreActions: (_, _, _) async {},
                      ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() => probe.wait(const Duration(seconds: 1)));
    await tester.pump();
    snapshots['expanded'] = snapshot();
    await probe.measure('player_lyrics_transitions', () async {
      for (final value in [1, 0, 1, 0]) {
        page.value = value;
        await probe.wait(const Duration(milliseconds: 500));
      }
    });
    if (mornye) {
      await probe.measure('player_lyrics_queue_transitions', () async {
        for (final value in [1, 0, 2, 0]) {
          page.value = value;
          await probe.wait(const Duration(milliseconds: 500));
        }
      });
    }
    snapshots['after_panels'] = snapshot();
    // Allow the queue's small thumbnail, but not a second full-size decode.
    expect(
      cache.currentSizeBytes,
      lessThan((snapshots['expanded']!['cache_bytes']! as int) * 1.25),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => probe.wait(const Duration(milliseconds: 500)));
    snapshots['unmounted'] = snapshot();
    await probe.finish(
      metadata: {
        'fixture':
            'Production ${mornye ? 'MornyePlayerLayout' : 'MaterialPlayerLayout'}, local 2400px static cover; '
            'synthetic lyrics/queue and no playback or persistent data',
        'style': style,
        'cache_snapshots': snapshots,
      },
    );
  });
}
