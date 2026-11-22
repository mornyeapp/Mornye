import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/home_recommendations.dart';

Track _track(String name, [String artist = 'Artist']) => Track(
  id: name,
  name: name,
  artistName: artist,
  albumName: 'Album',
  duration: 200,
);

List<String> _names(List<Track> tracks) => [
  for (final track in tracks) track.name,
];

void main() {
  test('without any fit the order is the extension\'s', () {
    final tracks = [
      for (var i = 0; i < 20; i++) _track('Song $i', 'Artist ${i % 2}'),
    ];
    expect(
      orderHomeRecommendations(tracks, List.filled(20, null)),
      orderedEquals(tracks),
    );
    expect(
      orderHomeRecommendations(
        tracks,
        homeRecommendationFits(
          tracks,
          homeRecommendationFit(at: DateTime(2026, 11, 23)),
        ),
      ),
      orderedEquals(tracks),
    );
    // A model that has seen nothing is no fit either.
    expect(
      homeRecommendationFit(
        preference: AutoplayPreferenceModel(),
        at: DateTime(2026, 11, 23),
      ),
      isNull,
    );
  });

  test('known songs go by fit into the known places; unknown ones and ties '
      'keep the extension\'s order', () {
    final tracks = [
      _track('Unknown first', 'U'),
      _track('Low', 'L'),
      _track('Tie one', 'T'),
      _track('Unknown middle', 'V'),
      _track('High', 'H'),
      _track('Tie two', 'S'),
      _track('Broken', 'B'),
    ];
    final ordered = orderHomeRecommendations(tracks, [
      null,
      -0.5,
      0.2,
      null,
      0.9,
      0.2,
      double.nan,
    ]);
    expect(_names(ordered), [
      'Unknown first',
      'High',
      'Tie one',
      'Unknown middle',
      'Tie two',
      'Low',
      'Broken',
    ]);
  });

  test('one artist does not fill the shelf', () {
    final tracks = [
      for (var i = 0; i < 5; i++) _track('Favorite $i', 'Favorite'),
      _track('Other', 'Other'),
      _track('Guest', 'Favorite feat. Guest'),
      _track('Third', 'Third'),
    ];
    final ordered = orderHomeRecommendations(tracks, [
      0.9,
      0.8,
      0.7,
      0.6,
      0.5,
      0.1,
      0.85,
      0.0,
    ]);
    // A credit counts for its first artist.
    expect(_names(ordered), [
      'Favorite 0',
      'Guest',
      'Favorite 1',
      'Other',
      'Third',
      'Favorite 2',
      'Favorite 3',
      'Favorite 4',
    ]);
  });

  test('the fit follows what Autoplay learned of the artists', () {
    final model = AutoplayPreferenceModel();
    final at = DateTime(2026, 11, 23, 20);
    for (var i = 0; i < 30; i++) {
      for (final (artist, reward) in [('Liked', 1.0), ('Skipped', 0.0)]) {
        model.learn(
          AutoplayLearningTrack(
            source: '/$artist/$i.flac',
            title: 'Song $i',
            artist: artist,
          ),
          at: at,
          reward: reward,
        );
      }
    }
    expect(model.artistEvidence(' LIKED '), greaterThan(1));
    expect(model.artistEvidence('Never heard'), 0);
    final fit = homeRecommendationFit(preference: model, at: at)!;
    final liked = fit(_track('New', 'Liked'))!;
    final credited = fit(_track('New', 'Guest feat. Liked'))!;
    final skipped = fit(_track('New', 'Skipped'))!;
    expect(liked, greaterThan(0));
    expect(skipped, lessThan(0));
    expect(credited, greaterThan(0));
    expect(credited, lessThan(liked));
    expect(fit(_track('New', 'Never heard')), isNull);
    final ordered = orderHomeRecommendations(
      [
        _track('One', 'Skipped'),
        _track('Two', 'Never heard'),
        _track('Three', 'Liked'),
      ],
      homeRecommendationFits([
        _track('One', 'Skipped'),
        _track('Two', 'Never heard'),
        _track('Three', 'Liked'),
      ], fit),
    );
    expect(_names(ordered), ['Three', 'Two', 'One']);
  });

  test('a stored order reads back and places its songs', () {
    final tracks = [_track('One'), _track('Two'), _track('Three')];
    final order = HomeRecommendationOrder.decode(
      HomeRecommendationOrder.of(
        [tracks[2], tracks[0], tracks[1]],
        tracks,
        [0.1, null, double.nan],
      ).encode(),
    )!;
    expect(order.fits, {homeRecommendationKey(tracks[0]): 0.1});
    expect(order.covers(tracks), isTrue);
    expect(_names(order.apply(tracks)), ['Three', 'One', 'Two']);
    // A song that left the shelf leaves the others in their order.
    expect(_names(order.apply([tracks[1], tracks[2]])), ['Three', 'Two']);
    // A new song has no place yet, so the order is decided again.
    final more = [...tracks, _track('Four')];
    expect(order.covers(more), isFalse);
    expect(_names(order.apply(more)), ['Three', 'One', 'Two', 'Four']);
    expect(HomeRecommendationOrder.decode('broken'), isNull);
    expect(HomeRecommendationOrder.decode(null), isNull);
  });

  test('one day in four keeps the extension\'s order', () {
    final days = [
      for (var day = 1; day <= 28; day++)
        '2026-11-${day.toString().padLeft(2, '0')}',
    ];
    final control = days.where(homeRecommendationControlDay).toList();
    expect(control, hasLength(7));
    expect(
      homeRecommendationRound(control[1]) - homeRecommendationRound(control[0]),
      4,
    );
  });
}
