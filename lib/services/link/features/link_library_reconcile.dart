import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/link/client/link_client_controller.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_library_jobs.dart';
import 'package:mornye/services/network_metadata_service.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/source_deletion_events.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/utils/logger.dart';

typedef LinkLibraryReconcile =
    Future<void> Function(LinkClientApi client, LinkLibraryJob job);

/// Only successful mutations of this desktop's files retire cached state.
Iterable<({String source, bool removed})> linkLibraryChangedSources(
  LinkClientApi client,
  LinkLibraryJob job,
) sync* {
  if (job.active ||
      job.succeeded == 0 ||
      !linkLibraryActionChangesCatalog(job.action)) {
    return;
  }
  for (final result in job.results) {
    if (result['error'] != null || result['songId'] is! String) continue;
    final removed =
        job.action == LinkLibraryAction.delete ||
        (job.action == LinkLibraryAction.convert && result['removed'] == true);
    // Keeping the original adds a separate song; its old queue entry stays.
    if (job.action == LinkLibraryAction.convert && !removed) continue;
    yield (
      source: linkDesktopSongSource(client.server, result['songId'] as String),
      removed: removed,
    );
  }
}

/// Refreshes affected artwork before the catalog rescan. Unrelated albums
/// keep their cached images, including when completed work is recovered.
final linkLibraryReconcileProvider = Provider<LinkLibraryReconcile>(
  (ref) => (client, job) async {
    bool current() =>
        ref.mounted && ref.read(linkPhoneClientProvider) == client;
    if (!current()) return;
    final storage = NetworkStorageService.instance;
    final connection = await storage.connection(client.server.connectionId);
    if (!current()) return;
    if (job.action == LinkLibraryAction.reEnrich ||
        job.action == LinkLibraryAction.editMetadata) {
      final remote = storage.openSubsonic(connection);
      try {
        final directory = Directory(
          '${(await getApplicationSupportDirectory()).path}/library_covers',
        );
        final refreshed = <String>{};
        for (final result in job.results) {
          if (!current()) return;
          if (result['error'] != null) continue;
          final song = await remote.song(
            subsonicSongPath(result['songId'] as String, 'raw'),
          );
          if (!refreshed.add(song.coverId) || song.coverId.isEmpty) continue;
          final path = await remote.cachedCover(song, directory);
          if (path == null) continue;
          if (job.completedMs > 0 &&
              (await File(path).stat()).modified.millisecondsSinceEpoch <
                  job.completedMs) {
            await remote.cachedCover(song, directory, refresh: true);
          }
        }
      } on Object catch (error) {
        AppLogger('LinkLibrary').w('Could not refresh changed artwork: $error');
      } finally {
        remote.close();
      }
    }
    for (final change in linkLibraryChangedSources(client, job)) {
      if (!current()) return;
      await NetworkMetadataService.instance.invalidate(
        change.source,
        refreshArtwork:
            job.action == LinkLibraryAction.editMetadata ||
            job.action == LinkLibraryAction.reEnrich,
      );
      if (!current()) return;
      if (change.removed) {
        await SourceDeletionEvents.instance.publish(change.source);
      } else {
        await SourceMetadataEvents.instance.publish(change.source);
      }
    }
    if (current()) {
      await ref
          .read(linkLibraryBridgeProvider)
          .rescan(client.server.connectionId);
    }
  },
);
