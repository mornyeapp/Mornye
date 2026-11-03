import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/autoplay_taste.dart';

/// Deterministic, bounded histories for native parity and full-route timings.
List<AutoplayTastePlay> autoplayTasteFixture(int count) {
  final start = DateTime.utc(2026, 1, 1);
  return [
    for (var i = 0; i < count; i++)
      AutoplayTastePlay(
        id: i + 1,
        song:
            'artist ${(i * 17 + i ~/ 13) % 192 ~/ 8}|song ${(i * 17 + i ~/ 13) % 192}',
        artist: 'artist ${(i * 17 + i ~/ 13) % 192 ~/ 8}',
        at: start.add(Duration(hours: (i ~/ 24) * 3, minutes: (i % 24) * 4)),
        kind: i % 29 == 0
            ? AutoplayFeedbackKind.loved
            : i % 23 == 0
            ? AutoplayFeedbackKind.playlisted
            : i % 11 == 0
            ? AutoplayFeedbackKind.skipped
            : i % 17 == 0
            ? AutoplayFeedbackKind.replayed
            : AutoplayFeedbackKind.listened,
        reward: i % 11 == 0 ? 0.1 : 0.7 + (i % 4) * 0.1,
      ),
  ];
}

/// Includes session boundaries, backwards feedback times and UTF-16 ordering.
List<AutoplayTastePlay> autoplayTasteEdgeFixture() {
  final start = DateTime.utc(2026, 1, 1);
  final events = <(String, int, AutoplayFeedbackKind, double)>[
    ('𐐀', 0, AutoplayFeedbackKind.listened, 1),
    ('𐐀', 1000000, AutoplayFeedbackKind.replayed, 1),
    ('\uE000', 600000000, AutoplayFeedbackKind.listened, 0.7),
    ('𐐀', 500000000, AutoplayFeedbackKind.loved, 1),
    ('𐐀', 2400000000, AutoplayFeedbackKind.listened, 1),
    ('\uE000', 2400000001, AutoplayFeedbackKind.skipped, 0.1),
    ('𐐀', 4200000002, AutoplayFeedbackKind.listened, 0.8),
    ('\uE000', 4200000003, AutoplayFeedbackKind.listened, 1),
    ('', 4200000004, AutoplayFeedbackKind.listened, 1),
    ('𐐀', 4200000005, AutoplayFeedbackKind.playlisted, 1),
    ('', 4200000006, AutoplayFeedbackKind.skipped, 0.5),
    ('\uE000', 4200000007, AutoplayFeedbackKind.listened, 1),
    ('', 4200000008, AutoplayFeedbackKind.listened, 1),
  ];
  return [
    for (final (i, event) in events.indexed)
      AutoplayTastePlay(
        id: i + 1,
        song: '${event.$1}|same',
        artist: event.$1,
        at: start.add(Duration(microseconds: event.$2)),
        kind: event.$3,
        reward: event.$4,
      ),
  ];
}

Map<String, dynamic> autoplayTasteFixtureRequest(
  List<AutoplayTastePlay> plays,
) => {
  'operation': 'train_autoplay_taste',
  'plays': [
    for (final play in plays)
      {
        'id': play.id,
        'song': play.song,
        'artist': play.artist,
        'atMicros': play.at.microsecondsSinceEpoch,
        'kind': play.kind.name,
        'reward': play.reward,
      },
  ],
};
