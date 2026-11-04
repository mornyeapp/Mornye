import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/home_top_picks_provider.dart';

ExploreItem _item(String id, {String type = 'playlist', String? cover = 'c'}) =>
    ExploreItem(
      id: id,
      uri: id,
      type: type,
      name: id,
      artists: '',
      coverUrl: cover,
    );

void main() {
  final sections = [
    ExploreSection(
      uri: 'a',
      title: 'A',
      items: [
        for (var i = 0; i < 12; i++) _item('p$i'),
        _item('album', type: 'album'),
        _item('coverless', cover: null),
      ],
    ),
    ExploreSection(uri: 'b', title: 'B', items: [_item('p0')]),
  ];

  test('picks covered playlists once and leaves the rest out', () {
    final picks = pickTopPickPlaylists(sections, '2026-11-04', count: 20);
    expect(picks.map((item) => item.id).toSet(), {
      for (var i = 0; i < 12; i++) 'p$i',
    });
    expect(picks, hasLength(12));
  });

  test('holds for the day, changes with the next and caps the count', () {
    List<String> ids(String day) => [
      for (final item in pickTopPickPlaylists(sections, day, count: 5)) item.id,
    ];
    expect(ids('2026-11-04'), hasLength(5));
    expect(ids('2026-11-04'), ids('2026-11-04'));
    expect(ids('2026-11-05'), isNot(ids('2026-11-04')));
  });

  test('leaves charts out, by their name or their section', () {
    final picks = pickTopPickPlaylists([
      ExploreSection(
        uri: 'a',
        title: 'Updated Playlists',
        items: [_item('Top 100: Global'), _item('Rock Hits')],
      ),
      ExploreSection(uri: 'b', title: 'City Charts', items: [_item('Paris')]),
    ], '2026-11-04');
    expect(picks.map((item) => item.id), ['Rock Hits']);
  });

  group('source extension', () {
    const off = AppSettings.homeFeedProviderOff;
    const preferred = homeTopPicksDefaultExtension;

    test('with no feed chosen the default wins, then the first', () {
      expect(pickTopPicksExtension(['a', preferred], off), preferred);
      expect(pickTopPicksExtension(['a', preferred], null), preferred);
      expect(pickTopPicksExtension(['a', 'b'], off), 'a');
      expect(pickTopPicksExtension(const [], off), isNull);
    });

    test('a chosen feed is kept, even over the default', () {
      expect(pickTopPicksExtension(['a', preferred], 'a'), 'a');
      expect(pickTopPicksExtension(['b', preferred], 'a'), isNull);
    });
  });
}
