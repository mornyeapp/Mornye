import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/utils/audio_quality_badge_policy.dart';
import 'package:mornye/utils/string_utils.dart';

enum LibraryItemSource { downloaded, local }

/// A library track backed by either a download-history record or a
/// local-library scan record, unified for shared list and batch handling.
class UnifiedLibraryItem {
  final String id;
  final String trackName;
  final String artistName;
  final String albumName;
  final String? coverUrl;
  final String? localCoverPath;
  final String filePath;
  final String? quality;
  final DateTime addedAt;
  final LibraryItemSource source;

  final DownloadHistoryItem? historyItem;
  final LocalLibraryItem? localItem;

  UnifiedLibraryItem({
    required this.id,
    required this.trackName,
    required this.artistName,
    required this.albumName,
    this.coverUrl,
    this.localCoverPath,
    required this.filePath,
    this.quality,
    required this.addedAt,
    required this.source,
    this.historyItem,
    this.localItem,
  });

  factory UnifiedLibraryItem.fromDownloadHistory(DownloadHistoryItem item) {
    return UnifiedLibraryItem(
      id: 'dl_${item.id}',
      trackName: item.trackName,
      artistName: item.artistName,
      albumName: item.albumName,
      coverUrl: item.coverUrl,
      filePath: item.filePath,
      quality:
          buildDisplayAudioQuality(
            bitDepth: item.bitDepth,
            sampleRate: item.sampleRate,
            bitrateKbps: item.bitrate,
            format: item.format,
          ) ??
          item.quality,
      addedAt: item.downloadedAt,
      source: LibraryItemSource.downloaded,
      historyItem: item,
    );
  }

  factory UnifiedLibraryItem.fromLocalLibrary(LocalLibraryItem item) {
    return UnifiedLibraryItem(
      id: 'local_${item.id}',
      trackName: item.trackName,
      artistName: item.artistName,
      albumName: item.albumName,
      coverUrl: null,
      localCoverPath: item.coverPath,
      filePath: item.filePath,
      quality: buildDisplayAudioQuality(
        bitDepth: item.bitDepth,
        sampleRate: item.sampleRate,
        bitrateKbps: item.bitrate,
        format: item.format,
      ),
      addedAt: item.fileModTime != null
          ? DateTime.fromMillisecondsSinceEpoch(item.fileModTime!)
          : item.scannedAt,
      source: LibraryItemSource.local,
      localItem: item,
    );
  }

  String? qualityForMode(String mode) {
    final history = historyItem;
    if (history != null) {
      return buildLibraryAudioQualityLabel(
        mode: mode,
        format: history.format,
        filePath: history.filePath,
        fileName: history.safFileName,
        bitrateKbps: history.bitrate,
        bitDepth: history.bitDepth,
        sampleRate: history.sampleRate,
        storedQuality: history.quality ?? quality,
      );
    }

    final local = localItem;
    if (local != null) {
      return buildLibraryAudioQualityLabel(
        mode: mode,
        format: local.format,
        filePath: local.filePath,
        bitrateKbps: local.bitrate,
        bitDepth: local.bitDepth,
        sampleRate: local.sampleRate,
        storedQuality: quality,
      );
    }

    return quality;
  }

  /// Returns the collection key used to match this item against playlist
  /// entries: prefer ISRC, fall back to source:id.
  String get collectionKey {
    if (historyItem != null) {
      return libraryTrackCollectionKey(
        id: historyItem!.collectionTrackId,
        source: historyItem!.collectionTrackSource,
        isrc: historyItem!.isrc,
      );
    }
    if (localItem != null) {
      return libraryTrackCollectionKey(
        id: localItem!.id,
        source: 'local',
        isrc: localItem!.isrc,
      );
    }
    return libraryTrackCollectionKey(id: id);
  }

  Track toTrack() {
    if (historyItem != null) {
      final h = historyItem!;
      return Track(
        id: h.collectionTrackId,
        name: h.trackName,
        artistName: h.artistName,
        albumName: h.albumName,
        albumArtist: h.albumArtist,
        coverUrl: h.coverUrl,
        isrc: h.isrc,
        duration: h.duration ?? 0,
        trackNumber: h.trackNumber,
        discNumber: h.discNumber,
        releaseDate: h.releaseDate,
        source: h.collectionTrackSource,
      );
    }
    if (localItem != null) {
      final l = localItem!;
      return Track(
        id: l.id,
        name: l.trackName,
        artistName: l.artistName,
        albumName: l.albumName,
        albumArtist: l.albumArtist,
        coverUrl: l.coverPath,
        isrc: l.isrc,
        duration: l.duration ?? 0,
        trackNumber: l.trackNumber,
        discNumber: l.discNumber,
        releaseDate: l.releaseDate,
        source: 'local',
      );
    }
    return Track(
      id: id,
      name: trackName,
      artistName: artistName,
      albumName: albumName,
      coverUrl: coverUrl,
      duration: 0,
    );
  }
}
