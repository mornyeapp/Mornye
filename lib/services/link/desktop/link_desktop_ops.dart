import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/desktop_deep_links.dart';
import 'package:mornye/services/link/desktop/link_arriving_files.dart';
import 'package:mornye/services/link/desktop/link_catalog_index.dart';
import 'package:mornye/services/link/desktop/link_downloads.dart';
import 'package:mornye/services/link/desktop/link_player.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/share_intent_service.dart';

const _openableSchemes = {'http', 'https', 'spotify', 'mornye'};

/// Whether a phone may ask the desktop to open [url]: web links, Spotify
/// URIs and `mornye://` links, the kinds the app accepts when shared.
bool linkOpenableUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  final scheme = uri.scheme.toLowerCase();
  if (!_openableSchemes.contains(scheme)) return false;
  return !scheme.startsWith('http') || uri.host.isNotEmpty;
}

/// Opens [url] as if it had been shared with the app: `mornye://` links go
/// to the deep link inbox, anything else to the shell's shared link
/// handler, which resolves it on the Search page.
Future<void> linkOpenSharedUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri != null && DesktopDeepLinks.isAppLink(uri)) {
    await PlatformBridge.queueExtensionCallbackUrl(url);
    return;
  }
  ShareIntentService().injectUrl(url);
}

/// How the desktop opens a URL a phone sent (`POST open`). Tests override
/// it.
final linkOpenUrlProvider = Provider<Future<void> Function(String url)>(
  (ref) => linkOpenSharedUrl,
);

/// [song] as the desktop player plays it from the Library, with [cover], a
/// cover file or web URL.
PlayableMedia linkPlayableFor(LinkCatalogSong song, {String? cover}) =>
    PlayableMedia(
      id: linkRecordIdOf(song.id),
      source: song.path,
      title: song.title,
      artist: song.artist,
      album: song.album ?? '',
      artUri: cover == null ? null : normalizeArtUri(cover),
      duration: song.durationMs == null
          ? null
          : Duration(milliseconds: song.durationMs!),
    );

/// The song file a phone uploaded to [path], with the details [ref] gives and
/// [cover], the phone's cover file or web URL. Without one the player shows
/// the cover embedded in the file once the song plays.
PlayableMedia linkPlayableForUpload(
  TrackRef ref,
  String path, {
  String? cover,
}) => PlayableMedia(
  id: path,
  source: path,
  title: ref.title,
  artist: ref.artist,
  album: ref.album ?? '',
  artUri: cover == null ? null : normalizeArtUri(cover),
  duration: ref.durationMs == null
      ? null
      : Duration(milliseconds: ref.durationMs!),
);

/// The uploaded song files in [dir] by [TrackRef.fileId]. Partial uploads
/// and other files are left out; a missing [dir] has none.
Future<Map<String, String>> linkReceivedFiles(String dir) async {
  final files = <String, String>{};
  if (dir.isEmpty) return files;
  try {
    await for (final entry in Directory(dir).list(followLinks: false)) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      final dot = name.indexOf('.');
      if (dot < 0) continue;
      final fileId = name.substring(0, dot);
      if (isLinkFileId(fileId) &&
          linkUploadExtensions.contains(name.substring(dot + 1))) {
        files[fileId] = entry.path;
      }
    }
  } on FileSystemException {
    // Nothing uploaded yet.
  }
  return files;
}

/// A play queue a Subsonic client saved (`savePlayQueue`).
class LinkSavedPlayQueue {
  const LinkSavedPlayQueue({
    required this.songIds,
    required this.positionMs,
    required this.changedMs,
    required this.changedBy,
    this.currentId,
  });

  final List<String> songIds;
  final String? currentId;
  final int positionMs;
  final int changedMs;
  final String changedBy;

  Map<String, dynamic> toJson() => {
    'songIds': songIds,
    'currentId': ?currentId,
    'positionMs': positionMs,
    'changedMs': changedMs,
    'changedBy': changedBy,
  };
}

String? _stringArg(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _intArg(Map<String, dynamic> args, String key) {
  final value = args[key];
  return value is num ? value.toInt() : null;
}

LinkException _invalid(String message) => LinkException('invalid', message);

/// The forwarded operations the desktop host answers itself (contract 6.1
/// and the play queue ops of 6.2): player state and commands, handoff,
/// downloads, opening links, track resolution and the Subsonic play queue.
class LinkDesktopOps {
  LinkDesktopOps({
    required LinkPlayerPort player,
    required LinkDownloadsPort downloads,
    required List<DownloadItem> Function() downloadItems,
    required Future<void> Function(String url) openUrl,
    required DesktopLinkCatalogIndex? Function() index,
    required String Function() desktopName,
    String Function(String deviceId)? deviceName,
    String Function()? receivedDir,
    Future<Map<String, String>> Function(Set<String> fileIds)? phoneCovers,
    LinkArrivingFiles? arriving,
    bool Function()? autoplay,
    bool Function()? autoMix,
    void Function(bool)? setAutoplay,
    void Function(bool)? setAutoMix,
    int Function()? nowMs,
  }) : _player = player,
       _downloads = downloads,
       _downloadItems = downloadItems,
       _openUrl = openUrl,
       _index = index,
       _desktopName = desktopName,
       _deviceName = deviceName ?? ((deviceId) => deviceId),
       _receivedDir = receivedDir ?? (() => ''),
       _phoneCovers = phoneCovers,
       _arriving = arriving,
       _autoplay = autoplay,
       _autoMix = autoMix,
       _setAutoplay = setAutoplay,
       _setAutoMix = setAutoMix,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// The longest play queue the Subsonic `getPlayQueue` answer carries.
  static const maxPlayQueue = 1000;

  final LinkPlayerPort _player;
  final LinkDownloadsPort _downloads;
  final List<DownloadItem> Function() _downloadItems;
  final Future<void> Function(String url) _openUrl;
  final DesktopLinkCatalogIndex? Function() _index;
  final String Function() _desktopName;
  final String Function(String deviceId) _deviceName;
  final String Function() _receivedDir;

  /// The covers paired phones listed for songs they uploaded, by file id.
  final Future<Map<String, String>> Function(Set<String> fileIds)? _phoneCovers;

  /// Streams song files a phone is still sending; without it a song plays
  /// once its upload is whole.
  final LinkArrivingFiles? _arriving;
  final bool Function()? _autoplay;
  final bool Function()? _autoMix;
  final void Function(bool)? _setAutoplay;
  final void Function(bool)? _setAutoMix;
  final int Function() _nowMs;
  final _random = math.Random();

  /// The queue the last `handoff/play` started, which `handoff/append`
  /// extends.
  String? _handoffId;

  final _savedQueues = <String, LinkSavedPlayQueue>{};
  List<LinkPlayerItem>? _observedQueue;
  String? _observedCurrent;
  int _desktopQueueChangedMs = 0;

  /// Registers these ops on [router].
  void register(LinkHostRouter router) {
    router
      ..register(LinkOps.state, (_) async => state().toJson())
      ..register(LinkOps.command, _command)
      ..register(LinkOps.handoffPlay, (request) => playHandoff(request.args))
      ..register(
        LinkOps.handoffAppend,
        (request) => appendHandoff(request.args),
      )
      ..register(LinkOps.handoffCurrent, (_) async => linkHandoffArgs(state()))
      ..register(LinkOps.queueAdd, (request) => addToQueue(request.args))
      ..register(LinkOps.downloads, _downloadsOp)
      ..register(LinkOps.open, _open)
      ..register(LinkOps.resolve, _resolve)
      ..register(LinkOps.getPlayQueue, _getPlayQueue)
      ..register(LinkOps.savePlayQueue, _savePlayQueue);
  }

  /// The desktop player as phones see it.
  LinkPlayerState state() => linkPlayerState(
    _player.snapshot(),
    index: _index(),
    autoplay: _autoplay?.call(),
    autoMix: _autoMix?.call(),
  );

  /// Notes the desktop's own queue, so `getPlayQueue` knows when it last
  /// changed. The host calls it on every player change.
  void observe(LinkPlayerSnapshot snapshot) {
    final current = snapshot.current;
    final currentKey = current == null
        ? null
        : '${current.id}\n${current.path}';
    if (identical(snapshot.queue, _observedQueue) &&
        currentKey == _observedCurrent) {
      return;
    }
    _observedQueue = snapshot.queue;
    _observedCurrent = currentKey;
    _desktopQueueChangedMs = _nowMs();
  }

  Future<Object?> _command(LinkRequest request) async {
    final command = LinkCommand.fromJson(request.args);
    if (command == null) throw _invalid('Missing action');
    await runCommand(command);
    return const {'ok': true};
  }

  /// Runs a player [command] from a phone on the desktop player.
  Future<void> runCommand(LinkCommand command) async {
    final args = command.args;
    switch (command.action) {
      case LinkActions.play:
        await _player.play();
      case LinkActions.pause:
        await _player.pause();
      case LinkActions.toggle:
        await (_player.snapshot().playing ? _player.pause() : _player.play());
      case LinkActions.next:
        await _player.next();
      case LinkActions.previous:
        await _player.previous();
      case LinkActions.seek:
        final positionMs = _intArg(args, 'positionMs');
        if (positionMs == null) throw _invalid('Missing positionMs');
        await _player.seek(Duration(milliseconds: math.max(0, positionMs)));
      case LinkActions.volume:
        final value = args['value'];
        if (value is! num) throw _invalid('Missing value');
        await _player.setVolume(value.toDouble().clamp(0, 1));
      case LinkActions.shuffle:
        final enabled = args['enabled'];
        if (enabled is! bool) throw _invalid('Missing enabled');
        await _player.setShuffle(enabled);
      case LinkActions.repeat:
        final mode = LinkRepeatMode.values.asNameMap()[args['mode']];
        if (mode == null) throw _invalid('Unknown repeat mode');
        await _player.setRepeat(mode);
      case LinkActions.autoplay:
      case LinkActions.autoMix:
        final enabled = args['enabled'];
        if (enabled is! bool) throw _invalid('Missing enabled');
        final write = command.action == LinkActions.autoplay
            ? _setAutoplay
            : _setAutoMix;
        if (write == null) throw _invalid('Playback preference is unavailable');
        write(enabled);
      case LinkActions.jump:
        await _player.jumpTo(_queueIndex(args, 'index'));
      case LinkActions.move:
        await _player.moveQueueItem(
          _queueIndex(args, 'from'),
          _queueIndex(args, 'to'),
        );
      case LinkActions.remove:
        final index = _queueIndex(args, 'index');
        if (index == _player.snapshot().index) {
          throw _invalid('The current song stays in the queue');
        }
        await _player.removeQueueItem(index);
      case LinkActions.playQueue:
        await playHandoff(args);
      default:
        throw _invalid('Unknown action ${command.action}');
    }
  }

  /// The desktop queue index for the queue window entry `args[key]`: phones
  /// index the window the state carries.
  int _queueIndex(Map<String, dynamic> args, String key) {
    final index = _intArg(args, key);
    final snapshot = _player.snapshot();
    final window = linkQueueWindow(snapshot.queue.length, snapshot.index);
    if (index == null || index < 0 || window.start + index >= window.end) {
      throw _invalid('Index out of range');
    }
    return window.start + index;
  }

  /// `handoff/play`: plays the songs of [args] the Library has or a phone
  /// uploaded, from the requested entry (or the next one it has) and
  /// position, and reports the entries it could not find. With `check` it
  /// only reports them. A `handoffId` names the queue for `handoff/append`.
  Future<Map<String, dynamic>> playHandoff(Map<String, dynamic> args) async {
    final queue = args['queue'];
    if (queue is! List) throw _invalid('Missing queue');
    final requested = _intArg(args, 'index') ?? 0;
    final resolved = await _resolveQueue(
      queue,
      arriving: args['check'] == true
          ? const {}
          : await _expectArriving(args['arriving']),
    );
    final media = <PlayableMedia>[];
    final missing = <int>[];
    var start = -1;
    var exact = false;
    for (var i = 0; i < resolved.length; i++) {
      final item = resolved[i];
      if (item == null) {
        missing.add(i);
        continue;
      }
      if (i == requested) {
        start = media.length;
        exact = true;
      } else if (i > requested && start < 0) {
        start = media.length;
      }
      media.add(item);
    }
    if (args['check'] == true) {
      return {'resolved': media.length, 'missing': missing};
    }
    String? handoffId;
    if (media.isNotEmpty) {
      if (args['autoplay'] case final bool enabled) _setAutoplay?.call(enabled);
      if (args['autoMix'] case final bool enabled) _setAutoMix?.call(enabled);
      final repeat = LinkRepeatMode.values.asNameMap()[args['repeat']];
      if (repeat != null) await _player.setRepeat(repeat);
      await _player.playQueue(
        media,
        index: start < 0 ? media.length - 1 : start,
        position: exact
            ? Duration(
                milliseconds: math.max(0, _intArg(args, 'positionMs') ?? 0),
              )
            : Duration.zero,
        playing: args['playing'] != false,
        shuffle: args['shuffle'] is bool ? args['shuffle'] as bool : null,
      );
      handoffId = _handoffId = '${_nowMs()}-${_random.nextInt(1 << 32)}';
    }
    return {
      'resolved': media.length,
      'missing': missing,
      'handoffId': ?handoffId,
    };
  }

  /// `handoff/append`: adds the songs of `queue` the desktop has to the
  /// end of the queue `handoffId` started, while that queue still plays.
  Future<Map<String, dynamic>> appendHandoff(Map<String, dynamic> args) async {
    final queue = args['queue'];
    if (queue is! List) throw _invalid('Missing queue');
    final handoffId = _stringArg(args, 'handoffId');
    if (handoffId == null || handoffId != _handoffId) {
      throw _invalid('Another queue plays on the computer now');
    }
    final media = [...(await _resolveQueue(queue)).nonNulls];
    if (media.isNotEmpty) await _player.append(media);
    return {'resolved': media.length};
  }

  /// `queue/add`: adds the songs of `queue` the desktop has to its queue,
  /// right after the current song when `next`; starts them when nothing is
  /// queued.
  Future<Map<String, dynamic>> addToQueue(Map<String, dynamic> args) async {
    final queue = args['queue'];
    if (queue is! List) throw _invalid('Missing queue');
    final media = [...(await _resolveQueue(queue)).nonNulls];
    if (media.isNotEmpty) {
      await _player.append(media, playNext: args['next'] == true);
    }
    return {'resolved': media.length};
  }

  /// The files of `arriving` (`[{"name","size"}]`, songs the phone is still
  /// sending) by [TrackRef.fileId], each streamed to the player until whole.
  Future<Map<String, String>> _expectArriving(Object? files) async {
    final arriving = _arriving;
    if (files is! List || arriving == null) return const {};
    final paths = <String, String>{};
    for (final entry in files) {
      if (entry is! Map) continue;
      final name = entry['name'];
      final size = entry['size'];
      if (name is! String || size is! int) continue;
      final arrival = await arriving.expect(_receivedDir(), name, size);
      if (arrival != null) paths[name.split('.').first] = arrival.path;
    }
    return paths;
  }

  /// Each entry of [queue] as the desktop plays it: the Library's song, else
  /// the file a phone uploaded or is sending ([arriving]) for it, else null.
  Future<List<PlayableMedia?>> _resolveQueue(
    List<Object?> queue, {
    Map<String, String> arriving = const {},
  }) async {
    final index = _index();
    if (index == null) {
      throw const LinkException('unavailable', 'The catalog is not ready');
    }
    final refs = [for (final item in queue) TrackRef.fromJson(item)];
    final received = refs.any((ref) => ref?.fileId != null)
        ? await linkReceivedFiles(_receivedDir())
        : const <String, String>{};
    final phoneCovers = _phoneCovers;
    final covers = phoneCovers == null
        ? const <String, String>{}
        : await phoneCovers({
            for (final ref in refs)
              if (ref?.fileId case final fileId?
                  when received.containsKey(fileId) ||
                      arriving.containsKey(fileId))
                fileId,
          });
    PlayableMedia? resolve(TrackRef? ref) {
      if (ref == null) return null;
      final songId = index.songIdForRef(ref);
      final song = songId == null ? null : index.songById(songId);
      if (song != null) {
        return linkPlayableFor(song, cover: index.coverFor(song.id));
      }
      final path = received[ref.fileId] ?? arriving[ref.fileId];
      return path == null
          ? null
          : linkPlayableForUpload(ref, path, cover: covers[ref.fileId]);
    }

    return [for (final ref in refs) resolve(ref)];
  }

  Future<Object?> _downloadsOp(LinkRequest request) async {
    if (request.method == 'GET') return linkDownloadsPayload(_downloadItems());
    final args = request.args;
    final url = _stringArg(args, 'url');
    if (url != null) {
      final link = await _downloads.resolveUrl(url);
      return {
        'queued': _downloads.enqueue(
          link.tracks,
          playlistName: link.playlistName,
        ),
      };
    }
    final tracks = args['tracks'];
    if (tracks is! List || tracks.isEmpty) throw _invalid('Pass url or tracks');
    final parsed = <Track>[];
    for (final json in tracks) {
      try {
        parsed.add(Track.fromJson(Map<String, dynamic>.from(json as Map)));
      } on Object {
        throw _invalid('Malformed track');
      }
    }
    return {
      'queued': _downloads.enqueue(
        parsed,
        service: _stringArg(args, 'service'),
        quality: _stringArg(args, 'quality'),
        playlistName: _stringArg(args, 'playlistName'),
      ),
    };
  }

  Future<Object?> _open(LinkRequest request) async {
    final url = _stringArg(request.args, 'url');
    if (url == null || !linkOpenableUrl(url)) {
      throw _invalid('Unsupported link');
    }
    await _openUrl(url);
    return const {'ok': true};
  }

  Future<Object?> _resolve(LinkRequest request) async {
    final tracks = request.args['tracks'];
    if (tracks is! List) throw _invalid('Missing tracks');
    final index = _index();
    if (index == null) {
      throw const LinkException('unavailable', 'The catalog is not ready');
    }
    return {
      'songIds': [
        for (final json in tracks)
          switch (TrackRef.fromJson(json)) {
            null => null,
            final ref => index.songIdForRef(ref),
          },
      ],
    };
  }

  /// `subsonic/getPlayQueue`: what the device saved, unless the desktop's
  /// own queue changed since; then the desktop's queue.
  Future<Object?> _getPlayQueue(LinkRequest request) async {
    final saved = _savedQueues[request.deviceId];
    if (saved != null && saved.changedMs >= _desktopQueueChangedMs) {
      return saved.toJson();
    }
    final snapshot = _player.snapshot();
    final index = _index();
    final window = linkQueueWindow(
      snapshot.queue.length,
      snapshot.index,
      max: maxPlayQueue,
    );
    final songIds = <String>[];
    String? currentId;
    for (var i = window.start; i < window.end; i++) {
      final item = snapshot.queue[i];
      final id = index?.songIdForMedia(id: item.id, path: item.path);
      if (id == null) continue;
      songIds.add(id);
      if (i == snapshot.index) currentId = id;
    }
    return {
      'songIds': songIds,
      'currentId': ?currentId,
      'positionMs': currentId == null ? 0 : snapshot.positionMs,
      'changedMs': _desktopQueueChangedMs == 0
          ? _nowMs()
          : _desktopQueueChangedMs,
      'changedBy': _desktopName(),
    };
  }

  Future<Object?> _savePlayQueue(LinkRequest request) async {
    final args = request.args;
    final songs = args['songs'];
    _savedQueues[request.deviceId] = LinkSavedPlayQueue(
      songIds: [
        if (songs is List)
          for (final song in songs)
            if (song is Map && song['id'] is String) song['id'] as String,
      ],
      currentId: _stringArg(args, 'currentId'),
      positionMs: math.max(0, _intArg(args, 'positionMs') ?? 0),
      changedMs: _nowMs(),
      changedBy: _deviceName(request.deviceId),
    );
    return const <String, dynamic>{};
  }
}
