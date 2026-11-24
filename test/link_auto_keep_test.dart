import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/link/features/link_auto_keep.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/services/link/features/link_phone_receiver.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_transfers.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/link_fakes.dart';

/// Waits, in real time, until [condition] holds.
Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Track _track(String id) => Track(
  id: id,
  name: 'Song $id',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
);

CollectionTrackEntry _entry(String id) =>
    CollectionTrackEntry(key: id, track: _track(id), addedAt: DateTime(2026));

/// The computer's song for each track whose id does not start with
/// `phone`, which stand for songs only this phone has.
Future<List<LinkOfflineSong>> _desktopSongs(
  List<Track> tracks,
  LinkServerRecord server,
) async => linkOfflineSongs([
  for (final track in tracks)
    LocalLibraryItem(
      id: 'row_${track.id}',
      trackName: track.name,
      artistName: track.artistName,
      albumName: track.albumName,
      filePath: track.id.startsWith('phone')
          ? '/music/${track.id}.flac'
          : linkDesktopSongSource(server, track.id, format: 'flac'),
      scannedAt: DateTime(2026),
      format: 'flac',
    ),
], server);

/// Downloads a few bytes, fails for [failing] songs and waits at [gate]
/// when the test sets one.
class _Transport implements LinkOfflineTransport {
  final requested = <String>[];
  final failing = <String>{};
  Completer<void>? gate;

  @override
  Future<void> download(
    String songId,
    File output, {
    required void Function() checkpoint,
    required void Function(int received, int? total) progress,
  }) async {
    requested.add(songId);
    await output.writeAsBytes(List.filled(10, 1));
    if (gate case final gate?) await gate.future;
    checkpoint();
    if (failing.contains(songId)) throw const HttpException('500');
  }

  @override
  void close() {}
}

class _Destination implements LinkOfflineDestination {
  _Destination(this.root);

  final Directory root;

  @override
  Future<LinkOfflineStored> store(
    File file, {
    required String relativeDir,
    required String fileName,
    required String mimeType,
  }) async {
    final target = File(p.join(root.path, relativeDir, fileName));
    await target.parent.create(recursive: true);
    await file.copy(target.path);
    return LinkOfflineStored(filePath: target.path, storageMode: 'app');
  }
}

/// Collections a test changes by hand.
class _Collections extends LibraryCollectionsNotifier {
  _Collections(this.initial);

  final LibraryCollectionsState initial;
  final loads = <String>[];

  @override
  LibraryCollectionsState build() => initial;

  @override
  Future<void> ensurePlaylistLoaded(String playlistId) async {
    loads.add(playlistId);
    final playlist = state.playlistById(playlistId);
    if (playlist == null || playlist.tracksLoaded) return;
    // Loading publishes the tracks but keeps the membership index.
    state = state.copyWith(
      playlists: [
        for (final next in state.playlists)
          next.id == playlistId ? next.copyWith(tracksLoaded: true) : next,
      ],
    );
  }

  void setPlaylist(String id, List<String> songs) {
    state = state.copyWith(
      playlists: [
        for (final next in state.playlists)
          next.id == id
              ? next.copyWith(tracks: [for (final s in songs) _entry(s)])
              : next,
      ],
    );
  }
}

UserPlaylistCollection _playlist(String id, List<String> songs) =>
    UserPlaylistCollection(
      id: id,
      name: 'Playlist $id',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      tracks: [for (final s in songs) _entry(s)],
    );

void main() {
  late Directory temp;
  late Directory root;
  late _Transport transport;
  late Set<String> saved;
  late LinkOfflineSaver saver;
  late FakeLinkClient client;
  late ProviderContainer transfersContainer;
  late LinkPhoneReceiver receiver;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('link_keep_temp');
    root = await Directory.systemTemp.createTemp('link_keep_root');
    transport = _Transport();
    saved = {};
    client = FakeLinkClient();
    saver = LinkOfflineSaver(
      serverId: linkTestServer.serverId,
      openTransport: () => transport,
      destination: _Destination(root),
      record: (item) async => saved.add(item.id),
      temporaryDirectory: () async => temp,
      exists: (historyId) async => saved.contains(historyId),
    );
    transfersContainer = ProviderContainer();
    receiver = LinkPhoneReceiver(
      transfers: transfersContainer.read(linkTransfersProvider.notifier),
      saver: () => saver,
    )..attach(client);
  });

  tearDown(() async {
    receiver.dispose();
    transfersContainer.dispose();
    await temp.delete(recursive: true);
    await root.delete(recursive: true);
  });

  List<LinkTransfer> transfers() =>
      transfersContainer.read(linkTransfersProvider);

  group('LinkAutoKeeper', () {
    late Map<String, List<String>> collections;
    late Set<String> kept;
    late LinkAutoKeeper keeper;
    late List<int> queued;

    setUp(() {
      collections = {};
      kept = {};
      queued = [];
      keeper = LinkAutoKeeper(
        kept: () async => kept,
        tracksOf: (collection) async =>
            collections[collection]?.map(_track).toList(),
        desktopSongsOf: _desktopSongs,
        saver: () => saver,
        queue: (songs) {
          queued.add(songs.length);
          final finished = Completer<LinkTransferStatus?>();
          final transfer = receiver.save(songs, onFinished: finished.complete);
          return transfer == null ? Future.value() : finished.future;
        },
        debounce: Duration.zero,
      );
    });

    tearDown(() => keeper.dispose());

    test(
      'saves the computer songs of kept collections that the phone lacks',
      () async {
        collections = {
          linkKeptPlaylist('a'): ['1', '2', 'phone-3'],
          linkKeptLoved: ['2', '4'],
          linkKeptPlaylist('b'): ['5'],
        };
        kept = {linkKeptPlaylist('a'), linkKeptLoved};
        saved.add(saver.historyId('4'));

        keeper.attach(client);
        await keeper.idle;

        // Song 2 once, song 4 already here, the phone's own song and the
        // collection that is not kept left out.
        expect(transport.requested, ['1', '2']);
        expect(transfers().single.entries.map((entry) => entry.title), [
          'Song 1',
          'Song 2',
        ]);
        expect(transfers().single.status.state, LinkTransferState.done);

        // Nothing is missing any more, so no new transfer starts.
        keeper.collectionsChanged();
        await keeper.idle;
        expect(transfers(), hasLength(1));
        expect(queued, [2]);
      },
    );

    test('waits for the connection', () async {
      collections = {
        linkKeptLoved: ['1'],
      };
      kept = {linkKeptLoved};
      client.setConnection(LinkConnectionState.disconnected);
      keeper.attach(client);
      keeper.marked();
      await keeper.idle;
      expect(transport.requested, isEmpty);

      client.setConnection(LinkConnectionState.connected);
      await keeper.idle;
      expect(transport.requested, ['1']);
    });

    test('a failed song waits for the next change or connection', () async {
      collections = {
        linkKeptPlaylist('a'): ['1', '2'],
        linkKeptLoved: ['3'],
      };
      kept = {linkKeptPlaylist('a')};
      transport.failing.add('2');
      keeper.attach(client);
      await keeper.idle;
      expect(transport.requested, ['1', '2']);

      // Keeping another collection does not try song 2 again.
      kept = {...kept, linkKeptLoved};
      keeper.marked();
      await keeper.idle;
      expect(transport.requested, ['1', '2', '3']);

      // A change of a kept collection does.
      keeper.collectionsChanged();
      await keeper.idle;
      expect(transport.requested, ['1', '2', '3', '2']);

      // So does the next connection.
      client
        ..setConnection(LinkConnectionState.disconnected)
        ..setConnection(LinkConnectionState.connected);
      await keeper.idle;
      expect(transport.requested, ['1', '2', '3', '2', '2']);
    });

    test('one run at a time, and reasons meanwhile run once more', () async {
      collections = {
        linkKeptLoved: ['1'],
      };
      kept = {linkKeptLoved};
      final gate = transport.gate = Completer<void>();
      keeper.attach(client);
      await until(() => transport.requested.isNotEmpty);

      collections = {
        linkKeptLoved: ['1', '2'],
      };
      keeper
        ..collectionsChanged()
        ..marked()
        ..collectionsChanged();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(queued, [1]);

      transport.gate = null;
      gate.complete();
      await until(() => queued.length == 2);
      await keeper.idle;
      expect(queued, [1, 1]);
      expect(transport.requested, ['1', '2']);
    });

    test(
      'a cancelled transfer leaves its songs for the next connection',
      () async {
        collections = {
          linkKeptLoved: ['1', '2'],
        };
        kept = {linkKeptLoved};
        final gate = transport.gate = Completer<void>();
        keeper.attach(client);
        await until(() => transport.requested.isNotEmpty);
        receiver.cancel(transfers().single.id);
        gate.complete();
        await keeper.idle;
        expect(transfers().single.status.state, LinkTransferState.cancelled);

        transport.gate = null;
        keeper.marked();
        await keeper.idle;
        expect(transfers(), hasLength(1));

        client
          ..setConnection(LinkConnectionState.disconnected)
          ..setConnection(LinkConnectionState.connected);
        await keeper.idle;
        expect(transfers(), hasLength(2));
        expect(transport.requested, ['1', '1', '2']);
      },
    );
  });

  group('linkAutoKeepProvider', () {
    late _Collections collections;
    late ProviderContainer container;
    late List<List<String>> runs;

    Future<void> settle() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await container.read(linkAutoKeepProvider).idle;
    }

    setUp(() {
      SharedPreferences.setMockInitialValues({
        LinkKeptCollections.prefsKey: [linkKeptPlaylist('a')],
      });
      runs = [];
      collections = _Collections(
        LibraryCollectionsState(
          isLoaded: true,
          playlists: [
            _playlist('a', ['1']),
            UserPlaylistCollection(
              id: 'b',
              name: 'Playlist b',
              createdAt: DateTime(2026),
              updatedAt: DateTime(2026),
              tracks: [_entry('2')],
              tracksLoaded: false,
            ),
          ],
        ),
      );
      container = ProviderContainer(
        overrides: [
          libraryCollectionsProvider.overrideWith(() => collections),
          linkPhoneClientProvider.overrideWithValue(client),
          linkOfflineSaverProvider.overrideWithValue(saver),
          linkPhoneReceiverProvider.overrideWithValue(receiver),
          linkAutoKeepDebounceProvider.overrideWithValue(Duration.zero),
          linkKeepDesktopSongsProvider.overrideWithValue((
            tracks,
            server,
          ) async {
            runs.add([for (final track in tracks) track.id]);
            return _desktopSongs(tracks, server);
          }),
        ],
      );
      container.listen(linkAutoKeepProvider, (_, _) {});
    });

    tearDown(() => container.dispose());

    test(
      'runs on connect, on a change of a kept playlist and when one is kept',
      () async {
        await settle();
        expect(transport.requested, ['1']);

        // Loading tracks and editing a playlist that is not kept are no
        // reason to run.
        final before = runs.length;
        collections.setPlaylist('b', ['2', '3']);
        await settle();
        expect(runs, hasLength(before));

        collections.setPlaylist('a', ['1', '4']);
        await settle();
        expect(transport.requested, ['1', '4']);

        await container
            .read(linkKeptCollectionsProvider.notifier)
            .setKept(linkKeptPlaylist('b'), true);
        await settle();
        expect(collections.loads, contains('b'));
        expect(transport.requested, ['1', '4', '2', '3']);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getStringList(LinkKeptCollections.prefsKey), [
          linkKeptPlaylist('a'),
          linkKeptPlaylist('b'),
        ]);
      },
    );

    test('stopping keeps the saved songs and starts nothing', () async {
      await settle();
      expect(transport.requested, ['1']);
      await container
          .read(linkKeptCollectionsProvider.notifier)
          .setKept(linkKeptPlaylist('a'), false);
      collections.setPlaylist('a', ['1', '5']);
      await settle();
      expect(transport.requested, ['1']);
      expect(saved, contains(saver.historyId('1')));
      expect(container.read(linkKeptCollectionsProvider).value, isEmpty);
    });
  });

  test('a song this phone already has from elsewhere is not copied', () async {
    final songs = await _desktopSongs([
      _track('1'),
      _track('2'),
      _track('3'),
      _track('4'),
    ], linkTestServer);
    final history = _History({
      // A copy saved from another device, or a download of the same song.
      'Song 1': '/music/Artist/Song 1.flac',
      // Its file is gone.
      'Song 2': '/music/Artist/Song 2.flac',
      // Only on network storage.
      'Song 3': 'network://nas/Artist/Song 3.flac',
    });

    final missing = await linkSongsNotOnThisPhone(
      songs,
      history: history,
      exists: (path) async => !path.contains('Song 2'),
    );

    expect([for (final song in missing) song.songId], ['2', '3', '4']);
    expect(history.asked, ['Song 1', 'Song 2', 'Song 3', 'Song 4']);
  });
}

/// A download history that holds a file for some song titles.
class _History extends Fake implements HistoryDatabase {
  _History(this.files);

  final Map<String, String> files;
  final asked = <String>[];

  @override
  Future<List<Map<String, dynamic>?>> findExistingTracks(
    List<HistoryLookupRequest> requests,
  ) async => [
    for (final request in requests)
      () {
        asked.add(request.trackName);
        final path = files[request.trackName];
        return path == null
            ? null
            : <String, dynamic>{'id': request.trackName, 'filePath': path};
      }(),
  ];
}
