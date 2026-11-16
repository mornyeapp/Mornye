import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/audio_conversion_utils.dart';
import 'package:mornye/widgets/batch_convert_sheet.dart';

void main() {
  for (final mornye in [false, true]) {
    testWidgets('the resampler quality moves by a tap or a drag ($mornye)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      LosslessConversionProcessing? selected;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.light) : ThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: BatchConvertSheet(
                formats: const ['FLAC', 'MP3'],
                title: 'Convert tracks',
                confirmLabel: 'Convert now',
                sourceBitDepth: 24,
                sourceSampleRate: 96000,
                onConvert:
                    (format, bitrate, quality, processing, keepOriginal) {
                      selected = processing;
                    },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> tap(String label) async {
        // "Original" leads both the bit depth and the sample rate choices;
        // the sample rate comes second.
        final finder = find.text(label).last;
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      final slider = find.byKey(const ValueKey('resampler-quality'));

      /// Taps the slider's track at [fraction] of its width.
      Future<void> tapTrack(double fraction) async {
        await tester.ensureVisible(slider);
        await tester.pumpAndSettle();
        final box = tester.getRect(slider);
        await tester.tapAt(
          Offset(box.left + box.width * fraction, box.center.dy),
        );
        await tester.pumpAndSettle();
      }

      Future<LosslessConversionProcessing> convert() async {
        await tap('Convert now');
        return selected!;
      }

      // The level only matters once the sample rate changes.
      expect(slider, findsNothing);
      await tap('44.1 kHz');
      expect(slider, findsOneWidget);
      expect(find.text('Quality'), findsOneWidget);

      // SWR starts at the library's own filter.
      expect(find.text('Medium'), findsOneWidget);
      expect(find.text('32-tap filter'), findsOneWidget);
      expect(losslessResamplerFilterOptions(await convert()), [
        'resampler=swr',
      ]);

      // A tap anywhere on the track jumps to the nearest level.
      await tapTrack(0.98);
      expect(find.text('Best'), findsOneWidget);
      expect(find.text('256-tap filter'), findsOneWidget);
      expect((await convert()).normalizedResamplerQuality, 'best');
      await tapTrack(0.5);
      expect(find.text('High'), findsOneWidget);
      expect(find.text('64-tap filter'), findsOneWidget);

      // Dragging the handle moves it too.
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      final box = tester.getRect(slider);
      await tester.dragFrom(
        Offset(box.center.dx, box.center.dy),
        Offset(-box.width, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('Fast'), findsOneWidget);
      expect(losslessResamplerFilterOptions(await convert()), [
        'resampler=swr',
        'filter_size=16',
      ]);

      // SoXR has its own levels and starts at the most it offers.
      await tap('SoXr');
      expect(find.text('Best'), findsOneWidget);
      expect(find.text('33-bit precision'), findsOneWidget);
      expect(losslessResamplerFilterOptions(await convert()), [
        'resampler=soxr',
        'precision=33',
        'cutoff=0.95',
        'cheby=1',
      ]);
      await tapTrack(0.66);
      expect(find.text('Very high'), findsOneWidget);
      expect(find.text('28-bit precision, SoX VHQ'), findsOneWidget);
      await tapTrack(0.34);
      expect(find.text('20-bit precision, SoX HQ'), findsOneWidget);
      expect(losslessResamplerFilterOptions(await convert()), [
        'resampler=soxr',
        'precision=20',
      ]);
      await tapTrack(0.02);
      expect(find.text('Medium'), findsOneWidget);
      expect(find.text('16-bit precision'), findsOneWidget);

      // Keeping the original rate needs no resampler, so the choice resets.
      await tap('Original');
      expect(slider, findsNothing);
      final original = await convert();
      expect(original.normalizedResampler, 'swr');
      expect(original.resamplerQuality, isNull);
      expect(tester.takeException(), isNull);
    });
  }
}
