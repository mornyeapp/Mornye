import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/batch_lyrics_sync_service.dart';
import 'package:mornye/widgets/batch_lyrics_sync_dialog.dart';

void main() {
  testWidgets('BatchLyricsSyncDialog displays progress and completes', (tester) async {
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

    final service = BatchLyricsSyncService(
      checkHasLyrics: (_) async => false,
      fetchLyrics: (track) async => '[00:01.00] lyrics',
      saveTags: (_, _) async {},
      saveSidecar: (_, _) async {},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (_) => BatchLyricsSyncDialog(
                    tracks: const [track1, track2],
                    service: service,
                  ),
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
    expect(find.text('Chiudi'), findsOneWidget);
  });
}
