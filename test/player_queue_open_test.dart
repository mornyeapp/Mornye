import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/player_queue_sheet.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

final _queue = [
  for (var i = 0; i < 40; i++)
    MediaItem(id: 'song$i', title: 'Song $i', artist: 'Artist'),
];

/// Shows the Material queue for a player on [playing]; [sheet] opens it the
/// way Now Playing does, otherwise it fills the page like the desktop panel.
Future<(ScrollController, StreamController<MediaItem?>)> _pump(
  WidgetTester tester, {
  required int playing,
  bool sheet = false,
}) async {
  final current = StreamController<MediaItem?>();
  addTearDown(current.close);
  final scroll = ScrollController();
  addTearDown(scroll.dispose);
  final container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith(_Settings.new),
      musicPlayerControllerProvider.overrideWithValue(MusicPlayerController()),
      currentMediaItemProvider.overrideWithBuild(
        (ref, notifier) => current.stream,
      ),
      playQueueProvider.overrideWith((ref) => Stream.value(_queue)),
      playbackStateProvider.overrideWith(
        (ref) => Stream.value(PlaybackState(queueIndex: playing)),
      ),
    ],
  );
  addTearDown(container.dispose);
  current.add(_queue[playing]);
  final theme = AppTheme.light();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: theme,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: sheet
              ? Builder(
                  builder: (context) => TextButton(
                    onPressed: () =>
                        showPlayerQueueSheet(context, theme.colorScheme),
                    child: const Text('Open queue'),
                  ),
                )
              : PlayerQueueSheet(
                  colorScheme: theme.colorScheme,
                  scrollController: scroll,
                ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (sheet) {
    await tester.tap(find.text('Open queue'));
    await tester.pumpAndSettle();
  }
  return (scroll, current);
}

Finder _row(int index) => find.widgetWithText(ListTile, 'Song $index');

double _listTop(WidgetTester tester) =>
    tester.getTopLeft(find.byType(ReorderableListView)).dy;

void main() {
  testWidgets('the queue opens at the playing song, one song above it', (
    tester,
  ) async {
    final (scroll, _) = await _pump(tester, playing: 20);

    expect(_row(0), findsNothing);
    expect(_row(20), findsOneWidget);
    final rowHeight = tester.getSize(_row(20)).height;
    expect(scroll.offset, moreOrLessEquals(19 * rowHeight));
    expect(tester.getTopLeft(_row(19)).dy, moreOrLessEquals(_listTop(tester)));
  });

  testWidgets('a song change while open never moves the list', (tester) async {
    final (scroll, current) = await _pump(tester, playing: 20);
    final opened = scroll.offset;

    current.add(_queue[30]);
    await tester.pumpAndSettle();
    expect(scroll.offset, opened);

    // The user can still scroll back to the songs already played.
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(_row(0), findsOneWidget);
  });

  for (final playing in [0, 1]) {
    testWidgets('song ${playing + 1} opens at the top', (tester) async {
      final (scroll, _) = await _pump(tester, playing: playing);
      expect(scroll.offset, 0);
      expect(_row(0), findsOneWidget);
    });
  }

  testWidgets('the last song opens at the end without overscroll', (
    tester,
  ) async {
    final (scroll, _) = await _pump(tester, playing: 39);
    expect(scroll.offset, scroll.position.maxScrollExtent);
    expect(_row(39), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Now Playing sheet opens at the playing song and scrolls '
      'back before it closes', (tester) async {
    await _pump(tester, playing: 20, sheet: true);
    expect(_row(20), findsOneWidget);
    expect(_row(0), findsNothing);
    final sheetTop = tester.getTopLeft(find.byType(PlayerQueueSheet)).dy;

    // Dragging down first shows the songs before it, in the same sheet size.
    await tester.drag(_row(20), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerQueueSheet), findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(PlayerQueueSheet)).dy,
      moreOrLessEquals(sheetTop),
    );
    expect(_row(17), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
