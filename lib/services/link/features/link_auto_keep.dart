import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/link/features/link_library_lookup.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkAutoKeep');

/// The kept collection id of Loved.
const linkKeptLoved = 'loved';

/// The kept collection id of the playlist [playlistId].
String linkKeptPlaylist(String playlistId) => 'playlist:$playlistId';

/// The playlist id of the kept collection [collection], or null for Loved
/// and unknown ids.
String? linkKeptPlaylistId(String collection) =>
    collection.startsWith('playlist:') ? collection.substring(9) : null;

/// The collections kept on this phone: their songs from the paired
/// computer are saved here by themselves while it is connected. Stored on
/// this phone only, in SharedPreferences, and never synced.
class LinkKeptCollections extends AsyncNotifier<Set<String>> {
  static const prefsKey = 'link_kept_collections';

  @override
  Future<Set<String>> build() async {
    final prefs = await SharedPreferences.getInstance();
    return Set.unmodifiable(prefs.getStringList(prefsKey) ?? const []);
  }

  /// Keeps [collection] on this phone, or stops keeping it. Stopping never
  /// deletes a saved song.
  Future<void> setKept(String collection, bool kept) async {
    final next = {...await future};
    if (kept ? !next.add(collection) : !next.remove(collection)) return;
    state = AsyncData(Set.unmodifiable(next));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(prefsKey, next.toList()..sort());
  }
}

final linkKeptCollectionsProvider =
    AsyncNotifierProvider<LinkKeptCollections, Set<String>>(
      LinkKeptCollections.new,
    );

/// The membership of each kept collection in [state], as one number per
/// collection. Loading a playlist's tracks keeps its number, so only an
/// added or removed song counts as a change.
Map<String, int> linkKeptMembership(
  LibraryCollectionsState state,
  Set<String> kept,
) => {
  for (final collection in kept)
    if (collection == linkKeptLoved)
      collection: Object.hashAllUnordered(state.loved.map((entry) => entry.key))
    else if (linkKeptPlaylistId(collection) case final id?)
      if (state.playlistById(id) case final playlist?)
        collection: Object.hashAllUnordered(playlist.trackKeys),
};

/// Queues [songs] as one incoming transfer and completes with its last
/// status, or with null when nothing was queued.
typedef LinkKeepQueue =
    Future<LinkTransferStatus?> Function(List<LinkOfflineSong> songs);

/// Saves the paired computer's songs of the kept collections to this phone
/// through the existing saver and Transfers. A run starts [debounce] after
/// the computer connects, a kept collection gains or loses a song, or a
/// collection is newly kept, and one runs at a time: a reason arriving
/// meanwhile runs once more afterwards. A run only queues songs the saver
/// says this phone does not have, and never deletes anything. Songs that
/// failed wait for the next connection or the next change of a kept
/// collection, so a song that keeps failing is not fetched in a loop.
class LinkAutoKeeper {
  LinkAutoKeeper({
    required this.kept,
    required this.tracksOf,
    required this.desktopSongsOf,
    required this.saver,
    required this.queue,
    this.debounce = const Duration(seconds: 5),
  });

  /// The kept collection ids.
  final Future<Set<String>> Function() kept;

  /// The tracks of a kept collection, or null when it no longer exists.
  final Future<List<Track>?> Function(String collection) tracksOf;

  /// The songs among [tracks] that this phone plays from [server].
  final Future<List<LinkOfflineSong>> Function(
    List<Track> tracks,
    LinkServerRecord server,
  )
  desktopSongsOf;

  /// Saves the paired computer's songs, or null while none is paired.
  final LinkOfflineSaver? Function() saver;
  final LinkKeepQueue queue;
  final Duration debounce;

  LinkClientApi? _client;
  StreamSubscription<LinkConnectionState>? _states;
  Timer? _timer;
  Future<void>? _running;
  bool _again = false;
  bool _retryFailed = false;
  bool _disposed = false;

  /// Song ids that failed since the last connection or kept change.
  final _failed = <String>{};

  /// Completes when no run waits or runs.
  @visibleForTesting
  Future<void> get idle async {
    while (!_disposed && (_timer?.isActive == true || _running != null)) {
      await (_running ?? Future<void>.delayed(debounce));
    }
  }

  /// Follows [client], the paired computer's session, or none.
  void attach(LinkClientApi? client) {
    if (_disposed || identical(client, _client)) return;
    unawaited(_states?.cancel());
    _states = null;
    _timer?.cancel();
    _failed.clear();
    _client = client;
    if (client == null) return;
    _states = client.connectionStates.listen((state) {
      if (state == LinkConnectionState.connected) {
        _schedule(retry: true);
      } else {
        _timer?.cancel();
      }
    });
    if (client.connectionState == LinkConnectionState.connected) {
      _schedule(retry: true);
    }
  }

  /// A kept collection gained or lost a song, here or through the sync.
  void collectionsChanged() => _schedule(retry: true);

  /// A collection was newly kept.
  void marked() => _schedule(retry: false);

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(_states?.cancel());
    _states = null;
    _client = null;
  }

  void _schedule({required bool retry}) {
    if (_disposed || _client == null) return;
    _retryFailed = _retryFailed || retry;
    _timer?.cancel();
    _timer = Timer(debounce, _start);
  }

  void _start() {
    if (_disposed) return;
    if (_running != null) {
      _again = true;
      return;
    }
    _running = _run().whenComplete(() {
      _running = null;
      if (_again) {
        _again = false;
        _start();
      }
    });
  }

  Future<void> _run() async {
    final client = _client;
    if (client == null ||
        client.connectionState != LinkConnectionState.connected) {
      return;
    }
    final saver = this.saver();
    if (saver == null) return;
    if (_retryFailed) {
      _retryFailed = false;
      _failed.clear();
    }
    try {
      final songs = <LinkOfflineSong>[];
      final seen = <String>{};
      for (final collection in await kept()) {
        final tracks = await tracksOf(collection);
        if (tracks == null || tracks.isEmpty) continue;
        for (final song in await desktopSongsOf(tracks, client.server)) {
          if (_failed.contains(song.songId) || !seen.add(song.songId)) {
            continue;
          }
          if (!await saver.has(song)) songs.add(song);
        }
      }
      if (songs.isEmpty || _disposed || !identical(client, _client)) return;
      _log.i('Keeping ${songs.length} songs on this phone');
      final status = await queue(songs);
      if (status == null) return;
      // Songs after the last one finished were never tried, for example
      // after a cancel or without a download folder.
      final end = status.state == LinkTransferState.done
          ? songs.length
          : status.index.clamp(0, songs.length);
      for (final index in {
        ...status.failed,
        for (var i = end; i < songs.length; i++) i,
      }) {
        if (index >= 0 && index < songs.length) {
          _failed.add(songs[index].songId);
        }
      }
    } on Object catch (error) {
      _log.w('Keeping songs on this phone failed: $error');
    }
  }
}

/// The tracks of the kept [collection], or null when it no longer exists.
Future<List<Track>?> linkKeptTracks(Ref ref, String collection) async {
  if (collection == linkKeptLoved) {
    final state = ref.read(libraryCollectionsProvider);
    return state.isLoaded
        ? [for (final entry in state.loved) entry.track]
        : null;
  }
  final id = linkKeptPlaylistId(collection);
  if (id == null) return null;
  await ref.read(libraryCollectionsProvider.notifier).ensurePlaylistLoaded(id);
  if (!ref.mounted) return null;
  final playlist = ref.read(libraryCollectionsProvider).playlistById(id);
  return playlist == null
      ? null
      : [for (final entry in playlist.tracks) entry.track];
}

/// Quiet time before a keep run. Tests override it.
final linkAutoKeepDebounceProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 5),
);

/// The songs among [tracks] that play from [server], matched to the Library
/// as playing the collection matches them. Tests override it.
final linkKeepDesktopSongsProvider =
    Provider<
      Future<List<LinkOfflineSong>> Function(
        List<Track> tracks,
        LinkServerRecord server,
      )
    >(
      (ref) =>
          (tracks, server) async => linkSongsNotOnThisPhone(
            linkOfflineSongs([
              for (final item in await linkLibraryItemsFor(
                tracks,
                includeLocal: ref.read(settingsProvider).localLibraryEnabled,
              ))
                ?item.localItem,
            ], server),
          ),
    );

/// The [songs] this phone has no file of. A download of the same song, or a
/// copy saved from another paired device, already keeps it here: without
/// this, a second device sharing the same songs had every one copied again.
Future<List<LinkOfflineSong>> linkSongsNotOnThisPhone(
  List<LinkOfflineSong> songs, {
  HistoryDatabase? history,
  Future<bool> Function(String path) exists = fileExists,
}) async {
  if (songs.isEmpty) return songs;
  final copies = await (history ?? HistoryDatabase.instance)
      .findExistingTracks([
        for (final song in songs)
          HistoryLookupRequest(
            spotifyId: '',
            isrc: song.item.isrc,
            trackName: song.item.trackName,
            artistName: song.item.artistName,
          ),
      ]);
  final missing = <LinkOfflineSong>[];
  for (var i = 0; i < songs.length; i++) {
    final path = copies[i]?['filePath'] as String? ?? '';
    // A copy on network storage is not on this phone.
    final here =
        path.isNotEmpty && !path.startsWith('network://') && await exists(path);
    if (!here) missing.add(songs[i]);
  }
  return missing;
}

/// Keeps the kept collections on this phone, for the app's lifetime on
/// phones ([linkPhoneFeaturesProvider] keeps it alive). Transfers come
/// through [linkPhoneReceiverProvider], so they show on the Transfers page.
final linkAutoKeepProvider = Provider<LinkAutoKeeper>((ref) {
  final keeper = LinkAutoKeeper(
    kept: () => ref.read(linkKeptCollectionsProvider.future),
    tracksOf: (collection) => linkKeptTracks(ref, collection),
    desktopSongsOf: ref.watch(linkKeepDesktopSongsProvider),
    saver: () => ref.read(linkOfflineSaverProvider),
    queue: (songs) {
      final finished = Completer<LinkTransferStatus?>();
      final transfer = ref
          .read(linkPhoneReceiverProvider)
          .save(songs, onFinished: finished.complete);
      return transfer == null ? Future.value() : finished.future;
    },
    debounce: ref.watch(linkAutoKeepDebounceProvider),
  );
  ref.listen(
    linkPhoneClientProvider,
    (_, client) => keeper.attach(client),
    fireImmediately: true,
  );

  // Compared per collection kept both times, so keeping or loading one is
  // not a change of its songs.
  var membership = <String, int>{};
  var loaded = false;
  void collectionsChanged() {
    final state = ref.read(libraryCollectionsProvider);
    final kept = ref.read(linkKeptCollectionsProvider).value ?? const {};
    final next = linkKeptMembership(state, kept);
    final changed = next.entries.any(
      (entry) =>
          membership.containsKey(entry.key) &&
          membership[entry.key] != entry.value,
    );
    membership = next;
    if (changed) {
      keeper.collectionsChanged();
    } else if (state.isLoaded && !loaded && kept.isNotEmpty) {
      // The collections finished loading after the computer connected.
      keeper.marked();
    }
    loaded = state.isLoaded;
  }

  ref.listen(
    libraryCollectionsProvider,
    (_, _) => collectionsChanged(),
    fireImmediately: true,
  );
  ref.listen(linkKeptCollectionsProvider, (previous, next) {
    final before = previous?.value ?? const <String>{};
    final after = next.value ?? const <String>{};
    collectionsChanged();
    if (after.difference(before).isNotEmpty) keeper.marked();
  });
  ref.onDispose(keeper.dispose);
  return keeper;
});
