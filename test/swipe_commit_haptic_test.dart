import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/player_queue_dismissible.dart';
import 'package:mornye/widgets/player_track_swipe.dart';
import 'package:mornye/widgets/swipe_delete_dismissible.dart';

void main() {
  late List<Object?> haptics;

  setUp(() {
    haptics = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  final songs = [
    for (var i = 0; i < 4; i++) MediaItem(id: '$i', title: 'Song $i'),
  ];

  group('Up Next swipe', () {
    late List<MediaItem> entries;
    late MediaItem? playing;
    late StateSetter rebuild;

    Future<void> pumpQueue(
      WidgetTester tester, {
      bool reducedMotion = false,
    }) async {
      entries = songs.take(3).toList();
      playing = entries.first;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reducedMotion),
            child: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return Scaffold(
                  body: Column(
                    children: [
                      for (final item in entries)
                        PlayerQueueDismissible(
                          key: ObjectKey(item),
                          enabled: !identical(item, playing),
                          onRemove: () => setState(() {
                            if (identical(item, playing)) return;
                            entries.removeWhere(
                              (entry) => identical(entry, item),
                            );
                          }),
                          child: SizedBox(
                            width: 320,
                            height: 64,
                            child: Text(item.title),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
    }

    Finder row(String title) => find.ancestor(
      of: find.text(title),
      matching: find.byType(PlayerQueueDismissible),
    );

    // Drags the row past the remove threshold and lets go.
    Future<void> swipe(WidgetTester tester, String title) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.text(title)),
      );
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-80, 0));
      await tester.pump();
      expect(haptics, isEmpty, reason: 'not yet past the threshold');
      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump();
      expect(haptics, ['HapticFeedbackType.mediumImpact']);
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      expect(haptics, hasLength(1), reason: 'one tick per crossing');
      await gesture.up();
    }

    // Lets the slide finish and the collapse run partway.
    Future<void> midCollapse(WidgetTester tester, String title) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(entries, hasLength(3), reason: 'still collapsing');
      final height = tester.getSize(row(title).first).height;
      expect(height, inExclusiveRange(0, 64));
    }

    testWidgets('collapses the row before removing it', (tester) async {
      await pumpQueue(tester);
      final below = tester.getTopLeft(find.text('Song 2')).dy;
      await swipe(tester, 'Song 1');

      final heights = <double>[];
      for (var i = 0; i < 40 && entries.length == 3; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (entries.length == 3) {
          heights.add(tester.getSize(row('Song 1').first).height);
        }
      }
      expect(entries.map((item) => item.id), ['0', '2']);
      expect(heights.where((h) => h > 0 && h < 64), isNotEmpty);
      for (var i = 1; i < heights.length; i++) {
        expect(heights[i], lessThanOrEqualTo(heights[i - 1]));
      }
      expect(heights.last, lessThan(16));
      await tester.pumpAndSettle();
      expect(find.text('Song 1'), findsNothing);
      expect(tester.getTopLeft(find.text('Song 2')).dy, below - 64);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reduced motion removes at once and keeps the haptic', (
      tester,
    ) async {
      await pumpQueue(tester, reducedMotion: true);
      await swipe(tester, 'Song 1');
      for (var i = 0; i < 40 && entries.length == 3; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (entries.length == 3) {
          expect(tester.getSize(row('Song 1').first).height, 64);
        }
      }
      expect(entries.map((item) => item.id), ['0', '2']);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a queue change mid-collapse removes the swiped song only', (
      tester,
    ) async {
      await pumpQueue(tester);
      await swipe(tester, 'Song 2');
      await midCollapse(tester, 'Song 2');
      rebuild(() => entries.insert(0, songs[3]));
      await tester.pumpAndSettle();
      expect(entries.map((item) => item.id), ['3', '0', '1']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a row that starts playing mid-collapse stays', (tester) async {
      await pumpQueue(tester);
      await swipe(tester, 'Song 1');
      await midCollapse(tester, 'Song 1');
      rebuild(() => playing = entries[1]);
      await tester.pumpAndSettle();
      expect(entries.map((item) => item.id), ['0', '1', '2']);
      expect(tester.getSize(row('Song 1').first).height, 64);
      expect(
        tester.getTopLeft(find.text('Song 1')).dx,
        tester.getTopLeft(find.text('Song 0')).dx,
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a download swipe ticks once at its threshold', (tester) async {
    var dismissed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: SwipeDeleteDismissible(
                dismissKey: const ValueKey('download'),
                onDismissed: (_) => dismissed++,
                child: const SizedBox(height: 64, child: Text('Download')),
              ),
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Download')),
    );
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    expect(haptics, isEmpty);
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(haptics, hasLength(1));
    // Back under the threshold and over again ticks again.
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(haptics, hasLength(2));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(dismissed, 1);
  });

  testWidgets('a title swipe ticks where letting go would skip', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerTrackSwipe(
          queue: songs,
          currentIndex: 0,
          onSelected: (_) async {},
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const PlayerTrackSwipeRegion(
                      child: SizedBox(width: 200, height: 200),
                    ),
                    PlayerTrackSwipeTitles(
                      current: songs[0],
                      builder: (item) => Text(item.title),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final cover = tester.getCenter(find.byType(PlayerTrackSwipeRegion).first);
    final gesture = await tester.startGesture(cover);
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    expect(haptics, isEmpty);
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(haptics, hasLength(1));
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    expect(haptics, hasLength(1));
    // No song before the first one: a right swipe never ticks.
    await gesture.moveBy(const Offset(260, 0));
    await tester.pump();
    expect(haptics, hasLength(1));
    await gesture.cancel();
    await tester.pumpAndSettle();
  });

  testWidgets('a follow swipe ticks at its commit travel', (tester) async {
    final releases = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerTrackSwipe.follow(
          onRelease: (_, travel) => releases.add(travel),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: PlayerTrackSwipeTitles(
                  current: songs[0],
                  builder: (item) => Text(item.title),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Song 0')),
    );
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    expect(haptics, isEmpty);
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    expect(haptics, hasLength(1));
    // Back inside the commit travel and out again on the other side.
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(haptics, hasLength(1));
    await gesture.moveBy(const Offset(70, 0));
    await tester.pump();
    expect(haptics, hasLength(2));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(releases.single, greaterThanOrEqualTo(48));
  });
}
