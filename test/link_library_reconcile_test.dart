import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/features/link_library_reconcile.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/link_library_jobs.dart';

import 'support/link_fakes.dart';

void main() {
  final client = FakeLinkClient();
  tearDownAll(client.close);

  LinkLibraryJob job(
    LinkLibraryAction action, {
    LinkLibraryJobStatus status = LinkLibraryJobStatus.completed,
    bool removed = false,
  }) => LinkLibraryJob(
    id: 'change_1',
    action: action,
    status: status,
    total: 2,
    finished: 2,
    succeeded: 1,
    results: [
      {'songId': 'l:failed', 'error': 'operation_failed'},
      {'songId': 'l:saved', 'removed': removed},
    ],
  );

  for (final action in [
    LinkLibraryAction.editMetadata,
    LinkLibraryAction.reEnrich,
    LinkLibraryAction.replayGain,
    LinkLibraryAction.removeReplayGain,
    LinkLibraryAction.delete,
  ]) {
    test('$action refreshes only the successful file in a partial batch', () {
      final changes = linkLibraryChangedSources(client, job(action)).toList();
      expect(changes, hasLength(1));
      expect(
        linkDesktopSongId(changes.single.source, client.server),
        'l:saved',
      );
      expect(changes.single.removed, action == LinkLibraryAction.delete);
    });
  }

  test('conversion retires an original only when its removal is confirmed', () {
    expect(
      linkLibraryChangedSources(client, job(LinkLibraryAction.convert)),
      isEmpty,
    );
    final change = linkLibraryChangedSources(
      client,
      job(LinkLibraryAction.convert, removed: true),
    ).single;
    expect(change.removed, isTrue);
  });

  test('previews, sidecars and unfinished jobs do not invalidate playback', () {
    for (final action in [
      LinkLibraryAction.readMetadata,
      LinkLibraryAction.reEnrichPreview,
      LinkLibraryAction.saveCover,
      LinkLibraryAction.saveLyrics,
    ]) {
      expect(linkLibraryChangedSources(client, job(action)), isEmpty);
    }
    expect(
      linkLibraryChangedSources(
        client,
        job(
          LinkLibraryAction.editMetadata,
          status: LinkLibraryJobStatus.running,
        ),
      ),
      isEmpty,
    );
    expect(
      linkLibraryChangedSources(
        client,
        job(
          LinkLibraryAction.editMetadata,
          status: LinkLibraryJobStatus.cancelled,
        ),
      ),
      hasLength(1),
    );
  });
}
