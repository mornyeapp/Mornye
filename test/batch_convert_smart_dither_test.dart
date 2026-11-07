import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/audio_conversion_utils.dart';
import 'package:mornye/widgets/batch_convert_sheet.dart';

void main() {
  for (final mornye in [false, true]) {
    testWidgets('Smart is the default and None remains selectable ($mornye)', (
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
        final finder = find.text(label);
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      await tap('16-bit');
      expect(find.text('Smart'), findsOneWidget);
      expect(
        find.text('Automatically applies dither only when lowering bit depth.'),
        findsOneWidget,
      );
      await tap('Convert now');
      expect(selected?.normalizedDither, 'auto');
      expect(selected?.highPass, isFalse);
      await tap('None');
      expect(find.text('Use TPDF HP'), findsNothing);
      await tap('Convert now');
      expect(selected?.normalizedDither, 'none');
      await tap('Smart');
      await tap('Use TPDF HP');
      await tap('Convert now');
      expect(selected?.normalizedDither, 'auto');
      expect(selected?.highPass, isTrue);
      expect(
        selected
            ?.resolveDither(sourceBitDepth: 24, targetBitDepth: 16)
            .normalizedDither,
        'triangular_hp',
      );
      await tap('MP3');
      expect(find.text('Dithering'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
