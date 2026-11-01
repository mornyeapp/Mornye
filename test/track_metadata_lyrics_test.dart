import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/screens/track_metadata_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  for (final fallbackExplicit in [false, true]) {
    for (final fileExplicit in <bool?>[true, false, null]) {
      testWidgets(
        'lyrics embed preserves tags with fallback explicit=$fallbackExplicit '
        'and file explicit=$fileExplicit',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          tester.view.physicalSize = const Size(1000, 2400);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          const path = 'content://library/document/song.opus';
          final workingPath = '${Directory.systemTemp.path}/lyrics-test.opus';
          const lyrics = '[00:01.00]Fresh online lyrics';
          List<String>? embedArguments;
          const ffmpeg = MethodChannel('flutter.arthenica.com/ffmpeg_kit');
          const events = MethodChannel(
            'flutter.arthenica.com/ffmpeg_kit_event',
          );
          const paths = MethodChannel('plugins.flutter.io/path_provider');
          messenger.setMockMethodCallHandler(paths, (_) async {
            return Directory.systemTemp.path;
          });
          messenger.setMockMethodCallHandler(events, (_) async => null);
          messenger.setMockMethodCallHandler(ffmpeg, (call) async {
            if (call.method == 'ffmpegSession') {
              embedArguments = List<String>.from(
                (call.arguments as Map)['arguments'] as List,
              );
              // Inspect the real embed command without writing an audio file.
              throw PlatformException(code: 'captured_embed');
            }
            return null;
          });
          messenger.setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'safStat':
                return jsonEncode({'exists': true, 'size': 100});
              case 'readAudioMetadata':
              case 'getSafFileModTimes':
                return '{}';
              case 'safCopyToTemp':
                return workingPath;
              case 'extractCoverToFile':
                return jsonEncode({'error': 'No cover'});
              case 'getLyricsLRCWithSource':
                final online = (call.arguments as Map)['file_path'] == '';
                return jsonEncode({
                  'lyrics': online ? lyrics : '',
                  'source': online ? 'Example Lyrics' : '',
                });
              case 'readFileMetadata':
                if ((call.arguments as Map)['file_path'] != workingPath) {
                  return '{}';
                }
                return jsonEncode({
                  'title': ' File title ',
                  'artist': ' First Artist; Second Artist ',
                  'album': ' ',
                  'album_artist': ' Album Artist ',
                  'date': ' 2026-01-02 ',
                  'isrc': ' EXAMPLE12345 ',
                  'genre': ' Genre ',
                  'label': ' Label ',
                  'copyright': ' Copyright ',
                  'composer': ' Composer ',
                  'comment': ' Comment ',
                  'lyrics': 'Old embedded lyrics',
                  'track_number': 2,
                  'total_tracks': 12,
                  'disc_number': 1,
                  'total_discs': 3,
                  'explicit': fileExplicit,
                });
              default:
                return null;
            }
          });
          addTearDown(() {
            for (final mocked in [channel, ffmpeg, events, paths]) {
              messenger.setMockMethodCallHandler(mocked, null);
            }
          });
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: TrackMetadataScreen(
                  item: DownloadHistoryItem(
                    id: 'lyrics-song',
                    trackName: 'Fallback title',
                    artistName: 'Fallback artist',
                    albumName: 'Fallback album',
                    filePath: path,
                    service: 'example-provider',
                    downloadedAt: DateTime(2026),
                    format: 'opus',
                    explicit: fallbackExplicit,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Fetch from Online'));
          await tester.tap(find.text('Fetch from Online'));
          await tester.pumpAndSettle();
          expect(find.text('Fresh online lyrics'), findsOneWidget);
          // The box spans the card, not just the longest line, so its
          // scrollbar sits at the card's edge.
          final lyricsBox = find.ancestor(
            of: find.text('Fresh online lyrics'),
            matching: find.byType(Scrollbar),
          );
          final titleRow = find
              .ancestor(
                of: find.text('Lyrics').last,
                matching: find.byType(Row),
              )
              .first;
          expect(
            tester.getSize(lyricsBox).width,
            moreOrLessEquals(tester.getSize(titleRow).width, epsilon: 1),
          );
          await tester.ensureVisible(find.text('Embed Lyrics'));
          // Start the file work outside the fake clock so its cleanup can finish.
          await tester.runAsync(() async {
            await tester.tap(find.text('Embed Lyrics'));
            for (var i = 0; i < 100 && embedArguments == null; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          });
          await tester.pumpAndSettle();
          expect(embedArguments, isNotNull);
          final tags = <String, String>{};
          for (var i = 0; i < embedArguments!.length - 1; i++) {
            if (embedArguments![i] != '-metadata') continue;
            final tag = embedArguments![i + 1];
            final separator = tag.indexOf('=');
            tags[tag.substring(0, separator)] = tag.substring(separator + 1);
          }
          expect(tags, {
            'TITLE': 'File title',
            'ARTIST': 'First Artist; Second Artist',
            'ALBUM': 'Fallback album',
            'ALBUMARTIST': 'Album Artist',
            'DATE': '2026-01-02',
            'YEAR': '2026',
            'ISRC': 'EXAMPLE12345',
            'GENRE': 'Genre',
            'ORGANIZATION': 'Label',
            'COPYRIGHT': 'Copyright',
            'COMPOSER': 'Composer',
            'COMMENT': 'Comment',
            'TRACKNUMBER': '2/12',
            'DISCNUMBER': '1/3',
            'LYRICS': lyrics,
            'UNSYNCEDLYRICS': lyrics,
            if (fallbackExplicit || fileExplicit == true) 'ITUNESADVISORY': '1',
          });
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final scenario in [
    'fallback',
    'local',
    'instrumental',
    'empty',
    'unavailable',
  ]) {
    testWidgets('metadata reads local lyrics: $scenario', (tester) async {
      SharedPreferences.setMockInitialValues({});
      const path = 'content://library/document/song.flac';
      const lyrics = '[00:01.00]A locally stored lyric line';
      var metadataReads = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'safStat':
            return jsonEncode({'exists': true, 'size': 100});
          case 'readAudioMetadata':
            return '{}';
          case 'getLyricsLRCWithSource':
            // Opening metadata must never trigger an online lyrics request.
            expect((call.arguments as Map)['file_path'], path);
            if (scenario == 'unavailable') {
              throw PlatformException(code: 'backend_unavailable');
            }
            return jsonEncode({
              'lyrics': scenario == 'instrumental'
                  ? '[instrumental:true]'
                  : scenario == 'local'
                  ? lyrics
                  : '',
              'source': scenario == 'local' ? 'Embedded' : '',
            });
          case 'readFileMetadata':
            expect((call.arguments as Map)['file_path'], path);
            metadataReads++;
            return jsonEncode({'lyrics': scenario == 'empty' ? '' : lyrics});
          case 'getSafFileModTimes':
            return '{}';
          default:
            return null;
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final item = DownloadHistoryItem(
        id: 'local-song',
        trackName: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: path,
        service: 'example-provider',
        downloadedAt: DateTime(2026),
        format: 'flac',
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: TrackMetadataScreen(item: item),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        metadataReads,
        ['local', 'instrumental'].contains(scenario) ? 0 : 1,
      );
      expect(
        find.text('A locally stored lyric line'),
        ['empty', 'instrumental'].contains(scenario)
            ? findsNothing
            : findsOneWidget,
      );
      expect(
        find.text('Instrumental track'),
        scenario == 'instrumental' ? findsOneWidget : findsNothing,
      );
      expect(
        find.text('No lyrics found in this file'),
        scenario == 'empty' ? findsOneWidget : findsNothing,
      );
      expect(find.text('Embed Lyrics'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
