import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/playback_settings_page.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/spatial_audio.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/settings_search_catalog.dart';
import 'package:mornye/widgets/settings_group.dart';

const _title = 'Spatial audio';
const _events = EventChannel('com.zarz.mornye/spatial_audio');

final _l10n = lookupAppLocalizations(const Locale('en'));

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// Answers a listen with [state], like the native stream does.
void _mockState(Map<String, Object?> state) {
  _messenger.setMockStreamHandler(
    _events,
    MockStreamHandler.inline(onListen: (_, events) => events.success(state)),
  );
  addTearDown(() => _messenger.setMockStreamHandler(_events, null));
}

Map<String, Object?> _android({
  bool available = true,
  bool enabled = true,
  bool headTracking = false,
  bool stereo = false,
  bool multichannel = false,
}) => {
  'platform': 'android',
  'sdk': 34,
  'spatializer': {
    'available': available,
    'enabled': enabled,
    'headTracking': headTracking,
    'stereo': stereo,
    'multichannel': multichannel,
  },
};

Future<ProviderContainer> _pumpPage(
  WidgetTester tester, {
  required bool mornye,
  AppSettings settings = const AppSettings(),
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [initialSettingsProvider.overrideWithValue(settings)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: mornye
            ? MornyeTheme.build(Brightness.dark, accent: MornyeAccent.blue)
            : AppTheme.light(),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const PlaybackSettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Finder get _row => find.byWidgetPredicate(
  (widget) => widget is SettingsSwitchItem && widget.title == _title,
);

Future<SettingsSwitchItem> _scrollToRow(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    _row,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  return tester.widget<SettingsSwitchItem>(_row);
}

void main() {
  tearDown(() {
    debugAndroidAudioSettingsOverride = null;
    debugAndroidTvOverride = null;
    debugSpatialAudioPlatformOverride = null;
    debugDesktopPlatformOverride = null;
    usbAudioStatus.value = const UsbAudioStatus();
  });

  test('the setting defaults to on and round-trips through JSON', () {
    expect(const AppSettings().spatialAudio, isTrue);
    expect(AppSettings.fromJson(const {}).spatialAudio, isTrue);
    final off = const AppSettings().copyWith(spatialAudio: false);
    expect(off.toJson()['spatialAudio'], isFalse);
    expect(AppSettings.fromJson(off.toJson()).spatialAudio, isFalse);
    expect(off.copyWith().spatialAudio, isFalse);
  });

  group('platform', () {
    test('mobile hosts are neither platform in tests', () {
      expect(spatialAudioPlatform, SpatialAudioPlatform.none);
    });

    for (final (platform, expected) in [
      (TargetPlatform.macOS, SpatialAudioPlatform.macos),
      (TargetPlatform.windows, SpatialAudioPlatform.none),
      (TargetPlatform.linux, SpatialAudioPlatform.none),
    ]) {
      test('desktop $platform is $expected', () {
        debugDesktopPlatformOverride = true;
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        expect(spatialAudioPlatform, expected);
      });
    }

    test('settings search lists it except on Windows, Linux and TV', () {
      bool listed({bool androidAudio = false}) => SettingsSearchCatalog(
        _l10n,
        androidAudio: androidAudio,
      ).playback.any((entry) => entry.title == _l10n.spatialAudio);
      expect(listed(androidAudio: true), isTrue);
      debugAndroidTvOverride = true;
      expect(listed(androidAudio: true), isFalse);
      debugAndroidTvOverride = null;
      expect(listed(), isFalse);
      debugSpatialAudioPlatformOverride = SpatialAudioPlatform.ios;
      expect(listed(), isTrue);
      debugSpatialAudioPlatformOverride = null;
      debugDesktopPlatformOverride = true;
      for (final (platform, shown) in [
        (TargetPlatform.macOS, true),
        (TargetPlatform.windows, false),
        (TargetPlatform.linux, false),
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(listed(), shown, reason: '$platform');
      }
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('state', () {
    test('reads the Android spatializer facts', () {
      final state = SpatialAudioState.fromMap(
        _android(headTracking: true, stereo: true, multichannel: true),
      );
      expect(state.platform, 'android');
      expect(state.available, isTrue);
      expect(state.enabled, isTrue);
      expect(state.headTracking, isTrue);
      expect(state.stereo, isTrue);
      expect(state.multichannel, isTrue);
    });

    test('an Android release without a spatializer has none', () {
      final state = SpatialAudioState.fromMap(const {
        'platform': 'android',
        'sdk': 31,
        'spatializer': null,
      });
      expect(state.available, isFalse);
      expect(
        spatialAudioStatus(
          enabled: true,
          platform: SpatialAudioPlatform.android,
          state: state,
        ),
        SpatialAudioStatus.unavailable,
      );
    });

    test('reads the iOS output port', () {
      final state = SpatialAudioState.fromMap(const {
        'platform': 'ios',
        'enabled': true,
      });
      expect(state.enabled, isTrue);
      expect(state.available, isNull);
    });
  });

  group('status', () {
    SpatialAudioStatus? android(
      Map<String, Object?> map, {
      bool enabled = true,
      UsbAudioStatus? usb,
    }) => spatialAudioStatus(
      enabled: enabled,
      platform: SpatialAudioPlatform.android,
      state: SpatialAudioState.fromMap(map),
      usb: usb,
    );

    test('Android maps the spatializer to what it does', () {
      expect(
        android(_android(available: false, stereo: true)),
        SpatialAudioStatus.unavailable,
      );
      expect(
        android(_android(enabled: false, stereo: true)),
        SpatialAudioStatus.systemOff,
      );
      expect(android(_android(stereo: true)), SpatialAudioStatus.stereo);
      expect(
        android(_android(stereo: true, headTracking: true)),
        SpatialAudioStatus.stereoHeadTracking,
      );
      expect(
        android(_android(multichannel: true, headTracking: true)),
        SpatialAudioStatus.multichannelOnly,
      );
      expect(android(_android()), SpatialAudioStatus.unavailable);
    });

    test('the direct Android outputs never reach the spatializer', () {
      final state = _android(stereo: true);
      expect(
        android(
          state,
          usb: const UsbAudioStatus(reason: 'active', driver: 'usb_direct'),
        ),
        SpatialAudioStatus.directUsb,
      );
      expect(
        android(state, usb: const UsbAudioStatus(reason: 'active')),
        SpatialAudioStatus.directUsb,
      );
      expect(
        android(
          state,
          usb: const UsbAudioStatus(
            reason: 'active',
            driver: 'aaudio_exclusive',
          ),
        ),
        SpatialAudioStatus.directAAudio,
      );
      // Only a playing direct path counts.
      expect(
        android(state, usb: const UsbAudioStatus(reason: 'unsupported')),
        SpatialAudioStatus.stereo,
      );
    });

    test('no status while the setting is off or nothing is known', () {
      expect(android(_android(stereo: true), enabled: false), isNull);
      expect(
        spatialAudioStatus(
          enabled: true,
          platform: SpatialAudioPlatform.android,
        ),
        isNull,
      );
      expect(
        spatialAudioStatus(enabled: true, platform: SpatialAudioPlatform.none),
        isNull,
      );
    });

    test('iOS follows the output port', () {
      SpatialAudioStatus? ios(bool? on) => spatialAudioStatus(
        enabled: true,
        platform: SpatialAudioPlatform.ios,
        state: SpatialAudioState(platform: 'ios', enabled: on),
      );
      expect(ios(true), SpatialAudioStatus.outputOn);
      expect(ios(false), SpatialAudioStatus.outputOff);
      expect(ios(null), isNull);
    });

    test('macOS names exclusive output only', () {
      SpatialAudioStatus? macos({required bool exclusive}) =>
          spatialAudioStatus(
            enabled: true,
            platform: SpatialAudioPlatform.macos,
            exclusiveOutput: exclusive,
          );
      expect(macos(exclusive: true), SpatialAudioStatus.exclusiveOutput);
      expect(macos(exclusive: false), isNull);
    });

    test('every status has its message', () {
      expect(
        {
          for (final status in SpatialAudioStatus.values)
            status: spatialAudioStatusLabel(_l10n, status),
        },
        {
          SpatialAudioStatus.directUsb: 'Not used with direct USB output.',
          SpatialAudioStatus.directAAudio:
              'Not used with AAudio exclusive output.',
          SpatialAudioStatus.exclusiveOutput: 'Not used with exclusive output.',
          SpatialAudioStatus.systemOff:
              'Spatial audio is off in system settings.',
          SpatialAudioStatus.unavailable:
              'Not available on this device or output.',
          SpatialAudioStatus.stereo: 'Stereo music is spatialized.',
          SpatialAudioStatus.stereoHeadTracking:
              'Stereo music is spatialized, with head tracking available.',
          SpatialAudioStatus.multichannelOnly:
              'Only multichannel songs (such as 5.1 or Dolby Atmos) are '
              'spatialized on this device.',
          SpatialAudioStatus.outputOn: 'Spatial audio is on for this output.',
          SpatialAudioStatus.outputOff:
              'Not available with this output, or turned off in Control '
              'Center.',
        },
      );
    });
  });

  for (final mornye in [false, true]) {
    testWidgets('Android shows the live status and turns it off ($mornye)', (
      tester,
    ) async {
      debugAndroidAudioSettingsOverride = true;
      _mockState(_android(stereo: true, headTracking: true));
      // The media3 engine applies the switch live, so no next-song note.
      final container = await _pumpPage(
        tester,
        mornye: mornye,
        settings: const AppSettings(media3Engine: true),
      );
      var item = await _scrollToRow(tester);
      expect(item.value, isTrue);
      expect(item.subtitle, startsWith(_l10n.spatialAudioDescription));
      expect(
        item.subtitle,
        endsWith('Stereo music is spatialized, with head tracking available.'),
      );
      expect(item.subtitle, isNot(contains(_l10n.spatialAudioNextSong)));

      usbAudioStatus.value = const UsbAudioStatus(
        reason: 'active',
        driver: 'usb_direct',
      );
      await tester.pump();
      item = tester.widget<SettingsSwitchItem>(_row);
      expect(item.subtitle, endsWith('Not used with direct USB output.'));

      await tester.tap(find.text(_title));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).spatialAudio, isFalse);
      item = tester.widget<SettingsSwitchItem>(_row);
      expect(item.value, isFalse);
      expect(item.subtitle, _l10n.spatialAudioDescription);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the old Android engine applies it from the next song', (
    tester,
  ) async {
    debugAndroidAudioSettingsOverride = true;
    _mockState(_android(enabled: false, stereo: true));
    await _pumpPage(
      tester,
      mornye: false,
      settings: const AppSettings(media3Engine: false),
    );
    final item = await _scrollToRow(tester);
    expect(item.enabled, isTrue);
    expect(
      item.subtitle,
      [
        _l10n.spatialAudioDescription,
        _l10n.spatialAudioNextSong,
        'Spatial audio is off in system settings.',
      ].join('\n\n'),
    );
  });

  testWidgets('Android TV has no row', (tester) async {
    debugAndroidAudioSettingsOverride = true;
    debugAndroidTvOverride = true;
    _mockState(_android(stereo: true));
    await _pumpPage(tester, mornye: false);
    // The direct USB row follows it in the Audio output group.
    await tester.scrollUntilVisible(
      find.text(_l10n.usbBitPerfect),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(_row, findsNothing);
  });

  testWidgets('a state change updates the status line', (tester) async {
    debugAndroidAudioSettingsOverride = true;
    MockStreamHandlerEventSink? sink;
    _messenger.setMockStreamHandler(
      _events,
      MockStreamHandler.inline(
        onListen: (_, events) {
          sink = events;
          events.success(_android(multichannel: true));
        },
      ),
    );
    addTearDown(() => _messenger.setMockStreamHandler(_events, null));
    await _pumpPage(tester, mornye: false);
    var item = await _scrollToRow(tester);
    expect(item.subtitle, endsWith(_l10n.spatialAudioMultichannelOnly));
    sink!.success(_android(available: false));
    await tester.pumpAndSettle();
    item = tester.widget<SettingsSwitchItem>(_row);
    expect(item.subtitle, endsWith(_l10n.spatialAudioUnavailable));
  });

  for (final mornye in [false, true]) {
    testWidgets('iOS has its own Audio output group ($mornye)', (tester) async {
      debugSpatialAudioPlatformOverride = SpatialAudioPlatform.ios;
      _mockState(const {'platform': 'ios', 'enabled': false});
      await _pumpPage(tester, mornye: mornye);
      final item = await _scrollToRow(tester);
      expect(item.value, isTrue);
      expect(item.subtitle, endsWith(_l10n.spatialAudioOutputOff));
      expect(find.text(_l10n.newPlaybackEngine), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'macOS names exclusive output in the desktop group',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      debugDesktopPlatformOverride = true;
      await _pumpPage(
        tester,
        mornye: false,
        settings: const AppSettings(exclusiveOutput: true),
      );
      final item = await _scrollToRow(tester);
      expect(item.subtitle, endsWith('Not used with exclusive output.'));
      expect(item.showDivider, isFalse);
    },
  );

  testWidgets(
    'Windows and Linux have no spatial audio row',
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
    (tester) async {
      debugDesktopPlatformOverride = true;
      await _pumpPage(tester, mornye: false);
      for (var i = 0; i < 10; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
        await tester.pumpAndSettle();
        expect(_row, findsNothing);
      }
    },
  );
}
