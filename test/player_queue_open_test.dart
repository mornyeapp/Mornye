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

final _defaultQueue = [
  for (var i = 0; i < 40; i++)
    MediaItem(id: 'song$i', title: 'Song $i', artist: 'Artist'),
];

/// A queue entry that counts the rows built for it: only a real row reads
/// the title.
class _CountedItem extends MediaItem {
  const _CountedItem(this.index, this.builds)
    : super(id: 'song$index', title: 'Song $index', artist: 'Artist');

  final int index;
  final Set<int> builds;

  @override
  String get title {
    builds.add(index);
    return super.title;
  }
}

/// Shows the Material queue for a player on [playing]; [sheet] opens it the
/// way Now Playing does, otherwise it fills the page like the desktop panel.
Future<(ScrollController, StreamController<MediaItem?>)> _pump(
  WidgetTester tester, {
  required int playing,
  bool sheet = false,
  List<MediaItem>? queue,
}) async {
  final songs = queue ?? _defaultQueue;
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
      playQueueProvider.overrideWith((ref) => Stream.value(songs)),
      playbackStateProvider.overrideWith(
        (ref) => Stream.value(PlaybackState(queueIndex: playing)),
      ),
    ],
  );
  addTearDown(container.dispose);
  current.add(songs[playing]);
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

/// The gap between two rows of the connected group.
const _rowGap = 2.0;

double _listTop(WidgetTester tester) =>
    tester.getTopLeft(find.byType(ReorderableListView)).dy;

void main() {
  testWidgets('the queue opens at the playing song, one song above it', (
    tester,
  ) async {
    final (scroll, _) = await _pump(tester, playing: 20);

    expect(_row(0), findsNothing);
    expect(_row(20), findsOneWidget);
    final rowHeight = tester.getSize(_row(20)).height + _rowGap;
    expect(scroll.offset, moreOrLessEquals(19 * rowHeight));
    expect(tester.getTopLeft(_row(19)).dy, moreOrLessEquals(_listTop(tester)));
  });

  testWidgets('a song change while open never moves the list', (tester) async {
    final (scroll, current) = await _pump(tester, playing: 20);
    final opened = scroll.offset;

    current.add(_defaultQueue[30]);
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

  testWidgets('a long queue opens far down without building the songs '
      'before the playing one', (tester) async {
    final builds = <int>{};
    final queue = [for (var i = 0; i < 3000; i++) _CountedItem(i, builds)];
    final (scroll, _) = await _pump(tester, playing: 2500, queue: queue);

    final rowHeight = tester.getSize(_row(2500)).height + _rowGap;
    expect(scroll.offset, moreOrLessEquals(2499 * rowHeight));
    expect(
      tester.getTopLeft(_row(2499)).dy,
      moreOrLessEquals(_listTop(tester)),
    );
    // Only the first screen, measured before the jump, and the screen the
    // jump lands on.
    expect(builds.length, lessThan(80));
    expect(builds.where((index) => index > 40 && index < 2400), isEmpty);

    // No empty box stays behind: the rows kept above the viewport are real,
    // and so are the songs before them once the user scrolls back.
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SizedBox && widget.key is ObjectKey,
        skipOffstage: false,
      ),
      findsNothing,
    );
    scroll.jumpTo(scroll.offset - 6 * rowHeight);
    await tester.pumpAndSettle();
    expect(_row(2494), findsOneWidget);
    expect(_row(2496), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short queue gets a sheet that ends at its last song', (
    tester,
  ) async {
    await _pump(
      tester,
      playing: 0,
      sheet: true,
      queue: _defaultQueue.sublist(0, 2),
    );
    final list = find.byType(ReorderableListView);
    // The list's own padding is all that follows the last song.
    expect(
      tester.getBottomLeft(list).dy - tester.getBottomLeft(_row(1)).dy,
      moreOrLessEquals(24),
    );
    expect(
      tester.getSize(list).height,
      moreOrLessEquals(2 * tester.getSize(_row(0)).height + _rowGap + 24),
    );
  });

  testWidgets('the songs are one connected group of rows', (tester) async {
    await _pump(tester, playing: 0, queue: _defaultQueue.sublist(0, 3));
    Finder surface(int index) =>
        find.ancestor(of: _row(index), matching: find.byType(Material)).first;
    BorderRadius corners(int index) =>
        ((tester.widget<Material>(surface(index)).shape!
                    as RoundedRectangleBorder)
                .borderRadius
            as BorderRadius);

    // Each row is its own surface, a small gap from the next.
    expect(
      tester.getTopLeft(surface(1)).dy - tester.getBottomLeft(surface(0)).dy,
      moreOrLessEquals(_rowGap),
    );
    // Large corners close the group, small ones join the rows inside it.
    expect(corners(0).topLeft.x, greaterThan(corners(0).bottomLeft.x));
    expect(corners(1).topLeft, corners(1).bottomLeft);
    expect(corners(2).bottomLeft.x, greaterThan(corners(2).topLeft.x));
    expect(tester.takeException(), isNull);
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
