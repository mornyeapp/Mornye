import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/routes/now_playing_route.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/audio_quality_badges.dart';
import 'package:mornye/widgets/material_player_layout.dart';
import 'package:mornye/widgets/player_details_sheet.dart';
import 'package:mornye/widgets/player_gesture_regions.dart';

MediaItem _item(String id, {String? source}) => MediaItem(
  id: id,
  title: id,
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  extras: {'source': source ?? '/music/$id.flac'},
);

class _FooterRoute extends NowPlayingRoute {
  _FooterRoute(this.onOpenQueue) : super(child: const SizedBox());

  final VoidCallback onOpenQueue;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => PlayerQueueSwipeRegion(
    onOpenQueue: onOpenQueue,
    child: const ColoredBox(
      key: ValueKey('gesture-player'),
      color: Colors.black,
    ),
  );
}

void main() {
  testWidgets('metadata and mode changes leave the player visual intact', (
    tester,
  ) async {
    final read = Completer<Map<String, dynamic>>();
    final metadata = PlayerMetadataController(readMetadata: (_) => read.future);
    final seekPreview = PlaybackSeekPreview();
    final playback = StreamController<PlaybackState>.broadcast();
    addTearDown(metadata.dispose);
    addTearDown(seekPreview.dispose);
    addTearDown(playback.close);
    final item = _item('First');
    final pending = metadata.load(item);
    var visualBuilds = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackStateProvider.overrideWith((ref) => playback.stream),
          playerCollectionTrackProvider.overrideWith(
            (ref, item) async => Track(
              id: item.id,
              name: item.title,
              artistName: item.artist ?? '',
              albumName: item.album ?? '',
              duration: 180,
              source: 'local',
            ),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: MaterialPlayerLayout(
                mediaItem: item,
                metadata: metadata,
                seekPreview: seekPreview,
                colorScheme: Theme.of(context).colorScheme,
                showLyrics: true,
                lyricsBuilder: (_) {
                  visualBuilds++;
                  return const SizedBox.expand();
                },
                onOpenQueue: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final beforeMetadata = visualBuilds;
    read.complete({
      'explicit': true,
      'format': 'FLAC',
      'sample_rate': 48000,
      'bit_depth': 24,
    });
    await pending;
    await tester.pumpAndSettle();
    expect(visualBuilds, beforeMetadata);
    expect(
      tester
          .widget<ExplicitTrackTitle>(find.byType(ExplicitTrackTitle))
          .explicit,
      isTrue,
    );
    const quality = 'FLAC  ·  24-bit  ·  48 kHz';
    final qualityWidget = tester.widget<Text>(find.text(quality));

    playback.add(
      PlaybackState(
        processingState: AudioProcessingState.ready,
        updatePosition: const Duration(seconds: 45),
        shuffleMode: AudioServiceShuffleMode.all,
        repeatMode: AudioServiceRepeatMode.one,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(visualBuilds, beforeMetadata);
    expect(find.text('0:45'), findsOneWidget);
    expect(
      identical(tester.widget<Text>(find.text(quality)), qualityWidget),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('details retain their captured item when playback changes', (
    tester,
  ) async {
    final read = Completer<Map<String, dynamic>>();
    final metadata = PlayerMetadataController(
      readMetadata: (path) => path.startsWith('content://')
          ? read.future
          : Future.value({'title': 'Second tags'}),
    );
    addTearDown(metadata.dispose);
    final first = _item('First', source: 'content://library/first.flac');
    await metadata.load(first);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showPlayerDetailsSheet(
                context,
                Theme.of(context).colorScheme,
                metadata: metadata,
                mediaItem: first,
              ),
              child: const Text('Details'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);
    await metadata.load(_item('Second'));
    read.complete({'title': 'First tags'});
    await tester.pumpAndSettle();
    expect(find.text('First tags'), findsOneWidget);
    expect(find.text('Second tags'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('footer opens the queue upwards and dismisses downwards', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    var queueOpens = 0;
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const SizedBox()),
    );
    navigator.currentState!.push(_FooterRoute(() => queueOpens++));
    await tester.pumpAndSettle();
    final footer = find.byKey(const ValueKey('gesture-player'));
    await tester.fling(footer, const Offset(0, -80), 600);
    await tester.pumpAndSettle();
    expect(queueOpens, 1);
    expect(footer, findsOneWidget);
    await tester.fling(footer, const Offset(0, 240), 1000);
    await tester.pumpAndSettle();
    expect(queueOpens, 1);
    expect(footer, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
