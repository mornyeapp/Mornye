import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/utils/duplicate_cleanup_policy.dart';

IsrcDuplicateEntry _entry(String id) {
  return IsrcDuplicateEntry(
    id: id,
    source: 'local',
    trackName: 'Track $id',
    artistName: 'Artist',
    filePath: '/music/$id.flac',
  );
}

void main() {
  test(
    'deleting the first copy clears both indexes and retains the chosen copy',
    () async {
      final best = _entry('best');
      final retained = _entry('retained');
      final files = {best.filePath, retained.filePath};
      final history = {best.filePath};
      final library = {...files};
      final deleted = await deleteReviewedDuplicateCopies(
        entries: [best],
        retainedEntries: [retained],
        deleteFile: (path) async => files.remove(path),
        removePhysicalFile: (path) async {
          history.remove(path);
          library.remove(path);
        },
        removeIndexEntry: (_) async => fail('This is a separate physical file'),
      );
      expect(deleted, 1);
      expect(files, {retained.filePath});
      expect(history, isEmpty);
      expect(library, {retained.filePath});
    },
  );

  test(
    'retained aliases are not deleted and failed deletes keep their indexes',
    () async {
      final copy = _entry('same');
      final retained = IsrcDuplicateEntry(
        id: 'other-index',
        source: 'downloaded',
        trackName: 'Track',
        artistName: 'Artist',
        filePath: 'file://${copy.filePath}',
      );
      final removedRows = <String>[];
      final failed = _entry('failed');
      final deletionAttempts = <String>[];
      final deleted = await deleteReviewedDuplicateCopies(
        entries: [copy, failed],
        retainedEntries: [retained],
        deleteFile: (path) async {
          deletionAttempts.add(path);
          return false;
        },
        removePhysicalFile: (_) async => fail('Neither file was deleted'),
        removeIndexEntry: (entry) async => removedRows.add(entry.id),
      );
      expect(deleted, 1);
      expect(removedRows, [copy.id]);
      expect(deletionAttempts, [failed.filePath]);
    },
  );

  test('keep-best-all retains one entry and deletes the rest per group', () {
    final firstBest = _entry('first-best');
    final firstLower = _entry('first-lower');
    final firstLowest = _entry('first-lowest');
    final secondBest = _entry('second-best');
    final secondLower = _entry('second-lower');

    final plan = buildKeepBestAllDuplicatePlan([
      IsrcDuplicateGroup(
        isrc: 'FIRST',
        entries: [firstBest, firstLower, firstLowest],
      ),
      IsrcDuplicateGroup(isrc: 'SECOND', entries: [secondBest, secondLower]),
    ]);

    expect(plan.groupCount, 2);
    expect(plan.retainedEntries, [firstBest, secondBest]);
    expect(plan.entriesToDelete, [firstLower, firstLowest, secondLower]);
  });

  test('keep-best-all ignores groups that no longer contain duplicates', () {
    final onlyCopy = _entry('only-copy');

    final plan = buildKeepBestAllDuplicatePlan([
      IsrcDuplicateGroup(isrc: 'ONLY', entries: [onlyCopy]),
      const IsrcDuplicateGroup(isrc: 'EMPTY', entries: []),
    ]);

    expect(plan.groupCount, 0);
    expect(plan.retainedEntries, isEmpty);
    expect(plan.entriesToDelete, isEmpty);
  });
}
