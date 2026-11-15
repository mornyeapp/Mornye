import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/album_track_order.dart';
import 'package:mornye/providers/album_track_sort_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/album_track_sort_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _album = (album: 'Example Album', artist: 'Example Artist');
const _songs = ['First', 'Second', 'Third'];

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('each album keeps its own choice across a restart', () async {
    final first = ProviderContainer();
    addTearDown(first.dispose);
    first
        .read(albumTrackChoicesProvider.notifier)
        .setSort(_album, AlbumTrackSort.mostPlayed);
    await _flush();
    await _flush();

    final restarted = ProviderContainer();
    addTearDown(restarted.dispose);
    final choices = restarted.read(albumTrackChoicesProvider.notifier);
    await _flush();
    await _flush();
    // Spelling differences between pages must not split an album.
    expect(
      choices.of((album: 'EXAMPLE ALBUM', artist: 'example artist')).sort,
      AlbumTrackSort.mostPlayed,
    );
    expect(
      choices.of((album: 'Example Album', artist: 'Someone Else')).sort,
      AlbumTrackSort.album,
    );
  });

  test('a custom order survives a switch to another sort', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final choices = container.read(albumTrackChoicesProvider.notifier);
    choices.setCustom(_album, ['Third', 'First']);
    expect(container.read(albumTrackRanksProvider(_album)), {
      'third': -2,
      'first': -1,
    });
    choices.setSort(_album, AlbumTrackSort.album);
    expect(container.read(albumTrackRanksProvider(_album)), isNull);
    choices.setSort(_album, AlbumTrackSort.custom);
    expect(container.read(albumTrackRanksProvider(_album)), {
      'third': -2,
      'first': -1,
    });
  });

  for (final mornye in [false, true]) {
    testWidgets('the button offers the sorts (Mornye: $mornye)', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.dark) : null,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: Center(
                child: AlbumTrackSortButton(albumKey: _album, songs: _songs),
              ),
            ),
          ),
        ),
      );
      Future<void> openMenu() async {
        await tester.tap(find.byType(AlbumTrackSortButton));
        await tester.pumpAndSettle();
      }

      AlbumTrackSort sort() =>
          container.read(albumTrackChoicesProvider.notifier).of(_album).sort;

      await openMenu();
      await tester.tap(find.text('Most Played'));
      await tester.pumpAndSettle();
      expect(sort(), AlbumTrackSort.mostPlayed);

      await openMenu();
      await tester.tap(find.text('Custom Order'));
      await tester.pumpAndSettle();
      // Opening the editor already selects the order it shows.
      expect(sort(), AlbumTrackSort.custom);
      for (final song in _songs) {
        expect(find.text(song), findsOneWidget);
      }
      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      list.onReorderItem?.call(0, 2);
      await tester.pump();
      expect(
        container.read(albumTrackChoicesProvider.notifier).of(_album).custom,
        [
          albumTrackRankKey('Second'),
          albumTrackRankKey('Third'),
          albumTrackRankKey('First'),
        ],
      );
      expect(tester.takeException(), isNull);
    });
  }
}
