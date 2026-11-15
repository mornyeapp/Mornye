import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/network_offline_actions.dart';

UnifiedLibraryItem _item(String path) => UnifiedLibraryItem(
  id: path,
  trackName: 'Song',
  artistName: 'Artist',
  albumName: 'Album',
  filePath: path,
  addedAt: DateTime(2026),
  source: LibraryItemSource.local,
);

Future<void> _pump(
  WidgetTester tester,
  UnifiedLibraryItem item, {
  required ThemeData theme,
  TextDirection direction = TextDirection.ltr,
  double inset = 0,
}) => tester.pumpWidget(
  MaterialApp(
    theme: theme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Directionality(
      textDirection: direction,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox.square(
          dimension: 160,
          child: OfflineAvailabilityCover(
            item: item,
            inset: inset,
            child: const SizedBox.square(
              key: ValueKey('cover'),
              dimension: 160,
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  const server = 'network://nas/song.flac';

  testWidgets('the badge takes the corner free of the play button', (
    tester,
  ) async {
    await _pump(tester, _item(server), theme: ThemeData(), inset: 4);
    final cover = tester.getRect(find.byKey(const ValueKey('cover')));
    final badge = tester.getRect(
      find.ancestor(
        of: find.byType(AppIcon),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect(badge.left, cover.left + 4);
    expect(badge.bottom, cover.bottom - 4);
    // A grid card's play button sits at the opposite corner, end 4, bottom 4.
    expect(badge.right, lessThan(cover.right - 4 - 48));
  });

  testWidgets('the corner follows the reading direction', (tester) async {
    await _pump(
      tester,
      _item(server),
      theme: ThemeData(),
      direction: TextDirection.rtl,
    );
    final cover = tester.getRect(find.byKey(const ValueKey('cover')));
    final badge = tester.getRect(
      find.ancestor(
        of: find.byType(AppIcon),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect(badge.right, cover.right);
  });

  for (final mornye in [false, true]) {
    testWidgets('the badge uses the tonal icon container (Mornye: $mornye)', (
      tester,
    ) async {
      final theme = mornye
          ? MornyeTheme.build(Brightness.dark)
          : ThemeData(colorSchemeSeed: Colors.teal);
      await _pump(tester, _item(server), theme: theme);
      // The nearest box is the badge; Mornye's page transition adds its own.
      final decoration =
          tester
                  .widget<DecoratedBox>(
                    find
                        .ancestor(
                          of: find.byType(AppIcon),
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      final icon = tester.widget<AppIcon>(find.byType(AppIcon));
      expect(decoration.color, theme.colorScheme.secondaryContainer);
      expect(icon.color, theme.colorScheme.onSecondaryContainer);
      expect(icon.fill, 1);
    });
  }

  testWidgets('a song only on this device shows no badge', (tester) async {
    await _pump(tester, _item('/music/song.flac'), theme: ThemeData());
    expect(find.byType(AppIcon), findsNothing);
  });
}
