import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/widgets/artist_featured_album_card.dart';

const _album = ArtistAlbum(
  id: 'album-1',
  name: 'Example album',
  releaseDate: '2026-02-03',
  totalTracks: 12,
  albumType: 'album',
  artists: 'Example artist',
);

Future<void> _pump(
  WidgetTester tester, {
  VoidCallback? onTap,
  VoidCallback? onAdd,
  Future<Map<String, dynamic>> Function()? loadMetadata,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ArtistFeaturedAlbumCard(
            album: _album,
            onTap: onTap ?? () {},
            onAdd: onAdd ?? () {},
            loadMetadata: loadMetadata,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a provider without a note gets the album summary', (
    tester,
  ) async {
    await _pump(tester, loadMetadata: () async => const {});
    expect(find.textContaining('2026'), findsOneWidget);
    expect(find.textContaining('12'), findsOneWidget);
  });

  testWidgets('a failed read keeps the album summary', (tester) async {
    await _pump(
      tester,
      loadMetadata: () => Future.error(StateError('offline')),
    );
    expect(find.textContaining('2026'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the editorial note replaces the summary, without its markup', (
    tester,
  ) async {
    await _pump(
      tester,
      loadMetadata: () async => const {
        'album_info': {
          'editorial_notes': {
            'short': 'A <b>short</b> note',
            'standard': 'The <i>longer</i> note',
          },
        },
      },
    );
    expect(find.text('The longer note'), findsOneWidget);
    expect(find.textContaining('2026'), findsNothing);
  });

  testWidgets('the plus adds the album and the card opens it', (tester) async {
    var added = 0;
    var opened = 0;
    await _pump(tester, onAdd: () => added++, onTap: () => opened++);

    await tester.tap(find.byTooltip('Add to Library'));
    await tester.pumpAndSettle();
    expect((added, opened), (1, 0));

    await tester.tap(find.text('Example album'));
    await tester.pumpAndSettle();
    expect((added, opened), (1, 1));
  });
}
