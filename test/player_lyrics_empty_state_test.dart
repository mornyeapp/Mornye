import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/player_lyrics.dart';
import 'package:mornye/widgets/player_lyrics_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoLyrics extends PlayerMetadataController {
  int searches = 0;

  @override
  bool get canSearchOnline => true;

  @override
  Future<void> searchOnline() async => searches++;
}

Future<_NoLyrics> _pump(
  WidgetTester tester, {
  required double height,
  required double covered,
}) async {
  final metadata = _NoLyrics();
  final preview = PlaybackSeekPreview();
  addTearDown(metadata.dispose);
  addTearDown(preview.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: height,
              child: LyricsCoveredBottom(
                height: covered,
                child: PlayerLyricsSection(
                  metadata: metadata,
                  seekPreview: preview,
                  colorScheme: const ColorScheme.dark(),
                  isActive: true,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return metadata;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final search = find.widgetWithText(ExpressiveButton, 'Search online');

  for (final desktop in [false, true]) {
    for (final mornye in [false, true]) {
      testWidgets(
        'Search online saves found lyrics and reports write failure (desktop=$desktop, Mornye=$mornye)',
        (tester) async {
          debugDesktopPlatformOverride = desktop;
          addTearDown(() => debugDesktopPlatformOverride = null);
          final saving = Completer<void>();
          final writes = <(String, String)>[];
          final metadata = PlayerMetadataController(
            readMetadata: (_) async => const {},
            parseLyrics: (raw) async => LyricsParser.parse(raw),
            fetchOnlineLyrics: (_) async => 'Found lyrics',
            saveOnlineLyrics: (source, raw) async {
              writes.add((source, raw));
              await saving.future;
              throw StateError('Read-only file');
            },
          );
          final preview = PlaybackSeekPreview();
          addTearDown(metadata.dispose);
          addTearDown(preview.dispose);
          await metadata.load(
            MediaItem(
              id: 'song',
              title: 'Song',
              artist: 'Artist',
              extras: const {'source': '/music/song.flac'},
            ),
          );
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                theme: mornye
                    ? MornyeTheme.build(Brightness.dark)
                    : AppTheme.light(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: PlayerLyricsSection(
                    metadata: metadata,
                    seekPreview: preview,
                    colorScheme: const ColorScheme.dark(),
                    isActive: true,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(search);
          await tester.pumpAndSettle();
          expect(writes, [('/music/song.flac', 'Found lyrics')]);
          expect(find.text('Found lyrics'), findsOneWidget);
          expect(search, findsNothing);
          saving.complete();
          await tester.pumpAndSettle();
          expect(find.text('Found lyrics'), findsOneWidget);
          expect(find.byType(SnackBar), findsOneWidget);
          expect(metadata.onlineLyricsSaveFailed, isTrue);
        },
      );
    }
  }

  testWidgets('no-lyrics state centers above the covered controls', (
    tester,
  ) async {
    await _pump(tester, height: 600, covered: 300);

    final button = tester.getRect(search);
    expect(button.bottom, lessThanOrEqualTo(300));
    // Centered in the visible 300 px, not the whole 600 px area.
    final message = tester.getCenter(find.text('No lyrics in this file'));
    expect(message.dy, closeTo(150, 40));
  });

  testWidgets('a short visible area scrolls to the search button', (
    tester,
  ) async {
    final metadata = await _pump(tester, height: 300, covered: 220);

    await tester.dragUntilVisible(
      search,
      find.byType(SingleChildScrollView),
      const Offset(0, -40),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(search).bottom, lessThanOrEqualTo(80));

    await tester.tap(search);
    expect(metadata.searches, 1);
  });
}
