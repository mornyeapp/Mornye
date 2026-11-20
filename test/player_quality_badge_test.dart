import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/player_playback_controls.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

void main() {
  Future<void> pumpControls(
    WidgetTester tester, {
    required Map<String, dynamic> file,
    required String mode,
    required bool mornye,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final metadata = PlayerMetadataController(
      readMetadata: (_) async => file,
      parseLyrics: (raw) async => LyricsParser.parse(raw ?? ''),
    );
    addTearDown(metadata.dispose);
    await metadata.load(
      const MediaItem(
        id: 'song',
        title: 'Song',
        extras: {'source': '/music/song'},
      ),
    );
    final preview = PlaybackSeekPreview();
    addTearDown(preview.dispose);
    final theme = mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(
            () => FixedSettingsNotifier(
              AppSettings(libraryQualityLabelMode: mode),
            ),
          ),
          playbackStateProvider.overrideWith((ref) => const Stream.empty()),
        ],
        child: MaterialApp(
          theme: theme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PlayerPlaybackControls(
              mediaId: 'song',
              duration: const Duration(minutes: 3),
              seekPreview: preview,
              colorScheme: theme.colorScheme,
              metadata: metadata,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  const opus = {'format': 'opus', 'sample_rate': 48000, 'bitrate': 375};

  for (final mornye in [false, true]) {
    testWidgets('the format line keeps its figures (Mornye: $mornye)', (
      tester,
    ) async {
      await pumpControls(
        tester,
        file: opus,
        mode: AppSettings.libraryQualityLabelBitDepthOnly,
        mornye: mornye,
      );
      expect(find.text('OPUS  ·  48 kHz  ·  375 kbps'), findsOneWidget);
    });

    testWidgets('the Simple label mode shortens it (Mornye: $mornye)', (
      tester,
    ) async {
      for (final (file, label) in const [
        (opus, 'OPUS'),
        ({'format': 'flac', 'bit_depth': 16, 'sample_rate': 44100}, 'Lossless'),
        ({'format': 'flac', 'bit_depth': 24, 'sample_rate': 96000}, 'Hi-Res'),
        ({'format': 'm4a', 'audio_codec': 'eac3', 'bitrate': 768}, 'Dolby'),
      ]) {
        await pumpControls(
          tester,
          file: file,
          mode: AppSettings.libraryQualityLabelSimple,
          mornye: mornye,
        );
        expect(find.text(label), findsOneWidget, reason: '$file');
        expect(find.textContaining('kHz'), findsNothing);
        expect(find.textContaining('kbps'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
    });
  }
}
