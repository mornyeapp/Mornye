import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/batch_lyrics_sync_service.dart';

void main() {
  test('BatchLyricsSyncService processes items and updates progress', () async {
    const track1 = Track(
      id: '1',
      name: 'Song 1',
      artistName: 'Artist 1',
      albumName: 'Album 1',
      duration: 180,
      source: 'local',
    );
    const track2 = Track(
      id: '2',
      name: 'Song 2',
      artistName: 'Artist 2',
      albumName: 'Album 2',
      duration: 200,
      source: 'local',
    );
    const track3 = Track(
      id: '3',
      name: 'Song 3',
      artistName: 'Artist 3',
      albumName: 'Album 3',
      duration: 220,
      source: 'local',
    );

    final item1 = const BatchLyricsItem(
      track: track1,
      filePath: '/music/song1.flac',
    );
    final item2 = const BatchLyricsItem(
      track: track2,
      filePath: '/music/song2.mp3',
    );
    final item3 = const BatchLyricsItem(
      track: track3,
      filePath: '/music/song3.m4a',
    );

    final fetched = <String>[];
    final savedTags = <String, String>{};
    final savedSidecars = <String, String>{};
    final progressEvents = <BatchLyricsProgress>[];

    final service = BatchLyricsSyncService(
      checkHasLyrics: (item) async {
        // Item 2 already has lyrics
        return item.track.id == '2';
      },
      fetchLyrics: (track) async {
        fetched.add(track.id);
        if (track.id == '3') return ''; // Empty/failed fetch
        return '[00:05.00] New Lyrics for ${track.name}';
      },
      saveTags: (filePath, lyrics) async {
        savedTags[filePath] = lyrics;
      },
      saveSidecar: (filePath, lyrics) async {
        savedSidecars[filePath] = lyrics;
        return true;
      },
    );

    await service.syncItems(
      [item1, item2, item3],
      onProgress: (progress) {
        progressEvents.add(progress);
      },
    );

    // item2 already had lyrics, so only track1 and track3 were queried
    expect(fetched, contains('1'));
    expect(fetched, contains('3'));
    expect(fetched.contains('2'), isFalse);

    // Track 1 succeeded with double persistence on filePath
    expect(savedTags['/music/song1.flac'], contains('Song 1'));
    expect(savedSidecars['/music/song1.flac'], contains('Song 1'));

    // Track 3 had empty lyrics so it shouldn't save
    expect(savedTags.containsKey('/music/song3.m4a'), isFalse);

    // Progress events
    expect(progressEvents.isNotEmpty, isTrue);
    final finalProgress = progressEvents.last;
    expect(finalProgress.total, equals(2));
    expect(finalProgress.completed, equals(2));
    expect(finalProgress.successful, equals(1));
    expect(finalProgress.failed, equals(1));
  });

  test(
    'BatchLyricsSyncService records failure if tag and sidecar write both fail',
    () async {
      const track = Track(
        id: 'fail-track',
        name: 'Fail Song',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 100,
      );
      final item = const BatchLyricsItem(
        track: track,
        filePath: '/music/fail.mp3',
      );

      final service = BatchLyricsSyncService(
        checkHasLyrics: (_) async => false,
        fetchLyrics: (_) async => '[00:01.00] Some lyrics',
        saveTags: (filePath, lyrics) async {
          throw Exception('Tag embedding failed');
        },
        saveSidecar: (filePath, lyrics) async {
          return false; // SAF write failed
        },
      );

      final progress = await service.syncItems([item], onProgress: (_) {});

      expect(progress.completed, equals(1));
      expect(progress.successful, equals(0));
      expect(progress.failed, equals(1));
    },
  );

  test(
    'BatchLyricsSyncService respects cancellation during check and download',
    () async {
      const track1 = Track(
        id: '1',
        name: 'Song 1',
        artistName: 'Artist 1',
        albumName: 'Album 1',
        duration: 180,
      );
      const track2 = Track(
        id: '2',
        name: 'Song 2',
        artistName: 'Artist 2',
        albumName: 'Album 2',
        duration: 200,
      );

      final item1 = const BatchLyricsItem(
        track: track1,
        filePath: '/music/song1.mp3',
      );
      final item2 = const BatchLyricsItem(
        track: track2,
        filePath: '/music/song2.mp3',
      );

      var cancel = false;
      final service = BatchLyricsSyncService(
        checkHasLyrics: (_) async => false,
        fetchLyrics: (track) async => '[00:01.00] lyrics',
        saveTags: (source, lyrics) async {},
        saveSidecar: (source, lyrics) async => true,
      );

      final result = await service.syncItems(
        [item1, item2],
        isCancelled: () => cancel,
        onProgress: (p) {
          if (p.completed == 1) cancel = true;
        },
      );

      expect(cancel, isTrue);
      expect(result.isCancelled, isTrue);
    },
  );
}
