import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/player_lyrics.dart';

const _text = 'AAAA BBBB CCCC';

Finder _timedPaint() => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.label == _text,
  ),
  matching: find.byType(CustomPaint),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => debugDesktopPlatformOverride = null);

  for (final desktop in [false, true]) {
    for (final mornye in [false, true]) {
      for (final timed in [false, true]) {
        final platform = desktop ? 'desktop' : 'mobile';
        final style = mornye ? 'Mornye' : 'Material';
        final format = timed ? 'TTML' : 'LRC';
        testWidgets('$platform $style $format preserves active line wrapping', (
          tester,
        ) async {
          debugDesktopPlatformOverride = desktop;
          tester.view.physicalSize = const Size(900, 1200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final preview = ValueNotifier<Duration?>(const Duration(seconds: 1));
          addTearDown(preview.dispose);
          final theme = mornye
              ? MornyeTheme.build(Brightness.dark)
              : AppTheme.dark();
          final lyrics = ParsedLyrics(
            synced: true,
            wordSynced: timed,
            plainText: '',
            lines: [
              const LyricLine(time: Duration.zero, text: 'Before'),
              LyricLine(
                time: const Duration(seconds: 10),
                end: const Duration(seconds: 20),
                text: _text,
                words: timed
                    ? const [
                        LyricWord(
                          time: Duration(seconds: 10),
                          end: Duration(seconds: 12),
                          text: 'AAAA ',
                        ),
                        LyricWord(
                          time: Duration(seconds: 12),
                          end: Duration(seconds: 14),
                          text: 'BBBB ',
                        ),
                        LyricWord(
                          time: Duration(seconds: 14),
                          end: Duration(seconds: 20),
                          text: 'CCCC',
                        ),
                      ]
                    : const [],
              ),
              const LyricLine(time: Duration(seconds: 20), text: 'After'),
            ],
          );
          for (final width in [desktop ? 328.0 : 250.0, 620.0]) {
            preview.value = const Duration(seconds: 1);
            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  playbackStateProvider.overrideWith(
                    (ref) => Stream.value(PlaybackState()),
                  ),
                ],
                child: MaterialApp(
                  theme: theme,
                  home: Scaffold(
                    body: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: width,
                        height: 800,
                        child: SyncedLyricsView(
                          lyrics: lyrics,
                          seekPreview: preview,
                          colorScheme: theme.colorScheme,
                          isActive: true,
                          showPronunciation: false,
                          showTranslation: false,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final text = find.text(_text);
            final paragraph = tester.renderObject<RenderParagraph>(text);
            final inactiveHeight = paragraph.size.height;
            final inactiveRows = paragraph
                .getBoxesForSelection(
                  const TextSelection(
                    baseOffset: 0,
                    extentOffset: _text.length,
                  ),
                )
                .map((box) => box.top)
                .toSet()
                .length;
            preview.value = const Duration(seconds: 11);
            await tester.pump();
            final primary = timed ? _timedPaint() : text;
            for (final elapsed in [32, 128]) {
              await tester.pump(Duration(milliseconds: elapsed));
              expect(
                tester.getSize(primary).height,
                closeTo(inactiveHeight, 0.01),
                reason: 'The growing text must keep the same wrapped rows',
              );
            }
            await tester.pumpAndSettle();
            expect(
              tester.getSize(primary).height,
              closeTo(inactiveHeight, 0.01),
              reason: 'Activating a line must not change its text layout',
            );
            if (!timed) {
              final activeParagraph = tester.renderObject<RenderParagraph>(
                text,
              );
              expect(
                activeParagraph
                    .getBoxesForSelection(
                      const TextSelection(
                        baseOffset: 0,
                        extentOffset: _text.length,
                      ),
                    )
                    .map((box) => box.top)
                    .toSet()
                    .length,
                inactiveRows,
              );
            }
            preview.value = const Duration(seconds: 1);
            await tester.pump();
            for (final elapsed in [32, 128]) {
              await tester.pump(Duration(milliseconds: elapsed));
              expect(
                tester.getSize(text).height,
                closeTo(inactiveHeight, 0.01),
                reason: 'The shrinking text must keep the same wrapped rows',
              );
            }
            await tester.pumpAndSettle();
            expect(tester.getSize(text).height, closeTo(inactiveHeight, 0.01));
            expect(tester.takeException(), isNull);
          }
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }

  testWidgets('Arabic word-synced lyrics preserve active line wrapping', (
    tester,
  ) async {
    const arabicLine = 'كان عندك كام سنة لما عرفت';
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preview = ValueNotifier<Duration?>(const Duration(seconds: 1));
    addTearDown(preview.dispose);
    final theme = MornyeTheme.build(Brightness.dark);
    const lyrics = ParsedLyrics(
      synced: true,
      wordSynced: true,
      plainText: arabicLine,
      lines: [
        LyricLine(time: Duration.zero, text: 'قبل'),
        LyricLine(
          time: Duration(seconds: 10),
          end: Duration(seconds: 20),
          text: arabicLine,
          words: [
            LyricWord(
              time: Duration(seconds: 10),
              end: Duration(seconds: 12),
              text: 'كان ',
            ),
            LyricWord(
              time: Duration(seconds: 12),
              end: Duration(seconds: 14),
              text: 'عندك ',
            ),
            LyricWord(
              time: Duration(seconds: 14),
              end: Duration(seconds: 16),
              text: 'كام ',
            ),
            LyricWord(
              time: Duration(seconds: 16),
              end: Duration(seconds: 18),
              text: 'سنة ',
            ),
            LyricWord(
              time: Duration(seconds: 18),
              end: Duration(seconds: 19),
              text: 'لما ',
            ),
            LyricWord(
              time: Duration(seconds: 19),
              end: Duration(seconds: 20),
              text: 'عرفت',
            ),
          ],
          romanization: 'kan andak kam sana lamma ereft',
          romanizationWords: [
            LyricWord(
              time: Duration(seconds: 10),
              end: Duration(seconds: 12),
              text: 'kan ',
            ),
            LyricWord(
              time: Duration(seconds: 12),
              end: Duration(seconds: 14),
              text: 'andak ',
            ),
            LyricWord(
              time: Duration(seconds: 14),
              end: Duration(seconds: 16),
              text: 'kam ',
            ),
            LyricWord(
              time: Duration(seconds: 16),
              end: Duration(seconds: 18),
              text: 'sana ',
            ),
            LyricWord(
              time: Duration(seconds: 18),
              end: Duration(seconds: 19),
              text: 'lamma ',
            ),
            LyricWord(
              time: Duration(seconds: 19),
              end: Duration(seconds: 20),
              text: 'ereft',
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(PlaybackState()),
          ),
        ],
        child: MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 320,
                height: 800,
                child: SyncedLyricsView(
                  lyrics: lyrics,
                  seekPreview: preview,
                  colorScheme: theme.colorScheme,
                  isActive: true,
                  showPronunciation: false,
                  showTranslation: false,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final text = find.text(arabicLine);
    expect(text, findsOneWidget);
    final inactiveHeight = tester
        .renderObject<RenderParagraph>(text)
        .size
        .height;

    preview.value = const Duration(seconds: 11);
    await tester.pumpAndSettle();
    final activePaint = find.descendant(
      of: find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == arabicLine,
      ),
      matching: find.byType(CustomPaint),
    );
    expect(tester.getSize(activePaint).height, closeTo(inactiveHeight, 0.01));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
