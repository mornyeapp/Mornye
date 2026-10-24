import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/link/link_devices_sheet.dart';

import 'support/link_fakes.dart';

class _CurrentItem extends CurrentMediaItemNotifier {
  _CurrentItem(this.item);

  final MediaItem? item;

  @override
  Stream<MediaItem?> build() => Stream.value(item);
}

Map<String, dynamic> _desktopState({bool playing = false}) => LinkPlayerState(
  track: const TrackRef(title: 'Desk Song', artist: 'Desk Artist'),
  playing: playing,
  positionMs: 30000,
  durationMs: 180000,
  updatedMs: 1,
  queue: const [
    TrackRef(title: 'Desk Song', artist: 'Desk Artist'),
    TrackRef(title: 'Up Next', artist: 'Desk Artist'),
  ],
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
  Widget host({
    required ThemeData theme,
    LinkClientApi? client,
    MediaItem? phoneItem,
    Widget child = const LinkDevicesSheet(),
  }) => ProviderScope(
    overrides: [
      linkPhoneClientProvider.overrideWithValue(client),
      currentMediaItemProvider.overrideWith(() => _CurrentItem(phoneItem)),
    ],
    child: MaterialApp(
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    ),
  );

  FakeLinkClient desktop({bool playing = false}) => FakeLinkClient(
    onGet: (op, query) => switch (op) {
      LinkOps.state => _desktopState(playing: playing),
      LinkOps.downloads => _downloads(),
      _ => null,
    },
  );

  for (final style in ['material', 'mornye']) {
    final theme = style == 'mornye'
        ? MornyeTheme.build(Brightness.light)
        : AppTheme.light();

    group('$style Devices sheet', () {
      testWidgets('shows the desktop player, queue and downloads', (
        tester,
      ) async {
        final client = desktop();
        await tester.pumpWidget(
          host(
            theme: theme,
            client: client,
            phoneItem: linkMediaItem(linkLocalMedia('a')),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.text('Studio PC'), findsOneWidget);
        expect(find.text('Connected'), findsOneWidget);
        expect(find.byKey(const ValueKey('link-remote-title')), findsOneWidget);
        expect(find.text('Desk Song'), findsWidgets);
        expect(find.text('0:30'), findsOneWidget);
        expect(find.text('3:00'), findsOneWidget);
        expect(find.text('Continue on this phone'), findsOneWidget);
        expect(find.text('Play on Studio PC'), findsOneWidget);
        expect(find.text('Queue on Studio PC'), findsOneWidget);
        expect(find.byKey(const ValueKey('link-queue-1')), findsOneWidget);

        await tester.scrollUntilVisible(
          find.text('Broken'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Downloads on Studio PC'), findsOneWidget);
        expect(find.text('Artist · Downloading 40%'), findsOneWidget);
        expect(find.text('Artist · Done'), findsOneWidget);
        expect(find.text('Artist · Failed'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('controls send commands to the desktop', (tester) async {
        final client = desktop();
        await tester.pumpWidget(host(theme: theme, client: client));
        await tester.pump();
        await tester.pump();

        expect(find.text('Play on Studio PC'), findsNothing);
        await tester.tap(find.byTooltip('Play').first);
        await tester.pump();
        await tester.tap(find.byTooltip('Next track').first);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('link-remote-shuffle')));
        await tester.pump();
        await tester.ensureVisible(find.byKey(const ValueKey('link-queue-1')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('link-queue-1')));
        await tester.pump();

        expect(
          [for (final post in client.posts) post.body['action']],
          ['toggle', 'next', 'shuffle', 'jump'],
        );
        expect(client.posts.last.body['args'], {'index': 1});
        // The play command shows at once.
        expect(find.byTooltip('Pause'), findsWidgets);

        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('a lost connection disables the controls', (tester) async {
        final client = desktop()
          ..connectionState = LinkConnectionState.disconnected;
        await tester.pumpWidget(host(theme: theme, client: client));
        await tester.pump();
        await tester.pump();
        expect(find.text('Not connected'), findsOneWidget);
        await tester.ensureVisible(find.byKey(const ValueKey('link-queue-1')));
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('link-queue-1')),
          warnIfMissed: false,
        );
        await tester.pump();
        expect(client.posts, isEmpty);
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
    });
  }
}
