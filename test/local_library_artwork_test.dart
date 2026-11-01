import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/local_album_screen.dart';
import 'package:mornye/screens/mornye_library_screen.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/local_library_artwork_builder.dart';
import 'package:mornye/widgets/mornye_artist_header.dart';

import 'support/fixed_settings.dart';

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aRZkAAAAASUVORK5CYII=',
  );
  late Directory directory;
  late File audio;
  late File scannedCover;
  late int extractions;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('local_album_artwork_');
    audio = await File('${directory.path}/song.flac').writeAsBytes([0, 1]);
    scannedCover = File('${directory.path}/missing.jpg');
    DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(
      Directory('${directory.path}/previews'),
    );
    DownloadedEmbeddedCoverResolver.setValidationClockForTesting(
      () => DateTime(2026),
    );
    extractions = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'extractCoverToFile') {
        extractions++;
        final args = call.arguments as Map<Object?, Object?>;
        await File(args['output_path'] as String).writeAsBytes(png);
        return jsonEncode({'success': true});
      }
      return null;
    });
  });

  tearDown(() async {
    await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting(
      preservePersistentFiles: false,
    );
    DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(null);
    messenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  Widget app(Widget home, {bool mornye = false}) => ProviderScope(
    overrides: [
      settingsProvider.overrideWith(
        () => FixedSettingsNotifier(
          const AppSettings(localLibraryEnabled: false),
        ),
      ),
    ],
    child: MaterialApp(
      theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );

  // File I/O completes outside Flutter's fake clock. Yield event-loop turns
  // until the observable result arrives, without sleeping for a fixed delay.
  Future<void> pumpUntil(WidgetTester tester, bool Function() ready) async {
    for (var turn = 0; turn < 200 && !ready(); turn++) {
      await tester.runAsync(() => scannedCover.stat());
      await tester.pump();
    }
    expect(ready(), isTrue);
  }

  Future<String?> playerPreview(
    WidgetTester tester,
  ) => tester.runAsync<String?>(() async {
    final preview = await DownloadedEmbeddedCoverResolver.resolveOrExtract(
      audio.path,
    );
    await DownloadedEmbeddedCoverResolver.resolveOrExtract(audio.path);
    await DownloadedEmbeddedCoverResolver.waitForPreviewValidationForTesting();
    return preview;
  });

  for (final missing in [true, false]) {
    testWidgets('builder recovers ${missing ? 'missing' : 'empty'} thumbnail', (
      tester,
    ) async {
      final recovered = Completer<String>();
      final preview = await playerPreview(tester);
      expect(preview, isNotNull);
      await tester.runAsync(() async {
        if (!missing) await scannedCover.writeAsBytes([]);
        await tester.pumpWidget(
          app(
            LocalLibraryArtworkBuilder(
              coverPath: scannedCover.path,
              filePath: audio.path,
              builder: (_, path) {
                if (path != null &&
                    path != scannedCover.path &&
                    !recovered.isCompleted) {
                  recovered.complete(path);
                }
                return Text(path ?? 'placeholder');
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
      });
      await tester.pumpAndSettle();
      await pumpUntil(tester, () => recovered.isCompleted);
      expect(
        await tester.runAsync(
          () async => File(await recovered.future).readAsBytes(),
        ),
        png,
      );
      await tester.pumpAndSettle();
      expect(extractions, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('valid scanned file URI avoids extraction', (tester) async {
    await tester.runAsync(() async {
      await scannedCover.writeAsBytes(png);
      await tester.pumpWidget(
        app(
          LocalLibraryArtworkBuilder(
            coverPath: scannedCover.uri.toString(),
            filePath: audio.path,
            builder: (_, path) => Text(path ?? 'placeholder'),
          ),
        ),
      );
      await tester.pumpAndSettle();
    });
    expect(find.text(scannedCover.path), findsOneWidget);
    expect(extractions, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a valid scanned cover builds once', (tester) async {
    var builds = 0;
    await tester.runAsync(() => scannedCover.writeAsBytes(png));
    await tester.pumpWidget(
      app(
        LocalLibraryArtworkBuilder(
          coverPath: scannedCover.path,
          filePath: audio.path,
          builder: (_, path) {
            builds++;
            return Text(path ?? 'placeholder');
          },
        ),
      ),
    );
    for (var turn = 0; turn < 20; turn++) {
      await tester.runAsync(() => scannedCover.stat());
      await tester.pump();
    }
    expect(find.text(scannedCover.path), findsOneWidget);
    expect(builds, 1);
    expect(extractions, 0);
  });

  testWidgets(
    'late scan validation cannot replace another album or update after dispose',
    (tester) async {
      final nextCover = await tester.runAsync(
        () => File('${directory.path}/next.jpg').writeAsBytes(png),
      );
      Widget artwork(String path) => app(
        LocalLibraryArtworkBuilder(
          coverPath: path,
          filePath: null,
          builder: (_, cover) => Text(cover ?? 'placeholder'),
        ),
      );
      await tester.pumpWidget(artwork(scannedCover.path));
      await tester.pumpWidget(artwork(nextCover!.path));
      await tester.runAsync(() => scannedCover.stat());
      await tester.pump();
      expect(find.text(nextCover.path), findsOneWidget);
      await tester.pumpWidget(artwork(scannedCover.path));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => scannedCover.stat());
      await tester.pump();
      expect(extractions, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mornye in [false, true]) {
    testWidgets('blank album cover keeps the scanned track cover ($mornye)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(430, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await scannedCover.writeAsBytes(png);
        await tester.pumpWidget(
          app(
            LocalAlbumScreen(
              albumName: 'Album',
              artistName: 'Artist',
              coverPath: '   ',
              tracks: [
                LocalLibraryItem(
                  id: 'song',
                  trackName: 'Song',
                  artistName: 'Artist',
                  albumName: 'Album',
                  filePath: audio.path,
                  coverPath: scannedCover.path,
                  scannedAt: DateTime(2026),
                ),
              ],
            ),
            mornye: mornye,
          ),
        );
        await tester.pumpAndSettle();
      });
      await tester.pumpAndSettle();
      expect(
        mornye
            ? tester
                  .widget<MornyeArtistSurface>(find.byType(MornyeArtistSurface))
                  .imageSource
            : tester
                  .widget<AlbumDetailHeader>(find.byType(AlbumDetailHeader))
                  .paletteSource,
        scannedCover.path,
      );
      expect(extractions, 0);
      expect(tester.takeException(), isNull);
    });

    for (final stale in [false, true]) {
      testWidgets('album header recovers artwork ($mornye, stale: $stale)', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(430, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        // The player has already recovered artwork, as in the tester report.
        final preview = await playerPreview(tester);
        await tester.runAsync(() async {
          await tester.pumpWidget(
            app(
              LocalAlbumScreen(
                albumName: 'Album',
                artistName: 'Artist',
                coverPath: stale ? scannedCover.path : null,
                tracks: [
                  LocalLibraryItem(
                    id: 'song',
                    trackName: 'Song',
                    artistName: 'Artist',
                    albumName: 'Album',
                    filePath: audio.path,
                    coverPath: stale ? scannedCover.path : null,
                    scannedAt: DateTime(2026),
                  ),
                ],
              ),
              mornye: mornye,
            ),
          );
          await tester.pumpAndSettle();
        });
        await tester.pumpAndSettle();
        await pumpUntil(
          tester,
          () => mornye
              ? tester
                        .widget<MornyeArtistSurface>(
                          find.byType(MornyeArtistSurface),
                        )
                        .imageSource ==
                    preview
              : tester
                        .widget<AlbumDetailHeader>(
                          find.byType(AlbumDetailHeader),
                        )
                        .paletteSource ==
                    preview,
        );
        expect(extractions, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Mornye album grid replaces a stale scan path', (tester) async {
    final preview = await playerPreview(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(
              () => FixedSettingsNotifier(
                const AppSettings(localLibraryEnabled: false),
              ),
            ),
            downloadHistoryProvider.overrideWith(_History.new),
            libraryBrowsePageLoaderProvider.overrideWithValue(
              (request) async => LibraryBrowsePage([
                LibraryBrowseEntry(
                  source: 'local',
                  key: 'album',
                  name: 'Album',
                  artist: 'Artist',
                  cover: scannedCover.path,
                  samplePath: audio.path,
                  trackCount: 1,
                ),
              ]),
            ),
          ],
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.light),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: MornyeLibraryScreen(
                page: MornyeLibraryPage.albums,
                onOpenSection: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    });
    await tester.pumpAndSettle();
    await pumpUntil(
      tester,
      () => tester
          .widgetList<LocalOrNetworkCoverImage>(
            find.byType(LocalOrNetworkCoverImage),
          )
          .any((image) => image.url == preview),
    );
    expect(extractions, 1);
    expect(tester.takeException(), isNull);
  });
}
