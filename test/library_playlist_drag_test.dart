import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_theme.dart';
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
}
