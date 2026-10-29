import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/library_selection_playback_actions.dart';
import 'package:mornye/widgets/library_track_selection_bar.dart';

class _Controller extends MusicPlayerController {
  List<String> enqueued = [];
  bool insertedNext = false;

  @override
  Future<void> enqueueLibraryItems(
    List<UnifiedLibraryItem> items, {
    bool playNext = false,
  }) async {
    enqueued = items.map((item) => item.id).toList();
    insertedNext = playNext;
  }
}

void main() {
  testWidgets(
    'external playback keeps playlist actions without queue controls',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [playerUiEnabledProvider.overrideWithValue(false)],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: LibrarySelectionPlaybackActions(
                items: const [],
                onClose: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Play next'), findsNothing);
      expect(find.text('Add to queue'), findsNothing);
      expect(find.text('Add to playlist'), findsOneWidget);
    },
  );

  for (final mornye in [false, true]) {
    for (final size in [const Size(390, 844), const Size(844, 390)]) {
      testWidgets('batch playback preserves selection order ($mornye, $size)', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final controller = _Controller();
        var closed = false;
        final items = [
          for (final id in ['second', 'first'])
            UnifiedLibraryItem.fromLocalLibrary(
              LocalLibraryItem(
                id: id,
                trackName: id,
                artistName: 'Artist',
                albumName: 'Album',
                filePath: 'content://library/$id.flac',
                scannedAt: DateTime(2026),
              ),
            ),
        ];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              musicPlayerControllerProvider.overrideWithValue(controller),
            ],
            child: MaterialApp(
              theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: LibraryTrackSelectionBar(
                    selectedCount: 2,
                    allSelected: true,
                    onClose: () => closed = true,
                    onToggleSelectAll: () {},
                    bottomPadding: 0,
                    onReEnrich: () {},
                    onConvert: () {},
                    onReplayGain: ({required remove}) {},
                    onDelete: () {},
                    playbackActions: LibrarySelectionPlaybackActions(
                      items: items,
                      onClose: () => closed = true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Play next'));
        await tester.pumpAndSettle();
        expect(controller.enqueued, items.map((item) => item.id));
        expect(controller.insertedNext, isTrue);
        expect(closed, isTrue);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
