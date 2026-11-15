import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/widgets/lyrics_screen_awake.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();

  @override
  void setKeepScreenOnLyrics(bool enabled) {
    state = state.copyWith(keepScreenOnLyrics: enabled);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  late List<bool> requests;

  setUp(() {
    requests = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'setScreenAwake') {
        requests.add(
          (call.arguments as Map<Object?, Object?>)['enabled']! as bool,
        );
      }
      return null;
    });
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('screen preference defaults on and survives settings round trips', () {
    expect(AppSettings.fromJson({}).keepScreenOnLyrics, isTrue);
    for (final enabled in [false, true]) {
      final settings = const AppSettings().copyWith(
        keepScreenOnLyrics: enabled,
      );
      expect(
        AppSettings.fromJson(settings.toJson()).keepScreenOnLyrics,
        enabled,
      );
    }
  });

  testWidgets('only visible lyrics hold the screen awake and release on exit', (
    tester,
  ) async {
    final visible = ValueNotifier(false);
    addTearDown(visible.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsProvider.overrideWith(_Settings.new)],
        child: MaterialApp(
          home: ValueListenableBuilder(
            valueListenable: visible,
            builder: (context, value, _) =>
                LyricsScreenAwake(visible: value, child: const SizedBox()),
          ),
        ),
      ),
    );
    expect(requests, isEmpty);
    visible.value = true;
    await tester.pump();
    expect(requests, [true]);
    await tester.pump();
    expect(requests, [
      true,
    ], reason: 'No repeated requests on unchanged frames');
    visible.value = false;
    await tester.pump();
    expect(requests, [true, false]);
    visible.value = true;
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(requests, [true, false, true, false]);
  });

  testWidgets(
    'releases in background, under another route, and when disabled',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final container = ProviderContainer(
        overrides: [settingsProvider.overrideWith(_Settings.new)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: navigator,
            home: const LyricsScreenAwake(visible: true, child: SizedBox()),
          ),
        ),
      );
      expect(requests.last, isTrue);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(requests.last, isFalse);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(requests.last, isTrue);
      navigator.currentState!.push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold()),
      );
      await tester.pumpAndSettle();
      expect(requests.last, isFalse);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(requests.last, isTrue);
      container.read(settingsProvider.notifier).setKeepScreenOnLyrics(false);
      await tester.pump();
      expect(requests.last, isFalse);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(requests.last, isFalse);
    },
  );
}
