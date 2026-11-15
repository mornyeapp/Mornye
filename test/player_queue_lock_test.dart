import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_player_queue.dart';
import 'package:mornye/widgets/player_queue_dismissible.dart';
import 'package:mornye/widgets/player_queue_sheet.dart';

import 'support/tooltip_finder.dart';

class _Player extends MusicPlayerController {
  final removed = <String>[];
  final moved = <(int, int)>[];
  int? jumpedTo;

  @override
  Future<void> jumpTo(int index) async => jumpedTo = index;

  @override
  void moveQueueItem(int oldIndex, int newIndex) =>
      moved.add((oldIndex, newIndex));
  @override
  void removeQueuedItem(MediaItem item) => removed.add(item.id);
}

class _Settings extends SettingsNotifier {
  _Settings(this.initial);

  final AppSettings initial;

  @override
  AppSettings build() => initial;

  @override
  void setQueueLocked(bool locked) =>
      state = state.copyWith(queueLocked: locked);
}

final _queue = [
  for (final name in ['Current', 'Next', 'Last'])
    MediaItem(id: name, title: name, artist: 'Artist'),
];

Future<(_Player, ProviderContainer)> _pump(
  WidgetTester tester, {
  required bool mornye,
  bool locked = false,
}) async {
  final player = _Player();
  final theme = mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.light();
  final container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith(
        () => _Settings(AppSettings(queueLocked: locked)),
      ),
      musicPlayerControllerProvider.overrideWithValue(player),
      currentMediaItemProvider.overrideWithBuild(
        (ref, notifier) => Stream.value(_queue.first),
      ),
      playQueueProvider.overrideWith((ref) => Stream.value(_queue)),
      playbackStateProvider.overrideWith(
        (ref) => Stream.value(PlaybackState(queueIndex: 0)),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: theme,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: mornye
              ? MornyePlayerQueue(colorScheme: theme.colorScheme)
              : PlayerQueueSheet(
                  colorScheme: theme.colorScheme,
                  scrollController: ScrollController(),
                ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (player, container);
}

Future<void> _swipeAway(WidgetTester tester, String title) async {
  await tester.drag(find.text(title), const Offset(-600, 0));
  await tester.pumpAndSettle();
}

void main() {
  for (final mornye in [false, true]) {
    testWidgets('the header lock blocks dragging and swiping ($mornye)', (
      tester,
    ) async {
      final (player, container) = await _pump(tester, mornye: mornye);
      expect(find.byType(ReorderableDragStartListener), findsWidgets);

      await tester.tap(findByTooltip('Lock queue'));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).queueLocked, isTrue);
      expect(findByTooltip('Unlock queue'), findsOneWidget);
      expect(find.byType(ReorderableDragStartListener), findsNothing);
      for (final row in tester.widgetList<PlayerQueueDismissible>(
        find.byType(PlayerQueueDismissible),
      )) {
        expect(row.enabled, isFalse);
      }
      await _swipeAway(tester, 'Next');
      expect(player.removed, isEmpty);
      // Tapping a song still plays it.
      await tester.tap(find.text('Last'));
      expect(player.jumpedTo, 2);

      await tester.tap(findByTooltip('Unlock queue'));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).queueLocked, isFalse);
      expect(find.byType(ReorderableDragStartListener), findsWidgets);
      await _swipeAway(tester, 'Next');
      expect(player.removed, ['Next']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a saved lock applies when the queue opens', (tester) async {
    await _pump(tester, mornye: false, locked: true);
    expect(findByTooltip('Unlock queue'), findsOneWidget);
    expect(find.byType(ReorderableDragStartListener), findsNothing);
  });

  test('the lock defaults to off and round-trips through JSON', () {
    expect(const AppSettings().queueLocked, isFalse);
    expect(AppSettings.fromJson(const {}).queueLocked, isFalse);
    final on = const AppSettings().copyWith(queueLocked: true);
    expect(on.toJson()['queueLocked'], isTrue);
    expect(AppSettings.fromJson(on.toJson()).queueLocked, isTrue);
  });
}
