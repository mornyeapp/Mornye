import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/screens/now_playing_screen.dart';
import 'package:mornye/services/app_orientation.dart';
import 'package:mornye/utils/android_tv.dart';

class _PlayerRoute extends NowPlayingRoute {
  _PlayerRoute() : super(child: const SizedBox());

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => const SizedBox.expand();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const portrait = ['DeviceOrientation.portraitUp'];
  const player = [
    'DeviceOrientation.portraitUp',
    'DeviceOrientation.landscapeLeft',
    'DeviceOrientation.landscapeRight',
  ];
  final requests = <List<String>>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    requests.clear();
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        requests.add((call.arguments as List<dynamic>).cast<String>());
      }
      return null;
    });
  });
  tearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );

  Future<NavigatorState> pumpApp(WidgetTester tester) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        navigatorObservers: [AppOrientationObserver()],
        home: const Scaffold(body: Text('Library')),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, [portrait]);
    return key.currentState!;
  }

  test('startup requests portrait before the first route is built', () async {
    await setAppOrientation();
    expect(requests, [portrait]);
  });

  test('TV stays landscape in setup, library and full player', () async {
    debugAndroidTvOverride = true;
    addTearDown(() => debugAndroidTvOverride = null);
    await setAppOrientation();
    await setAppOrientation(playerVisible: true);
    await setAppOrientation();
    expect(
      requests,
      List.filled(3, [
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]),
    );
  });

  testWidgets('only the full player enables landscape; sheets inherit it', (
    tester,
  ) async {
    final navigator = await pumpApp(tester);
    navigator.push(_PlayerRoute());
    await tester.pumpAndSettle();
    expect(requests, [portrait, player]);

    showModalBottomSheet<void>(
      context: navigator.context,
      builder: (_) =>
          const SizedBox(height: 100, child: Text('Player options')),
    );
    await tester.pumpAndSettle();
    expect(requests, [portrait, player]);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(requests, [portrait, player]);

    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Album')),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, [portrait, player, portrait]);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(requests, [portrait, player, portrait, player]);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(requests, [portrait, player, portrait, player, portrait]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelled dismissal keeps rotation; completed drag locks it', (
    tester,
  ) async {
    final navigator = await pumpApp(tester);
    final route = _PlayerRoute();
    navigator.push(route);
    await tester.pumpAndSettle();
    route.startDrag();
    route.updateDrag(
      DragUpdateDetails(
        globalPosition: const Offset(0, 240),
        delta: const Offset(0, 240),
        primaryDelta: 240,
      ),
      600,
    );
    await tester.pump();
    route.cancelDrag();
    await tester.pumpAndSettle();
    expect(requests, [portrait, player]);
    route.startDrag();
    route.endDrag(
      DragEndDetails(
        primaryVelocity: 1200,
        velocity: const Velocity(pixelsPerSecond: Offset(0, 1200)),
      ),
      600,
    );
    await tester.pumpAndSettle();
    expect(requests, [portrait, player, portrait]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing and replacing routes cannot leave landscape enabled', (
    tester,
  ) async {
    final navigator = await pumpApp(tester);
    final firstPlayer = _PlayerRoute();
    navigator.push(firstPlayer);
    await tester.pumpAndSettle();
    final secondPlayer = _PlayerRoute();
    navigator.push(secondPlayer);
    await tester.pumpAndSettle();
    navigator.removeRoute(firstPlayer);
    await tester.pumpAndSettle();
    expect(requests, [portrait, player]);
    navigator.pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Settings')),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, [portrait, player, portrait]);
    final thirdPlayer = _PlayerRoute();
    navigator.push(thirdPlayer);
    await tester.pumpAndSettle();
    navigator.removeRoute(thirdPlayer);
    await tester.pumpAndSettle();
    expect(requests, [portrait, player, portrait, player, portrait]);
    expect(tester.takeException(), isNull);
  });
}
