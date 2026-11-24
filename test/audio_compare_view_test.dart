import 'dart:math' as math;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/audio_compare_dsp.dart';
import 'package:mornye/services/audio_compare_engine.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/audio_analysis_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _reference = AudioCompareFileInfo(
  name: 'Song.flac',
  codec: 'FLAC',
  sampleRate: 44100,
  bitsPerSample: 24,
  channels: 2,
  durationSeconds: 60,
);

/// A result whose residual sits [residualDb] below a steady reference, with
/// most of it above the band split when [high].
AudioCompareResult _result({
  double residualDb = -35,
  double correlation = 0.9994,
  bool high = true,
  AudioCompareFileInfo other = const AudioCompareFileInfo(
    name: 'Song.mp3',
    codec: 'MP3',
    sampleRate: 44100,
    bitsPerSample: 0,
    channels: 2,
    durationSeconds: 60.03,
  ),
}) {
  const count = 500;
  const frames = 5292;
  final windows = [
    for (var i = 0; i < count; i++)
      () {
        // A louder stretch in the middle, as lossy residuals vary.
        final db = residualDb + 8 * math.sin(i / count * math.pi);
        final residual = audioCompareDbToPower(db - 10);
        const reference = 0.1;
        return AudioCompareWindow(
          startSeconds: i * frames / 44100,
          frames: frames,
          residual: Float64List.fromList([residual, residual]),
          reference: Float64List.fromList([reference, reference]),
          residualHigh: Float64List.fromList([
            if (high) ...[residual * 0.9, residual * 0.9] else ...[0, 0],
          ]),
          referenceHigh: Float64List.fromList([reference / 20, reference / 20]),
        );
      }(),
  ];
  return AudioCompareResult(
    reference: _reference,
    other: other,
    sampleRate: 44100,
    channels: 2,
    offsetFrames: 1105,
    gain: 1.052,
    correlation: correlation,
    excerptResidualDb: residualDb,
    windows: windows,
    driftMs: 0,
  );
}

Widget _host(Widget child, {required bool mornye}) => ProviderScope(
  child: MaterialApp(
    theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  ),
);

ColorScheme _scheme(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(Scaffold))).colorScheme;

Color? _noticeColor(WidgetTester tester, String key) => tester
    .widget<AppContentCard>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(AppContentCard),
      ),
    )
    .color;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('$style: progress offers cancel', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(
        _host(
          AudioCompareView(
            stage: AudioCompareStage.measuring,
            onCancel: () => cancelled = true,
          ),
          mornye: mornye,
        ),
      );
      expect(find.text('Measuring the difference'), findsOneWidget);
      expect(find.text('Step 3 of 4'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('audio-compare-cancel')));
      expect(cancelled, isTrue);
    });

    testWidgets('$style: result reads out the timeline and seeks', (
      tester,
    ) async {
      final result = _result();
      addTearDown(result.dispose);
      double? seeked;
      await tester.pumpWidget(
        _host(
          AudioCompareView(result: result, onSeek: (s) => seeked = s),
          mornye: mornye,
        ),
      );
      expect(result.notices, isEmpty);
      expect(find.byKey(const ValueKey('audio-compare-notice')), findsNothing);
      expect(
        find.text(
          'The files share a source but differ clearly, as lossy encoding '
          'or a filter does.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Most of the difference is in the high frequencies.'),
        findsOneWidget,
      );
      expect(find.text('1105 samples (25.1 ms)'), findsOneWidget);
      expect(find.text('+0.44 dB'), findsOneWidget);
      expect(
        find.text('FLAC · 44.1 kHz · 24-bit · Stereo · 1:00'),
        findsOneWidget,
      );
      expect(find.text('Left'), findsWidgets);

      final timeline = find.byKey(const ValueKey('audio-compare-timeline'));
      final box = tester.getRect(timeline);
      await tester.tapAt(
        Offset(box.left + 40 + (box.width - 40) / 2, box.center.dy),
      );
      await tester.pump();
      final readout = tester.widget<Text>(
        find.byKey(const ValueKey('audio-compare-readout')),
      );
      expect(readout.data, startsWith('0:30'));
      expect(readout.data, endsWith('dB'));
      await tester.tap(find.byKey(const ValueKey('audio-compare-seek')));
      expect(seeked, closeTo(30, 0.2));

      // The explanation stays folded until asked for.
      final explain = find.byKey(const ValueKey('audio-compare-explain'));
      await tester.scrollUntilVisible(explain, 200);
      expect(find.textContaining('A null test lines up'), findsNothing);
      await tester.tap(explain);
      await tester.pumpAndSettle();
      expect(find.textContaining('A null test lines up'), findsOneWidget);
    });

    testWidgets('$style: fits a phone width', (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final result = _result();
      addTearDown(result.dispose);
      await tester.pumpWidget(
        _host(
          AudioCompareView(result: result, onSeek: (_) {}),
          mornye: mornye,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('audio-compare-timeline')));
      await tester.pump();
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -2000),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style: no seek when the reference is not playing', (
      tester,
    ) async {
      final result = _result();
      addTearDown(result.dispose);
      await tester.pumpWidget(
        _host(AudioCompareView(result: result), mornye: mornye),
      );
      await tester.tap(find.byKey(const ValueKey('audio-compare-timeline')));
      await tester.pump();
      expect(find.byKey(const ValueKey('audio-compare-seek')), findsNothing);
    });

    testWidgets('$style: unrelated files show the notice', (tester) async {
      final result = _result(
        residualDb: 0,
        correlation: 0.02,
        high: false,
        other: const AudioCompareFileInfo(
          name: 'Other.flac',
          codec: 'FLAC',
          sampleRate: 48000,
          bitsPerSample: 16,
          channels: 2,
          durationSeconds: 75,
        ),
      );
      addTearDown(result.dispose);
      await tester.pumpWidget(
        _host(AudioCompareView(result: result), mornye: mornye),
      );
      expect(
        result.notices,
        containsAll([
          AudioCompareNotice.weakAlignment,
          AudioCompareNotice.residualHigh,
          AudioCompareNotice.durationMismatch,
        ]),
      );
      expect(
        find.byKey(const ValueKey('audio-compare-notice')),
        findsOneWidget,
      );
      expect(find.text('This comparison may not mean much'), findsOneWidget);
      expect(
        find.textContaining('could not be lined up with confidence'),
        findsOneWidget,
      );
      expect(find.textContaining('The lengths differ by'), findsOneWidget);
      // A notice is a warning, not an error.
      expect(
        _noticeColor(tester, 'audio-compare-notice'),
        _scheme(tester).tertiaryContainer,
      );
      // The band reading is withheld when the comparison is not meaningful.
      expect(
        find.text('The difference is spread across the whole range.'),
        findsNothing,
      );
    });

    testWidgets('$style: a decode failure can be retried', (tester) async {
      var retried = false;
      await tester.pumpWidget(
        _host(
          AudioCompareView(
            error: const AudioCompareException(
              AudioCompareFailure.decodeFailed,
            ),
            onRetry: () => retried = true,
          ),
          mornye: mornye,
        ),
      );
      expect(find.byKey(const ValueKey('audio-compare-error')), findsOneWidget);
      expect(
        _noticeColor(tester, 'audio-compare-error'),
        _scheme(tester).errorContainer,
      );
      expect(
        find.text('One of the files could not be decoded.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Retry'));
      expect(retried, isTrue);
    });

    testWidgets('$style: an unsupported codec says which', (tester) async {
      await tester.pumpWidget(
        _host(
          const AudioCompareView(
            error: UnsupportedAudioAnalysisCodecException('AC-4'),
          ),
          mornye: mornye,
        ),
      );
      expect(find.text('Unsupported audio format: AC-4'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });
  }

  testWidgets('the residual spectrogram has no save button', (tester) async {
    final result = _result();
    addTearDown(result.dispose);
    result.spectrogram = await tester.runAsync(
      () => createTestImage(width: 16, height: 8),
    );
    await tester.pumpWidget(
      _host(AudioCompareView(result: result), mornye: false),
    );
    await tester.scrollUntilVisible(
      find.text('Spectrogram of the difference'),
      200,
    );
    expect(find.text('Spectrogram of the difference'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('audio-analysis-save-spectrogram')),
      findsNothing,
    );
  });

  test('the same file is recognised by path or by name and size', () {
    expect(
      isSameAudioCompareFile(
        referencePath: '/music/a/../a/Song.flac',
        referenceSize: 0,
        otherPath: '/music/a/Song.flac',
        otherName: 'Song.flac',
        otherSize: 10,
      ),
      isTrue,
    );
    expect(
      isSameAudioCompareFile(
        referencePath:
            'content://provider/document/primary%3AMusic%2FSong.flac',
        referenceSize: 1234,
        otherPath: '/cache/file_picker/Song.flac',
        otherName: 'Song.flac',
        otherSize: 1234,
      ),
      isTrue,
    );
    expect(
      isSameAudioCompareFile(
        referencePath: '/music/Song.flac',
        referenceSize: 1234,
        otherPath: '/music/Song (hi-res).flac',
        otherName: 'Song (hi-res).flac',
        otherSize: 1234,
      ),
      isFalse,
    );
    expect(
      isSameAudioCompareFile(
        referencePath: '/music/Song.flac',
        referenceSize: 1234,
        otherPath: '/other/Song.flac',
        otherName: 'Song.flac',
        otherSize: 999,
      ),
      isFalse,
    );
  });

  test('only the Android picker copy of this pick is deleted', () {
    const cache = '/data/user/0/app/cache';
    expect(
      isAudioComparePickerCopy(
        '$cache/file_picker/1762800000000/Song.mp3',
        cacheDir: cache,
      ),
      isTrue,
    );
    for (final path in [
      '$cache/file_picker/Song.mp3',
      '$cache/file_picker/latest/Song.mp3',
      '$cache/file_picker/1762800000000/sub/Song.mp3',
      '$cache/other/1762800000000/Song.mp3',
      '/storage/emulated/0/Music/Song.mp3',
      '$cache/file_picker/1762800000000/../../Song.mp3',
    ]) {
      expect(isAudioComparePickerCopy(path, cacheDir: cache), isFalse);
    }
  });
}
