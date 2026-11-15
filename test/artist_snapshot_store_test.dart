import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/screens/artist_screen.dart';
import 'package:mornye/services/artist_snapshot_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _album = ArtistAlbum(
  id: 'album-1',
  name: 'Saved Album',
  releaseDate: '2024-05-01',
  totalTracks: 9,
  coverUrl: 'https://example.com/cover.jpg',
  albumType: 'album',
  artists: 'Example Artist',
  providerId: 'example-provider',
);
const _track = Track(
  id: 'song-1',
  name: 'Saved Song',
  artistName: 'Example Artist',
  albumName: 'Saved Album',
  duration: 180,
);
const _snapshot = ArtistSnapshot(
  artistId: 'artist-1',
  artistName: 'Example Artist',
  extensionId: 'example-provider',
  albums: [_album],
  releases: [_album],
  topTracks: [_track],
  headerImageUrl: 'https://example.com/header.jpg',
  monthlyListeners: 1200,
);

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('artist-snapshots-');
    addTearDown(() => directory.deleteSync(recursive: true));
  });

  ArtistSnapshotStore store({int maxArtists = 200}) => ArtistSnapshotStore(
    directory: () async => directory,
    maxArtists: maxArtists,
  );

  test('a saved page comes back whole, whatever the name case', () async {
    await store().save(_snapshot);
    final saved = await store().read('EXAMPLE ARTIST ');
    expect(saved?.artistId, 'artist-1');
    expect(saved?.extensionId, 'example-provider');
    expect(saved?.albums.single.name, 'Saved Album');
    expect(saved?.albums.single.providerId, 'example-provider');
    expect(saved?.releases?.single.totalTracks, 9);
    expect(saved?.topTracks?.single.name, 'Saved Song');
    expect(saved?.headerImageUrl, 'https://example.com/header.jpg');
    expect(saved?.monthlyListeners, 1200);
  });

  test('an artist never saved and a damaged file read as nothing', () async {
    expect(await store().read('Nobody'), isNull);
    await store().save(_snapshot);
    final file = Directory(
      '${directory.path}/artist_snapshots',
    ).listSync().whereType<File>().single;
    file.writeAsStringSync('{');
    expect(await store().read('Example Artist'), isNull);
  });

  test('the artists saved longest ago leave first', () async {
    final limited = store(maxArtists: 2);
    for (final name in ['First', 'Second', 'Third']) {
      await limited.save(
        ArtistSnapshot(artistId: name, artistName: name, albums: const []),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(await limited.read('First'), isNull);
    expect(await limited.read('Second'), isNotNull);
    expect(await limited.read('Third'), isNotNull);
  });

  testWidgets('a saved copy says so and shows the page', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('com.zarz.mornye/backend');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ArtistScreen(
            artistId: 'artist-1',
            artistName: 'Example Artist',
            albums: [_album],
            topTracks: [_track],
            savedCopy: true,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('artist-saved-copy')), findsOneWidget);
    expect(find.text('Saved Song'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
