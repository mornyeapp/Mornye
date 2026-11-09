import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/screens/listening_statistics_screen.dart';
import 'package:mornye/screens/library_tracks_folder_screen.dart';
import 'package:mornye/controllers/library_tracks_folder_data.dart';

void main() {
  test('Localization contains today and playlist edit strings in Italian and English', () async {
    final it = await AppLocalizations.delegate.load(const Locale('it'));
    expect(it.listeningStatsToday, 'Oggi');
    expect(it.editPlaylistAction, 'Modifica playlist');
    expect(it.autoMixMixing, 'DJ Mix');
    expect(it.autoMixCrossfading, 'Transizione DJ');

    final en = await AppLocalizations.delegate.load(const Locale('en'));
    expect(en.listeningStatsToday, 'Today');
    expect(en.editPlaylistAction, 'Edit playlist');
    expect(en.autoMixMixing, 'DJ Mix');
    expect(en.autoMixCrossfading, 'DJ Transition');
  });

  testWidgets('ListeningStatisticsScreen renders today choice chip', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('it'),
          home: ListeningStatisticsScreen(),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Oggi'), findsOneWidget);
    expect(find.text('7 giorni'), findsOneWidget);
    expect(find.text('30 giorni'), findsOneWidget);
  });

  testWidgets('LibraryTracksFolderScreen has unified edit button and no separate camera button', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('it'),
          home: LibraryTracksFolderScreen(
            mode: LibraryTracksFolderMode.playlist,
            playlistId: 'test-playlist',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('collection-edit-playlist')), findsOneWidget);
    expect(find.byIcon(Icons.camera_alt_outlined), findsNothing);
  });
}
