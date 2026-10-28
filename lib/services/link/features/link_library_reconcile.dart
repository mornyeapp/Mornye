import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/link/client/link_client_controller.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_library_jobs.dart';
import 'package:mornye/services/network_storage_service.dart';

typedef LinkLibraryReconcile =
    Future<void> Function(LinkClientApi client, LinkLibraryJob job);

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
      } finally {
        remote.close();
      }
    }
    if (current()) {
      await ref
          .read(linkLibraryBridgeProvider)
          .rescan(client.server.connectionId);
    }
  },
);
