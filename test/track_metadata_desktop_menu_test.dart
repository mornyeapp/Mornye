import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/screens/track_metadata_edit_sheet.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';

import 'support/app_icon_finder.dart';

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(isInitialized: true);
}

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
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const ffmpegEvents = MethodChannel('flutter.arthenica.com/ffmpeg_kit_event');
  Completer<String>? pendingMetadata;
  var metadataReads = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    pendingMetadata = null;
    metadataReads = 0;
    messenger.setMockMethodCallHandler(ffmpegEvents, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'readFileMetadata') {
        metadataReads++;
        return pendingMetadata?.future ?? jsonEncode({'audio_codec': 'flac'});
      }
      return switch (call.method) {
        'safStat' => jsonEncode({'exists': true, 'size': 100}),
        'readAudioMetadata' => '{}',
        'getLyricsLRCWithSource' => jsonEncode({'lyrics': ''}),
        'extractCoverToFile' => jsonEncode({'error': 'No cover'}),
        'getSafFileModTimes' => '{}',
        _ => null,
      };
    });
  });

  tearDown(() {
    debugDesktopPlatformOverride = null;
    messenger.setMockMethodCallHandler(ffmpegEvents, null);
    messenger.setMockMethodCallHandler(channel, null);
  });

  for (final afterSave in [false, true]) {
    testWidgets('closing metadata during an editor read is safe ($afterSave)', (
      tester,
    ) async {
      // Exercise the shared page lifecycle with the fake native channel.
      debugDesktopPlatformOverride = false;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [extensionProvider.overrideWith(_Extensions.new)],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: TrackMetadataScreen(
              item: DownloadHistoryItem(
                id: 'local-song',
                trackName: 'Song',
                artistName: 'Artist',
                albumName: 'Album',
                filePath: 'content://library/document/song.flac',
                service: 'example-provider',
                downloadedAt: DateTime(2026),
                format: 'flac',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(findAppIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      final gate = Completer<String>();
      if (!afterSave) pendingMetadata = gate;
      final reads = metadataReads;
      await tester.ensureVisible(find.text('Edit Metadata'));
      await tester.tap(find.text('Edit Metadata'));
      if (afterSave) {
        await _settleFileIo(tester);
      } else {
        await tester.pumpAndSettle();
      }
      if (afterSave) {
        expect(find.byType(EditMetadataSheet), findsOneWidget);
        pendingMetadata = gate;
        Navigator.of(tester.element(find.byType(EditMetadataSheet))).pop(true);
        await tester.pumpAndSettle();
      }
      expect(metadataReads, greaterThan(reads));
      await tester.pumpWidget(const SizedBox.shrink());
      gate.complete(jsonEncode({'title': 'Saved song', 'audio_codec': 'flac'}));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(EditMetadataSheet), findsNothing);
    });
  }

  for (final desktop in [true, false]) {
    testWidgets(
      'Material song page More button opens a ${desktop ? 'menu' : 'sheet'}',
      (tester) async {
        debugDesktopPlatformOverride = desktop;
        tester.view.physicalSize = desktop
            ? const Size(1200, 800)
            : const Size(900, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [extensionProvider.overrideWith(_Extensions.new)],
            child: MaterialApp(
              theme: AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: TrackMetadataScreen(
                item: DownloadHistoryItem(
                  id: 'local-song',
                  trackName: 'Song',
                  artistName: 'Artist',
                  albumName: 'Album',
                  filePath: 'content://library/document/song.flac',
                  service: 'example-provider',
                  downloadedAt: DateTime(2026),
                  format: 'flac',
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(findAppIcon(Icons.more_vert));
        await tester.pumpAndSettle();
        // Items that do not depend on the file being readable, since the
        // desktop backend library is absent under flutter test.
        expect(find.text('Copy file path'), findsOneWidget);
        expect(find.text('Go to Artist'), findsOneWidget);
        if (desktop) {
          expect(find.byType(MenuItemButton), findsWidgets);
          expect(find.byType(BottomSheet), findsNothing);
          final button = tester.getRect(findAppIcon(Icons.more_vert));
          final menu = tester.getRect(find.byType(MenuItemButton).first);
          expect(menu.top, greaterThanOrEqualTo(button.bottom - 1));
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byType(MenuItemButton), findsNothing);
        } else {
          expect(find.byType(BottomSheet), findsOneWidget);
          expect(find.byType(MenuItemButton), findsNothing);
        }
      },
    );
  }
}
