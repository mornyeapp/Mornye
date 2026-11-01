import 'dart:async';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/services/lyrics_translation_alignment.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/player_lyrics.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _source = ParsedLyrics(
  synced: true,
  wordSynced: true,
  plainText: 'AAAA BBBB',
  lines: [
    LyricLine(
      time: Duration.zero,
      end: Duration(seconds: 20),
      text: 'AAAA BBBB',
      words: [
        LyricWord(
          time: Duration.zero,
          end: Duration(seconds: 10),
          text: 'AAAA ',
        ),
        LyricWord(
          time: Duration(seconds: 10),
          end: Duration(seconds: 20),
          text: 'BBBB',
        ),
      ],
      romanization: 'One Two',
      romanizationWords: [
        LyricWord(
          time: Duration.zero,
          end: Duration(seconds: 10),
          text: 'One ',
        ),
        LyricWord(
          time: Duration(seconds: 10),
          end: Duration(seconds: 20),
          text: 'Two',
        ),
      ],
    ),
  ],
);

const _aiSource = ParsedLyrics(
  synced: true,
  wordSynced: true,
  plainText: '君を',
  lines: [
    LyricLine(
      time: Duration.zero,
      end: Duration(seconds: 20),
      text: '君を',
      words: [
        LyricWord(time: Duration.zero, end: Duration(seconds: 10), text: '君'),
        LyricWord(
          time: Duration(seconds: 10),
          end: Duration(seconds: 20),
          text: 'を',
        ),
      ],
    ),
  ],
);

Finder _paint(String text) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.label == text,
  ),
  matching: find.byType(CustomPaint),
);

Future<List<int>> _pixels(
  WidgetTester tester,
  String text, {
  Finder? target,
}) async {
  final paint = target ?? _paint(text);
  final painter = tester.widget<CustomPaint>(paint).painter!;
  final size = tester.getSize(paint);
  return (await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.ceil(), size.height.ceil());
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final result = bytes.buffer.asUint8List().toList();
    image.dispose();
    picture.dispose();
    return result;
  }))!;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final desktop in [false, true]) {
    for (final mornye in [false, true]) {
      for (final aiRomaji in [false, true]) {
        testWidgets('translation and pronunciation share pause/seek clock '
            '(desktop=$desktop, mornye=$mornye, ai=$aiRomaji)', (tester) async {
          debugDesktopPlatformOverride = desktop;
          addTearDown(() => debugDesktopPlatformOverride = null);
          tester.view.physicalSize = Size(desktop ? 1200 : 390, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final playback = StreamController<PlaybackState>.broadcast();
          final preview = ValueNotifier<Duration?>(null);
          addTearDown(playback.close);
          addTearDown(preview.dispose);
          final source = aiRomaji ? _aiSource : _source;
          final lyrics = applyLyricsTranslation(
            source,
            LyricsTranslationSource.of(source),
            ['Halo dunia'],
            romanizations: aiRomaji ? ['kimi o'] : const [],
            romanizationAlignments: aiRomaji
                ? const [
                    [
                      LyricsTranslationChunk('kimi ', 0),
                      LyricsTranslationChunk('o', 1),
                    ],
                  ]
                : const [],
            alignments: const [
              [
                LyricsTranslationChunk('Halo ', 0),
                LyricsTranslationChunk('dunia', 1),
              ],
            ],
          );
          final theme = mornye
              ? MornyeTheme.build(Brightness.dark)
              : ThemeData.dark();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                playbackStateProvider.overrideWith((ref) => playback.stream),
              ],
              child: MaterialApp(
                theme: theme,
                home: Scaffold(
                  body: SyncedLyricsView(
                    lyrics: lyrics,
                    seekPreview: preview,
                    colorScheme: theme.colorScheme,
                    isActive: true,
                    showPronunciation: true,
                    showTranslation: true,
                  ),
                ),
              ),
            ),
          );
          playback.add(
            PlaybackState(
              processingState: AudioProcessingState.ready,
              updatePosition: const Duration(seconds: 2),
            ),
          );
          await tester.pumpAndSettle();
          expect(_paint('Halo dunia'), findsOneWidget);
          final early = await _pixels(tester, 'Halo dunia');
          final readingPaint = aiRomaji
              ? find
                    .descendant(
                      of: find.byWidgetPredicate(
                        (widget) =>
                            widget is Semantics &&
                            widget.properties.label?.startsWith('kimi') == true,
                      ),
                      matching: find.byType(CustomPaint),
                    )
                    .first
              : null;
          final earlyReading = readingPaint == null
              ? null
              : await _pixels(tester, '', target: readingPaint);
          await tester.pump(const Duration(seconds: 1));
          expect(
            await _pixels(tester, 'Halo dunia'),
            early,
            reason: 'paused translation holds its highlight',
          );
          if (readingPaint != null) {
            expect(
              await _pixels(tester, '', target: readingPaint),
              earlyReading,
            );
          }
          preview.value = const Duration(seconds: 12);
          await tester.pumpAndSettle();
          expect(await _pixels(tester, 'Halo dunia'), isNot(early));
          if (readingPaint != null) {
            expect(
              await _pixels(tester, '', target: readingPaint),
              isNot(earlyReading),
            );
          }
          expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics &&
                  widget.properties.label?.contains(
                        aiRomaji ? 'kimi' : 'One',
                      ) ==
                      true,
            ),
            findsAtLeastNWidgets(1),
            reason: 'translation does not replace pronunciation',
          );
          preview.value = const Duration(seconds: 2);
          await tester.pumpAndSettle();
          expect(await _pixels(tester, 'Halo dunia'), early);
          if (readingPaint != null) {
            expect(
              await _pixels(tester, '', target: readingPaint),
              earlyReading,
            );
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
