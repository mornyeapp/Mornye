import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/screens/album_screen.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/album_description.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/audio_quality_badges.dart';
import 'package:mornye/widgets/disc_separator_chip.dart';
import 'package:mornye/widgets/track_list_tile.dart';

import 'support/tooltip_finder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backendChannel = MethodChannel('com.zarz.mornye/backend');
  final backendMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    backendMessenger.setMockMethodCallHandler(
      backendChannel,
      (_) async => null,
    );
    await PlatformBridge.clearTrackCache();
  });
  tearDown(() async {
    backendMessenger.setMockMethodCallHandler(
      backendChannel,
      (_) async => null,
    );
    await PlatformBridge.clearTrackCache();
    backendMessenger.setMockMethodCallHandler(backendChannel, null);
  });

  for (final nested in [true, false]) {
    for (final fetchedName in ['Actual Album Title', '  ']) {
      testWidgets(
        'extension album resolves its title (nested: $nested, name: "$fetchedName")',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          await tester.binding.setSurfaceSize(const Size(430, 1200));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          const channel = MethodChannel('com.zarz.mornye/backend');
          final messenger = tester.binding.defaultBinaryMessenger;
          var requests = 0;
          messenger.setMockMethodCallHandler(channel, (call) async {
            if (call.method != 'getProviderMetadata') return null;
            requests++;
            final info = <String, dynamic>{
              'name': fetchedName,
              'artists': 'Example Artist',
              'total_tracks': 1,
              'editorial_notes': {
                'standard': '<p>A <i>new direction</i> for the band.</p>',
                'short': 'A new direction.',
              },
            };
            final tracks = [
              {
                'id': 'example-song',
                'name': 'Example Song',
                'artists': 'Example Artist',
                'album_name': '',
                'duration_ms': 180000,
              },
            ];
            return jsonEncode(
              nested
                  ? {'album_info': info, 'track_list': tracks}
                  : {...info, 'tracks': tracks},
            );
          });
          addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                theme: MornyeTheme.build(Brightness.light),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: const ExtensionAlbumScreen(
                  extensionId: 'example-metadata',
                  albumId: 'example-album',
                  albumName: 'Album',
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final expected = fetchedName.trim().isEmpty ? 'Album' : fetchedName;
          final album = tester.widget<AlbumScreen>(find.byType(AlbumScreen));
          expect(album.albumName, expected);
          expect(
            album.description,
            '<p>A <i>new direction</i> for the band.</p>',
          );
          expect(album.tracks!.single.albumName, expected);
          expect(find.text(expected), findsWidgets);
          expect(requests, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        },
      );
    }
  }

  for (final mornye in [false, true]) {
    for (final discs in [1, 2]) {
      testWidgets('online album disc groups (Mornye: $mornye, discs: $discs)', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(430, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        backendMessenger.setMockMethodCallHandler(backendChannel, (call) async {
          if (call.method != 'getProviderMetadata') return null;
          return jsonEncode({
            'album_info': {'name': 'Example Album', 'total_tracks': 2},
            'track_list': [
              for (var index = 0; index < 2; index++)
                {
                  'id': 'song-$index',
                  'name': 'Song $index',
                  'artists': 'Example Artist',
                  'disc_number': index == 0 ? 1 : discs,
                  'total_discs': discs,
                  'track_number': discs == 1 ? index + 1 : 1,
                },
            ],
          });
        });
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: ExtensionAlbumScreen(
                extensionId: 'example-metadata',
                albumId: 'disc-album-$mornye-$discs',
                albumName: 'Example Album',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final tiles = tester.widgetList<TrackListTile>(
          find.byType(TrackListTile),
        );
        expect(tiles.map((tile) => tile.track.discNumber), [1, discs]);
        expect(tiles.map((tile) => tile.track.totalDiscs), [discs, discs]);
        expect(
          tiles.map((tile) => tile.track.trackNumber),
          discs == 1 ? [1, 2] : [1, 1],
        );
        if (discs == 1) {
          expect(find.byType(DiscSeparatorChip), findsNothing);
        } else {
          final headers = tester.widgetList<DiscSeparatorChip>(
            find.byType(DiscSeparatorChip),
          );
          expect(headers.map((header) => header.discNumber), [1, 2]);
          expect(
            tester.getTopLeft(find.text('Disc 2')).dy,
            inExclusiveRange(
              tester.getBottomLeft(find.text('Song 0')).dy,
              tester.getTopLeft(find.text('Song 1')).dy,
            ),
          );
          await tester.longPress(find.text('Song 1'));
          await tester.pumpAndSettle();
          expect(
            tester
                .widgetList<TrackListTile>(find.byType(TrackListTile))
                .map((tile) => tile.isSelected),
            [false, true],
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    }
  }

  for (final scenario
      in <
        ({
          String name,
          List<(String?, bool?)> qualities,
          Set<int> badgedRows,
          String? headerQuality,
          bool headerAtmos,
          bool catalogAtmos,
        })
      >[
        (
          name: 'uniform',
          qualities: [('16-bit', true), ('16-bit', true), ('16-bit', true)],
          badgedRows: {},
          headerQuality: '16-bit',
          headerAtmos: true,
          catalogAtmos: false,
        ),
        (
          name: 'bit depth exception first',
          qualities: [('24-bit', true), ('16-bit', true), ('16 bit', true)],
          badgedRows: {0},
          headerQuality: '16-bit',
          headerAtmos: true,
          catalogAtmos: false,
        ),
        (
          name: 'Atmos exception',
          qualities: [('16-bit', false), ('16-bit', true), ('16-bit', false)],
          badgedRows: {1},
          headerQuality: '16-bit',
          headerAtmos: false,
          catalogAtmos: false,
        ),
        (
          name: 'mixed without a majority',
          qualities: [('16-bit', false), ('24-bit', true)],
          badgedRows: {0, 1},
          headerQuality: null,
          headerAtmos: false,
          catalogAtmos: false,
        ),
        (
          name: 'mostly unknown',
          qualities: [('16-bit', false), (null, false), (null, false)],
          badgedRows: {0},
          headerQuality: null,
          headerAtmos: false,
          catalogAtmos: false,
        ),
        (
          name: 'album Atmos with unknown track modes',
          qualities: [('16-bit', null), ('16-bit', null), ('16-bit', null)],
          badgedRows: {},
          headerQuality: '16-bit',
          headerAtmos: true,
          catalogAtmos: true,
        ),
      ]) {
    testWidgets('Material album quality badges: ${scenario.name}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(430, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AlbumScreen(
              albumId: 'quality-${scenario.name}',
              albumName: 'Example Album',
              extensionId: 'example-metadata',
              audioTraits: [
                'lossless',
                if (scenario.catalogAtmos) 'dolby_atmos',
              ],
              tracks: [
                for (var i = 0; i < scenario.qualities.length; i++)
                  Track(
                    id: 'song-$i',
                    name: 'Song $i',
                    artistName: 'Example Artist',
                    albumName: 'Example Album',
                    duration: 180000,
                    trackNumber: i + 1,
                    audioQuality: scenario.qualities[i].$1,
                    audioModes: switch (scenario.qualities[i].$2) {
                      true => 'DOLBY_ATMOS',
                      false => 'STEREO',
                      null => null,
                    },
                    explicit: i == 0,
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rows = find.byType(TrackListTile);
      expect(rows, findsNWidgets(scenario.qualities.length));
      for (var i = 0; i < scenario.qualities.length; i++) {
        final badges = find.descendant(
          of: rows.at(i),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is AudioQualityBadge || widget is DolbyAtmosBadge,
          ),
        );
        expect(
          badges,
          scenario.badgedRows.contains(i) ? findsWidgets : findsNothing,
          reason: 'Song $i in ${scenario.name}',
        );
      }
      final header = find.byType(HeaderMetaRow);
      if (scenario.headerQuality != null) {
        expect(
          find.descendant(
            of: header,
            matching: find.text(scenario.headerQuality!),
          ),
          findsOneWidget,
        );
      } else {
        expect(
          find.descendant(of: header, matching: find.text('16-bit')),
          findsNothing,
        );
      }
      expect(
        find.descendant(of: header, matching: find.byType(DolbyAtmosLogo)),
        scenario.headerAtmos ? findsOneWidget : findsNothing,
      );
      expect(find.byType(ExplicitBadge), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('album tracks retain the extended tags supplied in search', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(430, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const channel = MethodChannel('com.zarz.mornye/backend');
    const payload = <String, dynamic>{
      'id': 'song-1',
      'spotify_id': 'song-1',
      'name': 'Example Song',
      'artists': 'Example Artist',
      'album_name': 'Example Album',
      'duration_ms': 180000,
      'track_number': 1,
      'genre': 'Example Genre',
      'label': 'Example Label',
      'copyright': 'Example Copyright',
      'comment': 'Example Comment',
      'upc': '0123456789012',
      'audio_quality': '16-bit',
      'audio_modes': 'DOLBY_ATMOS',
      'explicit': true,
    };
    var albumRequests = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getProviderMetadata') {
            expect(call.arguments, {
              'provider_id': 'example-metadata',
              'resource_type': 'album',
              'resource_id': 'metadata-album',
            });
            albumRequests++;
            return jsonEncode({
              'track_list': [payload],
              'album_info': {
                'name': 'Example Album',
                'total_tracks': 1,
                'album_type': 'album',
                'audio_traits': ['lossless', 'dolby_atmos'],
                'editorial_notes': {'standard': '<p>A new direction.</p>'},
              },
            });
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final searchTrack = Track.fromBackendMap(payload);
    expect(searchTrack.genre, 'Example Genre');
    expect(searchTrack.label, 'Example Label');
    expect(searchTrack.copyright, 'Example Copyright');

    final page = ProviderScope(
      child: MaterialApp(
        theme: MornyeTheme.build(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const AlbumScreen(
          albumId: 'metadata-album',
          albumName: 'Example Album',
          extensionId: 'example-metadata',
        ),
      ),
    );
    await tester.pumpWidget(page);
    await tester.pumpAndSettle();
    expect(albumRequests, 1);
    expect(find.byType(AlbumDescription), findsOneWidget);
    final albumTrack = tester
        .widget<TrackListTile>(find.byType(TrackListTile).first)
        .track;
    expect(albumTrack.id, searchTrack.id);
    expect(albumTrack.name, searchTrack.name);
    expect(albumTrack.genre, searchTrack.genre);
    expect(albumTrack.label, searchTrack.label);
    expect(albumTrack.copyright, searchTrack.copyright);
    expect(albumTrack.comment, searchTrack.comment);
    expect(albumTrack.upc, searchTrack.upc);
    expect(albumTrack.albumId, 'metadata-album');
    expect(albumTrack.albumType, 'album');
    expect(albumTrack.totalTracks, 1);
    expect(albumTrack.audioQuality, '16-bit');
    expect(find.text('Lossless'), findsOneWidget);
    expect(find.text('Dolby Atmos'), findsNothing);
    expect(findByTooltip('Dolby Atmos'), findsOneWidget);
    expect(find.byType(AudioQualityBadge), findsNothing);
    expect(find.byType(DolbyAtmosBadge), findsNothing);
    expect(find.byType(ExplicitBadge), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(page);
    await tester.pumpAndSettle();
    expect(albumRequests, 1);
    expect(
      tester
          .widget<AlbumDescription>(find.byType(AlbumDescription))
          .description,
      '<p>A new direction.</p>',
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
