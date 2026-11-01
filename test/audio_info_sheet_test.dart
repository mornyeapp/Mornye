import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/audio_route_info.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/audio_info_sheet.dart';

const _route = MethodChannel('com.zarz.mornye/audio_route');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    usbAudioStatus.value = const UsbAudioStatus();
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

  test('Android Bluetooth PCM properties do not report codec transport', () {
    for (final type in ['bluetooth', 'bluetooth_le', 'hearing_aid']) {
      final info = AudioRouteInfo.fromMap({
        'platform': 'android',
        'mixerSampleRate': 48000,
        'device': {
          'type': type,
          'sampleRates': [44100, 48000],
          'bitDepths': [16],
          'mixer': {'sampleRate': 96000, 'bitDepth': 24},
        },
      });
      expect(info.bluetoothFormatUnreported, isTrue, reason: type);
    }
    for (final (platform, type) in [
      ('android', 'usb'),
      ('android', 'speaker'),
      ('ios', 'bluetooth'),
    ]) {
      expect(
        AudioRouteInfo.fromMap({
          'platform': platform,
          'device': {'type': type},
        }).bluetoothFormatUnreported,
        isFalse,
      );
    }
  });

  for (final mornye in [false, true]) {
    testWidgets(
      'Bluetooth transport is separate from PCM defaults (Mornye=$mornye)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              _route,
              (call) async => {
                'platform': 'android',
                'mixerSampleRate': 48000,
                'framesPerBuffer': 256,
                'device': {
                  'type': 'bluetooth',
                  'name': 'Example earbuds',
                  'sampleRates': [44100, 48000],
                  'bitDepths': [16],
                  // A PCM preference is also not a measured codec format.
                  'mixer': {'sampleRate': 96000, 'bitDepth': 24},
                },
              },
            );
        final metadata = PlayerMetadataController();
        addTearDown(metadata.dispose);
        await metadata.load(
          const MediaItem(
            id: 'song',
            title: 'Song',
            extras: {
              'source': 'https://example.test/song.m4a',
              'format': 'm4a',
              'sample_rate': 44100,
              'bitrate': 333,
            },
          ),
        );
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
        await tester.scrollUntilVisible(
          find.text('Bluetooth codec format'),
          200,
        );
        expect(find.text('Not reported by Android'), findsNWidgets(2));
        expect(find.text('44.1 kHz → 48 kHz'), findsNothing);
        expect(find.text('44.1 kHz → 96 kHz'), findsNothing);
        expect(find.text('Output sample rate'), findsNothing);
        expect(find.text('Output format'), findsNothing);
        expect(find.text('System default sample rate'), findsOneWidget);
        expect(find.text('48 kHz'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('Android PCM formats'), 200);
        expect(find.text('Android PCM sample rates'), findsOneWidget);
        expect(find.text('44.1 kHz, 48 kHz'), findsOneWidget);
        expect(find.text('16-bit'), findsOneWidget);
        expect(find.text('24-bit'), findsNothing);
        expect(find.text('System default buffer'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('returning from settings refreshes the same track route', (
    tester,
  ) async {
    var bluetooth = true;
    var reads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_route, (call) async {
          reads++;
          return {
            'platform': 'android',
            'mixerSampleRate': 48000,
            'device': {
              'type': bluetooth ? 'bluetooth' : 'speaker',
              'name': bluetooth ? 'Example earbuds' : 'Example phone',
            },
          };
        });
    final metadata = PlayerMetadataController();
    addTearDown(metadata.dispose);
    await metadata.load(
      const MediaItem(
        id: 'song',
        title: 'Song',
        extras: {
          'source': 'https://example.test/song.m4a',
          'format': 'm4a',
          'sample_rate': 44100,
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
    expect(find.text('Bluetooth codec format'), findsOneWidget);
    final initialReads = reads;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    bluetooth = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(reads, initialReads + 1);
    expect(find.text('Bluetooth codec format'), findsNothing);
    expect(find.text('Phone speaker · Example phone'), findsOneWidget);
  });

  testWidgets('Android defaults do not claim DAC resampling', (tester) async {
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
    await tester.scrollUntilVisible(find.text('Resampling'), 200);
    expect(find.text('96 kHz → 48 kHz'), findsNothing);
    expect(find.text('Yes, unaltered samples'), findsNothing);
    await tester.scrollUntilVisible(find.text('USB audio · Example DAC'), 200);
    expect(find.text('System default sample rate'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('2.0 ms · 96 frames'), 200);
    expect(find.text('2.0 ms · 96 frames'), findsOneWidget);
  });

  for (final mornye in [false, true]) {
    testWidgets('USB changes refresh an open audio sheet (Mornye=$mornye)', (
      tester,
    ) async {
      var device = 'First DAC';
      var reads = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_route, (call) async {
            reads++;
            return {
              'platform': 'android',
              'device': {'type': 'usb', 'name': device},
            };
          });
      final metadata = PlayerMetadataController();
      addTearDown(metadata.dispose);
      await metadata.load(
        const MediaItem(
          id: 'track',
          title: 'Track',
          extras: {
            'source': 'https://example.test/track.flac',
            'format': 'flac',
          },
        ),
      );
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
      final before = reads;
      device = 'Second DAC';
      usbAudioStatus.value = const UsbAudioStatus(reason: 'route_changed');
      await tester.pumpAndSettle();
      expect(reads, greaterThan(before));
      await tester.scrollUntilVisible(find.text('USB audio · Second DAC'), 200);
      expect(find.text('USB audio · First DAC'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

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
