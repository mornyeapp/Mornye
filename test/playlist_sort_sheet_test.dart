import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/playlist_sort.dart';
import 'package:mornye/widgets/playlist_sort_sheet.dart';

void main() {
  group('PlaylistSortSheet', () {
    testWidgets('renders sort options in sheet and selects one', (
      tester,
    ) async {
      PlaylistSortMode? selectedMode;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  selectedMode = await showPlaylistSortSheet(
                    context: context,
                    currentSort: PlaylistSortMode.custom,
                    hasDateAdded: true,
                  );
                },
                child: const Text('Open Sort Sheet'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Sort Sheet'));
      await tester.pumpAndSettle();

      // Check that options appear
      expect(find.text('Custom order'), findsOneWidget);
      expect(find.text('Date added (newest first)'), findsOneWidget);
      expect(find.text('Title (A-Z)'), findsOneWidget);

      // Tap on Date added (newest first)
      await tester.tap(find.text('Date added (newest first)'));
      await tester.pumpAndSettle();

      expect(selectedMode, PlaylistSortMode.dateAddedDesc);
    });

    testWidgets('omits date added options when hasDateAdded is false', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  showPlaylistSortSheet(
                    context: context,
                    currentSort: PlaylistSortMode.titleAsc,
                    hasDateAdded: false,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Date added (newest first)'), findsNothing);
      expect(find.text('Title (A-Z)'), findsOneWidget);
    });

    testWidgets('opens context menu when anchor context is provided', (
      tester,
    ) async {
      PlaylistSortMode? selectedMode;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (btnContext) => buildPlaylistSortButton(
                context: btnContext,
                currentSort: PlaylistSortMode.custom,
                hasDateAdded: true,
                onSortChanged: (mode) => selectedMode = mode,
              ),
            ),
          ),
        ),
      );

      final button = find.byKey(const ValueKey('playlist-sort-button'));
      expect(button, findsOneWidget);

      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(find.text('Title (A-Z)'), findsOneWidget);
      await tester.tap(find.text('Title (A-Z)'));
      await tester.pumpAndSettle();

      expect(selectedMode, PlaylistSortMode.titleAsc);
    });
  });
}
