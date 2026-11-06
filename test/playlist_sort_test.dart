import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
      final sorted = sortCollectionTrackEntries(
        entries,
        PlaylistSortMode.dateAddedDesc,
      );

      expect(sorted.map((e) => e.key).toList(), ['3', '2', '1']);
    });

    test('sorts by dateAddedAsc (oldest first)', () {
      final entries = [entry3, entry2, entry1];
      final sorted = sortCollectionTrackEntries(
        entries,
        PlaylistSortMode.dateAddedAsc,
      );

      expect(sorted.map((e) => e.key).toList(), ['1', '2', '3']);
    });

    test('stable sort for identical dates', () {
      final entries = [entry2, entrySameDate];
      final sorted = sortCollectionTrackEntries(
        entries,
        PlaylistSortMode.dateAddedDesc,
      );

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
      final sorted = sortCollectionTrackEntries(
        entries,
        PlaylistSortMode.custom,
      );

      expect(sorted.map((e) => e.key).toList(), ['3', '1', '2']);
    });

    test('sorts diacritic and accented strings cleanly', () {
      const track1 = Track(
        id: 'd1',
        name: 'Álbum',
        artistName: 'Édith Piaf',
        albumName: 'A',
        duration: 100,
      );
      const track2 = Track(
        id: 'd2',
        name: 'Amour',
        artistName: 'Elton John',
        albumName: 'B',
        duration: 100,
      );
      const track3 = Track(
        id: 'd3',
        name: 'e\u0301clair', // decomposed combining acute accent
        artistName: 'Zebra',
        albumName: 'C',
        duration: 100,
      );
      const track4 = Track(
        id: 'd4',
        name: 'Zoo',
        artistName: 'ABBA',
        albumName: 'D',
        duration: 100,
      );

      final byTitle = sortTracksByMode([
        track4,
        track3,
        track2,
        track1,
      ], PlaylistSortMode.titleAsc);
      // 'Álbum' (album) < 'Amour' (amour) < 'éclair' (eclair) < 'Zoo' (zoo)
      expect(byTitle.map((t) => t.id).toList(), ['d1', 'd2', 'd3', 'd4']);

      final byArtist = sortTracksByMode([
        track3,
        track2,
        track1,
        track4,
      ], PlaylistSortMode.artistAsc);
      // 'ABBA' (abba) < 'Édith Piaf' (edith piaf) < 'Elton John' (elton john) < 'Zebra' (zebra)
      expect(byArtist.map((t) => t.id).toList(), ['d4', 'd1', 'd2', 'd3']);
    });
  });

  group('PlaylistSortStorage', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test(
      'defaults to PlaylistSortMode.custom when no preference is saved',
      () async {
        final mode = await PlaylistSortStorage.getSortMode('playlist-123');
        expect(mode, PlaylistSortMode.custom);
      },
    );

    test(
      'persists and retrieves custom sort mode for distinct playlists',
      () async {
        await PlaylistSortStorage.setSortMode(
          'playlist-1',
          PlaylistSortMode.titleAsc,
        );
        await PlaylistSortStorage.setSortMode(
          'playlist-2',
          PlaylistSortMode.dateAddedDesc,
        );

        expect(
          await PlaylistSortStorage.getSortMode('playlist-1'),
          PlaylistSortMode.titleAsc,
        );
        expect(
          await PlaylistSortStorage.getSortMode('playlist-2'),
          PlaylistSortMode.dateAddedDesc,
        );
        expect(
          await PlaylistSortStorage.getSortMode('playlist-3'),
          PlaylistSortMode.custom,
        );
      },
    );

    test('reverting to custom removes or resets the persisted entry', () async {
      await PlaylistSortStorage.setSortMode(
        'playlist-1',
        PlaylistSortMode.artistAsc,
      );
      expect(
        await PlaylistSortStorage.getSortMode('playlist-1'),
        PlaylistSortMode.artistAsc,
      );

      await PlaylistSortStorage.setSortMode(
        'playlist-1',
        PlaylistSortMode.custom,
      );
      expect(
        await PlaylistSortStorage.getSortMode('playlist-1'),
        PlaylistSortMode.custom,
      );
    });
  });
}
