import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/playlist_sort.dart';
import 'package:mornye/models/track.dart';

void main() {
  group('PlaylistSortMode & comparators', () {
    final trackA = const Track(
      id: '1',
      name: 'Alpha',
      artistName: 'The Beatles',
      albumName: 'Abbey Road',
      duration: 180,
    );
    final trackB = const Track(
      id: '2',
      name: 'beta',
      artistName: 'Queen',
      albumName: 'A Night at the Opera',
      duration: 120,
    );
    final trackC = const Track(
      id: '3',
      name: 'Charlie',
      artistName: 'AC/DC',
      albumName: 'Back in Black',
      duration: 240,
    );
    final trackEmpty = const Track(
      id: '4',
      name: '',
      artistName: '',
      albumName: '',
      duration: 0,
    );

    final entry1 = CollectionTrackEntry(
      key: '1',
      track: trackA,
      addedAt: DateTime.utc(2026, 1, 1),
    );
    final entry2 = CollectionTrackEntry(
      key: '2',
      track: trackB,
      addedAt: DateTime.utc(2026, 2, 1),
    );
    final entry3 = CollectionTrackEntry(
      key: '3',
      track: trackC,
      addedAt: DateTime.utc(2026, 3, 1),
    );
    final entrySameDate = CollectionTrackEntry(
      key: '4',
      track: trackEmpty,
      addedAt: DateTime.utc(2026, 2, 1),
    );

    test('sorts by dateAddedDesc (newest first)', () {
      final entries = [entry1, entry2, entry3];
      final sorted = sortCollectionTrackEntries(entries, PlaylistSortMode.dateAddedDesc);

      expect(sorted.map((e) => e.key).toList(), ['3', '2', '1']);
    });

    test('sorts by dateAddedAsc (oldest first)', () {
      final entries = [entry3, entry2, entry1];
      final sorted = sortCollectionTrackEntries(entries, PlaylistSortMode.dateAddedAsc);

      expect(sorted.map((e) => e.key).toList(), ['1', '2', '3']);
    });

    test('stable sort for identical dates', () {
      final entries = [entry2, entrySameDate];
      final sorted = sortCollectionTrackEntries(entries, PlaylistSortMode.dateAddedDesc);

      expect(sorted.map((e) => e.key).toList(), ['2', '4']);
    });

    test('sorts by titleAsc case-insensitively', () {
      final tracks = [trackC, trackB, trackA];
      final sorted = sortTracksByMode(tracks, PlaylistSortMode.titleAsc);

      expect(sorted.map((t) => t.id).toList(), ['1', '2', '3']);
    });

    test('sorts by titleDesc', () {
      final tracks = [trackA, trackB, trackC];
      final sorted = sortTracksByMode(tracks, PlaylistSortMode.titleDesc);

      expect(sorted.map((t) => t.id).toList(), ['3', '2', '1']);
    });

    test('sorts by artistAsc and places empty artists last', () {
      final tracks = [trackA, trackEmpty, trackC, trackB];
      final sorted = sortTracksByMode(tracks, PlaylistSortMode.artistAsc);

      expect(sorted.map((t) => t.id).toList(), ['3', '2', '1', '4']);
    });

    test('sorts by durationAsc and durationDesc', () {
      final tracks = [trackC, trackA, trackB];
      final asc = sortTracksByMode(tracks, PlaylistSortMode.durationAsc);
      expect(asc.map((t) => t.id).toList(), ['2', '1', '3']);

      final desc = sortTracksByMode(tracks, PlaylistSortMode.durationDesc);
      expect(desc.map((t) => t.id).toList(), ['3', '1', '2']);
    });

    test('restores custom (original) order', () {
      final entries = [entry3, entry1, entry2];
      final sorted = sortCollectionTrackEntries(entries, PlaylistSortMode.custom);

      expect(sorted.map((e) => e.key).toList(), ['3', '1', '2']);
    });
  });
}
