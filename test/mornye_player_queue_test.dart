import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_player_queue.dart';

class _Player extends MusicPlayerController {
  int? jumpedTo;
  (int, int)? moved;
  bool? shuffled;
  AudioServiceRepeatMode? repeat;

  @override
  Future<void> jumpTo(int index) async => jumpedTo = index;
  @override
  void moveQueueItem(int oldIndex, int newIndex) =>
      moved = (oldIndex, newIndex);
  @override
  Future<void> setShuffle(bool enabled) async => shuffled = enabled;
  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode mode) async =>
      repeat = mode;
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();

  @override
  void setAutoMix(bool enabled) => state = state.copyWith(autoMix: enabled);

  @override
  void setAutoplay(bool enabled) => state = state.copyWith(autoplay: enabled);
}

void main() {
  testWidgets(
    'upcoming queue maps taps and reorders to the complete playback queue',
    (tester) async {
      final player = _Player();
      final queue = [
        for (final name in ['Previous', 'Current', 'Next', 'Last'])
          MediaItem(id: name, title: name, artist: 'Artist'),
      ];
      final theme = MornyeTheme.build(Brightness.dark);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            musicPlayerControllerProvider.overrideWithValue(player),
            currentMediaItemProvider.overrideWithBuild(
              (ref, notifier) => Stream.value(queue[1]),
            ),
            playQueueProvider.overrideWith((ref) => Stream.value(queue)),
            playbackStateProvider.overrideWith(
              (ref) => Stream.value(PlaybackState(queueIndex: 1)),
            ),
          ],
          child: MaterialApp(
            theme: theme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: MornyePlayerQueue(colorScheme: theme.colorScheme),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Previous'), findsNothing);
      expect(find.text('Current'), findsNothing);
      await tester.tap(find.byTooltip('Autoplay off'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Autoplay on'), findsOneWidget);
      expect(find.text('Autoplay from your Library'), findsOneWidget);
      await tester.tap(find.byTooltip('Autoplay on'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Autoplay off'), findsOneWidget);
      await tester.tap(find.byTooltip('AutoMix off'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('AutoMix on'), findsOneWidget);
      await tester.tap(find.byTooltip('AutoMix on'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('AutoMix off'), findsOneWidget);
      await tester.tap(find.text('Last'));
      expect(player.jumpedTo, 3);
      final firstHandle = find.byType(ReorderableDragStartListener).first;
      final drag = await tester.startGesture(tester.getCenter(firstHandle));
      await tester.pump(const Duration(milliseconds: 100));
      await drag.moveBy(const Offset(0, 30));
      await tester.pump();
      await drag.moveBy(const Offset(0, 180));
      await tester.pump(const Duration(milliseconds: 300));
      await drag.up();
      await tester.pumpAndSettle();
      expect(player.moved, (2, 3));
      await tester.tap(find.byIcon(CupertinoIcons.shuffle));
      expect(player.shuffled, isTrue);
      await tester.tap(find.byIcon(CupertinoIcons.repeat));
      expect(player.repeat, AudioServiceRepeatMode.all);
      expect(find.byIcon(CupertinoIcons.ellipsis), findsNothing);
      final shuffleLibrary = AppLocalizations.of(
        tester.element(find.byType(MornyePlayerQueue)),
      ).nowPlayingShuffleLibrary;
      expect(find.text(shuffleLibrary), findsNothing);
      expect(find.text('Next'), findsOneWidget);

      // Switch to History tab
      final historyTab = AppLocalizations.of(
        tester.element(find.byType(MornyePlayerQueue)),
      ).playerQueueTabHistory;
      await tester.tap(find.text(historyTab));
      await tester.pumpAndSettle();
      expect(find.text('Previous'), findsOneWidget);
      await tester.tap(find.text('Previous'));
      expect(player.jumpedTo, 0);

      // Switch back to Queue tab
      final queueTab = AppLocalizations.of(
        tester.element(find.byType(MornyePlayerQueue)),
      ).playerQueueTabQueue;
      await tester.tap(find.text(queueTab));
      await tester.pumpAndSettle();
      expect(find.text('Previous'), findsNothing);
      expect(find.text('Next'), findsOneWidget);

      expect(tester.takeException(), isNull);
    },
  );
}
