import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/utils/string_utils.dart';

/// Prevents asynchronous queue startup checks from overlapping before
/// [DownloadQueueState.isProcessing] can be published.
class QueueProcessingGate {
  bool _active = false;
  bool _pending = false;

  bool tryEnter() {
    if (_active) {
      _pending = true;
      return false;
    }
    _active = true;
    return true;
  }

  bool leave() {
    _active = false;
    final shouldRunAgain = _pending;
    _pending = false;
    return shouldRunAgain;
  }
}

/// Set on queued items when the persisted Android SAF grant fails validation.
/// The queue UI matches on this to offer re-selecting the download folder.
const String safPermissionLostErrorMessage =
    'SAF permission invalid or revoked. Please reconfigure download location in Settings.';

/// Set on queued items when the iOS download folder bookmark can no longer be
/// opened. The queue UI matches on this to offer re-selecting the folder.
const String downloadFolderAccessLostErrorMessage =
    'Download folder access lost. Please re-select your download folder in Settings.';

enum StorageWriteRecovery { requestSafAccess, useAppFolderFallback }

StorageWriteRecovery storageWriteRecoveryFor({required bool useSaf}) {
  return useSaf
      ? StorageWriteRecovery.requestSafAccess
      : StorageWriteRecovery.useAppFolderFallback;
}

bool canStartForegroundDownloadForLifecycle(AppLifecycleState? lifecycleState) {
  return lifecycleState == AppLifecycleState.resumed;
}

String nativeWorkerStatusAfterSnapshotStop({
  required bool workerRunning,
  required String status,
}) {
  if (workerRunning) return status;
  return switch (status) {
    'preparing' || 'downloading' || 'finalizing' => 'queued',
    _ => status,
  };
}

/// Keeps a download in its finalizing state until its durable Library record
/// has been written. If persistence fails, completion is deliberately not
/// published so the queue can surface the error instead of losing the file
/// from the app while it still exists on disk.
Future<void> persistBeforePublishingDownloadCompletion({
  required Future<void> Function() persist,
  required void Function() publish,
}) async {
  await persist();
  publish();
}

/// Keeps native-worker finalization visually distinct from completion.
/// Download bytes may reach 100% before SAF publishing, metadata persistence,
/// and queue reconciliation have finished.
double nativeWorkerFinalizingProgress(double progress) {
  final normalized = progress.clamp(0.0, 1.0).toDouble();
  if (normalized <= 0) return 0.95;
  return min(normalized, 0.99);
}

/// Whether a backend failure means the selected destination could not be
/// written. This intentionally stays provider-agnostic: once an output path is
/// unwritable, trying more audio providers against that same path only wastes
/// time and hides the actionable storage failure behind a later network error.
bool isStorageWriteFailure({String? errorType, String? errorMessage}) {
  if (errorType?.trim().toLowerCase() == 'permission') return true;

  final message = errorMessage?.trim().toLowerCase() ?? '';
  if (message.isEmpty) return false;
  return message.contains('operation not permitted') ||
      message.contains('permission denied') ||
      message.contains('read-only file system') ||
      message.contains('failed to create file') ||
      message.contains('failed to create directory') ||
      message.contains('failed to access saf directory') ||
      message.contains('failed to create saf file') ||
      message.contains('failed to open saf file') ||
      message.contains('failed to publish saf') ||
      message.contains('failed to publish deferred saf') ||
      message.contains('failed to copy extension output to saf');
}

/// [track] as the download queue keeps it: without a `network://` cover,
/// which only this device's cover store reads (a Loved or playlist entry of
/// a network song), so a download never shows, fetches or embeds one.
Track queuedDownloadTrack(Track track) =>
    track.coverUrl?.startsWith('network://') == true
    ? Track.fromJson({
        ...track.toJson(),
        'coverUrl': null,
        'availability': track.availability?.toJson(),
      })
    : track;

/// Makes the album-artist credit stable for tracks from the same album.
///
/// Some metadata providers expose every `MAIN` track artist as the album
/// artist. On collaboration tracks that turns one album into values such as
/// "Artist", "Artist, Guest A", and "Artist, Guest B". Music libraries then
/// split the files into separate albums. Keep the complete track artist credit
/// intact, but reduce inconsistent album-artist credits to the artist names
/// shared by every track in that album.
List<Track> normalizeBatchAlbumArtists(List<Track> tracks) {
  if (tracks.length < 2) return tracks;

  final albumGroups = <String, List<int>>{};
  for (var index = 0; index < tracks.length; index++) {
    final key = _batchAlbumIdentity(tracks[index]);
    if (key == null) continue;
    albumGroups.putIfAbsent(key, () => <int>[]).add(index);
  }

  List<Track>? normalized;
  for (final indices in albumGroups.values) {
    if (indices.length < 2) continue;
    final albumTracks = [for (final index in indices) tracks[index]];
    final canonicalArtist = _sharedBatchAlbumArtist(albumTracks);
    if (canonicalArtist == null) continue;

    for (final index in indices) {
      final currentArtist = normalizeOptionalString(tracks[index].albumArtist);
      if (currentArtist == canonicalArtist) continue;
      normalized ??= List<Track>.of(tracks);
      normalized[index] = tracks[index].copyWith(albumArtist: canonicalArtist);
    }
  }

  return normalized ?? tracks;
}

String? _batchAlbumIdentity(Track track) {
  final source = normalizeOptionalString(track.source)?.toLowerCase() ?? '';
  final albumId = normalizeOptionalString(track.albumId)?.toLowerCase();
  if (albumId != null) return '$source|id:$albumId';

  final albumName = normalizeOptionalString(track.albumName)?.toLowerCase();
  if (albumName == null) return null;

  final cover = normalizeOptionalString(
    normalizeCoverReference(track.coverUrl),
  )?.toLowerCase();
  if (cover != null) return '$source|cover:$albumName|$cover';

  final releaseDate = normalizeOptionalString(track.releaseDate) ?? '';
  final totalTracks = track.totalTracks ?? 0;
  final primaryArtist = primaryArtistName(
    track.artistName,
    albumArtist: track.albumArtist,
  ).trim().toLowerCase();
  return '$source|meta:$albumName|$releaseDate|$totalTracks|$primaryArtist';
}

String? _sharedBatchAlbumArtist(List<Track> tracks) {
  final albumArtists = tracks
      .map((track) => normalizeOptionalString(track.albumArtist))
      .toList(growable: false);
  final firstAlbumArtist = albumArtists.first;
  if (firstAlbumArtist != null &&
      albumArtists.every(
        (artist) => artist?.toLowerCase() == firstAlbumArtist.toLowerCase(),
      )) {
    return firstAlbumArtist;
  }

  final credits = <List<String>>[];
  for (var index = 0; index < tracks.length; index++) {
    final rawCredit = albumArtists[index] ?? tracks[index].artistName;
    final names = splitArtistNames(rawCredit);
    if (names.isEmpty) return null;
    credits.add(names);
  }

  final sharedKeys = credits.first.map((name) => name.toLowerCase()).toSet();
  for (final credit in credits.skip(1)) {
    final keys = credit.map((name) => name.toLowerCase()).toSet();
    sharedKeys.removeWhere((name) => !keys.contains(name));
  }
  if (sharedKeys.isEmpty) return null;

  // Preserve a provider's original separator whenever one of its credits is
  // already exactly the shared album credit.
  for (final rawCredit in albumArtists.whereType<String>()) {
    final keys = splitArtistNames(
      rawCredit,
    ).map((name) => name.toLowerCase()).toSet();
    if (keys.length == sharedKeys.length && keys.containsAll(sharedKeys)) {
      return rawCredit;
    }
  }

  final displayNames = <String>[];
  final seen = <String>{};
  for (final name in credits.first) {
    final key = name.toLowerCase();
    if (sharedKeys.contains(key) && seen.add(key)) displayNames.add(name);
  }
  return displayNames.isEmpty ? null : displayNames.join(', ');
}
