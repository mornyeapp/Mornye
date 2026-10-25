import 'dart:async';

import 'package:mornye/services/link/desktop/link_arriving_files.dart';
import 'package:mornye/services/link/desktop/link_catalog_index.dart';
import 'package:mornye/services/link/desktop/link_desktop_ops.dart';
import 'package:mornye/services/link/desktop/link_phone_catalogs.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkPhoneSources');

/// [song] as the desktop's identity index compares it.
TrackRef linkPhoneSongRef(LinkPhoneSong song) => TrackRef(
  title: song.title,
  artist: song.artist,
  album: song.album,
  durationMs: song.durationMs,
  isrc: song.isrc,
);

/// [song]'s fields under the keys a network tag read answers.
Map<String, dynamic> linkPhoneSongTags(
  LinkPhoneSong song, {
  String? coverPath,
}) => {
  'title': song.title,
  'artist': song.artist,
  'album': ?song.album,
  'album_artist': ?song.albumArtist,
  'track_number': ?song.track,
  'disc_number': ?song.disc,
  if (song.year != null) 'date': '${song.year}',
  'genre': ?song.genre,
  if (song.durationMs != null) 'duration': (song.durationMs! / 1000).round(),
  'isrc': ?song.isrc,
  'bitrate': ?song.bitRate,
  'sample_rate': ?song.sampleRate,
  'bit_depth': ?song.bitDepth,
  'explicit': song.explicit,
  'format': song.suffix,
  'cover_path': ?coverPath,
};

/// The upload name `<fileId>.<ext>` of a phone song path, or null.
String? _songName(String path) {
  final dot = path.indexOf('.');
  if (dot <= 0 || path.contains('/')) return null;
  final fileId = path.substring(0, dot);
  final ext = path.substring(dot + 1);
  return isLinkFileId(fileId) && linkUploadExtensions.contains(ext)
      ? path
      : null;
}

typedef _Answer = ({String deviceId, Completer<Map<String, dynamic>> answer});

/// A song the phone is sending: the `file` it lands as, its `size`, whether
/// it plays before it is whole, and its arrival.
typedef _Sending = ({
  String file,
  int size,
  bool streamable,
  LinkArrival arrival,
});

/// Paired phones' songs in the desktop's Library (contract 12.3 and 12.4):
/// the `network://<sourceId>/` hosts the Link desktop host installs as
/// [NetworkStorageService.virtualSources]. Scans list the committed song
/// list without the songs the desktop has; playback uses the received
/// file, else asks the connected phone to send it.
class LinkPhoneSources implements NetworkVirtualSources {
  LinkPhoneSources({
    required LinkPhoneCatalogs catalogs,
    required DesktopLinkCatalogIndex? Function() index,
    required String Function() receivedDir,
    required String? Function(String sourceId) connectedDevice,
    required Future<int> Function(Map<String, dynamic> message, String deviceId)
    send,
    required LinkArrivingFiles? Function() arriving,
    Future<Map<String, dynamic>> Function(String path)? readTags,
    this.answerTimeout = const Duration(seconds: 15),
    this.progressInterval = const Duration(milliseconds: 250),
  }) : _catalogs = catalogs,
       _index = index,
       _receivedDir = receivedDir,
       _connectedDevice = connectedDevice,
       _send = send,
       _arriving = arriving,
       _readTags = readTags ?? PlatformBridge.readFileMetadata;

  /// How long a phone has to start sending a song it was asked for.
  final Duration answerTimeout;

  /// How often [receive] reports the bytes of a song on its way.
  final Duration progressInterval;

  final LinkPhoneCatalogs _catalogs;
  final DesktopLinkCatalogIndex? Function() _index;
  final String Function() _receivedDir;
  final String? Function(String sourceId) _connectedDevice;
  final Future<int> Function(Map<String, dynamic> message, String deviceId)
  _send;
  final LinkArrivingFiles? Function() _arriving;
  final Future<Map<String, dynamic>> Function(String path) _readTags;

  /// Resolves under way by song name; one request serves them all.
  final _requests = <String, Future<String>>{};

  /// Requests under way by song name, until the phone starts sending; plays
  /// and transfers of the same song share one.
  final _asks = <String, Future<_Sending>>{};

  /// Phones asked for a song, by song name, until they answer.
  final _answers = <String, _Answer>{};

  /// Songs on their way to the received folder, by song name.
  final _sending = <String, _Sending>{};

  /// Sources scanned before the identity index was ready.
  final _unindexed = <String>{};

  @override
  bool owns(String id) => isLinkPhoneSourceId(id);

  @override
  Stream<NetworkVirtualSong> songs(String id) async* {
    final index = _index();
    if (index == null) _unindexed.add(id);
    final covers = await _catalogs.coverPaths(id);
    await for (final song in _catalogs.songs(id)) {
      // The desktop's own copy stands for it.
      if (index?.songIdForRef(linkPhoneSongRef(song)) != null) continue;
      final cover = covers[song.coverKey];
      yield (
        path: song.name,
        tags: linkPhoneSongTags(song, coverPath: cover),
        coverPath: cover,
        size: song.size > 0 ? song.size : null,
        modifiedTime: song.addedMs,
      );
    }
  }

  /// The sources scanned without the identity index, to scan again now
  /// that it is ready.
  List<String> takeUnindexed() {
    final ids = _unindexed.toList();
    _unindexed.clear();
    return ids;
  }

  @override
  Future<String> resolve(String id, String path) async {
    final name = _songName(path);
    if (name == null) throw const FormatException('Invalid phone song');
    final fileId = name.substring(0, name.indexOf('.'));
    final received = (await linkReceivedFiles(_receivedDir()))[fileId];
    if (received != null) return received;
    final sending = _sending[name];
    if (sending != null) {
      final arrival = await _arriving()?.expect(
        _receivedDir(),
        sending.file,
        sending.size,
      );
      if (arrival != null) return arrival.url;
    }
    // A block body: an arrow would hand whenComplete the removed future
    // itself to wait for.
    return _requests[name] ??= _request(id, name).whenComplete(() {
      _requests.remove(name);
    });
  }

  /// Asks the phone behind [id] for [name] and waits for it to start.
  Future<String> _request(String id, String name) async {
    final deviceId = _connectedDevice(id);
    if (deviceId == null) {
      throw const LinkException('unavailable', 'The phone is not connected');
    }
    final sending = await _ask(deviceId, name);
    // A file that plays only once whole (an MP4 with its index at the end).
    if (!sending.streamable) {
      await sending.arrival.done;
      return sending.arrival.path;
    }
    return sending.arrival.url;
  }

  /// The whole file of the phone song [name] in the received folder: one
  /// received before, else asked of the phone [deviceId] and waited for
  /// until it is whole, never streamed. [onProgress] hears the bytes written
  /// so far every [progressInterval].
  Future<String> receive(
    String deviceId,
    String name, {
    void Function(int received, int size)? onProgress,
  }) async {
    if (_songName(name) == null) {
      throw const FormatException('Invalid phone song');
    }
    var sending = _sending[name];
    if (sending == null && !_asks.containsKey(name)) {
      final fileId = name.substring(0, name.indexOf('.'));
      final received = (await linkReceivedFiles(_receivedDir()))[fileId];
      if (received != null) return received;
      sending = _sending[name];
    }
    sending ??= await _ask(deviceId, name);
    final arrival = sending.arrival;
    if (onProgress != null) {
      final file = sending.file;
      final size = sending.size;
      final timer = Timer.periodic(
        progressInterval,
        (_) => onProgress(_arriving()?.written(file) ?? 0, size),
      );
      try {
        await arrival.done;
      } finally {
        timer.cancel();
      }
      onProgress(size, size);
    } else {
      await arrival.done;
    }
    return arrival.path;
  }

  /// Asks the phone [deviceId] for [name] and waits for it to start
  /// sending; callers asking meanwhile share the request.
  Future<_Sending> _ask(String deviceId, String name) {
    // A block body: an arrow would hand whenComplete the removed future
    // itself to wait for.
    return _asks[name] ??= _askPhone(deviceId, name).whenComplete(() {
      _asks.remove(name);
    });
  }

  /// Sends `files.request` for [name] to [deviceId] and waits for its
  /// answer.
  Future<_Sending> _askPhone(String deviceId, String name) async {
    final answer = Completer<Map<String, dynamic>>();
    // A disconnect can fail it before the send returns.
    answer.future.ignore();
    final entry = (deviceId: deviceId, answer: answer);
    _answers[name] = entry;
    try {
      final delivered = await _send({
        'type': LinkMessageTypes.filesRequest,
        'name': name,
      }, deviceId);
      if (delivered == 0) {
        throw const LinkException('unavailable', 'The phone is not connected');
      }
      final message = await answer.future.timeout(
        answerTimeout,
        onTimeout: () => throw const LinkException(
          'timeout',
          'The phone did not send the song',
        ),
      );
      return await _arrive(name, message);
    } finally {
      if (identical(_answers[name], entry)) _answers.remove(name);
    }
  }

  /// Expects the song the phone started to send, or fails as it answered.
  Future<_Sending> _arrive(String name, Map<String, dynamic> message) async {
    if (message['type'] == LinkMessageTypes.filesFailed) {
      final reason = message['reason'];
      throw LinkException(
        'unavailable',
        reason is String && reason.isNotEmpty
            ? 'The phone could not send the song: $reason'
            : 'The phone could not send the song',
      );
    }
    final file = message['file'];
    final size = message['size'];
    final fileId = name.substring(0, name.indexOf('.'));
    if (file is! String || size is! int || !file.startsWith('$fileId.')) {
      throw const LinkException('invalid', 'The phone sent another file');
    }
    final arrival = await _arriving()?.expect(_receivedDir(), file, size);
    if (arrival == null) {
      throw const LinkException('unavailable', 'The song cannot be received');
    }
    final _Sending sending = (
      file: file,
      size: size,
      streamable: message['streamable'] != false,
      arrival: arrival,
    );
    _sending[name] = sending;
    unawaited(
      arrival.done.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        if (identical(_sending[name], sending)) _sending.remove(name);
      }),
    );
    return sending;
  }

  /// Takes `files.sending` and `files.failed` from the phone [deviceId];
  /// returns whether [message] was one of them.
  bool onMessage(String deviceId, Map<String, dynamic> message) {
    final type = message['type'];
    if (type != LinkMessageTypes.filesSending &&
        type != LinkMessageTypes.filesFailed) {
      return false;
    }
    final name = message['name'];
    final pending = name is String ? _answers[name] : null;
    if (pending != null &&
        pending.deviceId == deviceId &&
        !pending.answer.isCompleted) {
      pending.answer.complete(message);
    }
    return true;
  }

  /// Fails the requests of phones that are no longer connected.
  void keepConnected(Set<String> deviceIds) {
    for (final pending in _answers.values.toList()) {
      if (!deviceIds.contains(pending.deviceId) &&
          !pending.answer.isCompleted) {
        pending.answer.completeError(
          const LinkException('unavailable', 'The phone disconnected'),
        );
      }
    }
  }

  @override
  Future<Map<String, dynamic>> metadata(String id, String path) async {
    final name = _songName(path);
    if (name == null) return const {};
    final fileId = name.substring(0, name.indexOf('.'));
    // A song still on its way is read once whole.
    final asked = _asks[name];
    if (asked != null) {
      await asked.then<void>((_) {}, onError: (Object _) {});
    }
    final sending = _sending[name];
    if (sending != null) {
      await sending.arrival.done.then<void>((_) {}, onError: (Object _) {});
    }
    final song = await _catalogs.song(id, fileId);
    final coverKey = song?.coverKey;
    final cover = coverKey == null
        ? null
        : await _catalogs.coverPath(id, coverKey);
    final received = (await linkReceivedFiles(_receivedDir()))[fileId];
    if (received != null) {
      try {
        final tags = Map<String, dynamic>.of(await _readTags(received));
        if (tags['error']?.toString().trim().isNotEmpty != true) {
          tags.remove('cover_base64');
          if (cover != null) tags['cover_path'] = cover;
          return tags;
        }
      } on Object catch (error) {
        _log.d('Could not read a received phone song: $error');
      }
    }
    return song == null ? const {} : linkPhoneSongTags(song, coverPath: cover);
  }

  /// Fails every request under way.
  void close() {
    for (final pending in _answers.values.toList()) {
      if (!pending.answer.isCompleted) {
        pending.answer.completeError(
          const LinkException('unavailable', 'Mornye Link stopped'),
        );
      }
    }
  }
}
