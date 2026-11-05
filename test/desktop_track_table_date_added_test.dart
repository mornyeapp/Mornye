import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/widgets/desktop/track_table.dart';

void main() {
  group('TrackTable dateAdded support', () {
    final row1 = TrackTableRow(
      id: '1',
      title: 'First Song',
      dateAdded: DateTime.utc(2026, 1, 10),
    );
    final row2 = TrackTableRow(
      id: '2',
      title: 'Second Song',
      dateAdded: DateTime.utc(2026, 3, 15),
    );
    final rowNoDate = TrackTableRow(
      id: '3',
      title: 'No Date Song',
    );

    test('compareTrackTableRows sorts by dateAdded correctly', () {
      // Ascending: earlier dates first
      expect(
        compareTrackTableRows(row1, row2, TrackTableColumn.dateAdded) < 0,
        isTrue,
      );
      expect(
        compareTrackTableRows(row2, row1, TrackTableColumn.dateAdded) > 0,
        isTrue,
      );
      // Missing date comes last
      expect(
        compareTrackTableRows(row1, rowNoDate, TrackTableColumn.dateAdded) < 0,
        isTrue,
      );
      expect(
        compareTrackTableRows(rowNoDate, row1, TrackTableColumn.dateAdded) > 0,
        isTrue,
      );
    });

    testWidgets('renders dateAdded column header and values', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverTrackTable(
                  rows: [row1, row2],
                  columns: const [
                    TrackTableColumn.title,
                    TrackTableColumn.dateAdded,
                  ],
                  selectedIds: const {},
                  onSelect: (_, _, _) {},
                  onActivate: (_) {},
                ),
              ],
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify column header exists
      expect(find.text('Date added'), findsOneWidget);
      // Verify formatted date string exists in the table
      expect(find.text('2026-01-10'), findsOneWidget);
      expect(find.text('2026-03-15'), findsOneWidget);
    });
  });
}
