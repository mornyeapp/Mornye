import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show listEquals, protected;
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/remote_playback.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/playback_artwork.dart';

final _log = AppLogger('LinkMirroredPlayback');

class _LinkSeek {
  _LinkSeek({
    required this.track,
    required this.index,
    required this.targetMs,
    required this.startedMs,
    required int previousMs,
  }) : toleranceMs = ((targetMs - previousMs).abs() ~/ 2).clamp(50, 500);

  final TrackRef track;
  final int index;
  final int targetMs;
  final int startedMs;
  final int toleranceMs;
  final done = Completer<void>();

  bool matches(LinkPlayerState player) {
    final other = player.track;
    if (player.index != index || other == null) return false;
    if (track.fileId != null && other.fileId != null) {
      return track.fileId == other.fileId;
    }
    if (track.songId != null && other.songId != null) {
      return track.songId == other.songId && track.serverId == other.serverId;
    }
    // The phone may resolve file ids and ISRCs after its first state push.
    return track.title == other.title &&
        track.artist == other.artist &&
        track.album == other.album;
  }
}

/// Another Mornye Link device's player, from the `player.state` it pushes,
/// as this device's player screens show and drive it. Each track shows as
/// [resolvePlayable] finds it on this device, else as its ref describes it.
/// The phone shows the computer this way, and the computer a phone.
abstract class LinkMirroredPlayback implements RemotePlayback {
  LinkMirroredPlayback({
    required this.name,
    required CoverStore covers,
    Future<String?> Function(String source)? extractArtwork,
    MediaItem? initialItem,
    PlaybackState? initialState,
    Duration tick = const Duration(milliseconds: 500),
    Duration seekTimeout = const Duration(seconds: 3),
    int Function()? nowMs,
  }) : _covers = covers,
       _extractArtwork =
           extractArtwork ??
           ((source) =>
               DownloadedEmbeddedCoverResolver.resolveOrExtract(source)),
       _mediaItem = _Latest(initialItem),
       _playbackState = _Latest(initialState ?? PlaybackState()),
       _tick = tick,
       _seekTimeout = seekTimeout,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _coverChanges = covers.changes.listen(_showCover);
  }

  @override
  final String name;

  /// The stored files of network covers, which items show.
  final CoverStore _covers;
  final Future<String?> Function(String source) _extractArtwork;
  final Duration _tick;
  final Duration _seekTimeout;
  final int Function() _nowMs;

  /// How many entries after the current song take priority over earlier ones.
  static const _resolveAhead = 20;
  static const _maxResolutions = 4;
  static const _itemLimit = 500;

  /// How many entries after the current song have their network covers
  /// fetched ahead. Other rows fetch theirs as they show.
  static const _coversAhead = 3;

  /// Starts with the constructor's `initialItem`, the song just sent there,
  /// so the player does not empty out until the device's state arrives.
  final _Latest<MediaItem?> _mediaItem;
  final _Latest<PlaybackState> _playbackState;
  final _queue = _Latest<List<MediaItem>>(const []);
  final _volume = _Latest<double>(1);
  final _transfer = _Latest<RemoteTransfer?>(null);

  /// The item each entry of [_queue] copies. Every entry is its own object,
  /// as in the local queue, so a repeated song keeps distinct rows.
  List<MediaItem> _queueBases = const [];

  /// The best item known for each track, and the tracks whose lookup ran.
  final _items = <TrackRef, MediaItem>{};
  final _resolved = <TrackRef>{};
  final _resolving = <TrackRef>{};
  final _pending = <TrackRef>{};
  final _failed = <TrackRef>{};

  /// Network covers asked of the store since the tracks were last refreshed.
  final _coverChecks = <String>{};
  final _coverRequests = <String, Object>{};
  late final StreamSubscription<String> _coverChanges;

  MediaItem? _currentBase;
  LinkPlayerState? _player;
  List<TrackRef> _queueRefs = const [];
  Timer? _ticker;
  Timer? _seekTimer;
  _LinkSeek? _seek;
  bool _disposed = false;
  int _lookupGeneration = 0;

  /// Sends [command] to the device shown.
  @protected
  Future<void> send(LinkCommand command);

  /// The item for [ref] known without a lookup, or null.
  @protected
  PlayableMedia? immediatePlayable(TrackRef ref) => null;

  /// Looks [ref] up on this device: its own file for the track, else the
  /// best description it has, or null.
  @protected
  Future<PlayableMedia?> resolvePlayable(TrackRef ref);

  /// The device's state shown last.
  @protected
  LinkPlayerState? get player => _player;

  @protected
  bool get disposed => _disposed;

  @override
  Stream<MediaItem?> get mediaItems => _mediaItem.stream;

  @override
  Stream<PlaybackState> get playbackStates => _playbackState.stream;

  @override
  Stream<List<MediaItem>> get queues => _queue.stream;

  @override
  Stream<double> get volumes => _volume.stream;

  @override
  Stream<RemoteTransfer?> get transfers => _transfer.stream;

  /// Looks up again the tracks whose lookup or cover failed, as once the
  /// device is reachable again.
  @protected
  void retryFailed() {
    for (final ref in _failed) {
      final reference = _items[ref]?.extras?['artworkRef'];
      if (reference is! String) continue;
      // The store waits a while after a failed fetch; the device is back.
      _covers.invalidate(reference);
      _coverChecks.remove(reference);
    }
    _resolved.removeAll(_failed);
    _failed.clear();
  }

  /// A catalog or its covers arrived after the player state. Keep the shown
  /// items while resolving them again, including earlier coverless matches.
  void refreshTracks() {
    if (_disposed) return;
    _lookupGeneration++;
    _resolved.clear();
    _failed.clear();
    _coverChecks.clear();
    _showTracks(force: false);
  }

  /// The network cover [reference] changed on its server: the playing and
  /// next songs with it check it again now, other songs once they show, so
  /// a job changing many songs fetches no covers nobody sees.
  void refreshCover(String reference) {
    if (_disposed) return;
    _covers.invalidate(reference);
    _coverChecks.remove(reference);
    _fetchShownCovers();
  }

  /// Shows the device's [player].
  void show(LinkPlayerState? player) {
    if (_disposed) return;
    final seek = _seek;
    if (seek != null) {
      final elapsed = (_nowMs() - seek.startedMs).clamp(0, 1 << 31);
      final advanced = player?.playing == true ? elapsed : 0;
      if (player == null ||
          !seek.matches(player) ||
          (player.positionMs >= seek.targetMs - seek.toleranceMs &&
              player.positionMs <=
                  seek.targetMs + advanced + seek.toleranceMs)) {
        _endSeek();
      }
    }
    _player = player;
    if (player != null) _volume.add(player.volume.clamp(0.0, 1.0));
    _showTracks(force: false);
    _showPlayback();
    final playing = player?.playing ?? false;
    if (playing != (_ticker != null)) {
      _ticker?.cancel();
      _ticker = playing ? Timer.periodic(_tick, (_) => _showPlayback()) : null;
    }
  }

  void _showTracks({required bool force}) {
    final player = _player;
    final track = player?.track;
    if (track != null) _itemFor(track);
    final refs = player?.queue ?? const <TrackRef>[];
    if (force || !listEquals(refs, _queueRefs)) {
      _queueRefs = refs;
      _showQueue([for (final ref in refs) _itemFor(ref)]);
    }
    // Prioritize the playing song and those next, then fill the rest of the
    // bounded queue window, including entries before the playing song.
    _pending.clear();
    void schedule(TrackRef ref) {
      if (!_resolved.contains(ref) && !_resolving.contains(ref)) {
        _pending.add(ref);
      }
    }

    if (track != null) schedule(track);
    final start = player?.index ?? 0;
    for (final ref in refs.skip(start < 0 ? 0 : start).take(_resolveAhead)) {
      schedule(ref);
    }
    for (final ref in refs) {
      schedule(ref);
    }
    _drainResolutions();
    _fetchShownCovers();
    _showCurrent();
  }

  /// Keep the previous display cover while the new track's lookup or cover
  /// fetch is pending. Queue entries never borrow another song's artwork.
  /// A completed lookup without artwork restores the normal placeholder.
  void _showCurrent() {
    final track = _player?.track;
    final base = track == null ? null : _itemFor(track);
    final waiting =
        track != null &&
        (!_resolved.contains(track) ||
            _coverRequests.containsKey(base?.extras?['artworkRef']));
    final artwork = base?.artUri ?? (waiting ? _mediaItem.value?.artUri : null);
    if (identical(base, _currentBase) && artwork == _mediaItem.value?.artUri) {
      return;
    }
    _currentBase = base;
    _mediaItem.add(
      base == null || artwork == base.artUri
          ? base
          : base.copyWith(artUri: artwork),
    );
  }

  /// [_fetchCovers] for the playing song and the next [_coversAhead].
  void _fetchShownCovers() {
    final player = _player;
    final start = player?.index ?? 0;
    _fetchCovers({
      ?player?.track,
      ...?player?.queue.skip(start < 0 ? 0 : start).take(_coversAhead + 1),
    });
  }

  /// Asks the store for the network covers of [refs], fetching those not
  /// stored yet, and shows each once it is there. Songs showing the cover
  /// from their tags skip it.
  void _fetchCovers(Set<TrackRef> refs) {
    for (final ref in refs) {
      final extras = _items[ref]?.extras;
      final reference = extras?['artworkRef'];
      final source = extras?['source'];
      if (reference is! String ||
          _failed.contains(ref) ||
          (source is String && _covers.songCover(source) != null) ||
          !_coverChecks.add(reference)) {
        continue;
      }
      final request = Object();
      _coverRequests[reference] = request;
      unawaited(
        _covers.file(reference).then((path) {
          if (_disposed || !identical(_coverRequests[reference], request)) {
            return;
          }
          _coverRequests.remove(reference);
          if (path == null) {
            _coverChecks.remove(reference);
            _failed.add(ref);
          }
          _showCover(reference);
          _showCurrent();
        }),
      );
    }
  }

  /// Shows the stored cover of the songs whose tag cover or network cover
  /// is [reference] on their items.
  void _showCover(String reference) {
    if (_disposed) return;
    var changed = false;
    for (final MapEntry(:key, :value) in _items.entries.toList()) {
      final source = value.extras?['source'];
      final network = value.extras?['artworkRef'];
      if (source is! String ||
          (reference != network &&
              reference != CoverStore.songCoverReference(source))) {
        continue;
      }
      final cover = _covers.songCover(
        source,
        network is String ? network : null,
      );
      if (cover == null || value.artUri == Uri.file(cover.path)) continue;
      _items[key] = value.copyWith(artUri: Uri.file(cover.path));
      changed = true;
    }
    if (changed) _showTracks(force: true);
  }

  void _drainResolutions() {
    while (!_disposed &&
        _resolving.length < _maxResolutions &&
        _pending.isNotEmpty) {
      final ref = _pending.first;
      _pending.remove(ref);
      _resolving.add(ref);
      unawaited(_resolve(ref));
    }
  }

  /// Shows a queue of [bases], keeping the entry objects of the songs it
  /// already showed, so moved rows keep their identity.
  void _showQueue(List<MediaItem> bases) {
    final spare = Map<MediaItem, List<MediaItem>>.identity();
    final shown = _queue.value;
    for (var i = 0; i < _queueBases.length && i < shown.length; i++) {
      spare.putIfAbsent(_queueBases[i], () => []).add(shown[i]);
    }
    _queueBases = bases;
    final entries = <MediaItem>[];
    for (final base in bases) {
      final reused = spare[base];
      entries.add(
        reused != null && reused.isNotEmpty
            ? reused.removeAt(0)
            : base.copyWith(),
      );
    }
    _queue.add(List.unmodifiable(entries));
  }

  void _showPlayback() {
    final player = _player;
    if (player == null || player.track == null) {
      _playbackState.add(PlaybackState());
      return;
    }
    final now = _nowMs();
    final index = player.index;
    _playbackState.add(
      PlaybackState(
        processingState: AudioProcessingState.ready,
        playing: player.playing,
        speed: _seek == null ? 1 : 0,
        updatePosition: Duration(
          milliseconds: _seek?.targetMs ?? player.positionAt(now),
        ),
        updateTime: DateTime.fromMillisecondsSinceEpoch(now),
        queueIndex: index >= 0 && index < player.queue.length ? index : null,
        shuffleMode: player.shuffle
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        repeatMode: switch (player.repeat) {
          LinkRepeatMode.none => AudioServiceRepeatMode.none,
          LinkRepeatMode.all => AudioServiceRepeatMode.all,
          LinkRepeatMode.one => AudioServiceRepeatMode.one,
        },
      ),
    );
  }

  /// The item for [ref]: the looked-up one, else one built from [ref].
  MediaItem _itemFor(TrackRef ref) => _items[ref] ??= _playable(
    ref,
    immediatePlayable(ref),
  ).toMediaItem(covers: _covers);

  PlayableMedia _playable(TrackRef ref, PlayableMedia? media) => PlayableMedia(
    id:
        media?.id ??
        'link:${ref.fileId ?? ref.isrc ?? ref.matchKey ?? ref.title}',
    source: media?.source ?? '',
    title: ref.title,
    artist: ref.artist,
    album: ref.album?.isNotEmpty == true ? ref.album! : media?.album ?? '',
    artUri: media?.artUri,
    networkArtworkSource: media?.networkArtworkSource,
    duration: ref.durationMs == null
        ? media?.duration
        : Duration(milliseconds: ref.durationMs!),
    bitDepth: media?.bitDepth,
    sampleRate: media?.sampleRate,
    bitrate: media?.bitrate,
    format: media?.format,
    explicit: media?.explicit ?? false,
    genre: media?.genre,
    autoplay: media?.autoplay ?? false,
    displayMetadata: media?.displayMetadata ?? const {},
  );

  /// Looks [ref] up once, with its cover: the one embedded in a local file,
  /// else the network cover its item, or the device's own song, names.
  Future<void> _resolve(TrackRef ref) async {
    final generation = _lookupGeneration;
    bool current() => !_disposed && generation == _lookupGeneration;
    try {
      final media = _playable(ref, await resolvePlayable(ref));
      if (!current()) return;
      var artwork = media.artUri;
      if (!media.isNetwork) {
        artwork =
            await resolveEmbeddedArtworkUri(
              media.source,
              artwork,
              extract: _extractArtwork,
            ) ??
            artwork;
      }
      if (!current()) return;
      // A matched local file may have no thumbnail, or one its scan removed.
      // Keep its identity for lyrics and favorites, but borrow the device's
      // cover.
      final uri = Uri.tryParse(artwork ?? '');
      final local = uri != null && (!uri.hasScheme || uri.scheme == 'file');
      String? borrowed;
      // A network cover shows from the store, not as the artwork itself.
      if (artwork == null ||
          artwork.isEmpty ||
          CoverStore.fetches(artwork) ||
          (local &&
              !await File(
                uri.scheme == 'file' ? uri.toFilePath() : artwork,
              ).exists())) {
        artwork = null;
        if (media.coverReference == null) {
          borrowed = immediatePlayable(ref)?.networkArtworkSource;
        }
      }
      if (!current()) return;
      if (_items.length >= _itemLimit) {
        _items.removeWhere((key, _) => !_queueRefs.contains(key));
        _resolved.removeWhere((key) => !_queueRefs.contains(key));
        _failed.removeWhere((key) => !_queueRefs.contains(key));
      }
      var item = media.toMediaItem(resolvedArtwork: artwork, covers: _covers);
      if (borrowed != null) {
        final stored = _covers.indexedFile(borrowed);
        item = item.copyWith(
          artUri: stored == null ? null : Uri.file(stored),
          extras: {...?item.extras, 'artworkRef': borrowed},
        );
      }
      _items[ref] = item;
      _resolved.add(ref);
      if (ref == _player?.track || _queueRefs.contains(ref)) {
        _showTracks(force: true);
      }
    } on Object catch (error) {
      if (!current()) return;
      _resolved.add(ref);
      _failed.add(ref);
      _log.w('Could not look up a song $name plays: $error');
      _showCurrent();
    } finally {
      _resolving.remove(ref);
      if (generation != _lookupGeneration && !_disposed) {
        _showTracks(force: false);
      } else {
        _drainResolutions();
      }
    }
  }

  Future<void> _send(LinkCommand command) async {
    try {
      await send(command);
    } on Object catch (error) {
      _log.w('$name did not take a command: $error');
    }
  }

  @override
  Future<void> play() => _send(const LinkCommand(LinkActions.play));

  @override
  Future<void> pause() => _send(const LinkCommand(LinkActions.pause));

  @override
  Future<void> seek(Duration position) {
    if (_disposed) return Future.value();
    final player = _player;
    final track = player?.track;
    if (player == null || track == null) {
      return _send(
        LinkCommand(LinkActions.seek, {'positionMs': position.inMilliseconds}),
      );
    }
    final reportedDuration = player.durationMs;
    final duration = reportedDuration != null && reportedDuration > 0
        ? reportedDuration
        : track.durationMs;
    final target = position.inMilliseconds.clamp(
      0,
      duration != null && duration > 0 ? duration : (1 << 62),
    );
    _endSeek();
    final seek = _seek = _LinkSeek(
      track: track,
      index: player.index,
      targetMs: target,
      previousMs: player.positionAt(_nowMs()),
      startedMs: _nowMs(),
    );
    // Sending a command only confirms delivery. Keep the timeline at the
    // requested position until the peer reports it, or the request expires.
    _seekTimer = Timer(_seekTimeout, () {
      if (!identical(_seek, seek)) return;
      _endSeek();
      _showPlayback();
    });
    _showPlayback();
    unawaited(
      Future<void>.sync(
        () => send(LinkCommand(LinkActions.seek, {'positionMs': target})),
      ).catchError((Object error) {
        _log.w('$name did not take a seek: $error');
        if (identical(_seek, seek)) {
          _endSeek();
          _showPlayback();
        }
      }),
    );
    return seek.done.future;
  }

  void _endSeek() {
    final seek = _seek;
    _seek = null;
    _seekTimer?.cancel();
    _seekTimer = null;
    if (seek != null) seek.done.complete();
  }

  @override
  Future<void> next() => _send(const LinkCommand(LinkActions.next));

  @override
  Future<void> previous() => _send(const LinkCommand(LinkActions.previous));

  @override
  Future<void> jumpTo(int index) =>
      _send(LinkCommand(LinkActions.jump, {'index': index}));

  @override
  Future<void> moveQueueItem(int from, int to) =>
      _send(LinkCommand(LinkActions.move, {'from': from, 'to': to}));

  @override
  Future<void> removeQueueItem(MediaItem item) async {
    final index = _queue.value.indexWhere((entry) => identical(entry, item));
    if (index >= 0) {
      await _send(LinkCommand(LinkActions.remove, {'index': index}));
    }
  }

  @override
  Future<void> setShuffle(bool enabled) =>
      _send(LinkCommand(LinkActions.shuffle, {'enabled': enabled}));

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode mode) => _send(
    LinkCommand(LinkActions.repeat, {
      'mode': switch (mode) {
        AudioServiceRepeatMode.none => LinkRepeatMode.none,
        AudioServiceRepeatMode.one => LinkRepeatMode.one,
        AudioServiceRepeatMode.all ||
        AudioServiceRepeatMode.group => LinkRepeatMode.all,
      }.name,
    }),
  );

  @override
  Future<void> setVolume(double value) => _send(
    LinkCommand(LinkActions.volume, {'value': value.clamp(0, 1).toDouble()}),
  );

  /// Runs [command], reporting the song files it sends as [transfers].
  @protected
  Future<void> sending(
    Future<void> Function(void Function(int sent, int total) onSending) command,
  ) async {
    try {
      await command((sent, total) {
        if (!_disposed) {
          _transfer.add(RemoteTransfer(sent: sent, total: total));
        }
      });
    } on Object catch (error) {
      _log.w('$name did not take a command: $error');
    } finally {
      if (!_disposed && _transfer.value != null) _transfer.add(null);
    }
  }

  void dispose() {
    _disposed = true;
    _endSeek();
    _pending.clear();
    _coverRequests.clear();
    _ticker?.cancel();
    unawaited(_coverChanges.cancel());
    _mediaItem.close();
    _playbackState.close();
    _queue.close();
    _volume.close();
    _transfer.close();
  }
}

/// A broadcast stream that starts each listener with the latest value.
class _Latest<T> {
  _Latest(this.value);

  T value;
  final _changes = StreamController<T>.broadcast();

  Stream<T> get stream => Stream.multi((listener) {
    listener.add(value);
    final subscription = _changes.stream.listen(
      listener.add,
      onDone: listener.close,
    );
    listener.onCancel = subscription.cancel;
  });

  void add(T next) {
    value = next;
    if (!_changes.isClosed) _changes.add(next);
  }

  void close() => unawaited(_changes.close());
}
