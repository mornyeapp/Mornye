import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/remote_playback.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_player_queue.dart';
import 'package:mornye/widgets/player_queue_sheet.dart';
import 'package:mornye/widgets/swipe_progress_haptic.dart';

class _Player extends MusicPlayerController {
  final removed = <String>[];
  final playedNext = <MediaItem>[];

  @override
  Future<bool> playQueuedItemNext(MediaItem item) async {
    playedNext.add(item);
    return true;
  }

  @override
  void removeQueuedItem(MediaItem item) => removed.add(item.id);
}

class _Settings extends SettingsNotifier {
  _Settings(this.initial);

  final AppSettings initial;

  @override
  AppSettings build() => initial;
}

class _Remote implements RemotePlayback {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _queue = [
  for (final name in ['Current', 'Next', 'Last'])
    MediaItem(id: name, title: name, artist: 'Artist'),
];

void main() {
  const hapticsChannel = MethodChannel('com.zarz.mornye/haptics');
  late List<double> haptics;

  setUp(() {
    haptics = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hapticsChannel, (call) async {
          if (call.method == 'pulse') {
            haptics.add((call.arguments as Map)['intensity'] as double);
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hapticsChannel, null);
  });

  Future<_Player> pump(
    WidgetTester tester, {
    required bool mornye,
    TextDirection direction = TextDirection.ltr,
    bool locked = false,
    bool swipeToQueue = true,
    bool remote = false,
    bool asSheet = false,
  }) async {
    final player = _Player();
    final theme = mornye
        ? MornyeTheme.build(Brightness.dark)
        : AppTheme.light();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(
            () => _Settings(
              AppSettings(queueLocked: locked, swipeToQueue: swipeToQueue),
            ),
          ),
          playerUiEnabledProvider.overrideWith((ref) => true),
          if (remote) activeRemotePlaybackProvider.overrideWithValue(_Remote()),
          musicPlayerControllerProvider.overrideWithValue(player),
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => Stream.value(_queue.first),
          ),
          playQueueProvider.overrideWith((ref) => Stream.value(_queue)),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(PlaybackState(queueIndex: 0)),
          ),
        ],
        child: MaterialApp(
          theme: theme,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Directionality(
            textDirection: direction,
            child: Scaffold(
              body: asSheet
                  ? Builder(
                      builder: (context) => TextButton(
                        onPressed: () =>
                            showPlayerQueueSheet(context, theme.colorScheme),
                        child: const Text('Open'),
                      ),
                    )
                  : mornye
                  ? MornyePlayerQueue(colorScheme: theme.colorScheme)
                  : PlayerQueueSheet(
                      colorScheme: theme.colorScheme,
                      scrollController: ScrollController(),
                    ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (asSheet) {
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
    }
    return player;
  }

  /// A slow drag, so its release is not a fling.
  Future<void> slowDrag(WidgetTester tester, String title, double dx) async {
    await tester.timedDrag(
      find.text(title),
      Offset(dx, 0),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
  }

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';
    for (final direction in TextDirection.values) {
      // Toward the row's end: rightward left to right, leftward right to
      // left.
      final towardEnd = direction == TextDirection.ltr ? 260.0 : -260.0;

      testWidgets('$style ${direction.name}: toward the end plays a copy '
          'next, toward the start still removes', (tester) async {
        final player = await pump(tester, mornye: mornye, direction: direction);
        final rest = tester.getTopLeft(find.text('Last'));

        final gesture = await tester.startGesture(
          tester.getCenter(find.text('Last')),
        );
        for (var i = 0; i < 26; i++) {
          await gesture.moveBy(Offset(towardEnd / 26, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        // The song rows' strip and commit pulse.
        expect(find.text('Play next'), findsOneWidget);
        expect(
          haptics.where(
            (value) => value >= SwipeProgressHaptic.commitIntensity,
          ),
          hasLength(1),
        );
        await gesture.up();
        await tester.pumpAndSettle();

        expect(player.playedNext.map((item) => item.id), ['Last']);
        expect(player.playedNext.single, same(_queue[2]));
        expect(player.removed, isEmpty);
        expect(find.text('Playing next'), findsOneWidget);
        // The entry springs back in place.
        expect(tester.getTopLeft(find.text('Last')), rest);

        await slowDrag(tester, 'Next', -towardEnd * 2.4);
        expect(player.removed, ['Next']);
        expect(player.playedNext, hasLength(1));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('$style: a locked queue refuses the swipe', (tester) async {
      final player = await pump(tester, mornye: mornye, locked: true);
      await slowDrag(tester, 'Last', 260);
      await slowDrag(tester, 'Next', -600);
      expect(player.playedNext, isEmpty);
      expect(player.removed, isEmpty);
      expect(find.text('Playing next'), findsNothing);
    });

    testWidgets('$style: screen readers get Play next on the row', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final player = await pump(tester, mornye: mornye);
      final node = tester.getSemantics(find.text('Last'));
      final labels = [
        for (final id in node.getSemanticsData().customSemanticsActionIds!)
          CustomSemanticsAction.getAction(id)!.label,
      ];
      expect(labels, contains('Play next'));
      expect(labels, isNot(contains('Add to queue')));
      final id = node.getSemanticsData().customSemanticsActionIds!.firstWhere(
        (id) => CustomSemanticsAction.getAction(id)!.label == 'Play next',
      );
      node.owner!.performAction(node.id, SemanticsAction.customAction, id);
      await tester.pumpAndSettle();
      expect(player.playedNext.map((item) => item.id), ['Last']);
      semantics.dispose();
    });
  }

  testWidgets('the Up Next sheet shows the confirmation over itself', (
    tester,
  ) async {
    final player = await pump(tester, mornye: false, asSheet: true);
    await slowDrag(tester, 'Last', 260);
    expect(player.playedNext.map((item) => item.id), ['Last']);
    final sheet = tester.getRect(find.byType(DraggableScrollableSheet));
    final message = tester.getRect(find.text('Playing next'));
    expect(sheet.contains(message.center), isTrue);
    // Hit-testable: drawn above the sheet, not under it.
    expect(find.text('Playing next').hitTestable(), findsOneWidget);
  });

  testWidgets('the playing song does not swipe to play next', (tester) async {
    final player = await pump(tester, mornye: false);
    await slowDrag(tester, 'Current', 260);
    expect(player.playedNext, isEmpty);
  });

  testWidgets('with Swipe songs to queue off, only removal swipes', (
    tester,
  ) async {
    final player = await pump(tester, mornye: false, swipeToQueue: false);
    await slowDrag(tester, 'Last', 260);
    expect(player.playedNext, isEmpty);
    await slowDrag(tester, 'Next', -600);
    expect(player.removed, ['Next']);
  });

  testWidgets('another device playing the queue offers no copy', (
    tester,
  ) async {
    final player = await pump(tester, mornye: true, remote: true);
    await slowDrag(tester, 'Last', 260);
    expect(player.playedNext, isEmpty);
  });
}
