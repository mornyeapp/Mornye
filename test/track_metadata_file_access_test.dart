import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/services/source_deletion_events.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/theme/mornye_theme.dart';
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
  }
}
