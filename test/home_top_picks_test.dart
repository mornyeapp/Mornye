import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/home_top_picks_provider.dart';

ExploreItem _item(
  String id, {
  String type = 'playlist',
  String? cover = 'https://example.test/cover.jpg',
  String? providerId,
}) => ExploreItem(
  id: id,
  uri: id,
  type: type,
  name: id,
  artists: '',
  coverUrl: cover,
  providerId: providerId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('picks covered playlists and albums once and leaves the rest out', () {
    final picks = pickTopPicks(sections, '2026-11-04', count: 20);
    expect(picks.map((item) => item.id).toSet(), {
      for (var i = 0; i < 12; i++) 'p$i',
      'album',
    });
    expect(picks, hasLength(13));
  });

  test('holds for the day, changes with the next and caps the count', () {
    List<String> ids(String day) => [
      for (final item in pickTopPicks(sections, day, count: 5)) item.id,
    ];
    expect(ids('2026-11-04'), hasLength(5));
    expect(ids('2026-11-04'), ids('2026-11-04'));
    expect(ids('2026-11-05'), isNot(ids('2026-11-04')));
  });

  group('albums', () {
    List<ExploreSection> feed({required int albums, required int playlists}) =>
        [
          ExploreSection(
            uri: 'feed',
            title: 'Feed',
            items: [
              for (var i = 0; i < albums; i++) _item('a$i', type: 'album'),
              for (var i = 0; i < playlists; i++) _item('p$i'),
              _item('song', type: 'track'),
              _item('bare', type: 'album', cover: null),
            ],
          ),
        ];

    List<String> types(List<ExploreSection> sections, {int count = 9}) => [
      for (final item in pickTopPicks(
        sections,
        '2026-11-04',
        count: count,
        albums: 4,
      ))
        item.type,
    ];

    test('take their share and come by turns with the playlists', () {
      expect(types(feed(albums: 10, playlists: 10)), [
        'album',
        'playlist',
        'album',
        'playlist',
        'album',
        'playlist',
        'album',
        'playlist',
        'playlist',
      ]);
    });

    test('take what too few playlists leave', () {
      final picked = types(feed(albums: 10, playlists: 2));
      expect(picked.where((type) => type == 'album'), hasLength(7));
      expect(picked.where((type) => type == 'playlist'), hasLength(2));
      expect(picked.take(4), ['album', 'playlist', 'album', 'playlist']);
    });

    test('a feed without them stays all playlists', () {
      expect(types(feed(albums: 0, playlists: 12)), List.filled(9, 'playlist'));
    });
  });

  test('playlist IDs are scoped to their provider', () {
    final picks = pickTopPicks([
      ExploreSection(
        uri: 'example:playlists',
        title: 'Playlists',
        items: [
          _item('shared-id', providerId: 'example-a'),
          _item('shared-id', providerId: 'example-b'),
          _item('shared-id', providerId: 'example-a'),
        ],
      ),
    ], '2026-11-04');
    expect(picks, hasLength(2));
    expect(picks.map((item) => item.providerId).toSet(), {
      'example-a',
      'example-b',
    });
  });

  test('leaves charts out, by their name or their section', () {
    final picks = pickTopPicks([
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

    test('Auto uses the first available extension', () {
      expect(pickTopPicksExtension(['a', 'b'], null), 'a');
      expect(pickTopPicksExtension(['a', 'b'], ''), 'a');
      expect(pickTopPicksExtension(const [], null), isNull);
    });

    test('Off does not fall back to an installed extension', () {
      expect(pickTopPicksExtension(['a', 'b'], off), isNull);
    });

    test('a chosen feed is kept while its extension is there', () {
      expect(pickTopPicksExtension(['a', 'b'], 'b'), 'b');
      expect(pickTopPicksExtension(['b', 'c'], 'a'), isNull);
    });
  });

  group('home feed layouts', () {
    ExploreSection section({String? layout, List<String>? types}) =>
        ExploreSection.fromJson({
          'layout': ?layout,
          'items': [
            for (final (index, type) in (types ?? ['track', 'track']).indexed)
              _item(
                'item-$index',
                type: type,
                providerId: 'example-provider',
              ).toJson(),
          ],
        });

    test('infers compact track lists for any feed without a layout', () {
      final inferred = section();
      expect(inferred.isQuickPicks, isTrue);
      expect(inferred.isFeatured, isFalse);
      final restored = ExploreSection.fromJson(inferred.toJson());
      expect(restored.isQuickPicks, isTrue);
      expect(restored.toJson()['layout'], 'quick-picks');
    });

    test('feed normalization preserves absent and explicit layouts', () async {
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getExtensionHomeFeed');
        return jsonEncode({
          'success': true,
          'sections': [
            {
              'items': [_item('track-1', type: 'track').toJson()],
            },
            {
              'layout': 'shelf',
              'items': [_item('track-2', type: 'track').toJson()],
            },
          ],
        });
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final sections = await readExtensionHomeFeed('example-feed');
      expect(sections, hasLength(2));
      expect(sections![0].isQuickPicks, isTrue);
      expect(sections[1].isQuickPicks, isFalse);
      expect(sections[0].items.single.providerId, 'example-feed');
    });

    test('explicit shelf keeps an all-track section as cards', () {
      final shelf = section(layout: 'shelf');
      expect(shelf.isQuickPicks, isFalse);
      expect(ExploreSection.fromJson(shelf.toJson()).isQuickPicks, isFalse);
    });

    test('mixed or empty sections do not infer a compact track list', () {
      expect(section(types: ['track', 'album']).isQuickPicks, isFalse);
      expect(section(types: []).isQuickPicks, isFalse);
    });

    test('quick-picks does not expose track actions for collections', () {
      for (final types in [
        ['track', 'album'],
        ['playlist'],
        <String>[],
      ]) {
        final invalid = section(layout: 'quick-picks', types: types);
        expect(invalid.isQuickPicks, isFalse);
        expect(invalid.toJson()['layout'], 'shelf');
      }
    });

    test('explicit quick-picks and featured layouts survive serialization', () {
      final quickPicks = section(layout: 'quick-picks');
      expect(quickPicks.isQuickPicks, isTrue);
      expect(ExploreSection.fromJson(quickPicks.toJson()).isQuickPicks, isTrue);
      final featured = section(layout: 'featured');
      expect(featured.isFeatured, isTrue);
      expect(featured.isQuickPicks, isFalse);
      expect(ExploreSection.fromJson(featured.toJson()).isFeatured, isTrue);
    });
  });
}
