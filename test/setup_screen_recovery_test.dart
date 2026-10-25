import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/setup_screen.dart';
import 'package:mornye/utils/android_tv.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> ensureLoaded() async {}
}

const _backend = MethodChannel('com.zarz.mornye/backend');
const _device = MethodChannel('dev.fluttercommunity.plus/device_info');
const _permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
const _treeUri =
    'content://com.android.externalstorage.documents/tree/primary%3AMusic';
const _selection = '{"tree_uri":"$_treeUri","display_name":"Music"}';

Widget _setup() => ProviderScope(
  overrides: [settingsProvider.overrideWith(_Settings.new)],
  child: const MaterialApp(
    locale: Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: SetupScreen(),
  ),
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  late SharedPreferences prefs;
  late Completer<String?> picker;
  String? retainedSelection;
  var pickerCalls = 0;
  var permissionRequests = 0;
  var audioGranted = true;
  var notificationsGranted = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    retainedSelection = null;
    pickerCalls = permissionRequests = 0;
    audioGranted = notificationsGranted = true;
    messenger.setMockMethodCallHandler(
      _device,
      (_) async => {
        'version': {
          'sdkInt': 33,
          'release': '13',
          'codename': 'REL',
          'incremental': '1',
        },
        for (final key in [
          'board',
          'bootloader',
          'brand',
          'device',
          'display',
          'fingerprint',
          'hardware',
          'host',
          'id',
          'manufacturer',
          'model',
          'product',
          'tags',
          'type',
        ])
          key: 'test',
        'isPhysicalDevice': false,
        'time': 0,
        'isLowRamDevice': false,
        'freeDiskSize': 1000,
        'totalDiskSize': 2000,
        'physicalRamSize': 8000,
        'availableRamSize': 4000,
      },
    );
    messenger.setMockMethodCallHandler(_permissions, (call) async {
      if (call.method == 'checkPermissionStatus') {
        final granted = call.arguments == Permission.notification.value
            ? notificationsGranted
            : audioGranted;
        return granted
            ? PermissionStatus.granted.index
            : PermissionStatus.denied.index;
      }
      if (call.method == 'requestPermissions') permissionRequests++;
      throw StateError('Unexpected permission request: ${call.method}');
    });
    messenger.setMockMethodCallHandler(_backend, (call) async {
      switch (call.method) {
        case 'pickSafTree':
          picker = Completer<String?>();
          pickerCalls++;
          expect(call.arguments, {'for_setup': true});
          final draft =
              jsonDecode(prefs.getString('setup_progress_v1')!)
                  as Map<String, dynamic>;
          expect(draft['step'], 4);
          return picker.future;
        case 'readSetupFolderSelection':
          return retainedSelection;
        case 'acknowledgeSetupFolderSelection':
          expect((call.arguments as Map)['payload'], retainedSelection);
          if (retainedSelection == _selection) {
            // The native copy must not be removed before the Dart draft is safe.
            final draft =
                jsonDecode(prefs.getString('setup_progress_v1')!)
                    as Map<String, dynamic>;
            expect(draft['treeUri'], _treeUri);
          }
          retainedSelection = null;
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    for (final channel in [_device, _permissions, _backend]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  Future<void> openFolderStep(WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_setup());
    await tester.pumpAndSettle();
    expect(find.text('1/5'), findsOneWidget);
    for (var step = 0; step < 4; step++) {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }
    expect(find.text('5/5'), findsOneWidget);
  }

  testWidgets(
    'TV setup uses writable app storage without permission or picker',
    (tester) async {
      debugAndroidTvOverride = true;
      addTearDown(() => debugAndroidTvOverride = null);
      final directory = Directory.systemTemp.createTempSync('mornye-tv-setup-');
      addTearDown(() => directory.deleteSync(recursive: true));
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
      addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
      audioGranted = notificationsGranted = false;
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_setup());
      await tester.pumpAndSettle();
      expect(find.text('1/3'), findsOneWidget);
      for (var step = 0; step < 2; step++) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
      }
      expect(find.text('3/3'), findsOneWidget);
      expect(find.text('${directory.path}/Mornye'), findsOneWidget);
      expect(find.text('Get Started'), findsOneWidget);
      expect(permissionRequests, 0);
      expect(pickerCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('normal picker return saves folder without restarting setup', (
    tester,
  ) async {
    await openFolderStep(tester);
    await tester.tap(find.text('Select Folder'));
    await tester.pump();
    retainedSelection = _selection;
    picker.complete(_selection);
    await tester.pumpAndSettle();
    expect(find.text('5/5'), findsOneWidget);
    expect(find.text('Music'), findsOneWidget);
    expect(retainedSelection, isNull);
    expect(pickerCalls, 1);
    expect(permissionRequests, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'recreated setup recovers folder even when the old reply is lost',
    (tester) async {
      await openFolderStep(tester);
      await tester.tap(find.text('Select Folder'));
      await tester.pump();
      expect(pickerCalls, 1);
      await tester.pumpWidget(const SizedBox());
      retainedSelection = _selection;
      await tester.pumpWidget(_setup());
      await tester.pumpAndSettle();
      expect(find.text('5/5'), findsOneWidget);
      expect(find.text('Music'), findsOneWidget);
      expect(retainedSelection, isNull);
      expect(permissionRequests, 0);
      // A late reply must not call setState on the disposed setup screen.
      picker.complete(_selection);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Check the next cold start as well, after native acknowledgement.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_setup());
      await tester.pumpAndSettle();
      expect(find.text('5/5'), findsOneWidget);
      expect(find.text('Music'), findsOneWidget);
    },
  );

  testWidgets('result arriving after recreation is recovered by native event', (
    tester,
  ) async {
    await prefs.setString('setup_progress_v1', '{"step":4}');
    await tester.pumpWidget(_setup());
    await tester.pumpAndSettle();
    expect(find.text('5/5'), findsOneWidget);
    retainedSelection = _selection;
    await messenger.handlePlatformMessage(
      _backend.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('setupFolderSelectionChanged'),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(find.text('Music'), findsOneWidget);
    expect(retainedSelection, isNull);
  });

  testWidgets('cancelled result preserves step and permits a new selection', (
    tester,
  ) async {
    await prefs.setString('setup_progress_v1', '{"step":4}');
    retainedSelection = '{}';
    await tester.pumpWidget(_setup());
    await tester.pumpAndSettle();
    expect(find.text('5/5'), findsOneWidget);
    expect(find.text('Select Folder'), findsOneWidget);
    expect(retainedSelection, isNull);
    await tester.tap(find.text('Select Folder'));
    await tester.pump();
    expect(pickerCalls, 1);
    picker.complete(_selection);
    await tester.pumpAndSettle();
    expect(find.text('Music'), findsOneWidget);
  });

  testWidgets('resume rechecks granted permissions without requesting again', (
    tester,
  ) async {
    await prefs.setString('setup_progress_v1', '{"step":2}');
    audioGranted = false;
    await tester.pumpWidget(_setup());
    await tester.pumpAndSettle();
    expect(find.text('Grant Permission'), findsOneWidget);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    audioGranted = true;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Storage Permission Granted!'), findsOneWidget);
    expect(permissionRequests, 0);
    expect(find.text('3/5'), findsOneWidget);
  });

  testWidgets('skipping notifications survives reopening setup', (
    tester,
  ) async {
    await prefs.setString('setup_progress_v1', '{"step":3}');
    notificationsGranted = false;
    await tester.pumpWidget(_setup());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_setup());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('5/5'), findsOneWidget);
    expect(permissionRequests, 0);
  });
}
