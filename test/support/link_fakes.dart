import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/link/features/link_phone_library.dart';
import 'package:mornye/services/link/features/link_phone_player.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/features/link_track_resolver.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/playable_media.dart';

const linkTestServer = LinkServerRecord(
  serverId: 'server-1',
  name: 'Studio PC',
  connectionId: 'conn-1',
  address: 'https://192.0.2.10:8443',
  fingerprint: 'ab:cd',
);

/// A desktop song as the phone streams it through [linkTestServer].
PlayableMedia linkDesktopMedia(
  String songId, {
  String title = 'Song',
  String artist = 'Artist',
  Duration? duration,
}) => PlayableMedia(
  id: 'desktop-$songId',
  source: linkDesktopSongSource(linkTestServer, songId, format: 'flac'),
  title: title,
  artist: artist,
  album: 'Album',
  duration: duration,
);

PlayableMedia linkLocalMedia(
  String id, {
  String title = 'Song',
  String artist = 'Artist',
  Duration? duration,
}) => PlayableMedia(
  id: id,
  source: '/music/$id.flac',
  title: title,
  artist: artist,
  album: 'Album',
  duration: duration,
);

MediaItem linkMediaItem(PlayableMedia media) => MediaItem(
  id: media.id,
  title: media.title,
  artist: media.artist,
  album: media.album,
  duration: media.duration,
  extras: {'source': media.source},
);

/// A [LinkClientApi] that records what the features send and answers from
/// [onGet] and [onPost].
class FakeLinkClient implements LinkClientApi {
  FakeLinkClient({
    this.server = linkTestServer,
    this.connectionState = LinkConnectionState.connected,
    this.onGet,
    this.onPost,
  });

  @override
  final LinkServerRecord server;

  @override
  LinkConnectionState connectionState;

  Object? Function(String op, Map<String, String> query)? onGet;
  Object? Function(String op, Map<String, dynamic> body)? onPost;

  final sent = <Map<String, dynamic>>[];
  final gets = <String>[];
  final posts = <({String op, Map<String, dynamic> body})>[];

  final _states = StreamController<LinkConnectionState>.broadcast(sync: true);
  final _messages = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );

  @override
  Stream<LinkConnectionState> get connectionStates => _states.stream;

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  /// A message the desktop pushes.
  void push(Map<String, dynamic> message) => _messages.add(message);

  void setConnection(LinkConnectionState state) {
    connectionState = state;
    _states.add(state);
  }

  /// The `player.state` messages sent so far.
  List<LinkPlayerState> get sentStates => [
    for (final message in sent)
      if (message['type'] == LinkMessageTypes.playerState)
        LinkPlayerState.fromJson(message['state'])!,
  ];

  @override
  void send(Map<String, dynamic> message) {
    if (connectionState == LinkConnectionState.connected) sent.add(message);
  }

  @override
  Future<Object?> get(String op, [Map<String, String> query = const {}]) async {
    gets.add(op);
    final reply = onGet?.call(op, query);
    if (reply is Exception) throw reply;
    return reply;
  }

  @override
  Future<Object?> post(String op, Map<String, dynamic> body) async {
    posts.add((op: op, body: body));
    final reply = onPost?.call(op, body);
    if (reply is Exception) throw reply;
    return reply ?? {'ok': true};
  }

  /// Fails the upload of a file name when it returns an exception.
  Exception? Function(String name)? onUpload;

  /// Runs while a file of [size] bytes uploads, reporting its progress
  /// through [sent]; the upload completes when it returns.
  Future<void> Function(String name, int size, void Function(int sent) sent)?
  whileUploading;

  /// The file names uploaded so far, with their bytes.
  final uploads = <({String name, List<int> bytes})>[];

  @override
  Future<void> upload(
    String name,
    File file, {
    void Function(int sent)? onProgress,
  }) async {
    final failure = onUpload?.call(name);
    if (failure != null) throw failure;
    final bytes = await file.readAsBytes();
    await whileUploading?.call(
      name,
      bytes.length,
      (sent) => onProgress?.call(sent),
    );
    uploads.add((name: name, bytes: bytes));
    onProgress?.call(bytes.length);
  }

  Future<void> close() async {
    await _states.close();
    await _messages.close();
  }
}

/// A [LinkPhonePlayer] that records calls and moves its snapshot the way
/// the app player would.
class FakePhonePlayer implements LinkPhonePlayer {
  FakePhonePlayer([this.snapshot = const LinkPhoneSnapshot()]);

  @override
  LinkPhoneSnapshot snapshot;

  final calls = <String>[];
  final _changes = StreamController<void>.broadcast(sync: true);

  ({List<PlayableMedia> items, int index, Duration position, bool playing})?
  played;

  @override
  Stream<void> get changes => _changes.stream;

  /// Replaces the snapshot and reports the change.
  void update(LinkPhoneSnapshot next) {
    snapshot = next;
    _changes.add(null);
  }

  LinkPhoneSnapshot _with({
    List<MediaItem>? queue,
    int? index,
    bool? playing,
    int? positionMs,
    bool? shuffle,
    LinkRepeatMode? repeat,
    double? volume,
  }) => LinkPhoneSnapshot(
    queue: queue ?? snapshot.queue,
    index: index ?? snapshot.index,
    playing: playing ?? snapshot.playing,
    positionMs: positionMs ?? snapshot.positionMs,
    durationMs: snapshot.durationMs,
    shuffle: shuffle ?? snapshot.shuffle,
    repeat: repeat ?? snapshot.repeat,
    volume: volume ?? snapshot.volume,
  );

  @override
  Future<void> playQueue(
    List<PlayableMedia> items, {
    required int index,
    required Duration position,
    required bool playing,
  }) async {
    calls.add('playQueue');
    played = (items: items, index: index, position: position, playing: playing);
    update(
      _with(
        queue: [for (final item in items) linkMediaItem(item)],
        index: index,
        positionMs: position.inMilliseconds,
        playing: playing,
      ),
    );
  }

  @override
  Future<void> play() async {
    calls.add('play');
    update(_with(playing: true));
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    update(_with(playing: false));
  }

  @override
  Future<void> next() async => calls.add('next');

  @override
  Future<void> previous() async => calls.add('previous');

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek ${position.inMilliseconds}');
    update(_with(positionMs: position.inMilliseconds));
  }

  @override
  Future<void> jump(int index) async {
    calls.add('jump $index');
    update(_with(index: index, positionMs: 0));
  }

  @override
  Future<void> setShuffle(bool enabled) async {
    calls.add('shuffle $enabled');
    update(_with(shuffle: enabled));
  }

  @override
  Future<void> setRepeat(LinkRepeatMode mode) async {
    calls.add('repeat ${mode.name}');
    update(_with(repeat: mode));
  }

  @override
  Future<void> setVolume(double value) async {
    calls.add('volume $value');
    update(_with(volume: value));
  }
}

/// A [LinkLibraryLookup] over fixed records.
class FakeLibraryLookup implements LinkLibraryLookup {
  FakeLibraryLookup([List<LinkLocalTrack>? tracks]) : tracks = tracks ?? [];

  final List<LinkLocalTrack> tracks;
  final queries = <String>[];

  @override
  Future<LinkLocalTrack?> recordFor({
    required String id,
    required String source,
  }) async {
    queries.add('record $source');
    for (final track in tracks) {
      if (track.media.source == source || track.media.id == id) return track;
    }
    return null;
  }

  @override
  Future<List<LinkLocalTrack>> byIsrc(String isrc) async {
    queries.add('isrc $isrc');
    return [
      for (final track in tracks)
        if (track.isrc == isrc) track,
    ];
  }

  @override
  Future<List<LinkLocalTrack>> byMatchKey(String matchKey) async {
    queries.add('key $matchKey');
    return [
      for (final track in tracks)
        if (linkMatchKey(track.media.title, track.media.artist) == matchKey)
          track,
    ];
  }
}

/// A Library Songs row of a scanned file.
Map<String, dynamic> linkLocalRow(
  String filePath, [
  Map<String, Object?> extra = const {},
]) => {
  'source': 'local',
  'item': {
    'id': filePath,
    'trackName': 'Song',
    'artistName': 'Artist',
    'filePath': filePath,
    ...extra,
  },
};

/// A Library Songs row of a download.
Map<String, dynamic> linkDownloadRow(
  String filePath, [
  Map<String, Object?> extra = const {},
]) => {
  'source': 'downloaded',
  'item': {
    'id': filePath,
    'trackName': 'Song',
    'artistName': 'Artist',
    'filePath': filePath,
    ...extra,
  },
};

/// Library Songs rows that a [LinkPhoneLibrary] pages, recording each query.
class FakeLibraryRows {
  FakeLibraryRows([List<Map<String, dynamic>>? rows]) : rows = rows ?? [];

  List<Map<String, dynamic>> rows;
  final queries = <QueueLibraryDbQuery>[];

  /// While set, pages wait for it.
  Completer<void>? hold;

  Future<QueueLibraryDbPage> load(QueueLibraryDbQuery query) async {
    queries.add(query);
    await hold?.future;
    final start = math.min(query.offset, rows.length);
    final end = math.min(start + query.limit, rows.length);
    return QueueLibraryDbPage(rows: rows.sublist(start, end), nextCursor: null);
  }

  /// A library over these rows, mapped on the test's isolate.
  LinkPhoneLibrary library({bool includeLocal = true, int pageSize = 1000}) =>
      LinkPhoneLibrary(
        includeLocal: () => includeLocal,
        loadPage: load,
        mapPage: (rows) async => mapLinkPhoneRows(rows),
        pageSize: pageSize,
      );
}
