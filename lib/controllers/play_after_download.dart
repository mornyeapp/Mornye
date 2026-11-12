import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/widgets/track_detail_actions.dart';

/// Downloads a track with the normal Mornye provider/quality selection and
/// opens the completed audio in the Android external player.
///
/// This is deliberately NOT streaming: downloading, decryption and finalization
/// finish before an ACTION_VIEW intent is sent. The saved file is retained.
void playAfterDownload(BuildContext context, WidgetRef ref, Track track) {
  final container = ProviderScope.containerOf(context, listen: false);
  final knownQueueIds = container
      .read(downloadQueueProvider)
      .items
      .map((item) => item.id)
      .toSet();
  final started = DateTime.now().subtract(const Duration(seconds: 2));

  ProviderSubscription<DownloadQueueState>? listener;
  Timer? expiry;
  String? requestId;
  var disposed = false;

  void notify(String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void stop() {
    if (disposed) return;
    disposed = true;
    expiry?.cancel();
    listener?.close();
  }

  listener = container.listen<DownloadQueueState>(
    downloadQueueProvider,
    (previous, next) {
      if (disposed) return;
      for (final item in next.items) {
        if (requestId == null) {
          if (knownQueueIds.contains(item.id) ||
              item.createdAt.isBefore(started) ||
              item.track.id != track.id ||
              item.track.name != track.name ||
              item.track.artistName != track.artistName) {
            continue;
          }
          requestId = item.id;
        }
        if (item.id != requestId) continue;

        if (item.status == DownloadStatus.completed) {
          final path = item.filePath;
          stop();
          if (path == null || path.isEmpty) {
            notify('Download completed, but the audio file is unavailable.');
            return;
          }
          // openFile handles both ordinary files and Android SAF content URIs.
          unawaited(
            openFile(path).catchError((Object error) {
              notify('Unable to open an external player: $error');
            }),
          );
          return;
        }

        if (item.status == DownloadStatus.failed ||
            item.status == DownloadStatus.skipped) {
          stop();
          notify(
            item.errorMessage.isEmpty
                ? 'Unable to prepare the audio for playback.'
                : item.errorMessage,
          );
          return;
        }
      }
    },
  );

  // Prevent lingering observers if the user dismisses the quality dialog
  // without choosing a provider or if the transfer never completes.
  expiry = Timer(const Duration(minutes: 30), stop);

  try {
    downloadSingleTrack(context, ref, track);
  } catch (_) {
    stop();
    rethrow;
  }
}
