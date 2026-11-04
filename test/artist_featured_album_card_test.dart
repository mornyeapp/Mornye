import 'dart:async';

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
  ArtistAlbum album = _album,
  VoidCallback? onTap,
  VoidCallback? onDownload,
  Future<Map<String, dynamic>> Function()? loadMetadata,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ArtistFeaturedAlbumCard(
            album: album,
            onTap: onTap ?? () {},
            onDownload: onDownload ?? () {},
            loadMetadata: loadMetadata,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  ArtistAlbum albumFrom(String provider) => ArtistAlbum(
    id: '123',
    providerId: provider,
    name: 'Example album',
    releaseDate: '2026-02-03',
    totalTracks: 12,
    albumType: 'album',
    artists: 'Example artist',
  );

  Map<String, dynamic> metadataNote(String note) => {
    'editorial_notes': {'standard': note},
  };

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

  testWidgets('switching providers clears a note for the same album ID', (
    tester,
  ) async {
    await _pump(
      tester,
      album: albumFrom('catalog-one'),
      loadMetadata: () async => metadataNote('First catalog note'),
    );
    expect(find.text('First catalog note'), findsOneWidget);

    final next = Completer<Map<String, dynamic>>();
    await _pump(
      tester,
      album: albumFrom('catalog-two'),
      loadMetadata: () => next.future,
    );
    expect(find.text('First catalog note'), findsNothing);
    expect(find.textContaining('2026'), findsOneWidget);

    next.complete(metadataNote('Second catalog note'));
    await tester.pumpAndSettle();
    expect(find.text('Second catalog note'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('returning to a provider ignores older pending notes', (
    tester,
  ) async {
    final first = Completer<Map<String, dynamic>>();
    final second = Completer<Map<String, dynamic>>();
    final current = Completer<Map<String, dynamic>>();
    for (final (provider, request) in [
      ('catalog-one', first),
      ('catalog-two', second),
      ('catalog-one', current),
    ]) {
      await _pump(
        tester,
        album: albumFrom(provider),
        loadMetadata: () => request.future,
      );
    }

    first.complete(metadataNote('Stale first note'));
    second.complete(metadataNote('Stale second note'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Stale'), findsNothing);
    expect(find.textContaining('2026'), findsOneWidget);

    current.complete(metadataNote('Current catalog note'));
    await tester.pumpAndSettle();
    expect(find.text('Current catalog note'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the download action and card navigation stay separate', (
    tester,
  ) async {
    var downloaded = 0;
    var opened = 0;
    await _pump(tester, onDownload: () => downloaded++, onTap: () => opened++);

    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    expect((downloaded, opened), (1, 0));

    await tester.tap(find.text('Example album'));
    await tester.pumpAndSettle();
    expect((downloaded, opened), (1, 1));
  });
}
