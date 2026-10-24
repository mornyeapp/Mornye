import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/link/features/link_handoff.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/services/link/features/link_phone_player.dart';
import 'package:mornye/services/link/features/link_remote_playback.dart';
import 'package:mornye/services/link/features/link_track_resolver.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/remote_playback.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/link/link_devices_sheet.dart';
import 'package:mornye/widgets/settings_group.dart';

import 'support/link_fakes.dart';

class _LocalItem extends LocalMediaItemNotifier {
  _LocalItem(this.item);

  final MediaItem? item;

  @override
  Stream<MediaItem?> build() => Stream.value(item);
}

class _PlaysOnDesktop extends LinkPlaysOnDesktop {
  _PlaysOnDesktop(this.initial);

  final bool initial;

  @override
  bool build() => initial;
}

/// The desktop as the player screens see it; only its name is read.
class _Remote implements RemotePlayback {
  @override
  String get name => 'Studio PC';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _desktopState() => LinkPlayerState(
  track: const TrackRef(title: 'Desk Song', artist: 'Desk Artist'),
  playing: true,
  positionMs: 30000,
  durationMs: 180000,
  updatedMs: 1,
  queue: const [TrackRef(title: 'Desk Song', artist: 'Desk Artist')],
  index: 0,
  volume: 0.5,
).toJson();

Map<String, dynamic> _downloads() => {
  'items': [
    {
      'id': 'd1',
      'title': 'Fetching',
      'artist': 'Artist',
      'status': 'downloading',
      'progress': 0.4,
    },
    {'id': 'd2', 'title': 'Fetched', 'artist': 'Artist', 'status': 'completed'},
    {'id': 'd3', 'title': 'Broken', 'artist': 'Artist', 'status': 'failed'},
  ],
};

void main() {
  final phoneItem = linkMediaItem(linkLocalMedia('a', title: 'Phone Song'));

  Widget host({
    required ThemeData theme,
    LinkClientApi? client,
    MediaItem? item,
    bool phonePlaying = false,
    bool onDesktop = false,
    RemotePlayback? remote,
    Widget? child,
  }) {
    final player = FakePhonePlayer(
      LinkPhoneSnapshot(
        queue: [?item],
        index: item == null ? -1 : 0,
        playing: phonePlaying,
      ),
    );
    final lookup = FakeLibraryLookup();
    return ProviderScope(
      overrides: [
        linkPhoneClientProvider.overrideWithValue(client),
        localMediaItemProvider.overrideWith(() => _LocalItem(item)),
        playbackPlayingProvider.overrideWithValue(phonePlaying),
        linkPlaysOnDesktopProvider.overrideWith(
          () => _PlaysOnDesktop(onDesktop),
        ),
        activeRemotePlaybackProvider.overrideWithValue(remote),
        linkHandoffProvider.overrideWithValue(
          client == null
              ? null
              : LinkHandoff(
                  client: client,
                  player: player,
                  refs: LinkTrackRefCache(lookup: lookup),
                  resolver: LinkTrackResolver(lookup: lookup),
                ),
        ),
      ],
      child: MaterialApp(
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body:
              child ??
              Builder(
                builder: (context) => TextButton(
                  onPressed: () => showLinkDevicesSheet(context),
                  child: const Text('Open'),
                ),
              ),
        ),
      ),
    );
  }

  FakeLinkClient desktop({bool desktopPlays = true}) => FakeLinkClient(
    onGet: (op, query) => switch (op) {
      LinkOps.state => desktopPlays ? _desktopState() : <String, dynamic>{},
      LinkOps.downloads => _downloads(),
      LinkOps.handoffCurrent => _desktopState(),
      _ => null,
    },
    onPost: (op, body) => {'resolved': 1, 'missing': <int>[]},
  );

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  SettingsItem row(WidgetTester tester, String key) =>
      tester.widget<SettingsItem>(find.byKey(ValueKey(key)));

  bool playsOnDesktop(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.byType(Scaffold).first),
  ).read(linkPlaysOnDesktopProvider);

  for (final style in ['material', 'mornye']) {
    final theme = style == 'mornye'
        ? MornyeTheme.build(Brightness.light)
        : AppTheme.light();

    group('$style Devices sheet', () {
      testWidgets('lists this phone, the desktop and its downloads', (
        tester,
      ) async {
        await tester.pumpWidget(
          host(theme: theme, client: desktop(), item: phoneItem),
        );
        await open(tester);

        expect(find.text('This phone'), findsOneWidget);
        expect(find.text('Studio PC'), findsOneWidget);
        expect(find.text('Connected'), findsOneWidget);
        // This phone plays, so it is checked and does nothing on a tap.
        expect(row(tester, 'link-device-phone').selected, isTrue);
        expect(row(tester, 'link-device-phone').onTap, isNull);
        expect(row(tester, 'link-device-desktop').selected, isFalse);
        expect(row(tester, 'link-device-desktop').onTap, isNotNull);
        // The desktop's own player now lives in Now Playing.
        expect(find.text('Desk Song'), findsNothing);

        await tester.scrollUntilVisible(
          find.text('Broken'),
          200,
          scrollable: find.byType(Scrollable).last,
        );
        expect(find.text('Downloads on Studio PC'), findsOneWidget);
        expect(find.text('Artist · Downloading 40%'), findsOneWidget);
        expect(find.text('Artist · Done'), findsOneWidget);
        expect(find.text('Artist · Failed'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('choosing the desktop moves what the phone plays there', (
        tester,
      ) async {
        final client = desktop();
        await tester.pumpWidget(
          host(
            theme: theme,
            client: client,
            item: phoneItem,
            phonePlaying: true,
          ),
        );
        await open(tester);
        await tester.tap(find.text('Studio PC'));
        await tester.pump();
        await tester.pump();

        expect(client.posts.single.op, LinkOps.handoffPlay);
        expect(playsOnDesktop(tester), isTrue);
        await tester.pump(const Duration(seconds: 5));
      });

      testWidgets('choosing the desktop from a paused phone only switches', (
        tester,
      ) async {
        final client = desktop();
        await tester.pumpWidget(
          host(theme: theme, client: client, item: phoneItem),
        );
        await open(tester);
        await tester.tap(find.text('Studio PC'));
        await tester.pump();

        expect(client.posts, isEmpty);
        expect(playsOnDesktop(tester), isTrue);
      });

      testWidgets('the desktop that plays is checked and not chosen again', (
        tester,
      ) async {
        final client = desktop();
        await tester.pumpWidget(
          host(theme: theme, client: client, item: phoneItem, onDesktop: true),
        );
        await open(tester);

        expect(row(tester, 'link-device-desktop').selected, isTrue);
        expect(row(tester, 'link-device-desktop').onTap, isNull);
        await tester.tap(find.text('Studio PC'), warnIfMissed: false);
        await tester.pump();
        expect(client.posts, isEmpty);
        expect(find.byType(LinkDevicesSheet), findsOneWidget);
      });

      testWidgets('choosing this phone takes over what the desktop plays', (
        tester,
      ) async {
        final client = desktop();
        await tester.pumpWidget(
          host(theme: theme, client: client, item: phoneItem, onDesktop: true),
        );
        await open(tester);
        await tester.tap(find.text('This phone'));
        await tester.pump();
        await tester.pump();

        expect(client.gets, contains(LinkOps.handoffCurrent));
        await tester.pump(const Duration(seconds: 5));
      });

      testWidgets('choosing this phone with nothing on the desktop switches', (
        tester,
      ) async {
        final client = desktop(desktopPlays: false);
        await tester.pumpWidget(
          host(theme: theme, client: client, item: phoneItem, onDesktop: true),
        );
        await open(tester);
        await tester.tap(find.text('This phone'));
        await tester.pump();

        expect(client.gets, isNot(contains(LinkOps.handoffCurrent)));
        expect(playsOnDesktop(tester), isFalse);
      });

      testWidgets('a lost connection leaves the desktop unavailable', (
        tester,
      ) async {
        final client = desktop()
          ..connectionState = LinkConnectionState.disconnected;
        await tester.pumpWidget(
          host(theme: theme, client: client, item: phoneItem),
        );
        await open(tester);

        expect(find.text('Not connected'), findsOneWidget);
        expect(row(tester, 'link-device-desktop').onTap, isNull);
      });

      testWidgets('the Devices button appears only with a paired desktop', (
        tester,
      ) async {
        await tester.pumpWidget(
          host(theme: theme, child: const LinkDevicesButton()),
        );
        expect(find.byTooltip('Devices'), findsNothing);

        await tester.pumpWidget(
          host(
            theme: theme,
            client: desktop(),
            child: const LinkDevicesButton(),
          ),
        );
        expect(find.byTooltip('Devices'), findsOneWidget);
        await tester.tap(find.byTooltip('Devices'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(LinkDevicesSheet), findsOneWidget);
        expect(find.text('Studio PC'), findsOneWidget);
      });

      testWidgets('the player says where the music plays', (tester) async {
        await tester.pumpWidget(
          host(
            theme: theme,
            client: desktop(),
            child: const LinkPlayingOnLabel(),
          ),
        );
        expect(find.textContaining('Playing on'), findsNothing);

        await tester.pumpWidget(
          host(
            theme: theme,
            client: desktop(),
            onDesktop: true,
            remote: _Remote(),
            child: const LinkPlayingOnLabel(),
          ),
        );
        expect(find.text('Playing on Studio PC'), findsOneWidget);
        await tester.tap(find.text('Playing on Studio PC'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(LinkDevicesSheet), findsOneWidget);
      });
    });
  }
}
