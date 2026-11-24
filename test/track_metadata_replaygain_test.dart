import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';

import 'support/app_icon_finder.dart';

class _History extends DownloadHistoryNotifier {
  _History(this._item);
  final DownloadHistoryItem _item;

  @override
  DownloadHistoryState build() => DownloadHistoryState(items: [_item]);

  @override
  Future<void> updateAudioMetadataForItem({
    required String id,
    String? quality,
    int? bitDepth,
    int? sampleRate,
    int? bitrate,
    String? format,
    int? trackNumber,
    int? totalTracks,
    int? discNumber,
    int? totalDiscs,
    int? duration,
    String? composer,
    bool? explicit,
    bool? hasLyrics,
    int? lyricsMetadataScanVersion,
    bool? hasReplayGain,
    int? replayGainMetadataScanVersion,
  }) async {
    state = state.copyWith(
      items: [
        state.items.single.copyWith(
          hasReplayGain: hasReplayGain,
          replayGainMetadataScanVersion: replayGainMetadataScanVersion,
        ),
      ],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  for (final hasTags in [true, false]) {
    testWidgets('metadata displays only saved ReplayGain (tags=$hasTags)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final metadata = hasTags
          ? {
              'bpm': '120',
              'mood': 'Calm',
              'replaygain_track_gain': ' -6.20 dB ',
              'replaygain_track_peak': '0.000000',
              'replaygain_album_gain': '0.00 dB',
              'replaygain_album_peak': '1.234567',
            }
          : {'replaygain_track_gain': ' ', 'replaygain_album_peak': null};
      var edits = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'editFileMetadata') {
          edits++;
          final args = call.arguments as Map;
          final fields = Map<String, String>.from(
            jsonDecode(args['metadata_json'] as String) as Map,
          );
          metadata.addAll(fields);
          return jsonEncode({'success': true, 'method': 'native'});
        }
        return switch (call.method) {
          'safStat' => jsonEncode({'exists': true, 'size': 100}),
          'readAudioMetadata' => jsonEncode(metadata),
          'readFileMetadata' => jsonEncode({
            ...metadata,
            'audio_codec': 'flac',
          }),
          'safCopyToTemp' => 'temporary-song.flac',
          'writeTempToSaf' => jsonEncode({'success': true}),
          'getLyricsLRCWithSource' => jsonEncode({'lyrics': '', 'source': ''}),
          'getSafFileModTimes' => '{}',
          _ => null,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final item = DownloadHistoryItem(
        id: 'track-$hasTags',
        trackName: 'Track',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: 'content://library/document/track-$hasTags.flac',
        service: 'provider-a',
        downloadedAt: DateTime(2026),
        quality: '16-bit/44.1kHz',
        bitDepth: 16,
        sampleRate: 44100,
        format: 'flac',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            downloadHistoryProvider.overrideWith(() => _History(item)),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: TrackMetadataScreen(item: item),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TrackMetadataScreen)),
      );
      expect(
        container.read(downloadHistoryProvider).items.single.hasReplayGain,
        hasTags,
      );
      for (final text in [
        'BPM',
        '120',
        'Mood',
        'Calm',
        'ReplayGain Track Gain',
        'ReplayGain Track Peak',
        'ReplayGain Album Gain',
        'ReplayGain Album Peak',
        '-6.20 dB',
        '0.000000',
        '0.00 dB',
        '1.234567',
      ]) {
        expect(find.text(text), hasTags ? findsOneWidget : findsNothing);
      }
      Future<void> openRemoval() async {
        await tester.tap(findAppIcon(Icons.more_vert));
        await tester.pumpAndSettle();
        expect(find.text('Edit audio file'), findsNothing);
        expect(find.text('Similar songs in Library'), findsNothing);
        expect(find.text('Remove ReplayGain'), findsOneWidget);
        await tester.ensureVisible(find.text('Remove ReplayGain'));
        await tester.tap(find.text('Remove ReplayGain'));
        await tester.pumpAndSettle();
        expect(find.byType(AppAlertDialog), findsOneWidget);
      }

      await openRemoval();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(edits, 0);
      if (hasTags) expect(find.text('-6.20 dB'), findsOneWidget);

      await openRemoval();
      await tester.tap(
        find.descendant(
          of: find.byType(AppDialogAction),
          matching: find.text('Remove ReplayGain'),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(edits, 1);
      expect(find.text('ReplayGain tags removed'), findsOneWidget);
      expect(find.text('ReplayGain Track Gain'), findsNothing);
      expect(find.text('ReplayGain Album Gain'), findsNothing);
      final updated = container.read(downloadHistoryProvider).items.single;
      expect(updated.hasReplayGain, isFalse);
      expect(updated.replayGainMetadataScanVersion, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
