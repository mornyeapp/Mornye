import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/player_queue_dismissible.dart';
import 'package:mornye/widgets/player_track_swipe.dart';

void main() {
  final queue = [
    for (var i = 0; i < 3; i++)
      MediaItem(id: '$i', title: 'Song $i', artist: 'Artist $i'),
  ];

  for (final reducedMotion in [false, true]) {
    testWidgets(
      'left swipe advances and right swipe returns without moving cover ($reducedMotion)',
      (tester) async {
        var index = 0;
        final selected = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reducedMotion),
              child: StatefulBuilder(
                builder: (context, setState) {
                  return PlayerTrackSwipe(
                    queue: queue,
                    currentIndex: index,
                    onSelected: (item) async {
                      selected.add(queue.indexOf(item));
                      setState(() => index = queue.indexOf(item));
                    },
                    child: Scaffold(
                      body: Center(
                        child: SizedBox(
                          width: 300,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const PlayerTrackSwipeRegion(
                                child: SizedBox(
                                  key: ValueKey('cover'),
                                  width: 200,
                                  height: 200,
                                  child: ColoredBox(color: Colors.black),
                                ),
                              ),
                              PlayerTrackSwipeTitles(
                                current: queue[index],
                                builder: (item) => Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(item.title),
                                    Text(item.artist!),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        final cover = find.byKey(const ValueKey('cover'));
        final coverRect = tester.getRect(cover);
        final titleX = tester.getTopLeft(find.text('Song 0')).dx;
        final gesture = await tester.startGesture(coverRect.center);
        await gesture.moveBy(const Offset(-110, 0));
        await tester.pump();
        expect(tester.getRect(cover), coverRect);
        expect(tester.getTopLeft(find.text('Song 0')).dx, lessThan(titleX));
        expect(find.text('Song 1'), findsOneWidget);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(selected, [1]);
        expect(tester.getTopLeft(find.text('Song 1')).dx, closeTo(titleX, 0.1));

        await tester.drag(find.text('Song 1'), const Offset(180, 0));
        await tester.pumpAndSettle();
        expect(selected, [1, 0]);
        // At the first song the previous direction resists, then returns.
        await tester.drag(cover, const Offset(200, 0));
        await tester.pumpAndSettle();
        expect(selected, [1, 0]);
        expect(tester.getTopLeft(find.text('Song 0')).dx, closeTo(titleX, 0.1));
        await tester.drag(cover, const Offset(-20, 0));
        await tester.pumpAndSettle();
        expect(selected, [1, 0]);
        await tester.drag(cover, const Offset(-200, 0));
        await tester.pumpAndSettle();
        await tester.drag(cover, const Offset(-200, 0));
        await tester.pumpAndSettle();
        expect(selected, [1, 0, 1, 2]);
        // At the last song, only the next direction is blocked.
        await tester.drag(cover, const Offset(-200, 0));
        await tester.pumpAndSettle();
        expect(selected, [1, 0, 1, 2]);
        await tester.drag(cover, const Offset(200, 0));
        await tester.pumpAndSettle();
        expect(selected, [1, 0, 1, 2, 1]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('neighbor titles build lazily and stay stable across frames', (
    tester,
  ) async {
    final builds = <String, int>{};
    final selected = <MediaItem>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: PlayerTrackSwipe(
                queue: queue,
                currentIndex: 1,
                onSelected: (item) async => selected.add(item),
                child: PlayerTrackSwipeTitles(
                  current: queue[1],
                  builder: (item) {
                    builds.update(
                      item.id,
                      (count) => count + 1,
                      ifAbsent: () => 1,
                    );
                    return Text(item.title);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(builds, {'1': 1});
    expect(find.text('Song 0'), findsNothing);
    expect(find.text('Song 2'), findsNothing);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Song 1')),
    );
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(builds, {'1': 1, '2': 1});
    final nextX = tester.getTopLeft(find.text('Song 2')).dx;
    await gesture.moveBy(const Offset(-10, 0));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.getTopLeft(find.text('Song 2')).dx, lessThan(nextX));
    expect(builds, {'1': 1, '2': 1});

    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    expect(find.text('Song 2'), findsNothing);
    expect(find.text('Song 0'), findsOneWidget);
    expect(builds, {'1': 1, '2': 1, '0': 1});
    await gesture.moveBy(const Offset(10, 0));
    await tester.pump(const Duration(milliseconds: 16));
    final previousX = tester.getTopLeft(find.text('Song 0')).dx;
    await gesture.cancel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getTopLeft(find.text('Song 0')).dx, lessThan(previousX));
    await tester.pump(const Duration(milliseconds: 80));
    expect(builds, {'1': 1, '2': 1, '0': 1});
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(find.text('Song 0'), findsNothing);
    expect(find.text('Song 2'), findsNothing);
    expect(builds, {'1': 1, '2': 1, '0': 1});
    expect(tester.takeException(), isNull);
  });

  testWidgets('neighbor titles refresh with parent, constraints and queue', (
    tester,
  ) async {
    var entries = queue;
    var label = 'original';
    var color = Colors.red;
    var width = 300.0;
    late StateSetter rebuild;
    final builds = <String, int>{};
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Scaffold(
              body: Center(
                child: SizedBox(
                  width: width,
                  child: PlayerTrackSwipe(
                    queue: entries,
                    currentIndex: 1,
                    onSelected: (_) async {},
                    child: PlayerTrackSwipeTitles(
                      current: entries[1],
                      builder: (item) {
                        builds.update(
                          item.id,
                          (count) => count + 1,
                          ifAbsent: () => 1,
                        );
                        return Text(
                          '${item.title} $label',
                          style: TextStyle(color: color),
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Song 1 original')),
    );
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(builds, {'1': 1, '2': 1});

    rebuild(() {
      label = 'updated';
      color = Colors.blue;
    });
    await tester.pump();
    expect(find.text('Song 2 original'), findsNothing);
    expect(find.text('Song 2 updated'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('Song 2 updated')).style!.color,
      Colors.blue,
    );
    expect(builds, {'1': 2, '2': 2});
    await gesture.moveBy(const Offset(-10, 0));
    await tester.pump();
    expect(builds, {'1': 2, '2': 2});

    rebuild(() => width = 240);
    await tester.pump();
    expect(tester.getSize(find.text('Song 2 updated')).width, 240);
    expect(builds, {'1': 3, '2': 3});

    rebuild(() {
      entries = [queue[0], queue[1], queue[2].copyWith(title: 'New metadata')];
    });
    await tester.pump();
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(find.text('Song 2 updated'), findsNothing);
    expect(find.text('New metadata updated'), findsOneWidget);

    rebuild(() => entries = [queue[0], queue[1], queue[0]]);
    await tester.pump();
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(find.text('New metadata updated'), findsNothing);
    expect(find.text('Song 0 updated'), findsOneWidget);
    final replacementBuilds = builds['0'];
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(builds['0'], replacementBuilds);
    expect(find.text('Song 0 updated'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('velocity and interruption', () {
    Future<void> pumpQueue(WidgetTester tester, List<int> selected) =>
        tester.pumpWidget(
          MaterialApp(
            theme: MornyeTheme.build(Brightness.dark),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 300,
                  child: PlayerTrackSwipe(
                    queue: queue,
                    currentIndex: 1,
                    onSelected: (item) async =>
                        selected.add(queue.indexOf(item)),
                    child: PlayerTrackSwipeTitles(
                      current: queue[1],
                      builder: (item) => Text(item.title),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

    /// How far the titles move in the first frame after a 100 px swipe
    /// toward the next song is let go at [speed] pixels a second.
    Future<double> firstFrameTravel(WidgetTester tester, double speed) async {
      final selected = <int>[];
      await pumpQueue(tester, selected);
      final title = find.text('Song 1');
      if (speed == 0) {
        final gesture = await tester.startGesture(tester.getCenter(title));
        for (var i = 0; i < 10; i++) {
          await gesture.moveBy(const Offset(-10, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        // Held still long enough that the release carries no speed.
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.up();
      } else {
        await tester.fling(title, const Offset(-100, 0), speed);
      }
      await tester.pump();
      final released = tester.getTopLeft(title).dx;
      await tester.pump(const Duration(milliseconds: 16));
      final travel = released - tester.getTopLeft(title).dx;
      await tester.pumpAndSettle();
      expect(selected, [2]);
      return travel;
    }

    testWidgets('a flung skip keeps the finger\'s speed', (tester) async {
      final still = await firstFrameTravel(tester, 0);
      final flung = await firstFrameTravel(tester, 1500);
      expect(still, greaterThan(0));
      // At 1500 px/s the finger covers 24 px in a 16 ms frame.
      expect(flung - still, greaterThan(12));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a swipe takes over titles returning to rest where they are', (
      tester,
    ) async {
      final selected = <int>[];
      await pumpQueue(tester, selected);
      final title = find.text('Song 1');
      final rest = tester.getTopLeft(title).dx;
      final first = await tester.startGesture(tester.getCenter(title));
      for (var i = 0; i < 6; i++) {
        await first.moveBy(const Offset(-10, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 200));
      await first.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      final caught = tester.getTopLeft(title).dx;
      expect(caught, inExclusiveRange(rest - 60, rest));

      // The titles follow the finger from where they are drawn instead of
      // finishing their return first.
      final second = await tester.startGesture(
        tester.getCenter(find.byType(PlayerTrackSwipeTitles)),
      );
      await second.moveBy(const Offset(20, 0));
      await tester.pump();
      expect(tester.getTopLeft(title).dx, closeTo(caught + 20, 1));
      await second.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getTopLeft(title).dx, closeTo(caught + 30, 1));
      await second.up();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(title).dx, closeTo(rest, 0.5));
      expect(selected, isEmpty);
      expect(tester.takeException(), isNull);
    });

    for (final mornye in [false, true]) {
      testWidgets('mini player titles flung away keep moving before they '
          'return (Mornye: $mornye)', (tester) async {
        final releases = <double>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.dark) : null,
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 300,
                  child: PlayerTrackSwipe.follow(
                    onRelease: (details, travel) => releases.add(travel),
                    child: PlayerTrackSwipeTitles(
                      current: queue[0],
                      builder: (item) => Text(item.title),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final title = find.text('Song 0');
        final rest = tester.getTopLeft(title).dx;
        // Past the commit distance, where the titles meet resistance.
        await tester.fling(title, const Offset(-60, 0), 1500);
        await tester.pump();
        final released = tester.getTopLeft(title).dx;
        expect(released, lessThan(rest - 48));
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getTopLeft(title).dx, lessThan(released));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(title).dx, closeTo(rest, 0.5));
        expect(releases, hasLength(1));
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('queue left swipe removes just that occurrence', (tester) async {
    final entries = [queue[0], queue[0].copyWith(), queue[1]];
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: Column(
              children: [
                for (final item in entries)
                  PlayerQueueDismissible(
                    key: ObjectKey(item),
                    enabled: !identical(item, entries.first),
                    onRemove: () => setState(() {
                      entries.removeWhere((entry) => identical(entry, item));
                    }),
                    child: SizedBox(
                      width: 320,
                      height: 64,
                      child: Text(item.title),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.drag(
      find.byType(PlayerQueueDismissible).at(1),
      const Offset(280, 0),
    );
    await tester.pumpAndSettle();
    expect(entries, hasLength(3));
    await tester.drag(
      find.byType(PlayerQueueDismissible).at(1),
      const Offset(-280, 0),
    );
    await tester.pumpAndSettle();
    expect(entries.map((item) => item.id), ['0', '1']);
    await tester.drag(
      find.byType(PlayerQueueDismissible).first,
      const Offset(-280, 0),
    );
    await tester.pumpAndSettle();
    expect(entries, hasLength(2));
    expect(tester.takeException(), isNull);
  });
}
