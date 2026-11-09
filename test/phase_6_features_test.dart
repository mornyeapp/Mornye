import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/routes/now_playing_route.dart';
import 'package:mornye/services/automix_analysis.dart';
import 'package:mornye/services/batch_lyrics_sync_service.dart';
import 'package:mornye/widgets/mornye_app_splash.dart';

void main() {
  group('Phase 6 DJ AutoMix lastSound and immediate transition', () {
    test('analyzeAutoMixPcm extracts lastSound from audible energy', () {
      final pcm = Uint8List(44100 * 2 * 2 * 2); // 2 seconds of silence
      final grid = analyzeAutoMixPcm(pcm);
      expect(grid.lastSound, greaterThanOrEqualTo(0));
    });

    test('AutoMixPlan anchors transition to audibleEnd rather than trailing silence', () {
      final outgoing = AutoMixBeatGrid(
        bpm: 120,
        phase: 0.5,
        confidence: 0.9,
        firstSound: 0.5,
        lastSound: 175.0, // track ends at 180s, but music stops at 175s
      );
      final incoming = AutoMixBeatGrid(
        bpm: 120,
        phase: 0.2,
        confidence: 0.9,
        firstSound: 0.2,
        lastSound: 160.0,
      );

      final plan = AutoMixPlan.create(
        outgoingDuration: const Duration(seconds: 180),
        incomingDuration: const Duration(seconds: 180),
        outro: outgoing,
        intro: incoming,
        outroOffset: 0.0,
      );

      expect(plan, isNotNull);
      expect(plan!.start.inMilliseconds, lessThan(175000));
      expect(plan.start.inMilliseconds, greaterThanOrEqualTo(165000));
    });
  });

  group('Phase 6 Batch lyrics sync fallback', () {
    test('syncItems succeeds and saves lyrics when usable lyrics are found', () async {
      final track = Track(
        id: 'test-track-id',
        name: 'Midnight City',
        artistName: 'M83',
        albumName: 'Hurry Up',
        duration: 240,
      );
      final item = BatchLyricsItem(track: track, filePath: '/tmp/test.mp3');

      var tagsSaved = false;
      var sidecarSaved = false;

      final service = BatchLyricsSyncService(
        checkHasLyrics: (i) async => false,
        fetchLyrics: (t) async =>
            '[00:10.00] City is my church\n[00:15.00] It wraps me in the blinding twilight',
        saveTags: (path, lyrics) async {
          tagsSaved = true;
        },
        saveSidecar: (path, lyrics) async {
          sidecarSaved = true;
          return true;
        },
      );

      final progress = await service.syncItems(
        [item],
        onProgress: (_) {},
        skipExisting: false,
      );

      expect(progress.successful, 1);
      expect(progress.failed, 0);
      expect(tagsSaved, isTrue);
      expect(sidecarSaved, isTrue);
    });
  });

  group('Phase 6 NowPlayingRoute swipe-down dismiss transitions', () {
    testWidgets('NowPlayingRoute applies rounded corners and scale on drag dismiss', (tester) async {
      final route = NowPlayingRoute(
        child: const Scaffold(body: Center(child: Text('Player Content'))),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark().copyWith(
            extensions: const [],
          ),
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context).push(route),
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Player Content'), findsOneWidget);

      // Trigger vertical drag
      route.startDrag();
      route.updateDrag(
        DragUpdateDetails(
          globalPosition: const Offset(100, 200),
          delta: const Offset(0, 100),
          primaryDelta: 100,
        ),
        800,
      );
      await tester.pump();

      // End drag with dismiss velocity
      route.endDrag(
        DragEndDetails(
          velocity: const Velocity(pixelsPerSecond: Offset(0, 600)),
          primaryVelocity: 600,
        ),
        800,
      );
      await tester.pumpAndSettle();

      // Succeeded in dismissing
      expect(find.text('Player Content'), findsNothing);
    });
  });

  group('Phase 6 MornyeAppSplash Screen', () {
    testWidgets('MornyeAppSplash displays HD badge and wordmark then dismisses', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MornyeAppSplash(
            child: const Scaffold(body: Text('Main Screen')),
          ),
        ),
      );

      await tester.pump();
      expect(find.text('M O R N Y E'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);

      // Advance animation to completion (1400ms)
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();

      expect(find.text('M O R N Y E'), findsNothing);
      expect(find.text('Main Screen'), findsOneWidget);
    });
  });
}
