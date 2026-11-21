import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/mornye_metadata_row.dart';
import 'package:mornye/widgets/mornye_player_details_sheet.dart';
import 'package:mornye/widgets/player_details_sheet.dart';

import 'support/tooltip_finder.dart';

const _item = MediaItem(
  id: 'song',
  title: 'A song',
  artist: 'An artist',
  album: 'An album',
  extras: {'source': 'https://example.com/song.flac'},
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => debugDesktopPlatformOverride = null);

  Future<void> open(
    WidgetTester tester, {
    required bool mornye,
    MediaItem item = _item,
  }) async {
    final metadata = PlayerMetadataController(
      readMetadata: (_) async => const {},
    );
    addTearDown(metadata.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: mornye
              ? MornyeTheme.build(Brightness.light)
              : AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showPlayerDetailsSheet(
                  context,
                  Theme.of(context).colorScheme,
                  metadata: metadata,
                  mediaItem: item,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('Material phones open the shared sheet with its handle', (
    tester,
  ) async {
    await open(tester, mornye: false);
    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(sheet.showDragHandle, isNot(true));
    expect(find.byType(AppSheetHandle), findsOneWidget);
    expect(find.byType(AppBottomSheet), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
    expect(find.text('A song · An artist'), findsOneWidget);
    expect(find.text('An album'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Material desktop opens the details as a dialog', (tester) async {
    debugDesktopPlatformOverride = true;
    await open(tester, mornye: false);
    final dialog = find.byKey(const ValueKey('app-sheet-dialog'));
    expect(dialog, findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Details'), findsOneWidget);
    // The always-visible bar accepts the draggable sheet's controller.
    expect(
      find.descendant(of: dialog, matching: find.byType(Scrollbar)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(findByTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Details'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  for (final desktop in [false, true]) {
    testWidgets(
      'Mornye keeps its glass details on ${desktop ? 'desktop' : 'phones'}',
      (tester) async {
        debugDesktopPlatformOverride = desktop;
        await open(tester, mornye: true);
        expect(find.byType(MornyePlayerDetailsSheet), findsOneWidget);
        expect(find.byType(AppBottomSheet), findsNothing);
        expect(find.byType(AppSheetHandle), findsOneWidget);
        expect(
          find.byKey(const ValueKey('app-sheet-dialog')),
          desktop ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('the Material sheet ends at its last row', (tester) async {
    await open(tester, mornye: false);
    final list = find.byType(ListView);
    final viewport = tester.state<ScrollableState>(
      find.descendant(of: list, matching: find.byType(Scrollable)),
    );
    final screen =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    // Three rows fill their list, and the sheet is no taller than them.
    expect(viewport.position.maxScrollExtent, 0);
    expect(tester.getSize(list).height, lessThan(screen * 0.4));
    expect(
      tester.getBottomLeft(list).dy -
          tester.getBottomLeft(find.text('An album')).dy,
      lessThan(48),
    );
  });

  for (final desktop in [false, true]) {
    testWidgets('the Mornye ${desktop ? 'dialog' : 'sheet'} ends at its '
        'last row', (tester) async {
      debugDesktopPlatformOverride = desktop;
      await open(tester, mornye: true);
      final list = find.byType(CustomScrollView);
      final rows = find.byType(MornyeMetadataRow);
      // Only the list's own padding follows the last row.
      expect(
        tester.getBottomLeft(list).dy - tester.getBottomLeft(rows.last).dy,
        moreOrLessEquals(24),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Mornye decodes the cover at its thumbnail size', (tester) async {
    await open(
      tester,
      mornye: true,
      item: _item.copyWith(artUri: Uri.file('/covers/song.jpg')),
    );
    final image = tester.widget<Image>(
      find.descendant(
        of: find.byType(MornyePlayerDetailsSheet),
        matching: find.byType(Image),
      ),
    );
    final provider = image.image as ResizeImage;
    expect(provider.width, (70 * tester.view.devicePixelRatio).ceil());
    expect(provider.height, isNull);
  });
}
