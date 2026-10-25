import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/link/desktop/link_catalog_exporter.dart';
import 'package:mornye/services/link/desktop/link_catalog_index.dart';
import 'package:mornye/services/link/desktop/link_desktop_backend.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/desktop/link_desktop_ops.dart';
import 'package:mornye/services/link/desktop/link_downloads.dart';
import 'package:mornye/services/link/desktop/link_phone_catalogs.dart';
import 'package:mornye/services/link/desktop/link_phone_library.dart';
import 'package:mornye/services/link/desktop/link_player.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/playable_media.dart';

const fakeFingerprint =
    'ab12cd34ef567890ab12cd34ef567890ab12cd34ef567890ab12cd34ef567890';

/// A Rust link server in memory: records every call and lets tests raise
/// the inbound events.
class FakeLinkBackend implements LinkDesktopBackend {
  final calls = <String>[];
  final replies =
      <({String requestId, Object? result, LinkException? error})>[];
  final sent = <({Map<String, dynamic> message, String? deviceId})>[];
  final catalogs = <String>[];
  List<LinkPairedDevice> deviceList = [];
  Object? startError;
  int delivered = 1;
  int catalogSongs = 0;
  bool running = false;
  String? runningName;
  LinkPairingWindow pairingWindow = LinkPairingWindow(
    pin: '123456',
    expiresMs: DateTime.now().millisecondsSinceEpoch + 300000,
    fingerprint: fakeFingerprint,
  );

  final _requests = StreamController<LinkRequestEvent>.broadcast();
  final _messages = StreamController<LinkMessageEvent>.broadcast();
  final _clients = StreamController<List<LinkClientInfo>>.broadcast();
  final _pairing = StreamController<LinkPairingEvent>.broadcast();

  LinkHostServer serverNamed(String name) => LinkHostServer(
    port: 47710,
    fingerprint: fakeFingerprint,
    serverId: 'server-1',
    name: name,
    // As the Rust server sends them: full URLs, not bare IPs.
    addresses: const ['https://192.168.1.5:47710'],
  );

  void request(
    String op, {
    String requestId = 'r1',
    String deviceId = 'phone-1',
    Map<String, dynamic> args = const {},
  }) => _requests.add(
    LinkRequestEvent(
      requestId: requestId,
      op: op,
      deviceId: deviceId,
      args: args,
    ),
  );

  void message(String deviceId, Map<String, dynamic> message) =>
      _messages.add(LinkMessageEvent(deviceId: deviceId, message: message));

  void connect(List<LinkClientInfo> clients) => _clients.add(clients);

  void pairingEvent(LinkPairingEvent event) => _pairing.add(event);

  List<Map<String, dynamic>> sentOfType(String type) => [
    for (final entry in sent)
      if (entry.message['type'] == type) entry.message,
  ];

  @override
  Future<LinkHostServer> start({required String name, int? port}) async {
    calls.add('start:$name');
    final error = startError;
    if (error != null) throw error;
    running = true;
    runningName = name;
    return serverNamed(name);
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    running = false;
  }

  @override
  Future<({LinkHostServer? server, List<LinkClientInfo> clients})>
  status() async {
    calls.add('status');
    return (
      server: running ? serverNamed(runningName ?? '') : null,
      clients: const <LinkClientInfo>[],
    );
  }

  @override
  Future<int> setCatalog(String path) async {
    calls.add('setCatalog');
    catalogs.add(path);
    return catalogSongs;
  }

  @override
  Future<LinkPairingWindow> beginPairing() async {
    calls.add('beginPairing');
    return pairingWindow;
  }

  @override
  Future<void> endPairing() async => calls.add('endPairing');

  @override
  Future<List<LinkPairedDevice>> devices() async {
    calls.add('devices');
    return deviceList;
  }

  @override
  Future<void> revoke(String deviceId) async {
    calls.add('revoke:$deviceId');
    deviceList = [
      for (final device in deviceList)
        if (device.deviceId != deviceId) device,
    ];
  }

  @override
  Future<LinkAppKey> createKey(String name) async {
    calls.add('createKey:$name');
    return const LinkAppKey(deviceId: 'app-1', apiKey: 'secret-key-1');
  }

  @override
  Future<void> reply(
    String requestId, {
    Object? result,
    LinkException? error,
  }) async {
    replies.add((requestId: requestId, result: result, error: error));
  }

  @override
  Future<int> send(Map<String, dynamic> message, {String? deviceId}) async {
    sent.add((message: message, deviceId: deviceId));
    return delivered;
  }

  @override
  Stream<LinkRequestEvent> get requests => _requests.stream;

  @override
  Stream<LinkMessageEvent> get messages => _messages.stream;

  @override
  Stream<List<LinkClientInfo>> get clients => _clients.stream;

  @override
  Stream<LinkPairingEvent> get pairing => _pairing.stream;
}

/// The desktop player in memory.
class FakeLinkPlayer implements LinkPlayerPort {
  LinkPlayerSnapshot current = const LinkPlayerSnapshot(updatedMs: 0);
  final calls = <String>[];
  List<PlayableMedia>? playedQueue;
  int? playedIndex;
  Duration? playedPosition;
  bool? playedPlaying;
  bool? playedShuffle;
  final _changes = StreamController<void>.broadcast();

  void emit(LinkPlayerSnapshot snapshot) {
    current = snapshot;
    _changes.add(null);
  }

  @override
  LinkPlayerSnapshot snapshot() => current;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> next() async => calls.add('next');

  @override
  Future<void> previous() async => calls.add('previous');

  @override
  Future<void> seek(Duration position) async =>
      calls.add('seek:${position.inMilliseconds}');

  @override
  Future<void> setVolume(double value) async => calls.add('volume:$value');

  @override
  Future<void> setShuffle(bool enabled) async => calls.add('shuffle:$enabled');

  @override
  Future<void> setRepeat(LinkRepeatMode mode) async =>
      calls.add('repeat:${mode.name}');

  @override
  Future<void> jumpTo(int index) async => calls.add('jump:$index');

  @override
  Future<void> moveQueueItem(int from, int to) async =>
      calls.add('move:$from:$to');

  @override
  Future<void> removeQueueItem(int index) async => calls.add('remove:$index');

  @override
  Future<void> playQueue(
    List<PlayableMedia> items, {
    required int index,
    required Duration position,
    required bool playing,
    bool? shuffle,
  }) async {
    calls.add('playQueue');
    playedQueue = items;
    playedIndex = index;
    playedPosition = position;
    playedPlaying = playing;
    playedShuffle = shuffle;
  }

  /// Every batch [append] added, in order.
  final appended = <List<PlayableMedia>>[];

  @override
  Future<void> append(
    List<PlayableMedia> items, {
    bool playNext = false,
  }) async {
    calls.add(playNext ? 'playNext' : 'append');
    appended.add(items);
  }
}

/// The download queue in memory.
class FakeLinkDownloads implements LinkDownloadsPort {
  final urls = <String>[];
  final queued =
      <
        ({
          List<Track> tracks,
          String? service,
          String? quality,
          String? playlistName,
        })
      >[];
  LinkResolvedLink resolved = (tracks: const <Track>[], playlistName: null);
  Object? resolveError;

  @override
  Future<LinkResolvedLink> resolveUrl(String url) async {
    urls.add(url);
    final error = resolveError;
    if (error != null) throw error;
    return resolved;
  }

  @override
  int enqueue(
    List<Track> tracks, {
    String? service,
    String? quality,
    String? playlistName,
  }) {
    queued.add((
      tracks: tracks,
      service: service,
      quality: quality,
      playlistName: playlistName,
    ));
    return tracks.length;
  }
}

/// An exporter that returns [songs] at once, without touching the disk.
class FakeLinkCatalogExporter extends LinkCatalogExporter {
  FakeLinkCatalogExporter({this.songs = const []});

  List<LinkCatalogSong> songs;
  final exports = <({bool includeLocal, String serverId})>[];

  @override
  Future<LinkCatalogExport> export({
    required bool includeLocal,
    required String serverId,
  }) async {
    exports.add((includeLocal: includeLocal, serverId: serverId));
    return LinkCatalogExport(
      path: '${Directory.systemTemp.path}/fake-catalog.ndjson',
      count: songs.length,
      index: DesktopLinkCatalogIndex(serverId: serverId, songs: songs),
    );
  }
}

class FakeDownloadItems extends Notifier<List<DownloadItem>> {
  @override
  List<DownloadItem> build() => const [];

  void replace(List<DownloadItem> items) => state = items;
}

final fakeDownloadItemsProvider =
    NotifierProvider<FakeDownloadItems, List<DownloadItem>>(
      FakeDownloadItems.new,
    );

typedef FakeLibraryRevision = ({int downloads, int library, bool includeLocal});

class FakeLibraryRevisionNotifier extends Notifier<FakeLibraryRevision> {
  @override
  FakeLibraryRevision build() => (downloads: 0, library: 0, includeLocal: true);

  void bump() => state = (
    downloads: state.downloads + 1,
    library: state.library,
    includeLocal: state.includeLocal,
  );
}

final fakeLibraryRevisionProvider =
    NotifierProvider<FakeLibraryRevisionNotifier, FakeLibraryRevision>(
      FakeLibraryRevisionNotifier.new,
    );

/// The desktop Library as phone songs use it, in memory.
class FakeLinkPhoneLibrary implements LinkPhoneLibrary {
  final calls = <String>[];

  /// Sources the owner removed or turned off; rescans skip them.
  final hidden = <String>{};

  @override
  Future<void> add(String sourceId, String name) async =>
      calls.add('add:$sourceId:$name');

  @override
  Future<void> rescan(String sourceId) async {
    if (!hidden.contains(sourceId)) calls.add('rescan:$sourceId');
  }

  @override
  Future<void> remove(String sourceId) async => calls.add('remove:$sourceId');
}

/// Overrides that run the desktop link host entirely on the fakes. Phone
/// songs are kept in [phoneFolder], by default a folder that does not
/// exist until a phone sends its songs.
List<Override> linkHostOverrides({
  required FakeLinkBackend backend,
  required FakeLinkPlayer player,
  FakeLinkDownloads? downloads,
  FakeLinkCatalogExporter? exporter,
  List<String>? openedUrls,
  FakeLinkPhoneLibrary? phoneLibrary,
  Directory? phoneFolder,
}) => [
  linkPhoneLibraryProvider.overrideWithValue(
    phoneLibrary ?? FakeLinkPhoneLibrary(),
  ),
  linkPhoneFolderProvider.overrideWithValue(
    () async =>
        phoneFolder ??
        Directory(
          '${Directory.systemTemp.path}/link-phones-missing-${Object().hashCode}',
        ),
  ),
  linkDesktopBackendProvider.overrideWithValue(backend),
  linkDesktopPlayerProvider.overrideWithValue(player),
  linkDesktopDownloadsProvider.overrideWithValue(
    downloads ?? FakeLinkDownloads(),
  ),
  linkCatalogExporterProvider.overrideWithValue(
    exporter ?? FakeLinkCatalogExporter(),
  ),
  linkDownloadItemsProvider.overrideWith(
    (ref) => ref.watch(fakeDownloadItemsProvider),
  ),
  linkLibraryRevisionProvider.overrideWith(
    (ref) => ref.watch(fakeLibraryRevisionProvider),
  ),
  linkOpenUrlProvider.overrideWithValue((url) async => openedUrls?.add(url)),
];

LinkPlayerItem playerItem(String id, {String? path, int durationMs = 200000}) =>
    LinkPlayerItem(
      id: id,
      path: path ?? '/music/$id.flac',
      title: 'Title $id',
      artist: 'Artist $id',
      album: 'Album',
      durationMs: durationMs,
    );

LinkCatalogSong catalogSong(
  String id, {
  String? path,
  String? title,
  String? artist,
  int? durationMs = 200000,
  String? isrc,
}) => LinkCatalogSong(
  id: id,
  title: title ?? 'Title ${linkRecordIdOf(id)}',
  artist: artist ?? 'Artist ${linkRecordIdOf(id)}',
  path: path ?? '/music/${linkRecordIdOf(id)}.flac',
  album: 'Album',
  durationMs: durationMs,
  isrc: isrc,
  matchKey: linkMatchKey(
    title ?? 'Title ${linkRecordIdOf(id)}',
    artist ?? 'Artist ${linkRecordIdOf(id)}',
  ),
);
