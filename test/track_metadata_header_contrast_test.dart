import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/cover_palette.dart' show HeaderPalette;
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/audio_quality_badges.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_metadata_row.dart';

void main() {
  for (final useFileUri in [false, true]) {
    testWidgets('Mornye metadata renders local artwork (URI=$useFileUri)', (
      tester,
    ) async {
      final cover = await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'metadata-cover-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.green, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(32, 32);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        return File('${directory.path}/cover with spaces #1.png')
          ..writeAsBytesSync(bytes!.buffer.asUint8List());
      });
      final item = LocalLibraryItem(
        id: 'local-cover-track',
        trackName: 'Track with artwork',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: '/missing/local-cover-track.flac',
        coverPath: useFileUri ? cover!.uri.toString() : cover!.path,
        scannedAt: DateTime(2026),
      );
      late ImageProvider<Object> artworkProvider;
      await tester.runAsync(() async {
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: MornyeTheme.build(Brightness.dark),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: TrackMetadataScreen(localItem: item),
            ),
          ),
        );
        final artwork = find.descendant(
          of: find.byType(Hero),
          matching: find.byType(Image),
        );
        // Warm the actual resized decode; FileImage alone has a different key.
        artworkProvider = tester.widget<Image>(artwork).image;
        await precacheImage(artworkProvider, tester.element(artwork));
      });
      await tester.pumpAndSettle();

      final artwork = find.descendant(
        of: find.byType(Hero),
        matching: find.byType(RawImage),
      );
      expect(artwork, findsOneWidget);
      expect(tester.widget<RawImage>(artwork).image, isNotNull);
      expect(find.byIcon(Icons.music_note), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await artworkProvider.evict();
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'Mornye metadata has single-level sections and stacked values ($brightness)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 780));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final item = DownloadHistoryItem(
          id: 'metadata-track',
          trackName: 'A long track title for a narrow screen',
          artistName: 'Artist',
          albumName: 'Album',
          filePath: '/missing/track.flac',
          service: 'provider-a',
          downloadedAt: DateTime(2026),
          isrc: 'USAAA2600001',
        );
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: MornyeTheme.build(brightness),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(1.6)),
                child: child!,
              ),
              home: TrackMetadataScreen(item: item),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byIcon(CupertinoIcons.back), findsOneWidget);
        expect(find.byIcon(CupertinoIcons.ellipsis), findsOneWidget);
        expect(find.byType(Card), findsNothing);
        // The sections are built as they scroll in, below the header.
        await tester.scrollUntilVisible(
          find.text('Track name'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        final row = find.widgetWithText(MornyeMetadataRow, 'Track name');
        expect(
          find.ancestor(of: row, matching: find.byType(MornyeGlass)),
          findsNothing,
        );
        expect(
          find.ancestor(
            of: row,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Material &&
                  widget.color == MornyeTheme.controlFill(tester.element(row)),
            ),
          ),
          findsOneWidget,
        );
        final value = find.descendant(
          of: row,
          matching: find.text(item.trackName),
        );
        expect(
          tester.getTopLeft(value).dy,
          greaterThan(tester.getBottomLeft(find.text('Track name')).dy),
        );
        expect(
          tester.widget<Text>(value).style?.color,
          MornyeTheme.build(brightness).colorScheme.onSurface,
        );
        await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
        await tester.pumpAndSettle();
        expect(find.byIcon(CupertinoIcons.square_stack), findsOneWidget);
        expect(find.byIcon(CupertinoIcons.gear_alt), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('metadata hero keeps technical text legible in light theme', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final item = DownloadHistoryItem(
      id: 'history-track',
      trackName: 'Track',
      artistName: 'Artist',
      albumName: 'Album',
      filePath: r'Z:\missing\track.flac',
      service: 'provider-a',
      downloadedAt: DateTime(2026),
      duration: 250,
      bitDepth: 16,
      sampleRate: 44100,
      format: 'flac',
      explicit: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: TrackMetadataScreen(item: item),
        ),
      ),
    );
    await tester.pump();

    final headerMeta = find.byType(HeaderMetaRow);
    expect(headerMeta, findsOneWidget);
    expect(
      find.descendant(of: headerMeta, matching: find.byType(ExplicitBadge)),
      findsOneWidget,
    );
    expect(find.text('Explicit'), findsNothing);
    // The header takes its colors from the artwork over the theme's surface,
    // so the details are dark on light here instead of white on a scrim.
    final scheme = HeaderPalette.of(tester.element(headerMeta));
    expect(
      scheme.surface.computeLuminance() - scheme.onSurface.computeLuminance(),
      greaterThan(0.5),
    );
    for (final label in const ['16-bit/44.1kHz', '4:10', 'Provider-a']) {
      final text = tester.widget<Text>(
        find.descendant(of: headerMeta, matching: find.text(label)),
      );
      expect(text.style?.color, scheme.onSurface);
    }

    final separators = tester.widgetList<Text>(
      find.descendant(of: headerMeta, matching: find.text('•')),
    );
    expect(separators, isNotEmpty);
    expect(
      separators.every((text) => text.style?.color == scheme.onSurfaceVariant),
      isTrue,
    );

    await tester.scrollUntilVisible(
      find.text('Duration'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final durationLabel = find.text('Duration');
    final metadataRow = find
        .ancestor(of: durationLabel, matching: find.byType(Row))
        .first;
    final row = tester.widget<Row>(metadataRow);

    expect(row.crossAxisAlignment, CrossAxisAlignment.baseline);
    expect(row.textBaseline, TextBaseline.alphabetic);
  });

  for (final mornye in [false, true]) {
    testWidgets('the cover keeps rounded corners while it flies between a '
        'list row and the header (mornye=$mornye)', (tester) async {
      final item = LocalLibraryItem(
        id: 'flight-track',
        filePath: '/missing/flight-track.flac',
        trackName: 'Track',
        artistName: 'Artist',
        albumName: 'Album',
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
                body: Align(
                  alignment: Alignment.bottomLeft,
                  child: GestureDetector(
                    key: const ValueKey('row'),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TrackMetadataScreen(localItem: item),
                      ),
                    ),
                    child: const Hero(
                      tag: 'cover_lib_flight-track',
                      child: SizedBox.square(
                        dimension: 48,
                        child: ColoredBox(color: Colors.green),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      // The row thumbnail's corner, and the header's, read from the page at
      // rest below.
      final thumbCorner = tester
          .element(find.byKey(const ValueKey('row')))
          .tokens
          .radiusThumb;
      late double headerCorner;
      Set<double> corners() => {
        for (final clip in tester.widgetList<ClipRRect>(find.byType(ClipRRect)))
          if (clip.borderRadius case final BorderRadius radius)
            radius.topLeft.x,
      };
      // Corners that changed between two moments of a flight: the cover's.
      Future<Set<double>> movingCorners() async {
        await tester.pump(const Duration(milliseconds: 60));
        final early = corners();
        await tester.pump(const Duration(milliseconds: 60));
        return corners().difference(early);
      }

      await tester.tap(find.byKey(const ValueKey('row')));
      await tester.pump();
      await tester.pump();
      final arriving = await movingCorners();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      headerCorner =
          (tester
                      .widget<ClipRRect>(
                        find
                            .ancestor(
                              of: find.byType(Hero),
                              matching: find.byType(ClipRRect),
                            )
                            .first,
                      )
                      .borderRadius
                  as BorderRadius)
              .topLeft
              .x;
      expect(headerCorner, greaterThan(thumbCorner));
      expect(arriving, hasLength(1));
      expect(arriving.single, inExclusiveRange(thumbCorner, headerCorner));

      Navigator.of(tester.element(find.byType(TrackMetadataScreen))).pop();
      await tester.pump();
      await tester.pump();
      final leaving = await movingCorners();
      expect(leaving, hasLength(1));
      expect(leaving.single, inExclusiveRange(thumbCorner, headerCorner));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  }
}
