import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/album_track_order.dart';

typedef _AlbumTrack = ({String name, int? disc, int? number});

AlbumTrackOrder<_AlbumTrack> _order(Iterable<_AlbumTrack> tracks) =>
    AlbumTrackOrder(
      tracks,
      discNumber: (track) => track.disc,
      trackNumber: (track) => track.number,
      trackName: (track) => track.name,
    );

void main() {
  group('ranks', () {
    const source = <_AlbumTrack>[
      (name: 'One', disc: 1, number: 1),
      (name: 'Two', disc: 1, number: 2),
      (name: 'Three', disc: 2, number: 1),
      (name: 'Four', disc: 2, number: 2),
    ];
    AlbumTrackOrder<_AlbumTrack> ranked(Map<String, int>? ranks) =>
        AlbumTrackOrder(
          source,
          discNumber: (track) => track.disc,
          trackNumber: (track) => track.number,
          trackName: (track) => track.name,
          ranks: ranks,
        );
    List<String> names(AlbumTrackOrder<_AlbumTrack> order) =>
        order.tracks.map((track) => track.name).toList();

    test('most played songs lead, the rest keep album order', () {
      final order = ranked(albumTrackPlayRanks({'FOUR': 9, 'two': 3}));
      expect(names(order), ['Four', 'Two', 'One', 'Three']);
      // A rank cuts across discs, so there are no disc sections to show.
      expect(order.discNumbers, [1]);
      expect(order.discGroups[1], order.tracks);
    });

    test('a custom order keeps songs it does not name last', () {
      final order = ranked(albumTrackCustomRanks(['three', 'one']));
      expect(names(order), ['Three', 'One', 'Two', 'Four']);
    });

    test('no ranks keep disc sections', () {
      final order = ranked(null);
      expect(names(order), ['One', 'Two', 'Three', 'Four']);
      expect(order.discNumbers, [1, 2]);
    });
  });

  test('album queue and disc sections share ordering with incomplete tags', () {
    final source = <_AlbumTrack>[
      (name: 'Disc two', disc: 2, number: 1),
      (name: 'Z missing', disc: null, number: null),
      (name: 'Second', disc: 1, number: 2),
      (name: 'First', disc: null, number: 1),
      (name: 'A 999', disc: 1, number: 999),
      (name: 'Legacy zero disc', disc: 0, number: 1),
    ];
    final original = List.of(source);
    final order = _order(source);
    expect(order.tracks.map((track) => track.name), [
      'Legacy zero disc',
      'First',
      'Second',
      'A 999',
      'Z missing',
      'Disc two',
    ]);
    expect(order.discNumbers, [0, 1, 2]);
    expect(order.discGroups[1]!.map((track) => track.name), [
      'First',
      'Second',
      'A 999',
      'Z missing',
    ]);
    expect(
      order.discNumbers.expand((disc) => order.discGroups[disc]!),
      order.tracks,
    );
    expect(source, original);
    expect(() => order.tracks.clear(), throwsUnsupportedError);
    expect(() => order.discGroups.clear(), throwsUnsupportedError);
    expect(() => order.discGroups[1]!.clear(), throwsUnsupportedError);
    expect(() => order.discNumbers.clear(), throwsUnsupportedError);
    source.clear();
    expect(order.tracks, hasLength(6));
  });

  test('empty albums have no queue or disc sections', () {
    final order = _order(const []);
    expect(order.tracks, isEmpty);
    expect(order.discGroups, isEmpty);
    expect(order.discNumbers, isEmpty);
  });
}
