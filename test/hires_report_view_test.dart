import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/hires_check_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/hires_report_view.dart';

/// What the backend returns for a whole-file inspection.
Map<String, dynamic> _json({
  String grade = 'clean',
  String verdict = 'standard_definition',
  Map<String, dynamic> integrity = const {'status': 'verified'},
  Map<String, dynamic> bitDepth = const {
    'status': 'full',
    'resolution_bits': 16.0,
  },
  Map<String, dynamic> bandwidth = const {'lowpass_class': 'none'},
  Map<String, dynamic> lossy = const {'status': 'not_found', 'score': 3.4},
}) => {
  'supported': true,
  'verdict': verdict,
  'declared_sample_rate': 44100,
  'declared_bit_depth': 16,
  'effective_bit_depth': 16,
  'cutoff_frequency_hz': 21000.0,
  'total_duration_s': 185.2,
  'report': {
    'grade': grade,
    'integrity': integrity,
    'bit_depth': bitDepth,
    'bandwidth': bandwidth,
    'lossy': lossy,
    'spectrum': {
      'step_hz': 137.8,
      'db': [for (var i = 0; i < 160; i++) -i * 0.6],
    },
  },
};

Future<void> _pump(WidgetTester tester, Map<String, dynamic> json) async {
  final result = HiResCheckResult.fromJson(json);
  tester.view.physicalSize = const Size(400, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: HiResReportView(result: result, report: result.report!),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a clean file says what was checked and what cannot be seen', (
    tester,
  ) async {
    await _pump(tester, _json());

    expect(find.text('No problems found'), findsOneWidget);
    expect(
      find.text('The audio matches the checksum stored in the file.'),
      findsOneWidget,
    );
    expect(find.text('All 16 bits carry audio.'), findsOneWidget);
    expect(find.textContaining('does not rule out a lossy'), findsOneWidget);
    expect(find.text('3.4 (found from 12)'), findsOneWidget);
    expect(find.textContaining('Read all 3:05'), findsOneWidget);
  });

  testWidgets('a pattern is measured against the limit of its own kind', (
    tester,
  ) async {
    await _pump(
      tester,
      _json(
        grade: 'lossy',
        lossy: {
          'status': 'found',
          'family': 'mp3',
          'frame_samples': 576,
          'score': 97.3,
          'ratio': 16.8,
          'found_score': 15.0,
        },
      ),
    );

    expect(find.textContaining('frame pattern of MP3:'), findsOneWidget);
    expect(find.textContaining('one block every 576 samples'), findsOneWidget);
    expect(find.text('97.3 (found from 15)'), findsOneWidget);
  });

  testWidgets('a codec frame pattern names the codec and the outcome', (
    tester,
  ) async {
    await _pump(
      tester,
      _json(
        grade: 'lossy',
        bandwidth: {
          'lowpass_hz': 16200.0,
          'lowpass_drop_db': 41.3,
          'lowpass_class': 'low',
        },
        lossy: {
          'status': 'found',
          'family': 'aac',
          'frame_samples': 1024,
          'score': 104.5,
          'ratio': 9.8,
        },
      ),
    );

    expect(find.text('Made from a lossy file'), findsOneWidget);
    expect(find.textContaining('frame pattern of AAC:'), findsOneWidget);
    expect(find.textContaining('one block every 1024 samples'), findsOneWidget);
    expect(find.text('16.2 kHz, 41 dB drop'), findsOneWidget);
    expect(find.textContaining('near 128 kbps'), findsOneWidget);
  });

  testWidgets('damage and a 16-bit source in a 24-bit file are spelled out', (
    tester,
  ) async {
    await _pump(
      tester,
      _json(
        grade: 'corrupt',
        integrity: {
          'status': 'decode_error',
          'declared_frames': 8167320,
          'decoded_frames': 4410000,
        },
        bitDepth: {'status': 'near_16bit', 'resolution_bits': 16.0},
      )..['declared_bit_depth'] = 24,
    );

    expect(find.text('Damaged file'), findsOneWidget);
    expect(find.textContaining('Decoding stopped at 1:40'), findsOneWidget);
    expect(
      find.textContaining('a 16-bit source stored as 24-bit'),
      findsOneWidget,
    );
  });
}
