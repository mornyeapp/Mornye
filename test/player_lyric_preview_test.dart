import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/player_lyric_preview.dart';
import 'package:mornye/widgets/player_lyrics.dart';

import 'support/fixed_settings.dart';

const _lrc = '''
[00:00.00]
[00:05.00]First example line
[00:10.00]Second example line
''';

const _enabled = AppSettings(playerShowLyricSnippet: true);

final _item = MediaItem(
  id: 'example-song',
  title: 'Example Song',
  artist: 'Example Artist',
  duration: const Duration(minutes: 3),
  extras: const {'source': '/music/example.flac'},
);

Future<PlayerMetadataController> _metadata([ParsedLyrics? lyrics]) async {
  final parsed = lyrics ?? LyricsParser.parse(_lrc);
  final metadata = PlayerMetadataController(
    parseLyrics: (_) async => parsed,
    readMetadata: (_) async => {
      'title': 'Example Song',
      'artist': 'Example Artist',
      'lyrics': _lrc,
    },
  );
  await metadata.load(_item);
  return metadata;
}

PlaybackState _at(
  Duration position, {
  bool playing = true,
  AudioProcessingState processingState = AudioProcessingState.ready,
}) => PlaybackState(
  playing: playing,
  processingState: processingState,
  updatePosition: position,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<
    ({
      ProviderContainer container,
      StreamController<PlaybackState> playback,
      PlaybackSeekPreview seekPreview,
    })
  >
  pumpPreview(
    WidgetTester tester, {
    required PlayerMetadataController metadata,
    AppSettings settings = _enabled,
    bool mornye = true,
    VoidCallback? onTap,
  }) async {
    final playback = StreamController<PlaybackState>.broadcast();
    addTearDown(playback.close);
    final seekPreview = PlaybackSeekPreview();
    final container = ProviderContainer(
      overrides: [
        playbackStateProvider.overrideWith((ref) => playback.stream),
        settingsProvider.overrideWith(() => FixedSettingsNotifier(settings)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PlayerLyricPreview(
              metadata: metadata,
              seekPreview: seekPreview,
              colorScheme: const ColorScheme.dark(),
              onTap: onTap,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return (container: container, playback: playback, seekPreview: seekPreview);
  }

  testWidgets('stays hidden with the default settings', (tester) async {
    expect(const AppSettings().playerShowLyricSnippet, isFalse);
    final view = await pumpPreview(
      tester,
      metadata: await _metadata(),
      settings: const AppSettings(),
    );
    view.playback.add(_at(const Duration(seconds: 6)));
    await tester.pumpAndSettle();
    expect(find.text('First example line'), findsNothing);
    expect(find.text('•••'), findsNothing);
    expect(find.byIcon(CupertinoIcons.forward), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final mornye in [true, false]) {
    testWidgets('follows the sung line and opens lyrics (mornye: $mornye)', (
      tester,
    ) async {
      var opened = 0;
      final view = await pumpPreview(
        tester,
        metadata: await _metadata(),
        mornye: mornye,
        onTap: () => opened++,
      );
      final chevron = mornye ? CupertinoIcons.forward : Icons.chevron_right;

      view.playback.add(_at(const Duration(seconds: 1), playing: false));
      await tester.pumpAndSettle();
      expect(find.text('•••'), findsOneWidget);
      expect(find.byIcon(chevron), findsOneWidget);

      view.playback.add(_at(const Duration(seconds: 6), playing: false));
      await tester.pumpAndSettle();
      expect(find.text('First example line'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Lyrics'),
        findsOneWidget,
        reason: 'The line reads as one Lyrics button',
      );

      await tester.tap(find.text('First example line'));
      await tester.pump();
      expect(opened, 1);

      view.playback.add(_at(const Duration(seconds: 11), playing: false));
      await tester.pumpAndSettle();
      expect(find.text('Second example line'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('moves to the next line on time without a new state', (
    tester,
  ) async {
    final view = await pumpPreview(tester, metadata: await _metadata());
    view.playback.add(_at(const Duration(milliseconds: 4500)));
    await tester.pump();
    expect(find.text('•••'), findsOneWidget);

    // The extrapolated position reaches the line 80 ms before it starts.
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('First example line'), findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('First example line'), findsOneWidget);

    // Pausing stops the line timer.
    view.playback.add(_at(const Duration(milliseconds: 9500), playing: false));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('First example line'), findsOneWidget);
    expect(find.text('Second example line'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('applies the lyrics timing offset', (tester) async {
    final view = await pumpPreview(tester, metadata: await _metadata());
    view.playback.add(_at(const Duration(milliseconds: 5500), playing: false));
    await tester.pumpAndSettle();
    expect(find.text('First example line'), findsOneWidget);

    // One second later: at 5.5 s the first line, now at 6 s, has not begun.
    await view.container
        .read(themeProvider.notifier)
        .setLyricsOffsetMs(1000, persist: false);
    await tester.pumpAndSettle();
    expect(find.text('First example line'), findsNothing);
    expect(find.text('•••'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('follows the seek preview while dragging', (tester) async {
    final view = await pumpPreview(tester, metadata: await _metadata());
    view.playback.add(_at(const Duration(seconds: 1), playing: false));
    await tester.pumpAndSettle();
    expect(find.text('•••'), findsOneWidget);

    final drag = view.seekPreview.begin(const Duration(seconds: 11));
    await tester.pumpAndSettle();
    expect(find.text('Second example line'), findsOneWidget);

    // Releasing without a seek returns to the playback position.
    view.seekPreview.end(drag);
    await tester.pumpAndSettle();
    expect(find.text('•••'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sweeps word-timed lines', (tester) async {
    final lyrics = ParsedLyrics(
      synced: true,
      wordSynced: true,
      plainText: 'one word at a time',
      lines: [
        LyricLine(
          time: const Duration(seconds: 4),
          end: const Duration(seconds: 8),
          text: 'one word at a time',
          words: [
            for (final (index, word) in [
              'one ',
              'word ',
              'at ',
              'a ',
              'time',
            ].indexed)
              LyricWord(
                time: Duration(milliseconds: 4000 + index * 800),
                end: Duration(milliseconds: 4800 + index * 800),
                text: word,
              ),
          ],
        ),
      ],
    );
    final view = await pumpPreview(tester, metadata: await _metadata(lyrics));
    view.playback.add(_at(const Duration(seconds: 5)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(WordTimedLyricLine), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.forward), findsOneWidget);

    view.playback.add(_at(const Duration(seconds: 5), playing: false));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
