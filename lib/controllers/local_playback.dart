import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/widgets/app_snack_bar.dart';

/// Plays [track] from download history or the local library when a matching
/// file already exists on disk.
///
/// Returns true when playback started (or when an error was surfaced to the
/// user), so callers can skip enqueueing a download; returns false when no
/// local copy is available. Stale history entries whose file no longer exists
/// are pruned as a side effect.
Future<bool> playLocalIfAvailable(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  final historyNotifier = ref.read(downloadHistoryProvider.notifier);

  try {
    DownloadHistoryItem? historyItem = await historyNotifier
        .getBySpotifyIdAsync(track.id);
    final isrc = track.isrc?.trim();
    historyItem ??= (isrc != null && isrc.isNotEmpty)
        ? await historyNotifier.getByIsrcAsync(isrc)
        : null;
    historyItem ??= await historyNotifier.findByTrackAndArtistAsync(
      track.name,
      track.artistName,
    );

    if (historyItem != null) {
      final exists = await fileExists(historyItem.filePath);
      if (exists) {
        await ref
            .read(playbackProvider.notifier)
            .playLocalPath(
              path: historyItem.filePath,
              title: track.name,
              artist: track.artistName,
              album: track.albumName,
              coverUrl: track.coverUrl ?? '',
            );
        return true;
      }
      historyNotifier.removeFromHistory(historyItem.id);
    }

    if (!ref.read(settingsProvider).localLibraryEnabled) return false;
    final localItem = await ref
        .read(localLibraryProvider.notifier)
        .findExistingAsync(
          isrc: isrc,
          trackName: track.name,
          artistName: track.artistName,
        );

    if (localItem != null && await fileExists(localItem.filePath)) {
      await ref
          .read(playbackProvider.notifier)
          .playLocalPath(
            path: localItem.filePath,
            title: localItem.trackName,
            artist: localItem.artistName,
            album: localItem.albumName,
            coverUrl: localItem.coverPath ?? track.coverUrl ?? '',
          );
      return true;
    }
  } catch (e) {
    if (context.mounted) showCannotOpenFileSnackBar(context, e);
    return true;
  }

  return false;
}
