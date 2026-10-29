import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/audio_route_info.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/audio_info_sheet.dart';

const _route = MethodChannel('com.zarz.mornye/audio_route');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_route, null);
  });

  test('route info tolerates partial platform maps', () {
    final info = AudioRouteInfo.fromMap({
      'mixerSampleRate': 48000,
      'framesPerBuffer': 192,
      'device': {
        'type': 'usb',
        'sampleRates': [48000, 44100, 0],
        'mixer': {'sampleRate': 96000, 'bitPerfect': true},
      },
      'spatializer': {'available': false},
    });

    expect(info.bufferMs, 4);
    expect(info.device?.sampleRates, [48000, 44100]);
    expect(info.device?.mixerSampleRate, 96000);
    expect(info.device?.mixerBitPerfect, isTrue);
    expect(info.spatialAvailable, isFalse);
    expect(info.stream, isNull);
  });

  testWidgets('shows source, signal and resampling to the output device', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _route,
          (call) async => {
            'platform': 'android',
            'mixerSampleRate': 48000,
            'framesPerBuffer': 96,
            'device': {
              'type': 'usb',
              'name': 'Example DAC',
              // A leftover preference must not claim bit-perfect playback.
              'mixer': {'sampleRate': 48000, 'bitPerfect': true},
            },
          },
        );
    final metadata = PlayerMetadataController();
    addTearDown(metadata.dispose);
    await metadata.load(
      const MediaItem(
        id: 'track',
        title: 'Track',
        extras: {
          'source': 'https://example.com/track.flac',
          'format': 'flac',
          'bit_depth': 24,
          'sample_rate': 96000,
        },
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAudioInfoSheet(context, metadata: metadata),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Audio info'), findsOneWidget);
    expect(find.text('Hi-Res Lossless'), findsOneWidget);
    expect(find.text('96 kHz'), findsOneWidget);
    expect(find.text('Up to 48 kHz (Nyquist)'), findsOneWidget);
    expect(find.text('144 dB'), findsOneWidget);
    expect(find.text('No ReplayGain tags'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('96 kHz → 48 kHz'), 200);
    expect(find.text('96 kHz → 48 kHz'), findsOneWidget);
    expect(find.text('Yes, unaltered samples'), findsNothing);
    await tester.scrollUntilVisible(find.text('USB audio · Example DAC'), 200);
    await tester.scrollUntilVisible(find.text('2.0 ms · 96 frames'), 200);
    expect(find.text('2.0 ms · 96 frames'), findsOneWidget);
  });

  testWidgets('a song from a paired device shows where it plays from', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_route, (call) async => null);
    final metadata = PlayerMetadataController(
      readMetadata: (_) async => const {'format': 'flac', 'bit_depth': 16},
    );
    addTearDown(metadata.dispose);
    await metadata.load(
      const MediaItem(
        id: 'track',
        title: 'Track',
        extras: {'source': 'network://desk/Album/Song.flac'},
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAudioInfoSheet(
              context,
              metadata: metadata,
              linkSources: const {'desk': 'Studio Mac'},
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Studio Mac via Mornye Link'), findsOneWidget);
    expect(find.text('Network storage'), findsNothing);
  });

  for (final mornye in [false, true]) {
    testWidgets(
      'SAF ReplayGain is loaded on opening Audio info (Mornye=$mornye)',
      (tester) async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_route, (call) async => null);
        final tags = Completer<Map<String, dynamic>>();
        var reads = 0;
        final metadata = PlayerMetadataController(
          readMetadata: (path) {
            expect(path, 'content://library/Song.opus');
            reads++;
            return tags.future;
          },
        );
        addTearDown(metadata.dispose);
        await metadata.load(
          const MediaItem(
            id: 'song',
            title: 'Song',
            extras: {
              'source': 'content://library/Song.opus',
              'format': 'opus',
              'bitrate': 380,
            },
          ),
        );
        expect(reads, 0, reason: 'Now Playing keeps SAF tag reads on demand');

        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Builder(
                builder: (context) => TextButton(
                  onPressed: () =>
                      showAudioInfoSheet(context, metadata: metadata),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(reads, 1);
        expect(find.text('Reading tags...'), findsOneWidget);
        expect(find.text('No ReplayGain tags'), findsNothing);

        tags.complete({
          'format': 'opus',
          'bitrate': 380,
          'replaygain_track_gain': '5.00 dB',
          'replaygain_track_peak': '0.326353',
          'replaygain_album_gain': '5.00 dB',
          'replaygain_album_peak': '0.326353',
        });
        await tester.pumpAndSettle();
        expect(find.text('No ReplayGain tags'), findsNothing);
        expect(find.text('Reading tags...'), findsNothing);
        expect(find.text('+5.00 dB'), findsNWidgets(2));
        expect(find.textContaining('0.326353'), findsNWidgets(2));

        Navigator.of(tester.element(find.text('Audio info'))).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(reads, 1, reason: 'Reopening the sheet reuses the loaded tags');
        expect(find.text('+5.00 dB'), findsNWidgets(2));
      },
    );
  }

  testWidgets('late route replies cannot replace the latest track snapshot', (
    tester,
  ) async {
    final replies = <Completer<Map<String, dynamic>>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_route, (call) {
          final reply = Completer<Map<String, dynamic>>();
          replies.add(reply);
          return reply.future;
        });
    final metadata = PlayerMetadataController();
    addTearDown(metadata.dispose);
    Future<void> load(String id) => metadata.load(
      MediaItem(
        id: id,
        title: id,
        extras: {
          'source': 'https://example.test/$id.flac',
          'format': 'flac',
          'bit_depth': 24,
          'sample_rate': 96000,
        },
      ),
    );
    await load('a');
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAudioInfoSheet(context, metadata: metadata),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await load('b');
    await tester.pump();
    await load('a');
    await tester.pump();
    expect(replies, hasLength(3));
    replies.last.complete({
      'mixerSampleRate': 96000,
      'device': {'type': 'usb', 'name': 'Current DAC'},
    });
    await tester.pumpAndSettle();
    for (final reply in replies.take(2)) {
      reply.complete({
        'mixerSampleRate': 48000,
        'device': {'type': 'usb', 'name': 'Stale DAC'},
      });
    }
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('USB audio · Current DAC'), 200);
    expect(find.text('USB audio · Stale DAC'), findsNothing);
  });
}
