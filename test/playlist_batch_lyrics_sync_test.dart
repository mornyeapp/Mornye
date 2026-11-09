import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/batch_lyrics_sync_service.dart';
import 'package:mornye/widgets/batch_lyrics_sync_dialog.dart';

void main() {
  testWidgets('BatchLyricsSyncDialog displays progress and completes', (
    tester,
  ) async {
    const track1 = Track(
      id: '1',
      name: 'Song 1',
      artistName: 'Artist 1',
      albumName: 'Album 1',
      duration: 180,
    );
    const track2 = Track(
      id: '2',
      name: 'Song 2',
      artistName: 'Artist 2',
      albumName: 'Album 2',
      duration: 200,
    );

    final items = const [
      BatchLyricsItem(track: track1, filePath: '/music/song1.mp3'),
      BatchLyricsItem(track: track2, filePath: '/music/song2.mp3'),
    ];

    final service = BatchLyricsSyncService(
      checkHasLyrics: (_) async => false,
      fetchLyrics: (track) async => '[00:01.00] lyrics',
      saveTags: (_, _) async {},
      saveSidecar: (_, _) async => true,
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('it'),
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                BatchLyricsSyncDialog.show(
                  context,
                  items: items,
                  service: service,
                );
              },
              child: const Text('Sync Lyrics'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Sync Lyrics'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(find.text('Sincronizzazione completata'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
  });
}
