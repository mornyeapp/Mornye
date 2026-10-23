import 'dart:collection';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/track_history_snapshot.dart';
import 'package:mornye/models/track.dart';

class _CountingTracks extends ListBase<Track> {
  final List<Track> values;
  int reads = 0;
  _CountingTracks(this.values);
  @override
  int get length => values.length;
  @override
  set length(int value) => throw UnsupportedError('immutable');
  @override
  Track operator [](int index) {
    reads++;
    return values[index];
  }

  @override
  void operator []=(int index, Track value) =>
      throw UnsupportedError('immutable');
}

void main() {
  test('retains lookups without scanning an unchanged 4000-track snapshot', () {
    final tracks = _CountingTracks(
      List.generate(
        4000,
        (index) => Track(
          id: '$index',
          name: 'Song $index',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 1,
        ),
      ),
    );
    final data = TrackHistorySnapshot()..update(tracks);
    final request = data.request;
    final hash = request.hashCode;
    final reads = tracks.reads;
    for (var i = 0; i < 100; i++) {
      data.update(tracks);
      expect(identical(data.request, request), isTrue);
      expect(data.request.hashCode, hash);
    }
    expect(tracks.reads, reads);
    expect(() => data.lookups.clear(), throwsUnsupportedError);
  });

  test(
    'replacement metadata, sorting, filtering, and empty lists invalidate',
    () {
      const first = Track(
        id: '1',
        name: 'First',
        artistName: 'A',
        albumName: 'Album',
        duration: 1,
      );
      const second = Track(
        id: '2',
        name: 'Second',
        artistName: 'A',
        albumName: 'Album',
        duration: 1,
      );
      final data = TrackHistorySnapshot()..update([first, second]);
      final original = data.request;
      data.update([first.copyWith(name: 'Edited'), second]);
      expect(data.request, isNot(original));
      expect(data.lookups.first.trackName, 'Edited');
      data.update([second, first]);
      expect(data.lookups.map((item) => item.spotifyId), ['2', '1']);
      data.update([second]);
      expect(data.lookups.single.spotifyId, '2');
      data.update([]);
      expect(data.lookups, isEmpty);
    },
  );
}
