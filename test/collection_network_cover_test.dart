import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/screens/extension_collection_screens.dart'
    show ExtensionAlbumScreen;
import 'package:mornye/services/background_favorites.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_media_identity.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/utils/playback_artwork.dart';
import 'package:mornye/widgets/cached_cover_image.dart';

const _source = 'network://nas/Album/song.flac';
const _ref = 'network://nas/Album/cover.jpg';
const _jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4];

/// The collection read of [track]: its JSON as the database stores it.
Track _stored(Track track) => Track.fromJson(
  jsonDecode(jsonEncode(track.toJson())) as Map<String, dynamic>,
);

void main() {
  late Directory directory;
  late CoverStore covers;
  var fetches = 0;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('collection-cover-');
    fetches = 0;
    // Trims every stored cover, as a full store does.
    covers = CoverStore(
      directory: () async => directory,
      fetch: (_, output) async {
        fetches++;
        await output.writeAsBytes(_jpeg);
      },
      maxFiles: 0,
    );
  });
  tearDown(() async {
    await covers.dispose();
    await directory.delete(recursive: true);
  });

  const media = PlayableMedia(
    id: _source,
    source: _source,
    title: 'Song',
    artist: 'Artist',
    networkArtworkSource: _ref,
  );
  Track loved(MediaItem item) =>
      collectionTrackForMedia(item, null, covers: covers);

  test('a loved network song keeps the reference of its cover', () async {
    final pending = media.toMediaItem(covers: covers);
    expect(pending.artUri, isNull);
    expect(_stored(loved(pending)).coverUrl, _ref);

    final file = await covers.file(_ref);
    final shown = media.toMediaItem(covers: covers);
    expect(shown.artUri, Uri.file(file!));
    expect(_stored(loved(shown)).coverUrl, _ref);
  });

  test(
    'the media controls love a network song with the player store',
    () async {
      await covers.file(_ref);
      final collections = _LovedRows();
      final favorites = BackgroundFavorites(
        library: _NoLibrary(),
        history: _NoHistory(),
        collections: collections,
        covers: covers,
      );
      expect(await favorites.toggle(media.toMediaItem(covers: covers)), isTrue);
      expect(
        (jsonDecode(collections.rows.values.single)
            as Map<String, dynamic>)['coverUrl'],
        _ref,
      );
    },
  );

  test('a song showing another cover keeps that cover as before', () async {
    await covers.file(_ref);
    MediaItem item(String? artUri, String? reference) => MediaItem(
      id: _source,
      title: 'Song',
      artUri: artUri == null ? null : Uri.parse(artUri),
      extras: {'source': _source, 'artworkRef': ?reference},
    );
    // The cover from its tags, a web cover, and older rows without a
    // reference.
    for (final shown in [
      'file:///data/user/0/app/files/covers/tags_0.image',
      'https://example.com/cover.jpg',
    ]) {
      expect(loved(item(shown, _ref)).coverUrl, shown);
      expect(loved(item(shown, null)).coverUrl, shown);
    }
    expect(loved(item('http://127.0.0.1:41234/7f3a', _ref)).coverUrl, isNull);

    // A tag cover reference fetches nothing, so it never stays alone.
    final tags = CoverStore.songCoverReference(_source);
    expect(CoverStore.refetches(tags), isFalse);
    expect(CoverStore.refetches(_ref), isTrue);
    expect(loved(item(null, tags)).coverUrl, isNull);
    const file = 'file:///data/user/0/app/files/covers/tags_1.image';
    expect(loved(item(file, tags)).coverUrl, file);
  });

  testWidgets('a trimmed cover of a loved song is fetched again', (
    tester,
  ) async {
    final first = await tester.runAsync(() => covers.file(_ref));
    final track = _stored(
      loved(
        MediaItem(
          id: _source,
          title: 'Song',
          artUri: Uri.file(first!),
          extras: const {'source': _source, 'artworkRef': _ref},
        ),
      ),
    );
    expect(track.coverUrl, _ref);
    await tester.runAsync(covers.trim);
    expect(File(first).existsSync(), isFalse);
    expect(covers.indexedFile(track.coverUrl), isNull);
    expect(fetches, 1);

    // Collection rows show a cover the store does not hold through
    // pendingCover, never as a URL.
    expect(isHttpCoverUrl(track.coverUrl), isFalse);
    await tester.pumpWidget(
      MaterialApp(
        home: pendingCover(
          track.coverUrl,
          covers: covers,
          placeholder: const Text('placeholder'),
          builder: (_) => Text('stored ${covers.indexedFile(track.coverUrl)}'),
        ),
      ),
    );
    expect(find.text('placeholder'), findsOneWidget);
    final stored = find.textContaining('stored');
    // The fetch reads and writes real files between frames.
    for (var i = 0; i < 200 && stored.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    final again = covers.indexedFile(track.coverUrl);
    expect(again, isNotNull);
    expect(find.text('stored $again'), findsOneWidget);
    expect(File(again!).existsSync(), isTrue);
    expect(fetches, 2);
  });

  test('collection playback shows a network cover from the store', () async {
    const track = Track(
      id: _source,
      name: 'Song',
      artistName: 'Artist',
      albumName: 'Album',
      coverUrl: _ref,
      duration: 180,
      source: 'local',
    );
    final playable = playableFromTrack(track, _source);
    expect(playable.coverReference, _ref);
    final pending = playable.toMediaItem(covers: covers);
    expect(pending.artUri, isNull);
    expect(pending.extras?['artworkRef'], _ref);

    final file = await covers.file(_ref);
    final shown = playable.toMediaItem(covers: covers);
    expect(shown.artUri, Uri.file(file!));
    expect(shown.extras?['artworkRef'], _ref);

    // Older rows play exactly as before.
    for (final (cover, artUri) in [
      (
        '/data/user/0/app/files/covers/a_b.image',
        'file:///data/user/0/app/files/covers/a_b.image',
      ),
      ('https://example.com/cover.jpg', 'https://example.com/cover.jpg'),
      ('content://media/cover', 'content://media/cover'),
    ]) {
      final older = playableFromTrack(
        Track.fromJson({...track.toJson(), 'coverUrl': cover}),
        _source,
      );
      expect(older.artUri, artUri);
      expect(older.coverReference, isNull);
    }
  });

  test(
    'a collection song that plays a local file shows its own cover',
    () async {
      const track = Track(
        id: _source,
        name: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        coverUrl: _ref,
        duration: 180,
        source: 'local',
      );
      for (final path in ['/music/song.flac', 'content://media/audio/1']) {
        final playable = playableFromTrack(track, path);
        expect(playable.artUri, isNull);
        expect(playable.coverReference, isNull);
        final item = playable.toMediaItem(covers: covers);
        expect(item.artUri, isNull);
        expect(item.extras?['artworkRef'], isNull);
        expect(
          await resolveEmbeddedArtworkUri(
            path,
            item.artUri?.toString(),
            extract: (_) async => '/covers/embedded.jpg',
          ),
          Uri.file('/covers/embedded.jpg').toString(),
        );
      }
      expect(fetches, 0);
    },
  );

  testWidgets('Go to album leaves a network cover behind', (tester) async {
    final pushed = <Route<dynamic>>[];
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [_Pushes(pushed)],
        home: Builder(
          builder: (inner) {
            context = inner;
            return const SizedBox();
          },
        ),
      ),
    );
    const web = 'https://example.com/cover.jpg';
    for (final cover in [_ref, web]) {
      await navigateToTrackAlbum(
        context,
        Track(
          id: 'song',
          name: 'Song',
          artistName: 'Artist',
          albumName: 'Album',
          albumId: 'album',
          coverUrl: cover,
          duration: 180,
          source: 'example',
        ),
      );
    }
    // The pages are never shown: the test ends before the next frame.
    expect(
      [
        for (final route in pushed)
          ((route as MaterialPageRoute<void>).builder(context)
                  as ExtensionAlbumScreen)
              .coverUrl,
      ],
      [null, web],
    );
  });
}

class _NoLibrary implements LibraryDatabase {
  @override
  Future<Map<String, dynamic>?> getById(String id) async => null;

  @override
  Future<List<Map<String, dynamic>>> findByTrackAndArtist(
    String trackName,
    String artistName,
  ) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoHistory implements HistoryDatabase {
  @override
  Future<Map<String, dynamic>?> findByFilePath(String filePath) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Loved rows by track key.
class _LovedRows implements LibraryCollectionsDatabase {
  final rows = <String, String>{};

  @override
  Future<bool> containsLovedTrack(String trackKey) async =>
      rows.containsKey(trackKey);

  @override
  Future<void> upsertLovedEntry({
    required String trackKey,
    required String trackJson,
    required String addedAt,
  }) async => rows[trackKey] = trackJson;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records pushed routes after the first.
class _Pushes extends NavigatorObserver {
  _Pushes(this.pushed);

  final List<Route<dynamic>> pushed;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) pushed.add(route);
  }
}
