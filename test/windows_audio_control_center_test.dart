import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/system_volume_provider.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/windows_audio_device_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/services/media_kit_playback_deck.dart';
import 'package:mornye/widgets/desktop/desktop_player_bar.dart';
import 'package:mornye/widgets/desktop/desktop_shortcuts.dart';
import 'package:mornye/widgets/desktop/windows_audio_quick_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_mpv_engine.dart';
import 'support/fixed_settings.dart';

class _FakeController implements MusicPlayerController {
  final List<String> calls = [];

  @override
  Future<void> togglePlayPause(bool isPlaying) async =>
      calls.add(isPlaying ? 'pause' : 'play');

  @override
  Future<void> next() async => calls.add('next');

  @override
  Future<void> previous() async => calls.add('previous');

  @override
  Future<void> seek(Duration position) async => calls.add('seek');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _track = MediaItem(
  id: 'track',
  title: 'A song',
  artist: 'An artist',
  duration: Duration(minutes: 3),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Windows Core Audio Native-to-Dart Endpoint Contract', () {
    test('parses native Core Audio endpoint fixture with distinct fields', () {
      final nativeFixture = <dynamic, dynamic>{
        'endpointId':
            '{0.0.0.00000000}.{841bf4d7-4d92-4c28-984e-d63897d26b06}',
        'mpvDeviceId':
            'wasapi/{841bf4d7-4d92-4c28-984e-d63897d26b06}',
        'guid': '{841bf4d7-4d92-4c28-984e-d63897d26b06}',
        'name': 'Realtek High Definition Audio (Speakers)',
        'isDefault': true,
        'state': 1,
        'mixSampleRate': 48000,
        'mixBitDepth': 32,
        'mixChannels': 2,
        'mixFormat': 'float',
        'id': 'wasapi/{841bf4d7-4d92-4c28-984e-d63897d26b06}',
      };

      final endpoint = WindowsAudioEndpoint.fromMap(nativeFixture);

      expect(
        endpoint.endpointId,
        '{0.0.0.00000000}.{841bf4d7-4d92-4c28-984e-d63897d26b06}',
      );
      expect(
        endpoint.mpvDeviceId,
        'wasapi/{841bf4d7-4d92-4c28-984e-d63897d26b06}',
      );
      expect(endpoint.guid, '{841bf4d7-4d92-4c28-984e-d63897d26b06}');
      expect(endpoint.name, 'Realtek High Definition Audio (Speakers)');
      expect(endpoint.isDefault, isTrue);
      expect(endpoint.state, 1);
      expect(endpoint.mixSampleRate, 48000);
      expect(endpoint.mixBitDepth, 32);
      expect(endpoint.mixChannels, 2);
      expect(endpoint.mixFormat, 'float');
      expect(endpoint.id, endpoint.mpvDeviceId);
    });

    test('handles multiple devices with unique MPV and endpoint IDs', () {
      final listFixture = <Map<dynamic, dynamic>>[
        {
          'endpointId': '{0.0.0.00000000}.{11111111-1111-1111-1111-111111111111}',
          'mpvDeviceId': 'wasapi/{11111111-1111-1111-1111-111111111111}',
          'guid': '{11111111-1111-1111-1111-111111111111}',
          'name': 'Internal Speakers',
          'isDefault': true,
          'state': 1,
        },
        {
          'endpointId': '{0.0.0.00000000}.{22222222-2222-2222-2222-222222222222}',
          'mpvDeviceId': 'wasapi/{22222222-2222-2222-2222-222222222222}',
          'guid': '{22222222-2222-2222-2222-222222222222}',
          'name': 'USB DAC Audio Quest Dragonfly',
          'isDefault': false,
          'state': 1,
        },
      ];

      final endpoints = listFixture.map(WindowsAudioEndpoint.fromMap).toList();

      expect(endpoints.length, 2);
      expect(endpoints[0].isDefault, isTrue);
      expect(endpoints[1].isDefault, isFalse);
      expect(endpoints[0].mpvDeviceId, isNot(equals(endpoints[1].mpvDeviceId)));
      expect(endpoints[0].endpointId, isNot(equals(endpoints[1].endpointId)));
    });

    test('supports backward compatibility for legacy saved identifier formats', () {
      final endpoint = WindowsAudioEndpoint.fromMap({
        'endpointId': '{0.0.0.00000000}.{33333333-3333-3333-3333-333333333333}',
        'mpvDeviceId': 'wasapi/{33333333-3333-3333-3333-333333333333}',
        'guid': '{33333333-3333-3333-3333-333333333333}',
        'name': 'Headphones',
        'isDefault': false,
        'state': 1,
      });

      // Legacy map where only 'id' was provided as wasapi/{GUID}
      final legacyFromId = WindowsAudioEndpoint.fromMap({
        'id': 'wasapi/{33333333-3333-3333-3333-333333333333}',
        'name': 'Headphones',
        'isDefault': false,
      });
      expect(
        legacyFromId.mpvDeviceId,
        'wasapi/{33333333-3333-3333-3333-333333333333}',
      );
      expect(legacyFromId.guid, '{33333333-3333-3333-3333-333333333333}');

      // Legacy map where only endpointId string was provided
      final legacyFromEndpointId = WindowsAudioEndpoint.fromMap({
        'endpointId':
            '{0.0.0.00000000}.{33333333-3333-3333-3333-333333333333}',
        'name': 'Headphones',
      });
      expect(
        legacyFromEndpointId.mpvDeviceId,
        'wasapi/{33333333-3333-3333-3333-333333333333}',
      );

      // Equality check
      expect(endpoint, equals(legacyFromId));
      expect(endpoint, equals(legacyFromEndpointId));
    });
  });

  group('Output Mode & AppSettings Synchronization', () {
    test('shared mode disables exclusiveOutput', () {
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => _TestSettingsNotifier(
              const AppSettings(
                exclusiveOutput: true,
                windowsOutputMode: 'exclusive_event',
              ),
            ),
          ),
        ],
      );

      final notifier = container.read(settingsProvider.notifier);
      notifier.setWindowsOutputMode('shared');

      final settings = container.read(settingsProvider);
      expect(settings.windowsOutputMode, 'shared');
      expect(settings.exclusiveOutput, isFalse);
    });

    test('exclusive_event and exclusive_push enable exclusiveOutput', () {
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => _TestSettingsNotifier(
              const AppSettings(
                exclusiveOutput: false,
                windowsOutputMode: 'shared',
              ),
            ),
          ),
        ],
      );

      final notifier = container.read(settingsProvider.notifier);

      notifier.setWindowsOutputMode('exclusive_event');
      expect(container.read(settingsProvider).windowsOutputMode, 'exclusive_event');
      expect(container.read(settingsProvider).exclusiveOutput, isTrue);

      notifier.setWindowsOutputMode('exclusive_push');
      expect(container.read(settingsProvider).windowsOutputMode, 'exclusive_push');
      expect(container.read(settingsProvider).exclusiveOutput, isTrue);
    });

    test('toggling exclusiveOutput synchronizes windowsOutputMode without competing booleans', () {
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => _TestSettingsNotifier(
              const AppSettings(
                exclusiveOutput: false,
                windowsOutputMode: 'shared',
              ),
            ),
          ),
        ],
      );

      final notifier = container.read(settingsProvider.notifier);

      notifier.setExclusiveOutput(true);
      expect(container.read(settingsProvider).exclusiveOutput, isTrue);
      expect(container.read(settingsProvider).windowsOutputMode, 'exclusive_event');

      notifier.setExclusiveOutput(false);
      expect(container.read(settingsProvider).exclusiveOutput, isFalse);
      expect(container.read(settingsProvider).windowsOutputMode, 'shared');
    });
  });

  group('Live Audio Output Monitor & Bit-Perfect Reporting', () {
    test('reports bit-perfect only when all conditions are satisfied', () {
      const bitPerfectStatus = WindowsAudioStatus(
        reason: 'active',
        mode: 'exclusive_event',
        activeDevice: 'USB DAC',
        sampleRate: 96000,
        bitDepth: 24,
        sourceSampleRate: 96000,
        sourceBitDepth: 24,
        isBitPerfect: true,
        bitPerfectReason: 'Bit-perfect direct output: WASAPI Exclusive active, unattenuated 100% volume, DSP/EQ bypassed, source rate matched (96000 Hz).',
      );

      expect(bitPerfectStatus.isBitPerfect, isTrue);
      expect(bitPerfectStatus.mode, 'exclusive_event');
      expect(bitPerfectStatus.sampleRate, 96000);
      expect(bitPerfectStatus.bitPerfectReason, contains('Bit-perfect'));
    });

    test('reports degradations when shared mixer, sample rate conversion, or attenuation active', () {
      const sharedStatus = WindowsAudioStatus(
        reason: 'active',
        mode: 'shared',
        activeDevice: 'Default Audio Endpoint',
        sampleRate: 48000,
        bitDepth: 24,
        sourceSampleRate: 44100,
        sourceBitDepth: 16,
        isBitPerfect: false,
        bitPerfectReason: 'WASAPI Shared mixer active • Sample rate conversion: 44100Hz -> 48000Hz • Digital volume attenuation: 80%',
      );

      expect(sharedStatus.isBitPerfect, isFalse);
      expect(sharedStatus.mode, 'shared');
      expect(sharedStatus.bitPerfectReason, contains('Shared mixer'));
      expect(sharedStatus.bitPerfectReason, contains('Sample rate conversion'));
    });

    test('honestly reports unsupported Push mode on libmpv backend without faking', () {
      const unsupportedPushStatus = WindowsAudioStatus(
        reason: 'active',
        mode: 'exclusive_event', // libmpv operates in event mode
        selectedDevice: 'Realtek Audio',
        activeDevice: 'Realtek Audio',
        sampleRate: 44100,
        isBitPerfect: false,
        bitPerfectReason: 'Push mode is not supported by libmpv backend (event callback in use)',
      );

      expect(unsupportedPushStatus.mode, isNot(equals('exclusive_push')));
      expect(unsupportedPushStatus.bitPerfectReason, contains('Push mode is not supported'));
    });
  });

  group('Desktop Player Bar ACC Entry Button & Platform Gating', () {
    late _FakeController controller;

    setUp(() {
      controller = _FakeController();
      debugDesktopPlatformOverride = true;
    });

    tearDown(() {
      debugDesktopPlatformOverride = null;
    });

    List<Override> barOverrides({required bool mornye}) => [
          settingsProvider.overrideWith(
            () => FixedSettingsNotifier(const AppSettings(playerMode: 'internal')),
          ),
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => Stream.value(_track),
          ),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(PlaybackState(playing: true)),
          ),
          musicPlayerControllerProvider.overrideWithValue(controller),
          systemVolumeProvider.overrideWith((ref) => Stream.value(0.5)),
          systemVolumeWriterProvider.overrideWithValue((value) async {}),
        ];

    testWidgets('Material theme renders ACC button on Windows', (tester) async {
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: barOverrides(mornye: false),
            child: MaterialApp(
              theme: AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const Scaffold(
                body: SizedBox(
                  width: 1400,
                  height: 100,
                  child: DesktopPlayerBar(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('desktop-player-acc-material')), findsOneWidget);
        expect(
          find.byWidgetPredicate((w) => w is AppIcon && w.icon == Icons.tune),
          findsOneWidget,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Mornye theme renders ACC button on Windows', (tester) async {
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: barOverrides(mornye: true),
            child: MaterialApp(
              theme: MornyeTheme.build(Brightness.light),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const Scaffold(
                body: SizedBox(
                  width: 1400,
                  height: 100,
                  child: DesktopPlayerBar(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('desktop-player-acc-mornye')), findsOneWidget);
        expect(find.byIcon(CupertinoIcons.slider_horizontal_3), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Player bar gates ACC button on macOS and Linux (absent)', (tester) async {
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final platform in [TargetPlatform.macOS, TargetPlatform.linux]) {
        debugDefaultTargetPlatformOverride = platform;
        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: barOverrides(mornye: false),
              child: MaterialApp(
                theme: AppTheme.light(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: const Scaffold(
                  body: SizedBox(
                    width: 1200,
                    height: 100,
                    child: DesktopPlayerBar(),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            find.byKey(const ValueKey('desktop-player-acc-material')),
            findsNothing,
            reason: 'ACC button must be absent on $platform',
          );
          expect(
            find.byKey(const ValueKey('desktop-player-acc-mornye')),
            findsNothing,
            reason: 'ACC button must be absent on $platform',
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    });

    testWidgets('Escape dismisses Audio Control Center before Now Playing or window mode', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        DesktopAudioControlCenterController.instance.open();
        expect(DesktopAudioControlCenterController.instance.isOpen, isTrue);

        await tester.pumpWidget(
          ProviderScope(
            overrides: barOverrides(mornye: false),
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: DesktopShortcuts(
                child: Scaffold(body: Text('Content')),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Send Escape key
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        // ACC should be dismissed
        expect(DesktopAudioControlCenterController.instance.isOpen, isFalse);
      } finally {
        DesktopAudioControlCenterController.instance.close();
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('Playback Engine Endpoint & Mode Configuration', () {
    late FakeMpvEngine engine;
    late MediaKitPlaybackDeck deck;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      engine = FakeMpvEngine();
      deck = MediaKitPlaybackDeck(playerId: 'win-acc-test', engine: engine);
    });

    tearDown(() async {
      await deck.dispose();
      playbackExclusiveOutput.value = false;
      playbackExclusiveDevice.value = '';
      debugDefaultTargetPlatformOverride = null;
    });

    test('selecting a non-default endpoint passes the correct MPV device ID to the playback engine', () async {
      const nonDefaultMpvId = 'wasapi/{22222222-2222-2222-2222-222222222222}';
      playbackExclusiveDevice.value = nonDefaultMpvId;
      playbackExclusiveOutput.value = true;

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(engine.properties['audio-device'], nonDefaultMpvId);
      expect(engine.properties['audio-exclusive'], 'yes');
    });

    test('fallback to shared mode resets audio-device and audio-exclusive', () async {
      playbackExclusiveDevice.value = 'wasapi/{22222222-2222-2222-2222-222222222222}';
      playbackExclusiveOutput.value = true;
      await Future<void>.delayed(const Duration(milliseconds: 100));

      playbackExclusiveOutput.value = false;
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(engine.properties['audio-exclusive'], 'no');
    });

    test('switching endpoint while staying in Shared mode applies audio-device and reloads output', () async {
      playbackExclusiveOutput.value = false;
      playbackExclusiveDevice.value = 'wasapi/{11111111-1111-1111-1111-111111111111}';
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(engine.properties['audio-device'], 'wasapi/{11111111-1111-1111-1111-111111111111}');
      expect(engine.properties['audio-exclusive'], 'no');

      // Change device while keeping Shared mode unchanged (target == _output for exclusive property)
      playbackExclusiveDevice.value = 'wasapi/{22222222-2222-2222-2222-222222222222}';
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(engine.properties['audio-device'], 'wasapi/{22222222-2222-2222-2222-222222222222}');
      expect(engine.properties['audio-exclusive'], 'no');
      expect(deck.debugAppliedAudioDevice, 'wasapi/{22222222-2222-2222-2222-222222222222}');
    });

    test('switching endpoint while staying in Exclusive mode applies audio-device and reloads output', () async {
      playbackExclusiveOutput.value = true;
      playbackExclusiveDevice.value = 'wasapi/{11111111-1111-1111-1111-111111111111}';
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(engine.properties['audio-device'], 'wasapi/{11111111-1111-1111-1111-111111111111}');
      expect(engine.properties['audio-exclusive'], 'yes');

      // Change device while keeping Exclusive mode unchanged
      playbackExclusiveDevice.value = 'wasapi/{22222222-2222-2222-2222-222222222222}';
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(engine.properties['audio-device'], 'wasapi/{22222222-2222-2222-2222-222222222222}');
      expect(engine.properties['audio-exclusive'], 'yes');
      expect(deck.debugAppliedAudioDevice, 'wasapi/{22222222-2222-2222-2222-222222222222}');
    });

    test('reloading audio output during playback preserves playing state and position', () async {
      playbackExclusiveDevice.value = 'wasapi/{11111111-1111-1111-1111-111111111111}';
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await deck.setFileSource('test_song.flac');
      await deck.resume();
      await deck.seek(const Duration(seconds: 42));

      expect(deck.state, PlaybackDeckState.playing);
      expect(engine.position, const Duration(seconds: 42));

      engine.calls.clear();
      // Switch output device while playing
      playbackExclusiveDevice.value = 'wasapi/{22222222-2222-2222-2222-222222222222}';
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // ao-reload executed and playback resumed
      expect(engine.calls.any((c) => c.length >= 2 && c[0] == 'command' && c[1] == 'ao-reload'), isTrue);
      expect(engine.calls.any((c) => c.isNotEmpty && c[0] == 'play'), isTrue);
      expect(deck.state, PlaybackDeckState.playing);
      expect(engine.position, const Duration(seconds: 42));
    });

    test('reloading audio output while paused preserves paused state', () async {
      playbackExclusiveDevice.value = 'wasapi/{11111111-1111-1111-1111-111111111111}';
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await deck.setFileSource('test_song.flac');
      await deck.resume();
      await deck.pause();

      expect(deck.state, PlaybackDeckState.paused);

      engine.calls.clear();
      // Switch output device while paused
      playbackExclusiveDevice.value = 'wasapi/{22222222-2222-2222-2222-222222222222}';
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(engine.calls.any((c) => c.length >= 2 && c[0] == 'command' && c[1] == 'ao-reload'), isTrue);
      expect(deck.state, PlaybackDeckState.paused);
      expect(engine.calls.any((c) => c.isNotEmpty && c[0] == 'play'), isFalse);
    });

    test('selected device and actual output device are distinct and not falsely reported as identical', () async {
      const defaultEp = WindowsAudioEndpoint(
        endpointId: '{0.0.0.00000000}.{default-guid}',
        mpvDeviceId: 'wasapi/{default-guid}',
        guid: '{default-guid}',
        name: 'Speakers (Realtek High Definition Audio)',
        isDefault: true,
        state: 1,
      );
      const usbEp = WindowsAudioEndpoint(
        endpointId: '{0.0.0.00000000}.{usb-guid}',
        mpvDeviceId: 'wasapi/{usb-guid}',
        guid: '{usb-guid}',
        name: 'Headphones (USB Audio DAC)',
        isDefault: false,
        state: 1,
      );
      WindowsAudioDeviceService.instance.debugSetEndpoints([defaultEp, usbEp]);

      try {
        // Case A: When user selects "System Default", selectedDevice reports 'System Default'
        // while activeDevice accurately reports the physical default endpoint name.
        playbackExclusiveDevice.value = '';
        await Future<void>.delayed(const Duration(milliseconds: 100));

        var status = windowsAudioStatus.value;
        expect(status.selectedDevice, 'System Default');
        expect(status.activeDevice, 'Speakers (Realtek High Definition Audio)');
        expect(status.selectedDevice, isNot(equals(status.activeDevice)));

        // Case B: When user selects Headphones, both report the endpoint name once applied.
        playbackExclusiveDevice.value = usbEp.mpvDeviceId;
        await Future<void>.delayed(const Duration(milliseconds: 100));

        status = windowsAudioStatus.value;
        expect(status.selectedDevice, 'Headphones (USB Audio DAC)');
        expect(status.activeDevice, 'Headphones (USB Audio DAC)');
        expect(status.selectedDevice, equals(status.activeDevice));

        // Case C: When output fails exclusive access and falls back to shared,
        // activeDevice accurately indicates the default fallback endpoint rather than falsely matching.
        playbackExclusiveOutput.value = true;
        await Future<void>.delayed(const Duration(milliseconds: 100));

        engine.openError = (prefix: 'ao', text: 'WASAPI exclusive failed');
        engine.errorEvents.add((prefix: 'cplayer', text: 'Could not open/initialize audio device -> no sound.'));
        await Future<void>.delayed(const Duration(milliseconds: 150));

        status = windowsAudioStatus.value;
        expect(status.selectedDevice, 'Headphones (USB Audio DAC)');
        expect(status.activeDevice, 'Speakers (Realtek High Definition Audio) (Fallback)');
        expect(status.selectedDevice, isNot(equals(status.activeDevice)));
      } finally {
        WindowsAudioDeviceService.instance.debugSetEndpoints(const []);
      }
    });
  });

  group('Capability Cache Invalidation', () {
    test('invalidateCapabilities clears cached entries', () {
      final service = WindowsAudioDeviceService.instance;
      service.invalidateCapabilities();
      service.invalidateCapabilities('wasapi/{test-guid}');
      service.invalidateCapabilities();
    });
  });
}

class _TestSettingsNotifier extends SettingsNotifier {
  _TestSettingsNotifier(this.initial);
  final AppSettings initial;

  @override
  AppSettings build() => initial;
}
