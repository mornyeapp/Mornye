import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/features/link_handoff.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/services/link/features/link_phone_player.dart';
import 'package:mornye/services/link/features/link_remote_playback.dart';
import 'package:mornye/services/link/features/link_track_resolver.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/together/link_together_controller.dart';
import 'package:mornye/services/link/together/link_together_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/link_fakes.dart';
import 'support/link_together_fakes.dart';

class _PlaysOnDesktop extends LinkPlaysOnDesktop {
  _PlaysOnDesktop(this.initial);

  final bool initial;

  @override
  bool build() => initial;
}

const _desktopSong = TrackRef(
  title: 'Desk Song',
  artist: 'Desk Artist',
  songId: 'song-1',
  serverId: 'server-1',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final phoneItem = linkMediaItem(
    linkLocalMedia('a', title: 'Phone Song'),
  ).copyWith(extras: const {'source': 'content://audio/document/a.flac'});

  /// The computer as the phone reaches it: [desktopPlays] says whether its
  /// player runs. Play together ops answer as a computer that has them, or
  /// `not_found` without [together].
  FakeLinkClient desktop({bool desktopPlays = false, bool together = true}) {
    Map<String, dynamic> report() => LinkTogetherReport(
      nowMs: DateTime.now().millisecondsSinceEpoch + 2500,
      track: _desktopSong,
      index: 0,
      playing: desktopPlays,
      ready: true,
      positionMs: 40000,
      durationMs: 200000,
    ).toJson();
    Object? unsupported(String op) =>
        LinkException('not_found', 'No handler for $op');
    return FakeLinkClient(
      onGet: (op, query) => switch (op) {
        LinkTogetherOps.time => together ? report() : unsupported(op),
        LinkOps.handoffCurrent => LinkHandoffQueue(
          queue: const [_desktopSong],
          index: 0,
          positionMs: 40000,
          playing: desktopPlays,
        ).toJson(),
        _ => null,
      },
      onPost: (op, body) => switch (op) {
        LinkOps.handoffPlay => {'resolved': 1, 'missing': <int>[]},
        LinkTogetherOps.start => report(),
        LinkTogetherOps.align => {'found': true},
        _ => {'ok': true},
      },
    );
  }

  ({ProviderContainer container, SimDeck deck, FakePhonePlayer player}) phone(
    FakeLinkClient client, {
    bool phonePlays = false,
    bool onDesktop = false,
  }) {
    final player = FakePhonePlayer(
      LinkPhoneSnapshot(
        queue: [phoneItem],
        index: 0,
        playing: phonePlays,
        positionMs: 12000,
        autoplay: true,
        autoMix: true,
      ),
    );
    final deck = SimDeck(
      trueNowMs: () => DateTime.now().millisecondsSinceEpoch,
      queue: [simSong('Phone Song')],
      durations: const [200000],
    );
    if (phonePlays) deck.playNow(position: 12000);
    final lookup = FakeLibraryLookup();
    final container = ProviderContainer(
      overrides: [
        linkPhoneClientProvider.overrideWithValue(client),
        linkPlaysOnDesktopProvider.overrideWith(
          () => _PlaysOnDesktop(onDesktop),
        ),
        linkTogetherPhoneDeckProvider.overrideWithValue(deck),
        linkHandoffProvider.overrideWithValue(
          LinkHandoff(
            client: client,
            player: player,
            refs: LinkTrackRefCache(lookup: lookup),
            resolver: LinkTrackResolver(lookup: lookup, server: client.server),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, deck: deck, player: player);
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the phone that plays shares its queue and leads', () async {
    final client = desktop();
    final (:container, :deck, player: _) = phone(client, phonePlays: true);
    final together = container.read(linkPlayTogetherProvider.notifier);

    expect(await together.start(), LinkTogetherStart.started);
    final state = container.read(linkPlayTogetherProvider);
    expect(state.phase, LinkTogetherPhase.active);
    expect(state.phoneLeads, isTrue);
    expect(deck.begun, isTrue);
    expect(deck.beganAsFollower, isFalse);

    final ops = [for (final post in client.posts) post.op];
    expect(
      ops.indexOf(LinkOps.handoffPlay),
      lessThan(ops.indexOf(LinkTogetherOps.start)),
    );
    final shared = client.posts.firstWhere(
      (post) => post.op == LinkOps.handoffPlay && post.body['check'] != true,
    );
    // Loaded paused, without changing the computer's saved choices.
    expect(shared.body['playing'], isFalse);
    expect(shared.body.containsKey('autoMix'), isFalse);
    expect(shared.body.containsKey('autoplay'), isFalse);
    final start = client.posts.firstWhere(
      (post) => post.op == LinkTogetherOps.start,
    );
    expect(start.body['role'], LinkTogetherRole.follower.name);
    expect(container.read(linkPlaysOnDesktopProvider), isFalse);

    // Choosing this phone ends it: the computer pauses.
    await together.stop(onPhone: true);
    expect(container.read(linkPlayTogetherProvider).active, isFalse);
    expect(deck.begun, isFalse);
    expect(deck.playing, isTrue);
    final stop = client.posts.lastWhere(
      (post) => post.op == LinkTogetherOps.stop,
    );
    expect(stop.body['session'], start.body['session']);
    expect(stop.body['pause'], isTrue);
    expect(container.read(linkPlaysOnDesktopProvider), isFalse);
  });

  test('the computer that plays leads and the phone loads its queue', () async {
    final client = desktop(desktopPlays: true);
    final (:container, :deck, :player) = phone(client, onDesktop: true);
    final together = container.read(linkPlayTogetherProvider.notifier);

    expect(await together.start(), LinkTogetherStart.started);
    expect(container.read(linkPlayTogetherProvider).phoneLeads, isFalse);
    expect(deck.beganAsFollower, isTrue);
    expect(client.gets, contains(LinkOps.handoffCurrent));
    expect(player.played?.playing, isFalse);
    expect(player.calls, isNot(contains('setAutoMix')));
    expect(container.read(linkPlaysOnDesktopProvider), isTrue);
    final start = client.posts.firstWhere(
      (post) => post.op == LinkTogetherOps.start,
    );
    expect(start.body['role'], LinkTogetherRole.leader.name);

    // Choosing the computer ends it there: the phone pauses and shows it.
    deck.playNow(position: 40000);
    await together.stop(onPhone: false);
    expect(deck.playing, isFalse);
    expect(
      client.posts.lastWhere((post) => post.op == LinkTogetherOps.stop).body,
      containsPair('pause', false),
    );
    expect(container.read(linkPlaysOnDesktopProvider), isTrue);
  });

  test('a lost connection ends it quietly on this phone', () async {
    final client = desktop(desktopPlays: true);
    final (:container, :deck, player: _) = phone(client, onDesktop: true);
    final together = container.read(linkPlayTogetherProvider.notifier);
    expect(await together.start(), LinkTogetherStart.started);
    deck.playNow(position: 40000);
    final posts = client.posts.length;

    client.setConnection(LinkConnectionState.disconnected);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(linkPlayTogetherProvider).active, isFalse);
    expect(container.read(linkPlaysOnDesktopProvider), isFalse);
    expect(deck.playing, isTrue);
    expect(deck.begun, isFalse);
    expect(client.posts.length, posts);
  });

  test(
    'an older computer asks for an update; nothing to play says so',
    () async {
      final old = phone(desktop(together: false), phonePlays: true);
      expect(
        await old.container.read(linkPlayTogetherProvider.notifier).start(),
        LinkTogetherStart.needsUpdate,
      );
      expect(old.container.read(linkPlayTogetherProvider).active, isFalse);

      final client = FakeLinkClient(
        onGet: (op, query) => LinkTogetherReport(
          nowMs: DateTime.now().millisecondsSinceEpoch,
        ).toJson(),
      );
      final empty = phone(client);
      empty.deck.load(const [], const []);
      expect(
        await empty.container.read(linkPlayTogetherProvider.notifier).start(),
        LinkTogetherStart.nothingPlaying,
      );
      expect(
        client.posts.where((post) => post.op == LinkTogetherOps.start),
        isEmpty,
      );
    },
  );

  test('the timing is remembered per computer and kept in range', () async {
    final client = desktop();
    final (:container, deck: _, player: _) = phone(client);
    final together = container.read(linkPlayTogetherProvider.notifier);
    await together.setShift(-180);
    await together.setShift(-4000);
    expect(container.read(linkPlayTogetherProvider).shiftMs, -1000);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(LinkPlayTogether.shiftKey('server-1')), -1000);

    // A new session reads it back.
    final again = phone(client);
    again.container.read(linkPlayTogetherProvider);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(again.container.read(linkPlayTogetherProvider).shiftMs, -1000);
  });
}
