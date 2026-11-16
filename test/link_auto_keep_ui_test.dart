import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/library_tracks_folder_screen.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/features/link_auto_keep.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';
import 'support/link_fakes.dart';

final _entries = [
  for (final id in ['a', 'b'])
    CollectionTrackEntry(
      key: id,
      addedAt: DateTime(2026),
      track: Track(
        id: id,
        name: 'Song $id',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 180,
      ),
    ),
];

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(
    isLoaded: true,
    loved: _entries,
    playlists: [
      UserPlaylistCollection(
        id: 'mix',
        name: 'My mix',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        tracks: _entries,
      ),
    ],
  );

  @override
  Future<void> ensurePlaylistLoaded(String id) async {}
}

class _Library extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Host extends LinkDesktopHost {
  @override
  LinkDesktopHostState build() => const LinkDesktopHostState();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => debugDesktopPlatformOverride = null);

  Future<void> open(
    WidgetTester tester, {
    required bool mornye,
    required LibraryTracksFolderMode mode,
    LinkClientApi? client,
  }) async {
    debugDesktopPlatformOverride = false;
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(FixedSettingsNotifier.new),
          libraryCollectionsProvider.overrideWith(_Collections.new),
          linkDesktopHostProvider.overrideWith(_Host.new),
          linkPhoneClientProvider.overrideWithValue(client),
          localLibraryProvider.overrideWith(_Library.new),
          downloadHistoryProvider.overrideWith(_History.new),
          downloadHistoryVisibleBatchExistsProvider.overrideWith(
            (ref, request) => const {},
          ),
          localLibraryCoverProvider.overrideWith((ref, request) async => null),
          localLibraryFirstCoverProvider.overrideWith(
            (ref, request) async => null,
          ),
        ],
        child: MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: LibraryTracksFolderScreen(
            mode: mode,
            playlistId: mode == LibraryTracksFolderMode.playlist ? 'mix' : null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byType(HeaderMoreButton));
    await tester.pumpAndSettle();
  }

  for (final mornye in [false, true]) {
    for (final (mode, collection) in [
      (LibraryTracksFolderMode.playlist, linkKeptPlaylist('mix')),
      (LibraryTracksFolderMode.loved, linkKeptLoved),
    ]) {
      testWidgets('keeps ${mode.name} on this phone from its menu '
          '(Mornye: $mornye)', (tester) async {
        await open(
          tester,
          mornye: mornye,
          mode: mode,
          client: FakeLinkClient(),
        );
        expect(find.text('Kept on this phone'), findsNothing);

        await openMenu(tester);
        expect(find.text('Stop keeping on this phone'), findsNothing);
        await tester.tap(find.text('Keep on this phone'));
        final sign = find.text('Kept on this phone');
        for (var frame = 0; frame < 120 && sign.evaluate().isEmpty; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(sign, findsOneWidget);
        double opacity() => tester
            .widget<Opacity>(
              find.ancestor(of: sign, matching: find.byType(Opacity)).first,
            )
            .opacity;
        // Material fades the label in on the effects spring; the Mornye
        // header meta stays still.
        expect(opacity(), mornye ? 1 : lessThan(1));
        await tester.pumpAndSettle();
        expect(opacity(), 1);
        expect(
          find.ancestor(of: sign, matching: find.byType(HeaderMetaRow)),
          findsOneWidget,
        );
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getStringList(LinkKeptCollections.prefsKey), [collection]);

        await openMenu(tester);
        expect(find.text('Keep on this phone'), findsNothing);
        await tester.tap(find.text('Stop keeping on this phone'));
        await tester.pumpAndSettle();
        expect(find.text('Kept on this phone'), findsNothing);
        expect(prefs.getStringList(LinkKeptCollections.prefsKey), isEmpty);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('no keep entry without a paired computer (Mornye: $mornye)', (
      tester,
    ) async {
      await open(
        tester,
        mornye: mornye,
        mode: LibraryTracksFolderMode.playlist,
      );
      await openMenu(tester);
      expect(find.text('Export as M3U8'), findsOneWidget);
      expect(find.text('Keep on this phone'), findsNothing);
    });
  }

  testWidgets('a kept playlist shows its sign at once when opened', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      LinkKeptCollections.prefsKey: [linkKeptPlaylist('mix')],
    });
    await open(tester, mornye: false, mode: LibraryTracksFolderMode.playlist);
    final sign = find.text('Kept on this phone');
    expect(sign, findsOneWidget);
    final builder = tester.widget<TweenAnimationBuilder<double>>(
      find.ancestor(
        of: sign,
        matching: find.byType(TweenAnimationBuilder<double>),
      ),
    );
    expect(builder.tween.begin, 1);

    // Stopping still works while no computer is paired.
    await openMenu(tester);
    await tester.tap(find.text('Stop keeping on this phone'));
    await tester.pumpAndSettle();
    expect(sign, findsNothing);
  });
}
