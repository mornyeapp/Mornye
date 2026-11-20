import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/utils/ordered_range_selection.dart';
import 'package:mornye/widgets/drag_select.dart';
import 'package:mornye/widgets/library_playlist_drag_source.dart';
import 'package:mornye/widgets/track_card.dart';

void main() {
  for (final grid in [false, true]) {
    testWidgets('Material ${grid ? 'grid' : 'list'} selects and drops tracks', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final selected = <String>{};
      final playlist = <String>[];
      final dropped = <String>[];
      var taps = 0;
      var dragging = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  DragTarget<String>(
                    onAcceptWithDetails: (details) {
                      dropped.add(details.data);
                      playlist.addAll(selected);
                    },
                    builder: (_, candidates, _) => SizedBox(
                      key: const ValueKey('playlist'),
                      width: 240,
                      height: 100,
                      child: Text(
                        candidates.isEmpty ? 'Playlist' : 'Drop here',
                      ),
                    ),
                  ),
                  for (final id in ['a', 'b'])
                    SizedBox(
                      width: 240,
                      height: grid ? 280 : 100,
                      child: LibraryPlaylistDragSource<String>(
                        key: ValueKey(id),
                        data: id,
                        onSelect: () => setState(() => selected.add(id)),
                        onDragStarted: () => setState(() => dragging = true),
                        onDragEnd: () => setState(() => dragging = false),
                        feedbackBuilder: (_) => Material(
                          child: Text('Dragging ${selected.length}'),
                        ),
                        child: grid
                            ? TrackGridCard(
                                cover: const ColoredBox(color: Colors.blue),
                                title: 'Song $id',
                                isSelected: selected.contains(id),
                                onTap: () => taps++,
                              )
                            : TrackCard(
                                leading: const SizedBox.square(dimension: 56),
                                title: 'Song $id',
                                isSelectionMode: selected.isNotEmpty,
                                isSelected: selected.contains(id),
                                onTap: () => taps++,
                              ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      // A normal tap still opens track details.
      await tester.tap(find.text('Song a'));
      await tester.pumpAndSettle();
      expect(taps, 1);

      // Holding without moving selects; releasing outside a target retains it.
      var gesture = await tester.startGesture(
        tester.getCenter(find.text('Song a')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(selected, {'a'});
      expect(dragging, isTrue);
      expect(find.text('Dragging 1'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(selected, {'a'});
      expect(playlist, isEmpty);
      expect(dragging, isFalse);

      // Another hold can select and drag the batch directly onto its playlist.
      gesture = await tester.startGesture(
        tester.getCenter(find.text('Song b')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Dragging 2'), findsOneWidget);
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('playlist'))),
      );
      await tester.pump();
      expect(find.text('Drop here'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(playlist, ['a', 'b']);
      expect(dropped, ['b']);
      expect(dragging, isFalse);
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('once selecting, a hold on another song slides to select', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const ids = ['a', 'b', 'c', 'd', 'e'];
    final selected = <String>{};
    Set<String>? base;
    var drags = 0;
    late StateSetter rebuild;
    final slide = DragSelectController(
      onUpdate: (anchor, current) => rebuild(
        () => applySlideSelection(
          selected: selected,
          base: base!,
          visibleItems: ids,
          anchor: anchor as String,
          target: current as String,
        ),
      ),
    );
    addTearDown(slide.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return ListView(
                children: [
                  for (final id in ids)
                    SizedBox(
                      key: ValueKey(id),
                      height: 100,
                      child: Builder(
                        builder: (context) {
                          // The Library Songs list: the first hold, and a
                          // hold on a selected song, drag to a playlist.
                          final drag =
                              selected.isEmpty || selected.contains(id);
                          return DragSelectItem(
                            controller: slide,
                            id: id,
                            child: LibraryPlaylistDragSource<String>(
                              data: id,
                              enabled: drag,
                              onSelect: () => setState(() => selected.add(id)),
                              onDragStarted: () => drags++,
                              onDragEnd: () {},
                              feedbackBuilder: (_) =>
                                  const Material(child: Text('Dragging')),
                              child: TrackCard(
                                leading: const SizedBox.square(dimension: 56),
                                title: 'Song $id',
                                isSelectionMode: selected.isNotEmpty,
                                isSelected: selected.contains(id),
                                onTap: () {},
                                onLongPress: drag
                                    ? null
                                    : () {
                                        base = {...selected};
                                        setState(() => selected.add(id));
                                        slide.begin(id);
                                      },
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );

    // The first hold drags, and sliding it selects nothing more.
    var gesture = await tester.startGesture(
      tester.getCenter(find.text('Song a')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(drags, 1);
    expect(find.text('Dragging'), findsOneWidget);
    await gesture.moveBy(const Offset(0, 200));
    await tester.pump();
    expect(selected, {'a'});
    expect(slide.isActive, isFalse);
    await gesture.up();
    await tester.pumpAndSettle();

    // A hold on another song selects along the finger instead of dragging,
    // although that song turns into a playlist drag source once selected.
    gesture = await tester.startGesture(tester.getCenter(find.text('Song c')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(selected, {'a', 'c'});
    expect(slide.isActive, isTrue);
    await gesture.moveBy(const Offset(0, 200));
    await tester.pump();
    expect(selected, {'a', 'c', 'd', 'e'});
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    expect(selected, {'a', 'c', 'd'});
    expect(drags, 1);
    expect(find.text('Dragging'), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(slide.isActive, isFalse);

    // A hold on a selected song drags the batch again.
    gesture = await tester.startGesture(tester.getCenter(find.text('Song d')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(drags, 2);
    expect(find.text('Dragging'), findsOneWidget);
    expect(slide.isActive, isFalse);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, {'a', 'c', 'd'});
    expect(tester.takeException(), isNull);
  });
}
