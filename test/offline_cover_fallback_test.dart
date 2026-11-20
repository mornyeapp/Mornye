import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/mornye_library_screen.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/player_artwork.dart';

import 'support/fixed_settings.dart';

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

// A web cover that is not cached fails to load, as it does offline: the
// test binding answers every HTTP request with an error status.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const url = 'https://example.com/covers/album.jpg';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aRZkAAAAASUVORK5CYII=',
  );
  late Directory directory;
  late File audio;
  late int extractions;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('offline_cover_');
    audio = await File('${directory.path}/song.flac').writeAsBytes([0, 1]);
    DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(
      Directory('${directory.path}/previews'),
    );
    DownloadedEmbeddedCoverResolver.setValidationClockForTesting(
      () => DateTime(2026),
    );
    extractions = 0;
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method == 'extractCoverToFile') {
        extractions++;
        final args = call.arguments as Map<Object?, Object?>;
        await File(args['output_path'] as String).writeAsBytes(png);
        return jsonEncode({'success': true});
      }
      return null;
    });
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
  });

  tearDown(() async {
    await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting(
      preservePersistentFiles: false,
    );
    DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(null);
    messenger.setMockMethodCallHandler(backend, null);
    messenger.setMockMethodCallHandler(paths, null);
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await directory.delete(recursive: true);
  });

  bool showsPreview(WidgetTester tester) =>
      tester.widgetList<Image>(find.byType(Image)).any((image) {
        var provider = image.image;
        if (provider is ResizeImage) provider = provider.imageProvider;
        return provider is FileImage &&
            provider.file.path.startsWith('${directory.path}/previews/');
      });

  // The player has read the song's art already, as when it played. File
  // work started under the fake clock never ends, so it is read here.
  Future<void> readSongArt(WidgetTester tester) async {
    final preview = await tester.runAsync(() async {
      final preview = await DownloadedEmbeddedCoverResolver.resolveOrExtract(
        audio.path,
      );
      await DownloadedEmbeddedCoverResolver.resolveOrExtract(audio.path);
      await DownloadedEmbeddedCoverResolver.waitForPreviewValidationForTesting();
      return preview;
    });
    expect(preview, isNotNull);
  }

  // Network work completes outside the fake clock.
  Future<void> pumpUntilPreview(WidgetTester tester) async {
    for (var i = 0; i < 300 && !showsPreview(tester); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(showsPreview(tester), isTrue);
  }

  Widget placeholder(BuildContext context) =>
      const ColoredBox(key: ValueKey('placeholder'), color: Colors.grey);

  testWidgets('a web cover that cannot load shows the song file art', (
    tester,
  ) async {
    await readSongArt(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: LocalOrNetworkCoverImage(
              url: url,
              width: 56,
              height: 56,
              networkCacheWidth: 112,
              placeholder: placeholder,
              songFile: audio.path,
            ),
          ),
        ),
      );
    });
    await pumpUntilPreview(tester);
    expect(extractions, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a missing local cover shows the song file art', (tester) async {
    await readSongArt(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: LocalOrNetworkCoverImage(
              url: '${directory.path}/gone.jpg',
              width: 56,
              height: 56,
              localCacheWidth: 112,
              placeholder: placeholder,
              songFile: audio.path,
            ),
          ),
        ),
      );
    });
    await pumpUntilPreview(tester);
    expect(extractions, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a cover looks its song file up only once it fails', (
    tester,
  ) async {
    var lookups = 0;
    await readSongArt(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: LocalOrNetworkCoverImage(
              url: '${directory.path}/gone.jpg',
              width: 56,
              height: 56,
              placeholder: placeholder,
              findSongFile: () async {
                lookups++;
                return audio.path;
              },
            ),
          ),
        ),
      );
    });
    await pumpUntilPreview(tester);
    expect(lookups, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a song file on network storage keeps the placeholder', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: LocalOrNetworkCoverImage(
              url: '${directory.path}/gone.jpg',
              width: 56,
              height: 56,
              placeholder: placeholder,
              songFile: 'network://nas/Album/song.flac',
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('placeholder')), findsOneWidget);
    expect(extractions, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('artist and genre rows show the song file art', (tester) async {
    await readSongArt(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox.square(
              dimension: 52,
              child: PlayerArtwork(
                artUri: url,
                colorScheme: const ColorScheme.light(),
                cacheWidth: 52,
                songFile: audio.path,
              ),
            ),
          ),
        ),
      );
    });
    await pumpUntilPreview(tester);
    expect(extractions, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Mornye album grid shows a download art offline', (tester) async {
    await readSongArt(tester);
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
                  source: 'downloaded',
                  key: 'album',
                  name: 'Album',
                  artist: 'Artist',
                  cover: url,
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
    await pumpUntilPreview(tester);
    expect(extractions, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
