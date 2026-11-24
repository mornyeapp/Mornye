import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/queue_swipe.dart';
import 'package:mornye/widgets/swipe_progress_haptic.dart';
import 'package:mornye/widgets/track_card.dart';

import 'support/fixed_settings.dart';

void main() {
  const hapticsChannel = MethodChannel('com.zarz.mornye/haptics');
  late List<bool> queued;

  /// Intensities sent to the native pulse channel.
  late List<double> haptics;

  /// The usage each pulse asked for; null means media.
  late List<Object?> usages;

  /// Whether a pulse at or above the commit strength was sent.
  bool committedPulse() =>
      haptics.any((value) => value >= SwipeProgressHaptic.commitIntensity);

  setUp(() {
    queued = [];
    haptics = [];
    usages = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hapticsChannel, (call) async {
          if (call.method == 'pulse') {
            final arguments = call.arguments as Map;
            haptics.add(arguments['intensity'] as double);
            usages.add(arguments['usage']);
          }
          return null;
        });
  });

  tearDown(() {
    debugDesktopPlatformOverride = null;
    debugAndroidTvOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hapticsChannel, null);
  });

  /// A song row whose swipe goes through the app's availability rule.
  Widget row(int index, {bool selecting = false}) => Consumer(
    builder: (context, ref, _) => TrackCard(
      leading: const SizedBox.square(dimension: 40),
      title: 'Song $index',
      isSelectionMode: selecting,
      onTap: () {},
      queueSwipe: queueSwipeEnabled(ref)
          ? QueueSwipeActions(({required playNext}) async {
              queued.add(playNext);
              return true;
            })
          : null,
    ),
  );

  Future<void> pumpList(
    WidgetTester tester, {
    bool enabled = true,
    bool mornye = false,
    bool selecting = false,
    TextDirection direction = TextDirection.ltr,
    Widget Function(Widget list)? wrap,
    int count = 30,
  }) async {
    final list = ListView(
      children: [for (var i = 0; i < count; i++) row(i, selecting: selecting)],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(
            () => FixedSettingsNotifier(AppSettings(swipeToQueue: enabled)),
          ),
          playerUiEnabledProvider.overrideWith((ref) => true),
        ],
        child: MaterialApp(
          theme: mornye
              ? MornyeTheme.build(Brightness.light)
              : AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          // The app's messenger: a new confirmation replaces the last one.
          builder: (_, child) => AppScaffoldMessenger(child: child!),
          home: Directionality(
            textDirection: direction,
            child: Scaffold(body: wrap == null ? list : wrap(list)),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder song(int index) => find.text('Song $index');

  /// A slow drag, so its release is not a fling.
  Future<void> slowDrag(WidgetTester tester, Finder finder, Offset by) async {
    await tester.timedDrag(finder, by, const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
  }

  group('direction', () {
    testWidgets('toward the end plays next, toward the start queues last', (
      tester,
    ) async {
      await pumpList(tester);
      await slowDrag(tester, song(0), const Offset(220, 0));
      expect(queued, [true]);
      expect(find.text('Playing next'), findsOneWidget);

      await slowDrag(tester, song(1), const Offset(-220, 0));
      expect(queued, [true, false]);
      expect(find.text('Added to queue'), findsOneWidget);
    });

    testWidgets('right-to-left layouts swap the directions', (tester) async {
      await pumpList(tester, direction: TextDirection.rtl);
      await slowDrag(tester, song(0), const Offset(220, 0));
      await slowDrag(tester, song(1), const Offset(-220, 0));
      expect(queued, [false, true]);
    });

    testWidgets('Mornye rows take the same directions', (tester) async {
      await pumpList(tester, mornye: true);
      await slowDrag(tester, song(0), const Offset(220, 0));
      await slowDrag(tester, song(1), const Offset(-220, 0));
      expect(queued, [true, false]);
    });

    testWidgets('the row springs back and is never removed', (tester) async {
      await pumpList(tester);
      final rest = tester.getTopLeft(song(0));
      await slowDrag(tester, song(0), const Offset(220, 0));
      expect(song(0), findsOneWidget);
      expect(tester.getTopLeft(song(0)), rest);
    });
  });

  group('release', () {
    for (final mornye in [false, true]) {
      testWidgets('a flung row keeps the finger\'s speed before it returns '
          '(Mornye: $mornye)', (tester) async {
        await pumpList(tester, mornye: mornye);
        final rest = tester.getTopLeft(song(0)).dx;
        await tester.fling(song(0), const Offset(100, 0), 1500);
        await tester.pump();
        final released = tester.getTopLeft(song(0)).dx;
        // The touch slop is not part of the swipe.
        expect(released, greaterThan(rest + 70));
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getTopLeft(song(0)).dx, greaterThan(released));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(song(0)).dx, rest);
        expect(queued, [true]);
      });

      testWidgets('a flick back toward rest never carries the row past it '
          '(Mornye: $mornye)', (tester) async {
        await pumpList(tester, mornye: mornye);
        final rest = tester.getTopLeft(song(0)).dx;
        final gesture = await tester.startGesture(tester.getCenter(song(0)));
        var time = Duration.zero;
        for (var i = 0; i < 10; i++) {
          time += const Duration(milliseconds: 16);
          await gesture.moveBy(const Offset(10, 0), timeStamp: time);
          await tester.pump(const Duration(milliseconds: 16));
        }
        // A pause, then a quick flick most of the way back.
        time += const Duration(milliseconds: 300);
        for (var i = 0; i < 5; i++) {
          time += const Duration(milliseconds: 6);
          await gesture.moveBy(const Offset(-10, 0), timeStamp: time);
        }
        await gesture.up(timeStamp: time);
        await tester.pump();
        expect(tester.getTopLeft(song(0)).dx, greaterThan(rest + 20));
        for (var frame = 0; frame < 40; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getTopLeft(song(0)).dx, greaterThanOrEqualTo(rest));
          expect(find.text('Add to queue'), findsNothing);
        }
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(song(0)).dx, rest);
        expect(queued, isEmpty);
      });
    }
  });

  group('threshold', () {
    testWidgets('a short drag does nothing', (tester) async {
      await pumpList(tester);
      await slowDrag(tester, song(0), const Offset(100, 0));
      await slowDrag(tester, song(0), const Offset(-100, 0));
      expect(queued, isEmpty);
      // Soft ticks on the way at most; never the commit pulse.
      expect(committedPulse(), isFalse);
    });

    testWidgets('crossing pulses once and shows the action; coming back '
        'before letting go cancels', (tester) async {
      await pumpList(tester);
      final gesture = await tester.startGesture(tester.getCenter(song(0)));
      for (var i = 0; i < 20; i++) {
        await gesture.moveBy(const Offset(10, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      // The ramp's ticks depend on the real clock's throttle; the commit
      // pulse comes last, once.
      expect(haptics.last, SwipeProgressHaptic.commitIntensity);
      // UI feedback: Android follows the touch feedback setting.
      expect(usages, everyElement('touch'));
      expect(
        haptics.where((value) => value >= SwipeProgressHaptic.commitIntensity),
        hasLength(1),
      );
      final count = haptics.length;
      expect(find.text('Play next'), findsOneWidget);
      for (var i = 0; i < 15; i++) {
        await gesture.moveBy(const Offset(-10, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(queued, isEmpty);
      // Dragging back gives nothing.
      expect(haptics, hasLength(count));
    });

    testWidgets('a fling past half the threshold commits', (tester) async {
      await pumpList(tester);
      await tester.fling(song(0), const Offset(-100, 0), 1500);
      await tester.pumpAndSettle();
      expect(queued, [false]);
    });

    testWidgets('a short fling does not commit', (tester) async {
      await pumpList(tester);
      await tester.fling(song(0), const Offset(40, 0), 1500);
      await tester.pumpAndSettle();
      expect(queued, isEmpty);
    });
  });

  group('availability', () {
    testWidgets('the setting off leaves rows without the swipe', (
      tester,
    ) async {
      await pumpList(tester, enabled: false);
      await slowDrag(tester, song(0), const Offset(220, 0));
      expect(queued, isEmpty);
      expect(find.text('Playing next'), findsNothing);
    });

    testWidgets('desktop and Android TV leave rows without the swipe', (
      tester,
    ) async {
      debugDesktopPlatformOverride = true;
      await pumpList(tester);
      await slowDrag(tester, song(0), const Offset(220, 0));
      debugDesktopPlatformOverride = false;
      debugAndroidTvOverride = true;
      await pumpList(tester, count: 29);
      await slowDrag(tester, song(1), const Offset(220, 0));
      expect(queued, isEmpty);
    });

    testWidgets('selection mode turns the swipe off', (tester) async {
      await pumpList(tester, selecting: true);
      await slowDrag(tester, song(0), const Offset(220, 0));
      expect(queued, isEmpty);
    });

    testWidgets('a touch at the screen edge stays with the system', (
      tester,
    ) async {
      await pumpList(tester);
      final y = tester.getCenter(song(0)).dy;
      await tester.timedDragFrom(
        Offset(8, y),
        const Offset(300, 0),
        const Duration(milliseconds: 600),
      );
      await tester.pumpAndSettle();
      expect(queued, isEmpty);
    });

    testWidgets('rows inside a page view leave the swipe to the pages', (
      tester,
    ) async {
      final controller = PageController();
      addTearDown(controller.dispose);
      await pumpList(
        tester,
        wrap: (list) => PageView(
          controller: controller,
          children: [list, const SizedBox.expand()],
        ),
      );
      await slowDrag(tester, song(0), const Offset(-500, 0));
      expect(queued, isEmpty);
      expect(controller.page, 1);
    });
  });

  group('scrolling', () {
    testWidgets('a vertical drag scrolls the list', (tester) async {
      await pumpList(tester);
      final before = tester.getTopLeft(song(3)).dy;
      await slowDrag(tester, song(3), const Offset(0, -200));
      expect(tester.getTopLeft(song(3)).dy, lessThan(before - 150));
      expect(queued, isEmpty);
      expect(haptics, isEmpty);
    });

    testWidgets('a drag less than twice as wide as tall scrolls', (
      tester,
    ) async {
      await pumpList(tester);
      final before = tester.getTopLeft(song(3)).dy;
      // Wider than tall, so a plain horizontal drag would win the arena.
      await slowDrag(tester, song(3), const Offset(220, -150));
      expect(tester.getTopLeft(song(3)).dy, lessThan(before - 100));
      expect(queued, isEmpty);
    });
  });

  testWidgets('screen readers get both actions on the row', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpList(tester);
    final node = tester.getSemantics(song(0));
    final ids = node.getSemanticsData().customSemanticsActionIds ?? const [];
    final playNext = CustomSemanticsAction.getIdentifier(
      const CustomSemanticsAction(label: 'Play next'),
    );
    final addToQueue = CustomSemanticsAction.getIdentifier(
      const CustomSemanticsAction(label: 'Add to queue'),
    );
    expect(ids, containsAll([playNext, addToQueue]));

    node.owner!.performAction(
      node.id,
      SemanticsAction.customAction,
      addToQueue,
    );
    await tester.pumpAndSettle();
    expect(queued, [false]);
    semantics.dispose();
  });
}
