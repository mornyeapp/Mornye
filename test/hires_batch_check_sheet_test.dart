import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/hires_check_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/hires_batch_check_sheet.dart';
import 'package:mornye/widgets/hires_report_content.dart';

UnifiedLibraryItem _song(String name, {String extension = 'flac'}) =>
    UnifiedLibraryItem(
      id: name,
      trackName: name,
      artistName: 'Example Artist',
      albumName: 'Example Album',
      filePath: '/music/$name.$extension',
      addedAt: DateTime(2026),
      source: LibraryItemSource.local,
    );

HiResCheckResult _result({
  String grade = 'clean',
  int bitDepth = 16,
  int sampleRate = 44100,
  Map<String, dynamic> lossy = const {'status': 'not_found', 'score': 3.4},
}) => HiResCheckResult.fromJson({
  'supported': true,
  'verdict': 'standard_definition',
  'declared_sample_rate': sampleRate,
  'declared_bit_depth': bitDepth,
  'effective_bit_depth': bitDepth,
  'cutoff_frequency_hz': 21000.0,
  'total_duration_s': 185.2,
  'report': {
    'grade': grade,
    'integrity': {'status': 'verified', 'computed_md5': 'abc123'},
    'bit_depth': {'status': 'full', 'resolution_bits': bitDepth.toDouble()},
    'bandwidth': {'lowpass_class': 'none'},
    'lossy': lossy,
  },
});

void main() {
  test('only FLAC and WAV songs are offered to the check', () {
    final songs = [
      _song('one'),
      _song('two', extension: 'mp3'),
      _song('three', extension: 'wav'),
    ];

    expect(
      [for (final song in hiResCheckableItems(songs)) song.trackName],
      ['one', 'three'],
    );
  });

  testWidgets('songs are read one by one and summed up at the end', (
    tester,
  ) async {
    final pending = <String, Completer<HiResCheckResult>>{};
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: HiResBatchCheck(
            songs: [_song('First'), _song('Second'), _song('Third')],
            skipped: 1,
            check: (path) =>
                (pending[path] = Completer<HiResCheckResult>()).future,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Reading song 1 of 3'), findsOneWidget);
    expect(find.text('Reading the whole file'), findsOneWidget);
    expect(find.text('Waiting'), findsNWidgets(2));
    expect(pending.keys, ['/music/First.flac']);

    pending['/music/First.flac']!.complete(_result());
    await tester.pump();
    await tester.pump();
    expect(find.text('Reading song 2 of 3'), findsOneWidget);
    expect(find.text('No problems found'), findsOneWidget);

    pending['/music/Second.flac']!.complete(
      _result(
        grade: 'lossy',
        bitDepth: 24,
        sampleRate: 96000,
        lossy: const {
          'status': 'found',
          'family': 'mp3',
          'frame_samples': 576,
          'score': 30.0,
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    pending['/music/Third.flac']!.completeError(StateError('cannot open'));
    await tester.pump();
    await tester.pump();

    expect(find.text('1 of 2 songs needs a look.'), findsOneWidget);
    expect(find.text('1 song could not be read.'), findsOneWidget);
    expect(find.textContaining('1 song in another format'), findsOneWidget);
    expect(
      find.textContaining('16-bit/44.1kHz (1), 24-bit/96kHz (1)'),
      findsOneWidget,
    );
    expect(find.text('Made from a lossy file'), findsOneWidget);
    expect(find.textContaining('cannot open'), findsOneWidget);
    expect(find.text('Share report'), findsOneWidget);

    // A finished song opens its full report in place.
    expect(find.textContaining('frame pattern of MP3:'), findsNothing);
    await tester.tap(find.text('Second'));
    await tester.pump();
    expect(find.textContaining('frame pattern of MP3:'), findsOneWidget);
  });

  testWidgets('the shared text carries every section of the report', (
    tester,
  ) async {
    late AppLocalizations l10n;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            l10n = context.l10n;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final result = _result();

    final text = HiResReportContent.of(
      l10n,
      result,
      result.report!,
    ).text(name: 'Example Artist - First');

    expect(text, startsWith('Example Artist - First\nNo problems found\n'));
    expect(text, contains('\n\nIntegrity\nThe audio matches the checksum'));
    expect(text, contains('Checksum (MD5): abc123'));
    expect(text, contains('\n\nBit depth\nAll 16 bits carry audio.'));
    expect(text, contains('Pattern strength: 3.4 (found from 12)'));
    expect(text, endsWith('No analysis can certify the original master.'));
  });
}
