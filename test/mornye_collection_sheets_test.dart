import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/track_collection_quick_actions.dart';

const _track = Track(
  id: 'example-track',
  name: 'Example track',
  artistName: 'Example artist',
  albumName: 'Example album',
  duration: 180,
);

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

class _Collections extends LibraryCollectionsNotifier {
  List<PlaylistPickerSummary> _summaries = [];
  final additions = <String>[];
  final createdNames = <String>[];
  final pendingAdditions = <Completer<void>>[];

  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);

  @override
  Future<String> createPlaylist(String name) async {
    createdNames.add(name);
    _summaries = [..._summaries, _playlist(name)];
    ref.invalidate(libraryPlaylistPickerSummariesProvider);
    return name;
  }

  @override
  Future<PlaylistAddBatchResult> addTracksToPlaylist(
    String playlistId,
    Iterable<Track> tracks, {
    bool preserveOccurrences = false,
  }) async {
    additions.add(playlistId);
    if (pendingAdditions.isNotEmpty) {
      await pendingAdditions.removeAt(0).future;
    }
    return PlaylistAddBatchResult(
      addedCount: tracks.length,
      alreadyInPlaylistCount: 0,
    );
  }
}

class _PopObserver extends NavigatorObserver {
  int pops = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops++;
  }
}

VoidCallback? _doneAction(WidgetTester tester, bool mornye) => mornye
    ? tester.widget<AppActionButton>(find.byType(AppActionButton)).onPressed
    : tester.widget<ExpressiveButton>(find.byType(ExpressiveButton)).onPressed;

PlaylistPickerSummary _playlist(String name, {bool contains = false}) =>
    PlaylistPickerSummary(
      id: name,
      name: name,
      trackCount: 2,
      containsAllRequestedTracks: contains,
    );

Widget _app(
  Widget child,
  _Collections collections, {
  required Brightness brightness,
  bool mornye = true,
  double textScale = 1,
  List<NavigatorObserver> navigatorObservers = const [],
}) => ProviderScope(
  overrides: [
    settingsProvider.overrideWith(_Settings.new),
    libraryCollectionsProvider.overrideWith(() => collections),
    libraryPlaylistPickerSummariesProvider.overrideWith(
      (ref, request) async => collections._summaries,
    ),
  ],
  child: MaterialApp(
    navigatorObservers: navigatorObservers,
    theme: mornye ? MornyeTheme.build(brightness) : ThemeData(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(body: child),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
    await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
          rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
        ))
        .load();
  });

  for (final mornye in [true, false]) {
    testWidgets('track menu copies the service link (Mornye: $mornye)', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      const linked = Track(
        id: 'example-track',
        name: 'Example track',
        artistName: 'Example artist',
        albumName: 'Example album',
        duration: 180,
        deezerId: '42',
      );
      await tester.pumpWidget(
        _app(
          const TrackCollectionQuickActions(track: linked),
          _Collections(),
          brightness: Brightness.light,
          mornye: mornye,
        ),
      );
      await tester.tap(find.byType(TrackCollectionQuickActions));
      await tester.pumpAndSettle();
      final action = find.text('Copy Deezer link');
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(copied, 'https://www.deezer.com/track/42');
      expect(find.text('Deezer URL copied to clipboard'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('desktop track menu offers the link only when known', (
    tester,
  ) async {
    final labels = <String, List<String>>{};
    const linked = Track(
      id: 'deezer:42',
      name: 'Example track',
      artistName: 'Example artist',
      albumName: 'Example album',
      duration: 180,
    );
    await tester.pumpWidget(
      _app(
        Consumer(
          builder: (context, ref, _) {
            for (final track in [_track, linked]) {
              labels[track.id] = [
                for (final group in trackOptionMenuGroups(context, ref, track))
                  for (final action in group) action.label,
              ];
            }
            return const SizedBox();
          },
        ),
        _Collections(),
        brightness: Brightness.light,
      ),
    );
    expect(labels['deezer:42'], contains('Copy Deezer link'));
    expect(labels['example-track']!.where((l) => l.contains('link')), isEmpty);
  });

  testWidgets('track menu hides the link for an unknown service', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const TrackCollectionQuickActions(track: _track),
        _Collections(),
        brightness: Brightness.light,
      ),
    );
    await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
    await tester.pumpAndSettle();
    expect(find.textContaining('link'), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('track menu reaches playlist creation in $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 680);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final collections = _Collections();
      await tester.pumpWidget(
        _app(
          const TrackCollectionQuickActions(track: _track),
          collections,
          brightness: brightness,
          textScale: 1.5,
        ),
      );
      await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
      await tester.pumpAndSettle();
      expect(find.byType(MornyeGlassPanel), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
      expect(find.byIcon(CupertinoIcons.doc_on_doc), findsNWidgets(2));

      await tester.ensureVisible(find.text('Add to playlist'));
      await tester.tap(find.text('Add to playlist'));
      await tester.pumpAndSettle();
      expect(find.text('No playlists yet'), findsOneWidget);
      expect(find.byType(MornyeGlassPanel), findsOneWidget);
      expect(find.text('Done').hitTestable(), findsOneWidget);

      await tester.tap(find.text('Create playlist'));
      await tester.pumpAndSettle();
      expect(find.byType(AppAlertDialog), findsOneWidget);
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(collections.createdNames, isEmpty);
      await tester.enterText(find.byType(TextFormField), 'Evening music');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(collections.createdNames, ['Evening music']);
      expect(collections.additions, ['Evening music']);
      expect(find.byIcon(CupertinoIcons.checkmark_circle_fill), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(collections.additions, ['Evening music']);
      expect(find.byType(MornyeGlassPanel), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final mornye in [true, false]) {
    testWidgets('picker submits and closes once (Mornye: $mornye)', (
      tester,
    ) async {
      final addition = Completer<void>();
      final collections = _Collections()
        .._summaries = [_playlist('Road trip')]
        ..pendingAdditions.add(addition);
      final observer = _PopObserver();
      await tester.pumpWidget(
        _app(
          Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () =>
                  showAddTracksToPlaylistSheet(context, ref, [_track]),
              child: const Text('Open'),
            ),
          ),
          collections,
          brightness: Brightness.light,
          mornye: mornye,
          navigatorObservers: [observer],
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Road trip'));
      await tester.pump();
      final submit = _doneAction(tester, mornye)!;
      // A repeated callback can arrive before the disabled button is rebuilt.
      submit();
      submit();
      await tester.pump();
      expect(collections.additions, ['Road trip']);
      expect(_doneAction(tester, mornye), isNull);
      expect(observer.pops, 0);

      addition.complete();
      await tester.pump();
      // The route remains mounted while its closing animation runs.
      submit();
      await tester.pumpAndSettle();
      expect(collections.additions, ['Road trip']);
      expect(observer.pops, 1);
      expect(find.text('Open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('picker retains selections after failure (Mornye: $mornye)', (
      tester,
    ) async {
      final firstAddition = Completer<void>()..complete();
      final secondAddition = Completer<void>();
      final collections = _Collections()
        .._summaries = [_playlist('Road trip'), _playlist('Evening music')]
        ..pendingAdditions.addAll([firstAddition, secondAddition]);
      final observer = _PopObserver();
      await tester.pumpWidget(
        _app(
          Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () =>
                  showAddTracksToPlaylistSheet(context, ref, [_track]),
              child: const Text('Open'),
            ),
          ),
          collections,
          brightness: Brightness.light,
          mornye: mornye,
          navigatorObservers: [observer],
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Road trip'));
      await tester.tap(find.text('Evening music'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await tester.pump();
      expect(collections.additions, ['Road trip', 'Evening music']);
      secondAddition.completeError(StateError('write failed'));
      await tester.pump();
      expect(observer.pops, 0);
      expect(_doneAction(tester, mornye), isNotNull);

      // Retrying keeps the failed selection and skips the persisted playlist.
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(collections.additions, [
        'Road trip',
        'Evening music',
        'Evening music',
      ]);
      expect(observer.pops, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('picker adds only new selections (Mornye: $mornye)', (
      tester,
    ) async {
      final collections = _Collections()
        .._summaries = [
          _playlist('Already included', contains: true),
          _playlist('Road trip'),
          _playlist('Unselected playlist'),
        ];
      await tester.pumpWidget(
        _app(
          Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () =>
                  showAddTracksToPlaylistSheet(context, ref, [_track]),
              child: const Text('Open'),
            ),
          ),
          collections,
          brightness: Brightness.light,
          mornye: mornye,
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Already included'));
      await tester.tap(find.text('Road trip'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(collections.additions, ['Road trip']);
      expect(tester.takeException(), isNull);
    });
  }
}
