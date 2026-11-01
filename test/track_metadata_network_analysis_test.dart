import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/audio_analysis_widget.dart';
import 'package:mornye/widgets/hires_check_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  final storage = NetworkStorageService.instance;
  setUpAll(() async {
    for (final protocol in NetworkProtocol.values) {
      final id = 'delete-${protocol.name}';
      await storage.save(
        NetworkConnection(
          id: id,
          name: 'Fixture NAS',
          protocol: protocol,
          address: protocol == NetworkProtocol.smb
              ? 'smb://example.test/MUSIC/'
              : 'https://example.test/music/',
        ),
      );
      await storage.resolve('network://$id/track.flac');
    }
  });
  tearDownAll(() async {
    for (final protocol in NetworkProtocol.values) {
      await storage.remove('delete-${protocol.name}');
    }
    await storage.dispose();
  });
  for (final mornye in [false, true]) {
    for (final protocol in NetworkProtocol.values) {
      testWidgets('network delete capability: $protocol (Mornye=$mornye)', (
        tester,
      ) async {
        final item = LocalLibraryItem(
          id: 'network://delete-${protocol.name}/track.flac',
          filePath: 'network://delete-${protocol.name}/track.flac',
          trackName: 'Network track',
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
              home: TrackMetadataScreen(localItem: item),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byTooltip('Show menu'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        if (protocol == NetworkProtocol.http ||
            protocol == NetworkProtocol.subsonic) {
          expect(find.text('Delete'), findsNothing);
          expect(find.text('Edit Metadata'), findsNothing);
        } else {
          expect(find.text('Delete'), findsWidgets);
          expect(find.text('Edit Metadata'), findsWidgets);
          await tester.ensureVisible(find.text('Delete').last);
          await tester.tap(find.text('Delete').last);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump(const Duration(milliseconds: 500));
          expect(
            find.textContaining(
              'permanently delete the file from your network storage',
            ),
            findsOneWidget,
          );
          await tester.tap(find.text('Cancel'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          expect(find.byType(TrackMetadataScreen), findsOneWidget);
          expect(
            find.textContaining(
              'permanently delete the file from your network storage',
            ),
            findsNothing,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
    for (final format in ['flac', 'wav', 'mp3']) {
      testWidgets(
        'network $format exposes supported analysers (Mornye=$mornye)',
        (tester) async {
          final item = LocalLibraryItem(
            id: 'network://fixture/track.$format',
            filePath: 'network://fixture/track.$format',
            trackName: 'Network track',
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
                home: TrackMetadataScreen(localItem: item),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.scrollUntilVisible(
            find.byType(AudioAnalysisCard),
            300,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.byType(AudioAnalysisCard), findsOneWidget);
          expect(
            tester
                .widget<AudioAnalysisCard>(find.byType(AudioAnalysisCard))
                .filePath,
            item.filePath,
          );
          expect(
            find.byType(HiResCheckCard),
            format == 'mp3' ? findsNothing : findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
