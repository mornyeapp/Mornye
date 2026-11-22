import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/source_deletion_events.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _settleFileIo(WidgetTester tester) async {
  await tester.runAsync(() async {
    var idleFrames = 0;
    for (var i = 0; i < 200 && idleFrames < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 25));
      idleFrames = tester.binding.hasScheduledFrame ? 0 : idleFrames + 1;
    }
    expect(idleFrames, 3);
  });
  await tester.pumpAndSettle();
}

void main() {
  const channel = MethodChannel('com.zarz.mornye/backend');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory cache;
  setUpAll(() async {
    cache = await Directory.systemTemp.createTemp('metadata-file-access-');
  });
  tearDownAll(() async => cache.delete(recursive: true));

  for (final mornye in [false, true]) {
    testWidgets(
      'open details refresh after an edit and deletion (Mornye=$mornye)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(paths, (_) async => cache.path);
        addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
        var title = 'Old title';
        messenger.setMockMethodCallHandler(channel, (call) async {
          return switch (call.method) {
            'safStat' => {'exists': true, 'size': 100},
            'extractCoverToFile' => jsonEncode({'error': 'No cover'}),
            'readFileMetadata' || 'readAudioMetadata' => jsonEncode({
              'title': title,
              'artist': 'Artist',
              'album': 'Album',
            }),
            _ => null,
          };
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final item = DownloadHistoryItem(
          id: 'edited-track',
          trackName: title,
          artistName: 'Artist',
          albumName: 'Album',
          filePath: 'content://provider/music/edited.flac',
          service: 'provider-a',
          downloadedAt: DateTime(2026),
        );
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.dark)
                  : ThemeData.dark(useMaterial3: true),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: TrackMetadataScreen(item: item),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(title), findsWidgets);
        title = 'Edited title';
        await tester.runAsync(
          () => SourceMetadataEvents.instance.publish(item.filePath),
        );
        await _settleFileIo(tester);
        expect(find.text(title), findsWidgets);
        expect(find.text('Old title'), findsNothing);
        await SourceDeletionEvents.instance.publish(item.filePath);
        await tester.pumpAndSettle();
        expect(find.text('File not found'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    for (final unavailable in [false, true]) {
      testWidgets('file status distinguishes provider errors from absence '
          '(Mornye=$mornye, unavailable=$unavailable)', (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 780));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'safStat') {
            if (unavailable) {
              throw PlatformException(code: 'provider_unavailable');
            }
            return {'exists': false};
          }
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final item = DownloadHistoryItem(
          id: 'provider-track',
          trackName: 'Track',
          artistName: 'Artist',
          albumName: 'Album',
          filePath: 'content://provider/music/track.flac',
          service: 'provider-a',
          downloadedAt: DateTime(2026),
        );
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.dark)
                  : ThemeData.dark(useMaterial3: true),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: TrackMetadataScreen(item: item),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('File not found'),
          unavailable ? findsNothing : findsOneWidget,
        );
        expect(
          find.text(
            'File is currently unavailable. Check storage access and try again.',
          ),
          unavailable ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the header has its buttons before the file check answers, '
        'and drops the round ones for a missing file (Mornye=$mornye)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'safStat' ? {'exists': false} : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final item = DownloadHistoryItem(
        id: 'unchecked-track',
        trackName: 'Track',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: 'content://provider/music/unchecked.flac',
        service: 'provider-a',
        downloadedAt: DateTime(2026),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [playerUiEnabledProvider.overrideWithValue(true)],
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark)
                : ThemeData.dark(useMaterial3: true),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: TrackMetadataScreen(item: item),
          ),
        ),
      );
      // The app's buttons, not flutter_test's own tooltip type.
      Finder round(String tooltip) => find.byWidgetPredicate(
        (widget) => widget is HeaderCircleButton && widget.tooltip == tooltip,
      );
      VoidCallback? play() => tester
          .widget<HeaderFilledButton>(find.byType(HeaderFilledButton))
          .onPressed;
      // The first frame, before the check of the file has answered.
      expect(round('Edit Metadata'), findsOneWidget);
      expect(round('Add to queue'), findsOneWidget);
      expect(play(), isNotNull);

      await tester.pumpAndSettle();
      expect(round('Edit Metadata'), findsNothing);
      expect(round('Add to queue'), findsNothing);
      expect(play(), isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the row picture flies under the cover while the page opens '
        '(Mornye=$mornye)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'safStat' ? {'exists': false} : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      const row = Key('row');
      const rowCover = Key('row-cover');
      final item = DownloadHistoryItem(
        id: 'flying-track',
        trackName: 'Track',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: 'content://provider/music/flying.flac',
        service: 'provider-a',
        downloadedAt: DateTime(2026),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark)
                : ThemeData.dark(useMaterial3: true),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: GestureDetector(
                    key: row,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TrackMetadataScreen(
                          item: item,
                          coverHeroTag: 'row',
                        ),
                      ),
                    ),
                    child: const SizedBox.square(
                      dimension: 56,
                      child: Hero(
                        tag: 'row',
                        child: ColoredBox(
                          key: rowCover,
                          color: Color(0xFF336699),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      Finder inRow() =>
          find.descendant(of: find.byKey(row), matching: find.byKey(rowCover));
      expect(inRow(), findsOneWidget);

      await tester.tap(find.byKey(row));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      // The row gave its picture to the flight, which shows it until the
      // page's own cover is decoded.
      expect(inRow(), findsNothing);
      expect(find.byKey(rowCover), findsOneWidget);
      expect(tester.getSize(find.byKey(rowCover)).width, greaterThan(56));

      await tester.pumpAndSettle();
      expect(find.byKey(rowCover), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the row picture stays on a cover that is not decoded when '
        'the flight lands (Mornye=$mornye)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'safStat' ? {'exists': false} : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      const row = Key('row');
      const rowCover = Key('row-cover');
      // Never decoded here: a test reads no file outside runAsync.
      final item = LocalLibraryItem(
        id: 'landing-track',
        trackName: 'Track',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: 'content://provider/music/landing.flac',
        coverPath: '${cache.path}/landing-cover.png',
        scannedAt: DateTime(2026),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark)
                : ThemeData.dark(useMaterial3: true),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: GestureDetector(
                    key: row,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TrackMetadataScreen(
                          localItem: item,
                          coverHeroTag: 'row',
                        ),
                      ),
                    ),
                    child: const SizedBox.square(
                      dimension: 56,
                      child: Hero(
                        tag: 'row',
                        child: ColoredBox(
                          key: rowCover,
                          color: Color(0xFF336699),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      Finder inRow() =>
          find.descendant(of: find.byKey(row), matching: find.byKey(rowCover));
      Finder onPage() => find.descendant(
        of: find.byType(TrackMetadataScreen),
        matching: find.byKey(rowCover),
      );

      await tester.tap(find.byKey(row));
      await tester.pumpAndSettle();
      // Landed with no picture of its own yet, the cover keeps the row's
      // instead of going empty.
      expect(onPage(), findsOneWidget);
      expect(tester.getSize(onPage()).width, greaterThan(56));

      Navigator.of(tester.element(find.byType(TrackMetadataScreen))).pop();
      await tester.pumpAndSettle();
      expect(inRow(), findsOneWidget);
      expect(find.byKey(rowCover), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
