import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/routes/now_playing_route.dart';
import 'package:mornye/widgets/player_underlay.dart';

void main() {
  tearDown(() {
    NowPlayingRoute.moving.value = false;
    NowPlayingRoute.coverLanding.value = false;
  });

  SnapshotController picture(WidgetTester tester) =>
      tester.widget<SnapshotWidget>(find.byType(SnapshotWidget)).controller;

  testWidgets('the page is a picture only while the player moves', (
    tester,
  ) async {
    await tester.pumpWidget(
      const PlayerUnderlay(child: ColoredBox(color: Colors.blue)),
    );
    expect(picture(tester).allowSnapshotting, isFalse);

    NowPlayingRoute.moving.value = true;
    await tester.pump();
    expect(picture(tester).allowSnapshotting, isTrue);

    NowPlayingRoute.moving.value = false;
    await tester.pump();
    expect(picture(tester).allowSnapshotting, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a cover that starts or ends its landing takes a new picture', (
    tester,
  ) async {
    await tester.pumpWidget(
      const PlayerUnderlay(child: ColoredBox(color: Colors.blue)),
    );
    NowPlayingRoute.moving.value = true;
    await tester.pump();
    var retaken = 0;
    void count() => retaken++;
    final controller = picture(tester)..addListener(count);

    NowPlayingRoute.coverLanding.value = true;
    expect(retaken, 1);
    await tester.pump();
    NowPlayingRoute.coverLanding.value = false;
    expect(retaken, 2);
    await tester.pump();
    controller.removeListener(count);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a touched page is live for the rest of the move', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: PlayerUnderlay(child: ColoredBox(color: Colors.blue)),
      ),
    );
    NowPlayingRoute.moving.value = true;
    await tester.pump();
    expect(picture(tester).allowSnapshotting, isTrue);

    final touch = await tester.startGesture(const Offset(100, 100));
    await tester.pump();
    expect(picture(tester).allowSnapshotting, isFalse);
    await touch.up();
    await tester.pump();
    expect(picture(tester).allowSnapshotting, isFalse);

    // The next move takes a picture again.
    NowPlayingRoute.moving.value = false;
    await tester.pump();
    NowPlayingRoute.moving.value = true;
    await tester.pump();
    expect(picture(tester).allowSnapshotting, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a touch on a resting page changes nothing', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: PlayerUnderlay(child: ColoredBox(color: Colors.blue)),
      ),
    );
    await tester.tapAt(const Offset(100, 100));
    await tester.pump();
    NowPlayingRoute.moving.value = true;
    await tester.pump();
    expect(picture(tester).allowSnapshotting, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a disabled underlay always paints the live page', (
    tester,
  ) async {
    await tester.pumpWidget(
      const PlayerUnderlay(
        enabled: false,
        child: ColoredBox(color: Colors.blue),
      ),
    );
    NowPlayingRoute.moving.value = true;
    await tester.pump();
    expect(picture(tester).allowSnapshotting, isFalse);

    await tester.pumpWidget(
      const PlayerUnderlay(child: ColoredBox(color: Colors.blue)),
    );
    expect(picture(tester).allowSnapshotting, isTrue);
    expect(tester.takeException(), isNull);
  });
}
