import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/batch_lyrics_sync_service.dart';

void main() {
  test('BatchLyricsSyncService processes tracks and updates progress', () async {
    const track1 = Track(
      id: '1',
      name: 'Song 1',
      artistName: 'Artist 1',
      albumName: 'Album 1',
      duration: 180,
      source: 'file:///path/song1.mp3',
    );
    const track2 = Track(
      id: '2',
      name: 'Song 2',
      artistName: 'Artist 2',
      albumName: 'Album 2',
      duration: 200,
      source: 'file:///path/song2.mp3',
    );
    const track3 = Track(
      id: '3',
      name: 'Song 3',
      artistName: 'Artist 3',
      albumName: 'Album 3',
      duration: 220,
      source: 'file:///path/song3.mp3',
    );

    final fetched = <String>[];
    final savedTags = <String, String>{};
    final savedSidecars = <String, String>{};
    final progressEvents = <BatchLyricsProgress>[];

    final service = BatchLyricsSyncService(
      checkHasLyrics: (track) async {
        // Track 2 already has lyrics
        return track.id == '2';
      },
      fetchLyrics: (track) async {
        fetched.add(track.id);
        if (track.id == '3') return ''; // Empty/failed fetch
        return '[00:05.00] New Lyrics for ${track.name}';
      },
      saveTags: (source, lyrics) async {
        savedTags[source] = lyrics;
      },
      saveSidecar: (source, lyrics) async {
        savedSidecars[source] = lyrics;
      },
    );

    await service.syncTracks(
      [track1, track2, track3],
      onProgress: (progress) {
        progressEvents.add(progress);
      },
    );

    // track2 already had lyrics, so only track1 and track3 were queried
    expect(fetched, contains('1'));
    expect(fetched, contains('3'));
    expect(fetched.contains('2'), isFalse);

    // Track 1 succeeded
    expect(savedTags['file:///path/song1.mp3'], contains('Song 1'));
    expect(savedSidecars['file:///path/song1.mp3'], contains('Song 1'));

    // Track 3 had empty lyrics so it shouldn't save
    expect(savedTags.containsKey('file:///path/song3.mp3'), isFalse);

    // Progress events
    expect(progressEvents.isNotEmpty, isTrue);
    final finalProgress = progressEvents.last;
    expect(finalProgress.total, equals(2));
    expect(finalProgress.completed, equals(2));
    expect(finalProgress.successful, equals(1));
    expect(finalProgress.failed, equals(1));
  });

  test('BatchLyricsSyncService respects cancellation', () async {
    const track1 = Track(
      id: '1',
      name: 'Song 1',
      artistName: 'Artist 1',
      albumName: 'Album 1',
      duration: 180,
      source: 'file:///path/song1.mp3',
    );
    const track2 = Track(
      id: '2',
      name: 'Song 2',
      artistName: 'Artist 2',
      albumName: 'Album 2',
      duration: 200,
      source: 'file:///path/song2.mp3',
    );

    var cancel = false;
    final service = BatchLyricsSyncService(
      checkHasLyrics: (_) async => false,
      fetchLyrics: (track) async => '[00:01.00] lyrics',
      saveTags: (source, lyrics) async {},
      saveSidecar: (source, lyrics) async {},
    );

    await service.syncTracks(
      [track1, track2],
      isCancelled: () => cancel,
      onProgress: (p) {
        if (p.completed == 1) cancel = true;
      },
    );

    expect(cancel, isTrue);
  });
}
