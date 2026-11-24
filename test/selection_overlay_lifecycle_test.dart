import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/collection_scaffold.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';

import 'support/tooltip_finder.dart';

Widget _app(ThemeData theme, GlobalKey<NavigatorState> navigator) {
  return ProviderScope(
    child: MaterialApp(
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SelectionOverlayHost(
        child: Navigator(
          key: navigator,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Library')),
          ),
        ),
      ),
    ),
  );
}

void main() {
  for (final mornye in [false, true]) {
    final name = mornye ? 'Mornye' : 'Material';
    final theme = mornye
        ? MornyeTheme.build(Brightness.light)
        : AppTheme.light();

    testWidgets('$name: leaving a collection removes its selection bar', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(_app(theme, navigator));
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => CollectionScaffold(
            scrollController: scroll,
            isSelectionMode: true,
            onExitSelectionMode: () {},
            appBar: const SliverAppBar(title: Text('Album')),
            slivers: const [],
            selectionBar: const Text('Delete 1 track'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Delete 1 track'), findsOneWidget);

      navigator.currentState!.pop();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Library'), findsOneWidget);
      expect(find.text('Delete 1 track'), findsNothing);
    });

    testWidgets('$name: an empty album removes its old selection bar', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      final scroll = ScrollController();
      final hasTracks = ValueNotifier(true);
      addTearDown(scroll.dispose);
      addTearDown(hasTracks.dispose);
      await tester.pumpWidget(_app(theme, navigator));
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => ValueListenableBuilder<bool>(
            valueListenable: hasTracks,
            builder: (_, hasTracks, _) => hasTracks
                ? CollectionScaffold(
                    scrollController: scroll,
                    isSelectionMode: true,
                    onExitSelectionMode: () {},
                    appBar: const SliverAppBar(title: Text('Album')),
                    slivers: const [],
                    selectionBar: const Text('Delete 1 track'),
                  )
                : const Scaffold(body: Text('No tracks found for this album')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Delete 1 track'), findsOneWidget);

      hasTracks.value = false;
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('No tracks found for this album'), findsOneWidget);
      expect(find.text('Delete 1 track'), findsNothing);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('Library'), findsOneWidget);
    });

    testWidgets(
      '$name: leaving Songs clears the bar and allows selecting again',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(_app(theme, navigator));
        for (var visit = 0; visit < 2; visit++) {
          navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => const _SongsSelectionPage(),
            ),
          );
          await tester.pumpAndSettle();
          await tester.longPress(find.text('Song'));
          await tester.pumpAndSettle();
          expect(find.byType(SelectionBottomBar), findsOneWidget);

          if (visit == 1) {
            await tester.tap(findByTooltip('Close'));
            await tester.pumpAndSettle();
            expect(find.byType(SelectionBottomBar), findsNothing);
          }
          await tester.tap(findByTooltip('Back'));
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          expect(find.text('Library'), findsOneWidget);
          expect(find.byType(SelectionBottomBar), findsNothing);
        }
      },
    );
  }
}

// Songs owns a controller directly and hides it in dispose, whereas album
// screens delegate that lifecycle to CollectionScaffold.
class _SongsSelectionPage extends StatefulWidget {
  const _SongsSelectionPage();

  @override
  State<_SongsSelectionPage> createState() => _SongsSelectionPageState();
}

class _SongsSelectionPageState extends State<_SongsSelectionPage> {
  final _selectionOverlay = SelectionOverlayController();

  @override
  void dispose() {
    _selectionOverlay.hide();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Songs'),
        leading: BackButton(onPressed: () => Navigator.pop(context)),
      ),
      body: ListTile(
        title: const Text('Song'),
        onLongPress: () => _selectionOverlay.show(
          context,
          (_) => SelectionBottomBar(
            selectedCount: 1,
            allSelected: true,
            onClose: _selectionOverlay.hide,
            onToggleSelectAll: _selectionOverlay.hide,
            bottomPadding: 0,
            children: const [Text('Delete 1 track')],
          ),
        ),
      ),
    );
  }
}
