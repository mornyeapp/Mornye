import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/selection_mode_mixin.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/desktop/desktop_selection.dart';
import 'package:mornye/widgets/desktop/hover_play_button.dart';
import 'package:mornye/widgets/desktop/library_drop_target.dart';
import 'package:mornye/widgets/desktop/track_table.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:mornye/widgets/track_card.dart';

Widget _app(Widget child, {bool mornye = false}) => ProviderScope(
  child: MaterialApp(
    theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  ),
);

Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(
    tester.getCenter(finder),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _click(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(
    tester.getCenter(finder),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.up();
  await tester.pump();
}

/// A song table over [SelectionModeMixin], the way the detail screens use it.
class _TableHost extends StatefulWidget {
  const _TableHost({required this.rows, this.onActivate, this.onDelete});

  final List<TrackTableRow> rows;
  final ValueChanged<String>? onActivate;
  final ValueChanged<Set<String>>? onDelete;

  @override
  State<_TableHost> createState() => _TableHostState();
}

class _TableHostState extends State<_TableHost>
    with SelectionModeMixin<_TableHost> {
  @override
  Widget build(BuildContext context) => DesktopListScope(
    onSelectAll: () => selectAll(widget.rows.map((row) => row.id)),
    onClearSelection: isSelectionMode ? exitSelectionMode : null,
    onDelete: widget.onDelete == null
        ? null
        : () => widget.onDelete!({...selectedIds}),
    onActivate: () => widget.onActivate?.call(selectionAnchorId ?? ''),
    child: CustomScrollView(
      slivers: [
        SliverTrackTable(
          rows: widget.rows,
          columns: const [
            TrackTableColumn.number,
            TrackTableColumn.title,
            TrackTableColumn.artist,
            TrackTableColumn.duration,
          ],
          selectedIds: selectedIds,
          onSelect: applyDesktopClick,
          onActivate: (id) => widget.onActivate?.call(id),
        ),
      ],
    ),
  );
}

const _rows = [
  TrackTableRow(
    id: 'b',
    number: 1,
    title: 'Bravo',
    artist: 'Zed',
    duration: Duration(minutes: 3),
  ),
  TrackTableRow(
    id: 'a',
    number: 2,
    title: 'Alpha',
    artist: 'Mike',
    duration: Duration(minutes: 5),
  ),
  TrackTableRow(
    id: 'c',
    number: 3,
    title: 'Charlie',
    artist: 'Ann',
    duration: Duration(minutes: 1),
  ),
];

List<String> _shownTitles(WidgetTester tester) {
  final titles = ['Alpha', 'Bravo', 'Charlie'];
  final positions = {
    for (final title in titles) title: tester.getTopLeft(find.text(title)).dy,
  };
  return titles..sort((a, b) => positions[a]!.compareTo(positions[b]!));
}

void main() {
  setUp(() {
    debugDesktopPlatformOverride = true;
    DesktopDoubleClick.reset();
  });

  tearDown(() {
    debugDesktopPlatformOverride = null;
    DesktopDoubleClick.reset();
  });

  List<List<ContextMenuAction>> menu(List<String> log) => [
    [
      ContextMenuAction(
        icon: Icons.play_arrow,
        label: 'Play',
        onSelected: () => log.add('play'),
      ),
    ],
    [
      ContextMenuAction(
        icon: Icons.delete_outline,
        label: 'Delete',
        destructive: true,
        onSelected: () => log.add('delete'),
      ),
    ],
  ];

  Widget card(List<String> log) => Builder(
    builder: (context) => TrackCard(
      leading: const SizedBox(width: 40),
      title: 'Song',
      onTap: () {},
      onLongPress: () => log.add('long-press'),
      onContextMenu: (position) =>
          showContextMenu(context, position: position, groups: menu(log)),
    ),
  );

  group('context menus', () {
    testWidgets('Material right-click opens the long-press actions', (
      tester,
    ) async {
      final log = <String>[];
      await tester.pumpWidget(_app(card(log)));

      await _rightClick(tester, find.text('Song'));
      expect(find.byType(MenuItemButton), findsNWidgets(2));
      expect(find.text('Play'), findsOneWidget);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(log, ['delete']);
      expect(find.byType(MenuItemButton), findsNothing);
    });

    testWidgets('Escape closes the Material menu without an action', (
      tester,
    ) async {
      final log = <String>[];
      await tester.pumpWidget(_app(card(log)));

      await _rightClick(tester, find.text('Song'));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      expect(log, isEmpty);
    });

    testWidgets('Mornye right-click opens the Mornye context menu', (
      tester,
    ) async {
      final log = <String>[];
      await tester.pumpWidget(_app(card(log), mornye: true));

      await _rightClick(tester, find.text('Song'));
      expect(find.byType(MornyeContextMenu), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);

      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      expect(log, ['play']);
      expect(find.byType(MornyeContextMenu), findsNothing);
    });

    testWidgets('Shift+F10 opens the menu of the item clicked last', (
      tester,
    ) async {
      final log = <String>[];
      await tester.pumpWidget(_app(DesktopListScope(child: card(log))));

      await _click(tester, find.text('Song'));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.text('Play'), findsOneWidget);
    });

    testWidgets('phones keep the long press and ignore right-clicks', (
      tester,
    ) async {
      debugDesktopPlatformOverride = false;
      final log = <String>[];
      await tester.pumpWidget(_app(card(log)));

      await _rightClick(tester, find.text('Song'));
      expect(find.text('Play'), findsNothing);

      await tester.longPress(find.text('Song'));
      expect(log, ['long-press']);
    });
  });

  group('song table', () {
    testWidgets('header clicks sort ascending, descending, then restore', (
      tester,
    ) async {
      await tester.pumpWidget(_app(const _TableHost(rows: _rows)));
      expect(_shownTitles(tester), ['Bravo', 'Alpha', 'Charlie']);

      await tester.tap(find.text('Title'));
      await tester.pump();
      expect(_shownTitles(tester), ['Alpha', 'Bravo', 'Charlie']);

      await tester.tap(find.text('Title'));
      await tester.pump();
      expect(_shownTitles(tester), ['Charlie', 'Bravo', 'Alpha']);

      await tester.tap(find.text('Title'));
      await tester.pump();
      expect(_shownTitles(tester), ['Bravo', 'Alpha', 'Charlie']);

      await tester.tap(find.text('Duration'));
      await tester.pump();
      expect(_shownTitles(tester), ['Charlie', 'Bravo', 'Alpha']);
    });

    testWidgets('quality sorts by its numbers', (tester) async {
      expect(
        compareTrackTableRows(
          const TrackTableRow(id: 'x', title: 'x', quality: '24-bit/96kHz'),
          const TrackTableRow(id: 'y', title: 'y', quality: '16-bit/44.1kHz'),
          TrackTableColumn.quality,
        ),
        greaterThan(0),
      );
      expect(
        compareTrackTableRows(
          const TrackTableRow(id: 'x', title: 'x'),
          const TrackTableRow(id: 'y', title: 'y', quality: 'MP3'),
          TrackTableColumn.quality,
        ),
        greaterThan(0),
      );
    });

    testWidgets('click activates, modifier clicks toggle and extend', (
      tester,
    ) async {
      final activated = <String>[];
      await tester.pumpWidget(
        _app(_TableHost(rows: _rows, onActivate: activated.add)),
      );
      final state = tester.state<_TableHostState>(find.byType(_TableHost));

      // A plain click acts like a tap on a phone row and selects nothing.
      await _click(tester, find.text('Bravo'));
      expect(activated, ['b']);
      expect(state.selectedIds, isEmpty);
      expect(state.isSelectionMode, isFalse);

      final toggle = defaultTargetPlatform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(toggle);
      await _click(tester, find.text('Alpha'));
      await _click(tester, find.text('Charlie'));
      expect(state.selectedIds, {'a', 'c'});
      expect(state.isSelectionMode, isTrue);
      await _click(tester, find.text('Alpha'));
      await tester.sendKeyUpEvent(toggle);
      expect(state.selectedIds, {'c'});
      expect(activated, ['b']);

      // Shift extends from the anchor (Charlie) to Bravo in shown order.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await _click(tester, find.text('Bravo'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(state.selectedIds, {'c', 'a', 'b'});
    });

    testWidgets('a double click activates once, Enter activates, Escape '
        'clears', (tester) async {
      final activated = <String>[];
      await tester.pumpWidget(
        _app(_TableHost(rows: _rows, onActivate: activated.add)),
      );
      final state = tester.state<_TableHostState>(find.byType(_TableHost));

      await _click(tester, find.text('Alpha'));
      await _click(tester, find.text('Alpha'));
      expect(activated, ['a']);

      final toggle = defaultTargetPlatform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(toggle);
      await _click(tester, find.text('Bravo'));
      await tester.sendKeyUpEvent(toggle);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(activated, ['a', 'b']);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(state.selectedIds, isEmpty);
      expect(state.isSelectionMode, isFalse);
    });

    testWidgets('a source-sorted table asks its source to sort', (
      tester,
    ) async {
      final requests = <TrackTableSort?>[];
      Widget table(TrackTableSort? sort) => _app(
        CustomScrollView(
          slivers: [
            SliverTrackTable(
              rows: _rows,
              columns: const [
                TrackTableColumn.title,
                TrackTableColumn.artist,
                TrackTableColumn.duration,
              ],
              selectedIds: const {},
              onSelect: (_, _, _) {},
              onActivate: (_) {},
              sort: sort,
              onSort: requests.add,
              sortableColumns: const {
                TrackTableColumn.title,
                TrackTableColumn.artist,
              },
            ),
          ],
        ),
      );
      await tester.pumpWidget(table(null));

      await tester.tap(find.text('Title'));
      await tester.pump();
      // The rows keep the source's order until the source re-sorts them.
      expect(_shownTitles(tester), ['Bravo', 'Alpha', 'Charlie']);
      expect(requests, [(column: TrackTableColumn.title, ascending: true)]);

      await tester.pumpWidget(
        table((column: TrackTableColumn.title, ascending: true)),
      );
      await tester.tap(find.text('Title'));
      await tester.tap(find.text('Duration'));
      await tester.pump();
      expect(requests.last, (column: TrackTableColumn.title, ascending: false));
      expect(requests, hasLength(2));
    });

    testWidgets('select all and Delete act on the whole selection', (
      tester,
    ) async {
      final deleted = <Set<String>>[];
      await tester.pumpWidget(
        _app(_TableHost(rows: _rows, onDelete: deleted.add)),
      );
      final state = tester.state<_TableHostState>(find.byType(_TableHost));

      await _click(tester, find.text('Alpha'));
      final primary = defaultTargetPlatform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(primary);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(primary);
      await tester.pump();
      expect(state.selectedIds, {'a', 'b', 'c'});

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      expect(deleted, [
        {'a', 'b', 'c'},
      ]);
    });
  });

  group('hover play button', () {
    Widget tile(VoidCallback onPlay) => _app(
      Center(
        child: SizedBox.square(
          dimension: 160,
          child: Stack(
            children: [
              const Positioned.fill(child: ColoredBox(color: Colors.grey)),
              DesktopHoverPlayButton(tooltip: 'Play', onPlay: onPlay),
            ],
          ),
        ),
      ),
    );

    testWidgets('Mornye dims the artwork under a small corner button', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          Center(
            child: SizedBox.square(
              dimension: 160,
              child: Stack(
                children: [
                  const Positioned.fill(child: ColoredBox(color: Colors.grey)),
                  DesktopHoverPlayButton(tooltip: 'Play', onPlay: () {}),
                ],
              ),
            ),
          ),
          mornye: true,
        ),
      );
      final scrim = find.byKey(const ValueKey('desktop-hover-scrim'));
      expect(tester.widget<AnimatedOpacity>(scrim).opacity, 0);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      final tile = tester.getRect(find.byType(ColoredBox).last);
      await mouse.addPointer(location: tile.center);
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(scrim).opacity, 1);
      expect(tester.getSize(scrim), tile.size);

      final disc = tester.getRect(
        find.descendant(
          of: find.byType(IconButton),
          matching: find.byType(Container),
        ),
      );
      expect(disc.size, const Size.square(30));
      expect(disc.left - tile.left, 10);
      expect(tile.bottom - disc.bottom, 10);
      await mouse.removePointer();
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('appears while the pointer is on the artwork', (tester) async {
      var played = 0;
      await tester.pumpWidget(tile(() => played++));
      final opacity = find.descendant(
        of: find.byType(DesktopHoverPlayButton),
        matching: find.byType(AnimatedOpacity),
      );
      expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: tester.getCenter(find.byType(ColoredBox).last),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);

      await tester.tap(find.byTooltip('Play'));
      expect(played, 1);
      await mouse.removePointer();
    });

    testWidgets('phones show no hover button', (tester) async {
      debugDesktopPlatformOverride = false;
      await tester.pumpWidget(tile(() {}));
      expect(find.byTooltip('Play'), findsNothing);
    });
  });

  group('drop to import', () {
    final sep = Platform.pathSeparator;
    String path(List<String> parts) => '$sep${parts.join(sep)}';

    test('adds dropped folders and the folders of music files', () {
      final music = path(['Users', 'me', 'Music']);
      final album = path(['Users', 'me', 'Music', 'Album']);
      final downloads = path(['Users', 'me', 'Downloads']);
      final folders = libraryFoldersForDrop([
        album,
        music,
        '$downloads${sep}song.flac',
        '$downloads${sep}other.MP3',
        path(['Users', 'me', 'Desktop', 'notes.txt']),
      ], isDirectory: (path) => path == music || path == album);
      // Album sits inside Music, so scanning Music covers it.
      expect(folders, unorderedEquals([music, downloads]));
    });

    test('ignores drops without music', () {
      expect(
        libraryFoldersForDrop([
          path(['tmp', 'cover.jpg']),
        ], isDirectory: (_) => false),
        isEmpty,
      );
    });
  });
}
