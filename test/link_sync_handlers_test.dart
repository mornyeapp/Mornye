import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/sync/link_collection_sync_store.dart';
import 'package:mornye/services/link/sync/link_history_sync_store.dart';
import 'package:mornye/services/link/sync/link_sync_handlers.dart';
import 'package:mornye/services/link/sync/link_sync_protocol.dart';
import 'package:mornye/services/link/sync/link_sync_runner.dart';
import 'package:mornye/utils/desktop_platform.dart';

import 'support/link_sync_support.dart';

final _songs = [
  linkCatalogSong('l:1', 'One', isrc: 'ISRC00000001'),
  linkCatalogSong('l:2', 'Two'),
  linkCatalogSong('d:3', 'Three'),
];

class _Desktop {
  _Desktop(this.container, this.db, this.listening);

  final ProviderContainer container;
  final Database db;
  final Database listening;
  int notified = 0;
  var _requests = 0;

  Future<Object?> call(
    String op, [
    Map<String, dynamic> args = const {},
  ]) async {
    final router = container.read(_routerProvider);
    final reply = await router.dispatch(
      LinkRequest(
        requestId: 'r${_requests++}',
        op: op,
        deviceId: 'subsonic-app',
        args: linkJsonRoundTrip(args)! as Map<String, dynamic>,
      ),
    );
    return linkJsonRoundTrip(reply);
  }
}

final _routerProvider = Provider<LinkHostRouter>((ref) {
  final router = ref.watch(linkHostRouterProvider);
  registerLinkSyncHandlers(router, ref);
  return router;
});

Future<_Desktop> _desktop() async {
  final directory = await linkSyncTempDirectory();
  final db = await openLinkCollectionsDatabase(directory, 'desk');
  final listening = await openLinkListeningDatabase(directory, 'desk');
  final container = ProviderContainer(
    overrides: [
      linkCollectionSyncStoreProvider.overrideWithValue(
        LinkCollectionSyncStore(() async => db),
      ),
      linkHistorySyncStoreProvider.overrideWithValue(
        LinkHistorySyncStore(() async => listening),
      ),
      libraryCollectionsProvider.overrideWith(
        () => LibraryCollectionsNotifier(
          database: LibraryCollectionsDatabase.withDatabase(db),
        ),
      ),
      linkSongTrackResolverProvider.overrideWithValue(
        (song) async => linkTrackFromSongInfo(song),
      ),
      linkSyncSettingsProvider.overrideWithValue(
        const LinkSyncSettings(localDebounce: Duration(milliseconds: 10)),
      ),
    ],
  );
  addTearDown(container.dispose);
  final desktop = _Desktop(container, db, listening);
  container
      .read(linkCatalogIndexProvider.notifier)
      .set(FakeLinkCatalogIndex(_songs));
  container
      .read(linkCollectionsChangedHookProvider.notifier)
      .set(() => desktop.notified++);
  container.read(_routerProvider);
  return desktop;
}

Map<String, dynamic> _playlistOf(Object? reply) =>
    (reply! as Map)['playlist'] as Map<String, dynamic>;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDesktopPlatformOverride = false;
  });
  tearDown(() => debugDesktopPlatformOverride = null);

  test(
    'Subsonic playlist ops create, read, edit and delete playlists',
    () async {
      final desktop = await _desktop();
      final created = _playlistOf(
        await desktop.call(LinkSyncSubsonicOps.createPlaylist, {
          'name': 'Desk Mix',
          'songs': [linkSongInfo(_songs[0]), linkSongInfo(_songs[1])],
        }),
      );
      final id = created['id'] as String;
      expect(created['name'], 'Desk Mix');
      expect(created['songIds'], ['l:1', 'l:2']);
      expect(created['createdMs'], isA<int>());
      expect(created['changedMs'], isA<int>());

      final listed = await desktop.call(LinkSyncSubsonicOps.getPlaylists);
      expect((listed! as Map)['playlists'], [created]);

      expect(
        await desktop.call(LinkSyncSubsonicOps.updatePlaylist, {
          'playlistId': id,
          'name': 'Renamed',
          'comment': 'ignored',
          'songIndexesToRemove': [0],
          'songsToAdd': [linkSongInfo(_songs[2])],
        }),
        <String, dynamic>{},
      );
      var playlist = _playlistOf(
        await desktop.call(LinkSyncSubsonicOps.getPlaylist, {'id': id}),
      );
      expect(playlist['name'], 'Renamed');
      expect(playlist['songIds'], ['l:2', 'd:3']);

      // createPlaylist with an id replaces the songs.
      playlist = _playlistOf(
        await desktop.call(LinkSyncSubsonicOps.createPlaylist, {
          'playlistId': id,
          'songs': [linkSongInfo(_songs[0])],
        }),
      );
      expect(playlist['songIds'], ['l:1']);
      expect(playlist['name'], 'Renamed');

      // The app's collection state follows.
      final state = desktop.container.read(libraryCollectionsProvider);
      expect(state.playlistById(id)?.name, 'Renamed');

      expect(
        await desktop.call(LinkSyncSubsonicOps.deletePlaylist, {'id': id}),
        <String, dynamic>{},
      );
      await expectLater(
        desktop.call(LinkSyncSubsonicOps.getPlaylist, {'id': id}),
        throwsA(
          isA<LinkException>().having(
            (error) => error.code,
            'code',
            'not_found',
          ),
        ),
      );
      await expectLater(
        desktop.call(LinkSyncSubsonicOps.createPlaylist, {
          'songs': <Object?>[],
        }),
        throwsA(isA<LinkException>().having((e) => e.code, 'code', 'invalid')),
      );
      // Subsonic edits are this desktop's changes, announced to phones.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(desktop.notified, greaterThan(0));
    },
  );

  test('star, unstar and getStarred map songs and artists', () async {
    final desktop = await _desktop();
    final artistId = linkCatalogArtistId('Desk  Artist ');
    expect(artistId, linkCatalogArtistId('desk artist'));
    expect(
      await desktop.call(LinkSyncSubsonicOps.star, {
        'songs': [linkSongInfo(_songs[0]), linkSongInfo(_songs[1])],
        'albums': [
          {'id': 'al-1', 'name': 'Desk Album', 'artist': 'Desk Artist'},
        ],
        'artists': [
          {'id': artistId, 'name': 'Desk Artist'},
        ],
      }),
      <String, dynamic>{},
    );
    // Starring again changes nothing.
    await desktop.call(LinkSyncSubsonicOps.star, {
      'songs': [linkSongInfo(_songs[0])],
      'artists': [
        {'id': artistId, 'name': 'Desk Artist'},
      ],
    });
    var starred = await desktop.call(LinkSyncSubsonicOps.getStarred);
    expect(starred, {
      'songIds': unorderedEquals(['l:1', 'l:2']),
      'albumIds': <String>[],
      'artistIds': [artistId],
    });
    final state = desktop.container.read(libraryCollectionsProvider);
    expect(state.loved, hasLength(2));
    expect(state.favoriteArtists.single.name, 'Desk Artist');

    await desktop.call(LinkSyncSubsonicOps.unstar, {
      'songs': [linkSongInfo(_songs[0])],
      'artists': [
        {'id': artistId, 'name': 'Desk Artist'},
      ],
    });
    starred = await desktop.call(LinkSyncSubsonicOps.getStarred);
    expect(starred, {
      'songIds': ['l:2'],
      'albumIds': <String>[],
      'artistIds': <String>[],
    });
  });

  test('scrobble submissions record desktop listening', () async {
    final desktop = await _desktop();
    final time = DateTime(2026, 10, 21, 12).millisecondsSinceEpoch;
    await desktop.call(LinkSyncSubsonicOps.scrobble, {
      'songs': [linkSongInfo(_songs[1])],
      'timesMs': [time],
      'submission': false,
    });
    expect(await desktop.listening.query('listening'), isEmpty);
    await desktop.call(LinkSyncSubsonicOps.scrobble, {
      'songs': [linkSongInfo(_songs[1])],
      'timesMs': [time],
      'submission': true,
    });
    final row = (await desktop.listening.query('listening')).single;
    expect(row['day'], '2026-10-21');
    expect(row['track_key'], '/music/Two.flac');
    expect(row['milliseconds'], 180000);
    expect(row['plays'], 1);
    final events = await desktop.call(LinkOps.history, {
      '_method': 'GET',
      'since': '0',
      'device': 'phone',
    });
    expect(
      ((events! as Map)['events'] as List).single,
      containsPair('ms', 180000),
    );
  });

  test(
    'collections endpoints page, apply, and announce peer changes',
    () async {
      final desktop = await _desktop();
      final reply = await desktop.call(LinkOps.collections, {
        '_method': 'POST',
        'device': 'phone',
        'changes': [
          LinkSyncChange(
            kind: LinkSyncKinds.loved,
            key: 'example:p',
            updatedMs: 1000,
            origin: 'phone',
            data: {'track': linkTestTrack('p').toJson(), 'addedMs': 900},
          ).toJson()..remove('origin'),
          {'kind': 'unknown', 'key': 'x', 'updatedMs': 1},
        ],
      });
      expect(reply, {'applied': 1, 'cursor': isA<int>()});
      expect(desktop.notified, 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        desktop.container
            .read(libraryCollectionsProvider)
            .containsLovedKey('example:p'),
        isTrue,
      );
      // Applying peer changes is not a desktop edit: no second announcement.
      expect(desktop.notified, 1);

      final forPhone = await desktop.call(LinkOps.collections, {
        '_method': 'GET',
        'since': '0',
        'device': 'phone',
      });
      expect((forPhone! as Map)['changes'], isEmpty);
      final forOther = await desktop.call(LinkOps.collections, {
        '_method': 'GET',
        'since': '0',
        'device': 'tablet',
        'limit': '1',
      });
      final page = forOther! as Map;
      expect(page['device'], isA<String>());
      // A full page may have more; the next page says it is the last.
      expect(page['more'], isTrue);
      final change = (page['changes'] as List).single as Map;
      expect(change['origin'], 'phone');
      expect((change['data'] as Map)['addedMs'], 900);
      final next = await desktop.call(LinkOps.collections, {
        '_method': 'GET',
        'since': '${page['cursor']}',
        'device': 'tablet',
        'limit': '1',
      });
      expect(next, containsPair('more', false));
      expect(next, containsPair('changes', isEmpty));
      expect(next, containsPair('cursor', page['latest']));

      await expectLater(
        desktop.call(LinkOps.collections, {'_method': 'POST'}),
        throwsA(isA<LinkException>().having((e) => e.code, 'code', 'invalid')),
      );
    },
  );
}
