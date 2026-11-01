import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/link/link_transfers.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/error_card.dart' show EmptyState;
import 'package:mornye/widgets/link/link_transfer_tile.dart';
import 'package:mornye/widgets/link/link_transfers_view.dart';
import 'package:mornye/widgets/sliver_layout_info_builder.dart';

final _l10n = lookupAppLocalizations(const Locale('en'));

String _id(String c) => List.filled(32, c).join();

List<LinkTransferEntry> _songs(int count, {String? cover}) => [
  for (var i = 0; i < count; i++)
    LinkTransferEntry(
      title: 'Song ${i + 1}',
      artist: 'Artist',
      coverPath: i == 0 ? cover : null,
    ),
];

final _start = DateTime(2026, 10, 25, 10);

/// Sending 12 songs, on the third (45% of it) after one saved and one the
/// receiver had.
final _running = LinkTransfer(
  direction: LinkTransferDirection.outgoing,
  peerId: 'desktop',
  peerName: 'Studio',
  entries: _songs(12, cover: '/music/covers/song-1.jpg'),
  status: LinkTransferStatus(
    transferId: _id('a'),
    state: LinkTransferState.running,
    total: 12,
    index: 2,
    received: 450,
    size: 1000,
    skipped: const [1],
  ),
  startedAt: _start,
);

final _queued = LinkTransfer(
  direction: LinkTransferDirection.incoming,
  peerId: 'desktop',
  peerName: 'Studio',
  entries: _songs(5),
  status: LinkTransferStatus(
    transferId: _id('b'),
    state: LinkTransferState.queued,
    total: 5,
  ),
  startedAt: _start.add(const Duration(minutes: 1)),
);

final _done = LinkTransfer(
  direction: LinkTransferDirection.outgoing,
  peerId: 'desktop',
  peerName: 'Studio',
  entries: _songs(12),
  status: LinkTransferStatus(
    transferId: _id('c'),
    state: LinkTransferState.done,
    total: 12,
    index: 12,
    skipped: const [3],
    failed: const [7],
  ),
  startedAt: _start.subtract(const Duration(minutes: 10)),
  finishedAt: _start.subtract(const Duration(minutes: 5)),
);

final _cancelled = LinkTransfer(
  direction: LinkTransferDirection.incoming,
  peerId: 'desktop',
  peerName: 'Studio',
  entries: _songs(12),
  status: LinkTransferStatus(
    transferId: _id('d'),
    state: LinkTransferState.cancelled,
    total: 12,
    index: 5,
  ),
  startedAt: _start.subtract(const Duration(minutes: 20)),
  finishedAt: _start.subtract(const Duration(minutes: 15)),
);

final _failed = LinkTransfer(
  direction: LinkTransferDirection.outgoing,
  peerId: 'desktop',
  peerName: 'Studio',
  entries: const [LinkTransferEntry(title: 'Only song', artist: 'Artist')],
  status: LinkTransferStatus(
    transferId: _id('e'),
    state: LinkTransferState.failed,
    total: 1,
    reason: 'disconnected',
  ),
  startedAt: _start.subtract(const Duration(minutes: 30)),
  finishedAt: _start.subtract(const Duration(minutes: 29)),
);

final _all = [_queued, _running, _done, _cancelled, _failed];

ThemeData _theme(bool mornye) =>
    mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light();

/// Pumps [home] (the Transfers page by default) over a store holding
/// [transfers]; cancel requests land in [cancelled].
Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required bool mornye,
  List<LinkTransfer> transfers = const [],
  List<String>? cancelled,
  Widget home = const LinkTransfersPage(),
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = const Size(800, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer();
  addTearDown(container.dispose);
  final store = container.read(linkTransfersProvider.notifier);
  for (final transfer in transfers) {
    store.add(transfer, cancel: () => cancelled?.add(transfer.id));
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: _theme(mornye),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
        home: home,
      ),
    ),
  );
  await tester.pump();
  return container;
}

/// Lets springs and progress easing finish; the wavy indicators never
/// settle.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Finder _tile(String title) => find.ancestor(
  of: find.text(title),
  matching: find.byType(LinkTransferTile),
);

void main() {
  for (final mornye in [false, true]) {
    testWidgets('transfer group padding survives scroll frames ($mornye)', (
      tester,
    ) async {
      await _pump(
        tester,
        mornye: mornye,
        transfers: [_running, _queued, _done, _failed],
      );
      tester.view.physicalSize = const Size(800, 400);
      await _settle(tester);
      final builder = find
          .byWidgetPredicate(
            (widget) =>
                widget is SliverLayoutInfoBuilder<double> ||
                widget is SliverLayoutBuilder,
          )
          .first;
      final padding = find
          .descendant(of: builder, matching: find.byType(SliverPadding))
          .first;
      final original = tester.widget<SliverPadding>(padding);
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(position.maxScrollExtent, greaterThan(100));
      for (var i = 1; i <= 10; i++) {
        position.jumpTo(i * 10);
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.widget<SliverPadding>(padding), same(original));
      }
      tester.view.physicalSize = const Size(600, 400);
      await tester.pump();
      expect(tester.widget<SliverPadding>(padding), isNot(same(original)));
      expect(tester.takeException(), isNull);
    });
  }

  group('text', () {
    test('titles name the songs, the device and the direction', () {
      expect(linkTransferTitle(_l10n, _running), 'Sending 12 songs to Studio');
      expect(
        linkTransferTitle(_l10n, _queued),
        'Receiving 5 songs from Studio',
      );
      expect(linkTransferTitle(_l10n, _done), '12 songs to Studio');
      expect(linkTransferTitle(_l10n, _cancelled), '12 songs from Studio');
      expect(linkTransferTitle(_l10n, _failed), 'Only song to Studio');
      final one = _failed.withStatus(
        _failed.status.copyWith(state: LinkTransferState.running),
        _start,
      );
      expect(linkTransferTitle(_l10n, one), 'Sending Only song to Studio');
    });

    test('status lines report progress and outcomes', () {
      expect(linkTransferStatusText(_l10n, _running), 'Song 3 · 3 of 12 · 20%');
      expect(linkTransferStatusText(_l10n, _queued), 'Waiting');
      expect(
        linkTransferStatusText(_l10n, _done),
        '10 saved · 1 already there · 1 failed',
      );
      expect(
        linkTransferStatusText(_l10n, _cancelled),
        'Stopped after 5 of 12',
      );
      expect(linkTransferStatusText(_l10n, _failed), 'Connection lost');

      LinkTransfer failedWith(String? reason, LinkTransferDirection way) =>
          LinkTransfer(
            direction: way,
            peerId: 'desktop',
            peerName: 'Studio',
            entries: _songs(4),
            status: LinkTransferStatus(
              transferId: _id('f'),
              state: LinkTransferState.failed,
              total: 4,
              index: 2,
              reason: reason,
            ),
            startedAt: _start,
          );
      expect(
        linkTransferStatusText(
          _l10n,
          failedWith('no_folder', LinkTransferDirection.incoming),
        ),
        'Choose a download folder first · 2 saved',
      );
      expect(
        linkTransferStatusText(
          _l10n,
          failedWith('no_folder', LinkTransferDirection.outgoing),
        ),
        'Studio has no download folder · 2 saved',
      );
      expect(
        linkTransferStatusText(
          _l10n,
          failedWith('busy', LinkTransferDirection.outgoing),
        ),
        'Busy, try again later · 2 saved',
      );
      expect(
        linkTransferStatusText(
          _l10n,
          failedWith(null, LinkTransferDirection.outgoing),
        ),
        'Something went wrong · 2 saved',
      );
      final stoppedAtOnce = _cancelled.withStatus(
        _cancelled.status.copyWith(index: 0),
        _start,
      );
      expect(linkTransferStatusText(_l10n, stoppedAtOnce), 'Stopped');
    });

    test('the summary follows what runs, then what finished', () {
      expect(linkTransfersSummary(_l10n, const []), 'No transfers yet');
      expect(linkTransfersProgress(const []), isNull);
      expect(
        linkTransfersSummary(_l10n, [_running, _done]),
        'Sending 12 songs to Studio · 20%',
      );
      expect(
        linkTransfersSummary(_l10n, [_queued]),
        'Receiving 5 songs from Studio · Waiting',
      );
      // 2.45 of 12 songs and 0 of 5.
      expect(linkTransfersProgress([_running, _queued]), closeTo(0.144, 1e-3));
      expect(
        linkTransfersSummary(_l10n, [_running, _queued, _done]),
        '2 transfers · 14%',
      );
      expect(linkTransfersProgress([_done, _failed]), isNull);
      expect(
        linkTransfersSummary(_l10n, [_done, _cancelled, _failed]),
        '3 transfers finished',
      );
      expect(linkTransferPercent(0.999, active: true), 99);
      expect(linkTransferPercent(1, active: false), 100);
    });
  });

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('$style: lists transfers in progress, then finished ones', (
      tester,
    ) async {
      await _pump(tester, mornye: mornye, transfers: _all);

      expect(find.text(_l10n.linkTransfersInProgress), findsOneWidget);
      expect(find.text(_l10n.linkTransfersFinished), findsOneWidget);
      expect(find.text('Sending 12 songs to Studio'), findsOneWidget);
      expect(find.text('Song 3'), findsOneWidget);
      expect(find.text('3 of 12 · 20%'), findsOneWidget);
      expect(find.text('Receiving 5 songs from Studio'), findsOneWidget);
      expect(find.text('Waiting'), findsOneWidget);
      expect(find.text('12 songs to Studio'), findsOneWidget);
      expect(
        find.text('10 saved · 1 already there · 1 failed'),
        findsOneWidget,
      );
      expect(find.text('12 songs from Studio'), findsOneWidget);
      expect(find.text('Stopped after 5 of 12'), findsOneWidget);
      expect(find.text('Only song to Studio'), findsOneWidget);
      expect(find.text('Connection lost'), findsOneWidget);

      // Active ones carry a ring, a bar and a stop button; finished ones
      // rest without them.
      expect(
        find.byKey(const ValueKey('link-transfer-ring')),
        findsNWidgets(2),
      );
      expect(
        find.byKey(const ValueKey('link-transfer-progress')),
        findsNWidgets(2),
      );
      expect(
        find.byKey(const ValueKey('link-transfer-stop')),
        findsNWidgets(2),
      );
      expect(find.byKey(const ValueKey('link-transfers-clear')), findsOne);

      // The running transfer leads, then the queue; the latest finished
      // one leads its group.
      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(
        top('Sending 12 songs to Studio'),
        lessThan(top('Receiving 5 songs from Studio')),
      );
      expect(
        top('Receiving 5 songs from Studio'),
        lessThan(top('12 songs to Studio')),
      );
      expect(top('12 songs to Studio'), lessThan(top('12 songs from Studio')));
      expect(top('12 songs from Studio'), lessThan(top('Only song to Studio')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style: opens a transfer to its songs and closes it', (
      tester,
    ) async {
      await _pump(tester, mornye: mornye, transfers: _all);
      expect(find.text('Song 1'), findsNothing);

      await tester.tap(find.text('Sending 12 songs to Studio'));
      await tester.pump();
      // The songs grow open with the spring rather than at once.
      expect(find.text('Song 1'), findsNothing);
      await _settle(tester);
      expect(find.text('Song 1'), findsOneWidget);
      expect(find.text('Artist · Saved'), findsOneWidget);
      expect(find.text('Artist · Already there'), findsOneWidget);
      expect(find.text('Artist · Copying · 45%'), findsOneWidget);
      expect(find.text('Artist · Waiting'), findsNWidgets(9));
      // Covers show from a file path or a web address.
      expect(find.byType(LocalOrNetworkCoverImage), findsOneWidget);

      await tester.tap(find.text('12 songs to Studio'));
      await _settle(tester);
      expect(find.text('Artist · Failed'), findsOneWidget);
      expect(find.text('Artist · Saved'), findsNWidgets(11));

      await tester.tap(find.text('12 songs from Studio'));
      await _settle(tester);
      expect(find.text('Artist · Not copied'), findsNWidgets(7));

      await tester.tap(find.text('Sending 12 songs to Studio'));
      await tester.tap(find.text('12 songs to Studio'));
      await tester.tap(find.text('12 songs from Studio'));
      await _settle(tester);
      expect(find.text('Song 1'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style: stops an active transfer', (tester) async {
      final cancelled = <String>[];
      await _pump(
        tester,
        mornye: mornye,
        transfers: _all,
        cancelled: cancelled,
      );
      await tester.tap(
        find.descendant(
          of: _tile('Receiving 5 songs from Studio'),
          matching: find.byKey(const ValueKey('link-transfer-stop')),
        ),
      );
      await tester.pump();
      expect(cancelled, [_queued.id]);
      // Stopping does not open the transfer.
      expect(find.text('Song 1'), findsNothing);
    });

    testWidgets('$style: clears the finished transfers', (tester) async {
      final container = await _pump(tester, mornye: mornye, transfers: _all);
      await tester.tap(find.byKey(const ValueKey('link-transfers-clear')));
      await _settle(tester);
      expect(container.read(linkTransfersProvider), hasLength(2));
      expect(find.text(_l10n.linkTransfersFinished), findsNothing);
      expect(find.text('12 songs to Studio'), findsNothing);
      expect(find.text('Sending 12 songs to Studio'), findsOneWidget);
      expect(find.byKey(const ValueKey('link-transfers-clear')), findsNothing);
    });

    testWidgets('$style: says how to start a transfer when there is none', (
      tester,
    ) async {
      await _pump(tester, mornye: mornye);
      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.text(_l10n.linkTransfersEmptyTitle), findsOneWidget);
      expect(find.text(_l10n.linkTransfersEmptyMessage), findsOneWidget);
      expect(find.text(_l10n.linkTransfersInProgress), findsNothing);
      expect(find.byKey(const ValueKey('link-transfers-clear')), findsNothing);
    });

    testWidgets('$style: follows the store as transfers progress', (
      tester,
    ) async {
      final container = await _pump(
        tester,
        mornye: mornye,
        transfers: [_running],
      );
      await tester.tap(find.text('Sending 12 songs to Studio'));
      await _settle(tester);
      final store = container.read(linkTransfersProvider.notifier);

      store.update(_running.status.copyWith(index: 3, received: 0));
      await _settle(tester);
      expect(find.text('Song 4'), findsNWidgets(2));
      expect(find.text('4 of 12 · 25%'), findsOneWidget);
      expect(find.text('Artist · Saved'), findsNWidgets(2));

      // Finished, it moves to its group and stays open.
      store.update(
        _running.status.copyWith(state: LinkTransferState.done, index: 12),
      );
      await _settle(tester);
      expect(find.text(_l10n.linkTransfersInProgress), findsNothing);
      expect(find.text(_l10n.linkTransfersFinished), findsOneWidget);
      expect(find.text('12 songs to Studio'), findsOneWidget);
      expect(find.text('11 saved · 1 already there'), findsOneWidget);
      expect(find.text('Artist · Saved'), findsNWidgets(11));
      expect(find.byKey(const ValueKey('link-transfer-ring')), findsNothing);
      expect(find.byKey(const ValueKey('link-transfer-stop')), findsNothing);
    });
  }

  testWidgets('opens at once under reduced motion', (tester) async {
    await _pump(tester, mornye: false, transfers: [_done], reduceMotion: true);
    await tester.tap(find.text('12 songs to Studio'));
    await tester.pump();
    expect(find.text('Song 12'), findsOneWidget);
  });

  testWidgets('shows a song cover stored as a file URI', (tester) async {
    final transfer = LinkTransfer(
      direction: LinkTransferDirection.outgoing,
      peerId: 'desktop',
      peerName: 'Studio',
      entries: _songs(
        12,
        cover: Uri.file('/music/covers/song-1.jpg').toString(),
      ),
      status: _done.status,
      startedAt: _done.startedAt,
      finishedAt: _done.finishedAt,
    );
    await _pump(
      tester,
      mornye: false,
      transfers: [transfer],
      reduceMotion: true,
    );
    await tester.tap(find.text('12 songs to Studio'));
    await tester.pump();
    final image = tester.widget<Image>(
      find.descendant(
        of: find.byType(LocalOrNetworkCoverImage),
        matching: find.byType(Image),
      ),
    );
    expect((image.image as FileImage).file.path, '/music/covers/song-1.jpg');
  });

  testWidgets('pushes the Transfers page on phones', (tester) async {
    await _pump(
      tester,
      mornye: false,
      transfers: [_running],
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showLinkTransfers(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);
    expect(find.byType(LinkTransfersPage), findsOneWidget);
    expect(find.byKey(const ValueKey('app-sheet-dialog')), findsNothing);
    expect(find.text('Sending 12 songs to Studio'), findsOneWidget);
  });

  group('desktop', () {
    setUp(() => debugDesktopPlatformOverride = true);
    tearDown(() => debugDesktopPlatformOverride = null);

    for (final mornye in [false, true]) {
      final style = mornye ? 'Mornye' : 'Material';

      testWidgets('$style: opens the list in a dialog', (tester) async {
        final container = await _pump(
          tester,
          mornye: mornye,
          transfers: _all,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showLinkTransfers(context),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await _settle(tester);
        final dialog = find.byKey(const ValueKey('app-sheet-dialog'));
        expect(dialog, findsOneWidget);
        expect(find.byType(LinkTransfersDialog), findsOneWidget);
        // The list size class.
        expect(tester.getSize(find.byType(LinkTransfersDialog)).width, 560);
        expect(
          find.descendant(
            of: dialog,
            matching: find.text(_l10n.linkTransfersTitle),
          ),
          findsOneWidget,
        );
        expect(find.text('Sending 12 songs to Studio'), findsOneWidget);

        await tester.tap(find.text('Sending 12 songs to Studio'));
        await _settle(tester);
        expect(find.text('Artist · Copying · 45%'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('link-transfers-clear')));
        await _settle(tester);
        expect(container.read(linkTransfersProvider), hasLength(2));
        expect(find.text(_l10n.linkTransfersFinished), findsNothing);
        expect(
          find.byKey(const ValueKey('link-transfers-clear')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
