import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
