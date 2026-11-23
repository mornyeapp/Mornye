import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/link/features/link_metadata_update.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/metadata_persistence_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/error_card.dart' show EmptyState;
import 'package:mornye/widgets/link/link_metadata_update_page.dart';

import 'support/page_back.dart';

final _l10n = lookupAppLocalizations(const Locale('en'));

const _server = LinkServerRecord(
  serverId: 'host-a',
  name: 'Studio',
  connectionId: 'connection-a',
  address: 'https://10.0.0.2:47710',
  fingerprint: 'ab',
);

String _origin(String songId) =>
    linkDesktopSongSource(_server, songId, format: 'flac');

DownloadHistoryItem _copy(String songId, String title, {String? genre}) =>
    DownloadHistoryItem(
      id: 'copy-$songId',
      trackName: title,
      artistName: 'Artist',
      albumName: 'Album',
      filePath: '/music/$songId.flac',
      originFilePath: _origin(songId),
      service: LinkOfflineSaver.service,
      downloadedAt: DateTime(2026),
      genre: genre,
    );

LocalLibraryItem _song(String songId, String title, {String? genre}) =>
    LocalLibraryItem(
      id: _origin(songId),
      trackName: title,
      artistName: 'Artist',
      albumName: 'Album',
      albumArtist: 'Artist',
      filePath: _origin(songId),
      scannedAt: DateTime(2026),
      genre: genre,
    );

class _Host {
  _Host({this.copies = const [], this.songs = const [], this.fail = false});

  List<DownloadHistoryItem> copies;
  final List<LocalLibraryItem> songs;
  bool fail;
  final requests = <MetadataSaveRequest>[];
  final records = <DownloadHistoryItem>[];
  final failing = <String>{};
  int reads = 0;

  LinkMetadataUpdater get updater => LinkMetadataUpdater(
    name: 'Studio',
    collector: LinkMetadataCollector(
      server: _server,
      copies: () async => copies,
      computerSongs: () {
        reads++;
        return fail
            ? Stream.error(StateError('offline'))
            : Stream.fromIterable(songs);
      },
      exists: (_) async => true,
    ),
    applier: LinkMetadataApplier(
      artistTagMode: () => 'joined',
      save: (request) async {
        requests.add(request);
        return failing.contains(request.filePath)
            ? const MetadataSaveResult.failed(MetadataSaveFailure.storage)
            : const MetadataSaveResult.saved();
      },
      record: (item) async => records.add(item),
      publish: (_) async {},
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  _Host host, {
  required bool mornye,
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [linkMetadataUpdaterProvider.overrideWithValue(host.updater)],
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showLinkMetadataUpdate(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _settle(tester);
}

/// Spinners never settle; pump past the page and snack bar transitions.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Finder _songRow(String id) =>
    find.byKey(ValueKey('link-metadata-song-copy-$id'));

Finder get _apply => find.byKey(const ValueKey('link-metadata-apply'));

Finder get _select => find.byKey(const ValueKey('link-metadata-select'));

void main() {
  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('$style: reviews each difference before updating', (
      tester,
    ) async {
      final host = _Host(
        copies: [
          _copy('1', 'Old one', genre: 'Pop'),
          _copy('2', 'Old two'),
          _copy('3', 'Same'),
        ],
        songs: [
          _song('1', 'New one', genre: 'Rock'),
          _song('2', 'New two'),
          _song('3', 'Same'),
        ],
      );
      await _pump(tester, host, mornye: mornye);

      expect(find.text(_l10n.linkMetadataUpdateTitle), findsWidgets);
      expect(
        find.text(_l10n.linkMetadataUpdateDescription('Studio')),
        findsOneWidget,
      );
      expect(_songRow('1'), findsOneWidget);
      expect(_songRow('2'), findsOneWidget);
      expect(_songRow('3'), findsNothing);
      expect(
        find.descendant(
          of: _songRow('1'),
          matching: find.text('Artist · ${_l10n.linkMetadataUpdateDiffers(2)}'),
        ),
        findsOneWidget,
      );
      expect(find.text(_l10n.linkMetadataUpdateApply(2)), findsOneWidget);

      // A song opens to its differences, all on.
      await tester.tap(_songRow('1'));
      await _settle(tester);
      expect(find.text(_l10n.editMetadataFieldTitle), findsOneWidget);
      expect(find.text(_l10n.trackGenre), findsOneWidget);
      expect(
        find.text(
          '${_l10n.linkMetadataUpdateOnPhone('Pop')}\n'
          '${_l10n.linkMetadataUpdateOnHost('Studio', 'Rock')}',
        ),
        findsOneWidget,
      );
      final switches = tester.widgetList<AppSwitch>(find.byType(AppSwitch));
      expect(switches.map((s) => s.value), [true, true]);
      await tester.tap(find.byKey(const ValueKey('link-metadata-genre')));
      await _settle(tester);
      expect(
        tester
            .widgetList<AppSwitch>(find.byType(AppSwitch))
            .map((s) => s.value),
        [true, false],
      );
      await pageBack(tester);
      await _settle(tester);
      expect(
        find.descendant(
          of: _songRow('1'),
          matching: find.text(
            'Artist · ${_l10n.linkMetadataUpdateDiffers(2)} · '
            '${_l10n.linkMetadataUpdateChosen(1, 2)}',
          ),
        ),
        findsOneWidget,
      );

      // Select none hides the update; select all brings every change back.
      await tester.tap(_select);
      await _settle(tester);
      expect(_apply, findsOneWidget);
      await tester.tap(_select);
      await _settle(tester);
      expect(_apply, findsNothing);
      await tester.tap(_select);
      await _settle(tester);
      expect(find.text(_l10n.linkMetadataUpdateApply(2)), findsOneWidget);

      // Nothing is written before the update.
      expect(host.requests, isEmpty);
      host.failing.add('/music/2.flac');
      await tester.tap(_apply);
      await _settle(tester);
      expect(host.requests.map((r) => r.filePath), [
        '/music/1.flac',
        '/music/2.flac',
      ]);
      expect(host.requests.first.metadata, {
        'title': 'New one',
        'genre': 'Rock',
      });
      expect(host.records.single.trackName, 'New one');
      expect(
        find.text(
          '${_l10n.linkMetadataUpdateResult(1)}. '
          '${_l10n.linkMetadataUpdateResultFailed(1)}',
        ),
        findsOneWidget,
      );
      // The song that failed stays listed to try again.
      expect(_songRow('1'), findsNothing);
      expect(_songRow('2'), findsOneWidget);
      expect(find.text(_l10n.linkMetadataUpdateApply(1)), findsOneWidget);
    });

    testWidgets('$style: says when everything matches', (tester) async {
      final host = _Host(
        copies: [_copy('1', 'Same')],
        songs: [_song('1', 'Same')],
      );
      await _pump(tester, host, mornye: mornye);
      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.text(_l10n.linkMetadataUpdateNoneTitle), findsOneWidget);
      expect(_apply, findsNothing);
      expect(_select, findsNothing);
    });

    testWidgets('$style: offers to try again when the host is unreachable', (
      tester,
    ) async {
      final host = _Host(
        copies: [_copy('1', 'Old')],
        songs: [_song('1', 'New')],
        fail: true,
      );
      await _pump(tester, host, mornye: mornye);
      expect(
        find.text(_l10n.linkMetadataUpdateFailedTitle('Studio')),
        findsOneWidget,
      );
      expect(_apply, findsNothing);
      host.fail = false;
      await tester.tap(find.text(_l10n.dialogRetry));
      await _settle(tester);
      expect(host.reads, 2);
      expect(_songRow('1'), findsOneWidget);
    });
  }

  testWidgets('shows progress while comparing', (tester) async {
    final songs = StreamController<LocalLibraryItem>();
    // Not awaited: the page has cancelled its listener by then.
    addTearDown(() => unawaited(songs.close()));
    final updater = LinkMetadataUpdater(
      name: 'Studio',
      collector: LinkMetadataCollector(
        server: _server,
        copies: () async => [_copy('1', 'Old')],
        computerSongs: () => songs.stream,
        exists: (_) async => true,
      ),
      applier: LinkMetadataApplier(
        artistTagMode: () => 'joined',
        record: (_) async {},
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [linkMetadataUpdaterProvider.overrideWithValue(updater)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const LinkMetadataUpdatePage(),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.text(_l10n.linkMetadataUpdateComparing('Studio')),
      findsOneWidget,
    );
    songs.add(_song('1', 'New'));
    await _settle(tester);
    expect(_songRow('1'), findsOneWidget);
  });
}
