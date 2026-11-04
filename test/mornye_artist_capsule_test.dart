import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/mornye_artist_header.dart';
import 'package:mornye/widgets/mornye_chrome.dart';

void main() {
  tearDown(() => debugDesktopPlatformOverride = null);

  Future<void> pumpHeader(
    WidgetTester tester, {
    required List<String> log,
    required bool desktop,
  }) async {
    debugDesktopPlatformOverride = desktop;
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                MornyeArtistHeader(
                  name: 'Artist',
                  showTitle: false,
                  artwork: const ColoredBox(color: Colors.grey),
                  actions: const [],
                  toolbarActions: [
                    HeaderCircleButton(
                      icon: CupertinoIcons.square_arrow_up,
                      tooltip: 'Share',
                      onPressed: () => log.add('share'),
                    ),
                    HeaderMoreButton(
                      groups: () => [
                        [
                          ContextMenuAction(
                            icon: CupertinoIcons.star,
                            label: 'Favorite',
                            onSelected: () => log.add('favorite'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  for (final desktop in [true, false]) {
    final platform = desktop ? 'desktop' : 'mobile';

    testWidgets('$platform groups Share and More at the trailing edge', (
      tester,
    ) async {
      final log = <String>[];
      await pumpHeader(tester, log: log, desktop: desktop);

      final capsule = find.byType(MornyeActionCapsule);
      final bounds = tester.getRect(
        find.descendant(of: capsule, matching: find.byType(MornyeGlass)),
      );
      expect(bounds.right, 900 - (desktop ? 16 : 12));
      // Level with the round back button.
      final back = tester.getRect(find.byTooltip('Back'));
      expect(bounds.center.dy, back.center.dy);
      expect(bounds.height, desktop ? 36 : 44);
      final share = tester.getRect(find.byTooltip('Share'));
      final more = tester.getRect(
        find.byTooltip(
          MaterialLocalizations.of(tester.element(capsule)).showMenuTooltip,
        ),
      );
      expect(share.right, lessThanOrEqualTo(more.left));

      await tester.tap(find.byTooltip('Share'));
      await tester.pumpAndSettle();
      expect(log, ['share']);

      await tester.tapAt(more.center);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Favorite'));
      await tester.pumpAndSettle();
      expect(log, ['share', 'favorite']);
    });
  }

  testWidgets('selection mode leaves the toolbar empty', (tester) async {
    debugDesktopPlatformOverride = false;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: const Scaffold(
            body: CustomScrollView(
              slivers: [
                MornyeArtistHeader(
                  name: 'Artist',
                  showTitle: false,
                  artwork: ColoredBox(color: Colors.grey),
                  actions: [],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byType(MornyeActionCapsule), findsNothing);
  });
}
