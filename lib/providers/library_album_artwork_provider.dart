import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_album_artwork.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/motion_artwork_store.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('AlbumArtwork');

/// The most a found cover keeps on its longest side, as for scanned covers.
const _coverMaxDimension = 800;

final libraryAlbumArtworkStoreProvider = Provider(
  (ref) => LibraryAlbumArtworkStore(
    database: () => LibraryDatabase.instance.database,
    coverDirectory: () async => Directory(
      '${(await getApplicationSupportDirectory()).path}/library_covers',
    ),
  ),
);

/// The album of the Library song at a path, and what was found for it, for
/// the album's page to show a found cover and offer removing it.
final libraryAlbumArtworkForSongProvider = FutureProvider.autoDispose
    .family<({String albumKey, AlbumArtworkRecord? record})?, String>((
      ref,
      filePath,
    ) async {
      final store = ref.watch(libraryAlbumArtworkStoreProvider);
      final albumKey = await store.albumKeyOf(filePath);
      if (albumKey == null) return null;
      final records = await store.records(albumKey: albumKey);
      return (albumKey: albumKey, record: records[albumKey]);
    });

/// A run of [AlbumArtworkJob] in progress, or its last result.
class LibraryAlbumArtworkState {
  const LibraryAlbumArtworkState({
    this.running = false,
    this.albumKey,
    this.done = 0,
    this.total = 0,
    this.cancelling = false,
  });

  final bool running;

  /// The album a single-album run is for; null for the whole Library.
  final String? albumKey;
  final int done;
  final int total;
  final bool cancelling;
}

/// Looks up artwork for Library albums in the background, so leaving the
/// page that started it does not stop it.
class LibraryAlbumArtworkNotifier extends Notifier<LibraryAlbumArtworkState> {
  bool _cancelled = false;
  Future<int>? _restoring;

  @override
  LibraryAlbumArtworkState build() => const LibraryAlbumArtworkState();

  MotionArtworkStore get _motion => ref.read(motionArtworkStoreProvider);

  Map<String, Extension> _providers() => {
    for (final extension in ref.read(extensionProvider).extensions)
      if (extension.enabled && extension.hasMetadataProvider)
        extension.id: extension,
  };

  /// Whether an enabled extension can look albums up.
  bool canLookUp() => _providers().isNotEmpty;

  AlbumArtworkJob _job() {
    final extensions = ref.read(extensionProvider);
    final byId = _providers();
    final providers = [
      for (final id in extensions.metadataProviderPriority)
        if (byId.containsKey(id)) id,
      for (final id in byId.keys)
        if (!extensions.metadataProviderPriority.contains(id)) id,
    ];
    return AlbumArtworkJob(
      store: ref.read(libraryAlbumArtworkStoreProvider),
      lookup: AlbumArtworkLookup(
        providers: providers,
        search: (providerId, query) {
          final provider = byId[providerId];
          if (provider != null && provider.hasCustomSearch) {
            final filter = provider.searchBehavior?.filterIdForKind('album');
            return PlatformBridge.customSearchWithExtension(
              providerId,
              query,
              options: {'limit': 10, 'filter': ?filter},
            );
          }
          return PlatformBridge.searchTracksWithMetadataProvider(
            providerId,
            query,
            limit: 10,
          );
        },
        details: (providerId, id) =>
            PlatformBridge.getProviderMetadata(providerId, 'album', id),
      ),
      downloadCover: (url, path) async {
        final result = await PlatformBridge.downloadCoverToFile(
          url,
          path,
          maxDimension: _coverMaxDimension,
        );
        return result['error'] == null && result['success'] != false;
      },
      hasMotion: (album) async =>
          await _motion.find(_motionKeys(album).first) != null,
      saveMotion: (album, url) async {
        final keys = _motionKeys(album);
        final saved = await _motion.save(
          keys.first,
          resolveSource: () async => url,
        );
        if (saved == null) return false;
        for (final key in keys.skip(1)) {
          await _motion.alias(key, keys.first);
        }
        return true;
      },
    );
  }

  /// The names players look the album's animated cover up by: the album
  /// with each song artist, and with the album artist.
  static List<MotionArtworkAlbum> _motionKeys(LibraryArtworkAlbum album) => [
    for (final artist in {...album.artists, album.album.artist})
      (album: album.album.album, artist: artist),
  ];

  /// Looks up covers for the albums without one ([covers]) and animated
  /// covers ([motion]) across the Library. Null while another run is busy.
  Future<AlbumArtworkSummary?> findMissing({
    required bool covers,
    required bool motion,
  }) => _run(covers: covers, motion: motion);

  /// Looks [albumKey] up again, also bringing back artwork removed from it.
  /// [motion] asks for an animated cover too, where the page can show one.
  Future<AlbumArtworkSummary?> findForAlbum(
    String albumKey, {
    required bool motion,
  }) => _run(
    covers: true,
    motion: motion && ref.read(settingsProvider).motionArtworkEnabled,
    albumKey: albumKey,
  );

  Future<AlbumArtworkSummary?> _run({
    required bool covers,
    required bool motion,
    String? albumKey,
  }) async {
    if (state.running || (!covers && !motion)) return null;
    _cancelled = false;
    state = LibraryAlbumArtworkState(running: true, albumKey: albumKey);
    try {
      final job = _job();
      if (albumKey == null) await job.restore(cancelled: () => _cancelled);
      final summary = await job.run(
        covers: covers,
        motion: motion,
        albumKey: albumKey,
        force: albumKey != null,
        cancelled: () => _cancelled,
        progress: (done, total) {
          if (!ref.mounted) return;
          state = LibraryAlbumArtworkState(
            running: true,
            albumKey: albumKey,
            done: done,
            total: total,
            cancelling: _cancelled,
          );
        },
      );
      await _changed(covers: summary.songs > 0, motion: summary.motion > 0);
      return summary;
    } catch (error, stack) {
      _log.e('Album artwork lookup failed: $error', error, stack);
      rethrow;
    } finally {
      if (ref.mounted) state = const LibraryAlbumArtworkState();
    }
  }

  void cancel() {
    if (!state.running) return;
    _cancelled = true;
    state = LibraryAlbumArtworkState(
      running: true,
      albumKey: state.albumKey,
      done: state.done,
      total: state.total,
      cancelling: true,
    );
  }

  /// Takes the found cover and animated cover off [albumKey] as wrong, and
  /// keeps later runs from bringing them back.
  Future<void> removeForAlbum(String albumKey) async {
    final store = ref.read(libraryAlbumArtworkStoreProvider);
    final album = (await store.albums(albumKey: albumKey)).firstOrNull;
    final record = await store.removeCover(albumKey);
    if (record == null) return;
    if (record.motionSaved && album != null) {
      for (final key in _motionKeys(album)) {
        await _motion.remove(key);
      }
    }
    await _changed(
      covers: record.coverFile != null,
      motion: record.motionSaved,
    );
  }

  /// Fetches again the found covers a cleared cache deleted. Runs after
  /// scans, which set found covers again only while their files exist.
  Future<int> restoreMissing() =>
      _restoring ??= _restore().whenComplete(() => _restoring = null);

  Future<int> _restore() async {
    try {
      final changed = await _job().restore();
      await _changed(covers: changed > 0, motion: false);
      return changed;
    } catch (error) {
      _log.w('Could not restore found album covers: $error');
      return 0;
    }
  }

  Future<void> _changed({required bool covers, required bool motion}) async {
    if (!ref.mounted) return;
    ref.invalidate(libraryAlbumArtworkForSongProvider);
    if (motion) ref.invalidate(playerMotionArtworkProvider);
    if (covers) {
      ref.read(localLibraryProvider.notifier).notifyArtworkChanged();
    }
  }
}

final libraryAlbumArtworkProvider =
    NotifierProvider<LibraryAlbumArtworkNotifier, LibraryAlbumArtworkState>(
      LibraryAlbumArtworkNotifier.new,
    );
