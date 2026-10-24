import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/sync/link_collection_sync_store.dart';
import 'package:mornye/services/link/sync/link_history_sync_store.dart';
import 'package:mornye/services/link/sync/link_sync_handlers.dart';
import 'package:mornye/services/link/sync/link_sync_runner.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/utils/desktop_platform.dart';

import 'support/link_sync_support.dart';

const _settings = LinkSyncSettings(
  localDebounce: Duration(milliseconds: 20),
  messageDebounce: Duration(milliseconds: 10),
  historyInterval: Duration.zero,
  historyPeriod: Duration(hours: 1),
);

/// Routes the phone's requests to the desktop handlers over a JSON wire.
class _FakeClient implements LinkClientApi {
  _FakeClient(this._router, {this.state = LinkConnectionState.connected});

  final LinkHostRouter _router;
  final states = StreamController<LinkConnectionState>.broadcast();
  final pushed = StreamController<Map<String, dynamic>>.broadcast();
  final sent = <Map<String, dynamic>>[];
  final posts = <(String, Map<String, dynamic>)>[];
  LinkConnectionState state;
  int gets = 0;
  int? failGet;
  var _requests = 0;

  @override
  LinkServerRecord get server => const LinkServerRecord(
    serverId: 'desk-1',
    name: 'Desk',
    connectionId: 'connection-1',
    address: 'https://desk.local:47710',
    fingerprint: 'ab',
  );

  @override
  LinkConnectionState get connectionState => state;

  @override
  Stream<LinkConnectionState> get connectionStates => states.stream;

  @override
  Stream<Map<String, dynamic>> get messages => pushed.stream;

  @override
  void send(Map<String, dynamic> message) => sent.add(message);

  Future<Object?> _dispatch(String op, Map<String, dynamic> args) async =>
      linkJsonRoundTrip(
        await _router.dispatch(
          LinkRequest(
            requestId: 'r${_requests++}',
            op: op,
            deviceId: 'phone-device',
            args: args,
          ),
        ),
      );

  @override
  Future<Object?> get(String op, [Map<String, String> query = const {}]) {
    if (gets++ == failGet) {
      return Future.error(const LinkException('timeout', 'dropped'));
    }
    return _dispatch(op, {...query, '_method': 'GET'});
  }

  @override
  Future<Object?> post(String op, Map<String, dynamic> body) {
    final wire = linkJsonRoundTrip(body)! as Map<String, dynamic>;
    posts.add((op, wire));
    return _dispatch(op, {...wire, '_method': 'POST'});
  }

  Future<void> close() async {
    await states.close();
    await pushed.close();
  }
}

final _routerProvider = Provider<LinkHostRouter>((ref) {
  final router = ref.watch(linkHostRouterProvider);
  registerLinkSyncHandlers(router, ref);
  return router;
});

typedef _Side = ({
  ProviderContainer container,
  Database db,
  Database listening,
});

Future<_Side> _side(String name, {bool desktop = false}) async {
  final directory = await linkSyncTempDirectory();
  final db = await openLinkCollectionsDatabase(directory, name);
  final listening = await openLinkListeningDatabase(directory, name);
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
      linkSyncSettingsProvider.overrideWithValue(_settings),
      linkHistoryFlushProvider.overrideWithValue(() async {}),
    ],
  );
  addTearDown(container.dispose);
  if (desktop) container.read(_routerProvider);
  return (container: container, db: db, listening: listening);
}

Future<Set<String>> _keys(Database db, String table) async => {
  for (final row in await db.rawQuery('SELECT track_key FROM $table'))
    row['track_key']! as String,
};

Future<void> _eventually(Future<bool> Function() condition) async {
  for (var attempt = 0; attempt < 300; attempt++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for sync');
}

ListeningDelta _listen(String key, int milliseconds) => ListeningDelta(
  '2026-10-22',
  ListeningTrack(key: key, title: key, artist: 'Artist', album: 'Album'),
  milliseconds,
  1,
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDesktopPlatformOverride = false;
  });
  tearDown(() => debugDesktopPlatformOverride = null);

  test('phone and desktop converge both ways and stay quiet after', () async {
    final desk = await _side('desk', desktop: true);
    final phone = await _side('phone');
    var announced = 0;
    desk.container
        .read(linkCollectionsChangedHookProvider.notifier)
        .set(() => announced++);
    final deskCollections = desk.container.read(
      libraryCollectionsProvider.notifier,
    );
    final phoneCollections = phone.container.read(
      libraryCollectionsProvider.notifier,
    );
    await phoneCollections.toggleLoved(linkTestTrack('a'));
    final playlistId = await phoneCollections.createPlaylist('Road');
    await phoneCollections.addTrackToPlaylist(playlistId, linkTestTrack('t1'));
    await deskCollections.toggleLoved(linkTestTrack('b'));
    await deskCollections.toggleFavoriteArtist(
      artistId: 'artist-1',
      providerId: 'example',
      name: 'Band',
    );
    await writeListeningDeltas(phone.listening, [_listen('/phone/x', 4000)]);
    await writeListeningDeltas(desk.listening, [_listen('/desk/y', 7000)]);

    final client = _FakeClient(desk.container.read(_routerProvider));
    addTearDown(client.close);
    final runner = phone.container.read(linkSyncRunnerProvider.notifier);
    phone.container.read(linkActiveClientProvider.notifier).set(client);
    await runner.syncNow();

    expect(await _keys(phone.db, 'loved_tracks'), {'example:a', 'example:b'});
    expect(await _keys(desk.db, 'loved_tracks'), {'example:a', 'example:b'});
    expect(await _keys(desk.db, 'playlist_tracks'), {'example:t1'});
    expect((await desk.db.query('playlists')).single['id'], playlistId);
    expect(await phone.db.query('favorite_artists'), hasLength(1));
    final phoneState = phone.container.read(libraryCollectionsProvider);
    expect(phoneState.containsLovedKey('example:b'), isTrue);
    expect(phoneState.favoriteArtists.single.name, 'Band');
    expect(
      client.sent,
      contains(equals({'type': LinkMessageTypes.collectionsChanged})),
    );
    expect(announced, greaterThan(0));

    // Only the phone's own changes travel up; desktop rows are not echoed.
    final phoneDevice = await phone.container
        .read(linkCollectionSyncStoreProvider)
        .deviceId();
    final pushedChanges = [
      for (final (op, body) in client.posts)
        if (op == LinkOps.collections)
          ...(body['changes'] as List).cast<Map<String, dynamic>>(),
    ];
    expect(pushedChanges.map((change) => change['origin']).toSet(), {
      phoneDevice,
    });

    final phoneTotals = await phone.listening.query('listening');
    expect(
      {for (final row in phoneTotals) row['track_key']: row['milliseconds']},
      {'/phone/x': 4000, '/desk/y': 7000},
    );
    final deskTotals = await desk.listening.query('listening');
    expect(deskTotals, hasLength(2));

    // Nothing new: a second sync pulls nothing and posts nothing.
    final posts = client.posts.length;
    final sent = client.sent.length;
    await runner.syncNow();
    expect(client.posts.length, posts);
    expect(client.sent.length, sent);

    // The desktop removes a song and announces it; the phone renames the
    // playlist locally. Both arrive.
    await deskCollections.removeLovedTracks(['example:a']);
    client.pushed.add({'type': LinkMessageTypes.collectionsChanged});
    await phoneCollections.renamePlaylist(playlistId, 'Coast');
    await _eventually(
      () async =>
          (await _keys(phone.db, 'loved_tracks')).length == 1 &&
          (await desk.db.query('playlists')).single['name'] == 'Coast',
    );
    expect(await _keys(phone.db, 'loved_tracks'), {'example:b'});
    await _eventually(
      () async => !phone.container.read(linkSyncRunnerProvider).syncing,
    );
    final status = phone.container.read(linkSyncRunnerProvider);
    expect(status.serverId, 'desk-1');
    expect(status.lastSyncedMs, isNotNull);
    expect(status.error, isNull);
  });

  test('an interrupted pull resumes from the last applied page', () async {
    final desk = await _side('desk', desktop: true);
    final phone = await _side('phone');
    await LibraryCollectionsDatabase.withDatabase(
      desk.db,
    ).upsertLovedTracksBatch([
      for (var i = 0; i < 1200; i++)
        {
          'track_key': 'example:$i',
          'track_json': linkTestTrackJson('$i'),
          'added_at': DateTime.now().toIso8601String(),
        },
    ]);
    final client = _FakeClient(
      desk.container.read(_routerProvider),
      state: LinkConnectionState.disconnected,
    )..failGet = 1;
    addTearDown(client.close);
    final runner = phone.container.read(linkSyncRunnerProvider.notifier);
    phone.container.read(linkActiveClientProvider.notifier).set(client);

    // Disconnected: nothing happens.
    await runner.syncNow();
    expect(client.gets, 0);

    client.state = LinkConnectionState.connected;
    client.states.add(LinkConnectionState.connected);
    await _eventually(
      () async => phone.container.read(linkSyncRunnerProvider).error != null,
    );
    expect(await _keys(phone.db, 'loved_tracks'), hasLength(500));
    final prefs = await SharedPreferences.getInstance();
    final cursor = prefs.getInt('link_sync_desk-1_collections_pull');
    expect(cursor, 500);

    await runner.syncNow();
    expect(await _keys(phone.db, 'loved_tracks'), hasLength(1200));
    expect(phone.container.read(linkSyncRunnerProvider).error, isNull);
    expect(
      prefs.getInt('link_sync_desk-1_collections_pull'),
      await desk.container.read(linkCollectionSyncStoreProvider).latestSeq(),
    );
  });

  test('a replaced desktop database is pulled again from the start', () async {
    final desk = await _side('desk', desktop: true);
    final phone = await _side('phone');
    await desk.container
        .read(libraryCollectionsProvider.notifier)
        .toggleLoved(linkTestTrack('old'));
    final client = _FakeClient(desk.container.read(_routerProvider));
    addTearDown(client.close);
    final runner = phone.container.read(linkSyncRunnerProvider.notifier);
    phone.container.read(linkActiveClientProvider.notifier).set(client);
    await runner.syncNow();
    expect(await _keys(phone.db, 'loved_tracks'), {'example:old'});

    // A fresh desktop database (new sync id, low sequence).
    final fresh = await _side('desk-new', desktop: true);
    await fresh.container
        .read(libraryCollectionsProvider.notifier)
        .toggleLoved(linkTestTrack('new'));
    final freshClient = _FakeClient(fresh.container.read(_routerProvider));
    addTearDown(freshClient.close);
    phone.container.read(linkActiveClientProvider.notifier).set(freshClient);
    await runner.syncNow();
    expect(await _keys(phone.db, 'loved_tracks'), {
      'example:old',
      'example:new',
    });
    expect(await _keys(fresh.db, 'loved_tracks'), {
      'example:old',
      'example:new',
    });
  });
}
