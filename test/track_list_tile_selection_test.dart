import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/screens/album_screen.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';
import 'package:mornye/widgets/track_detail_actions.dart';
import 'package:mornye/widgets/track_list_tile.dart';

void main() {
  test('explicit batch selection forces one provider and quality picker', () {
    expect(
      shouldShowBatchDownloadPicker(
        forceQualityPicker: true,
        askQualityBeforeDownload: false,
        allowQualityVariants: false,
      ),
      isTrue,
    );
  });

  const track = Track(
    id: 'track-1',
    name: 'Selected song',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 180,
    trackNumber: 1,
  );

  Widget buildTile({
    bool selectionMode = false,
    bool selected = false,
    VoidCallback? onToggleSelection,
    VoidCallback? onEnterSelectionMode,
    void Function()? onDownload,
  }) {
    return ProviderScope(
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: TrackListTile(
            track: track,
            isInHistory: false,
            onDownload: ({bool forceQualityPicker = false}) =>
                onDownload?.call(),
            leading: const SizedBox(width: 32, child: Text('1')),
            isSelectionMode: selectionMode,
            isSelected: selected,
            onToggleSelection: onToggleSelection,
            onEnterSelectionMode: onEnterSelectionMode,
          ),
        ),
      ),
    );
  }

  testWidgets('selection mode toggles the row without starting a download', (
    tester,
  ) async {
    var toggled = false;
    var downloaded = false;
    await tester.pumpWidget(
      buildTile(
        selectionMode: true,
        selected: true,
        onToggleSelection: () => toggled = true,
        onDownload: () => downloaded = true,
      ),
    );

    expect(find.byType(AnimatedSelectionCheckbox), findsOneWidget);
    await tester.tap(find.text('Selected song'));

    expect(toggled, isTrue);
    expect(downloaded, isFalse);
  });

  testWidgets('long press enters selection mode when the caller enables it', (
    tester,
  ) async {
    var enteredSelection = false;
    await tester.pumpWidget(
      buildTile(onEnterSelectionMode: () => enteredSelection = true),
    );

    await tester.longPress(find.text('Selected song'));

    expect(enteredSelection, isTrue);
  });

  testWidgets('album selection bar is mounted in front of the shell navbar', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var navbarTaps = 0;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            extendBody: true,
            body: const AlbumScreen(
              albumId: 'album-1',
              albumName: 'Album',
              artistName: 'Artist',
              tracks: [track],
            ),
            bottomNavigationBar: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => navbarTaps++,
              child: const SizedBox(height: 80),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Selected song'));
    await tester.longPress(find.text('Selected song'));
    await tester.pumpAndSettle();

    expect(find.byType(SelectionBottomBar), findsOneWidget);
    await tester.tapAt(const Offset(2, 898));
    await tester.pump();

    expect(navbarTaps, 0);
  });
}
