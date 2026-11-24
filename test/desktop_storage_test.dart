import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/setup_screen.dart';
import 'package:mornye/services/sqlite_helpers.dart';
import 'package:mornye/utils/desktop_folders.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/native_platform_name.dart';

import 'support/tooltip_finder.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> ensureLoaded() async {}
}

class _DirectoryPicker extends FilePickerPlatform {
  _DirectoryPicker(this.result);

  final String? result;
  String? initialDirectory;
  int calls = 0;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    calls++;
    this.initialDirectory = initialDirectory;
    if (initialDirectory != null && !Directory(initialDirectory).existsSync()) {
      throw FileSystemException(
        'Initial folder does not exist',
        initialDirectory,
      );
    }
    return result;
  }
}

ProcessResult _process(int exitCode, String stdout) =>
    ProcessResult(0, exitCode, stdout, '');

void main() {
  tearDown(() {
    debugDesktopPlatformOverride = null;
    debugDesktopMusicDirectoryOverride = null;
  });

  group('desktop Music folder', () {
    test('macOS uses ~/Music', () async {
      expect(
        await resolveDesktopMusicDirectory(
          operatingSystem: 'macos',
          environment: {'HOME': '/Users/test'},
        ),
        '/Users/test/Music',
      );
    });

    test('Linux prefers xdg-user-dir MUSIC', () async {
      List<String>? command;
      final path = await resolveDesktopMusicDirectory(
        operatingSystem: 'linux',
        environment: {'HOME': '/home/test'},
        runProcess: (executable, arguments) async {
          command = [executable, ...arguments];
          return _process(0, '/home/test/Musik\n');
        },
      );
      expect(command, ['xdg-user-dir', 'MUSIC']);
      expect(path, '/home/test/Musik');
    });

    test('Linux falls back to ~/Music when xdg has no Music entry', () async {
      Future<String?> resolve(DesktopProcessRunner runProcess) =>
          resolveDesktopMusicDirectory(
            operatingSystem: 'linux',
            environment: {'HOME': '/home/test'},
            runProcess: runProcess,
          );

      // xdg-user-dir prints HOME for an unset entry.
      expect(
        await resolve((_, _) async => _process(0, '/home/test\n')),
        '/home/test/Music',
      );
      expect(
        await resolve((_, _) async => _process(1, '')),
        '/home/test/Music',
      );
      expect(
        await resolve((_, _) => throw const ProcessException('xdg', [])),
        '/home/test/Music',
      );
    });

    test('Windows uses the known folder, then %USERPROFILE%', () async {
      expect(
        await resolveDesktopMusicDirectory(
          operatingSystem: 'windows',
          environment: {'USERPROFILE': r'C:\Users\test'},
          windowsMusicFolder: () async => r'D:\Media\Music',
        ),
        r'D:\Media\Music',
      );
      expect(
        await resolveDesktopMusicDirectory(
          operatingSystem: 'windows',
          environment: {'USERPROFILE': r'C:\Users\test'},
          windowsMusicFolder: () async => throw StateError('no shell32'),
        ),
        r'C:\Users\test\Music',
      );
    });

    test('default output folder adds the Mornye subfolder', () async {
      expect(
        await resolveDesktopDefaultOutputDirectory(
          operatingSystem: 'windows',
          environment: const {},
          windowsMusicFolder: () async => r'C:\Users\test\Music',
        ),
        r'C:\Users\test\Music\Mornye',
      );
      expect(
        await resolveDesktopDefaultOutputDirectory(
          operatingSystem: 'macos',
          environment: {'HOME': '/Users/test'},
        ),
        '/Users/test/Music/Mornye',
      );
      expect(
        await resolveDesktopDefaultOutputDirectory(
          operatingSystem: 'linux',
          environment: const {},
          runProcess: (_, _) async => _process(1, ''),
        ),
        isNull,
      );
    });
  });

  group('desktop picker initial directory', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('desktop-picker-dir-');
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    test('keeps an existing selected directory', () async {
      final selected = await Directory(p.join(root.path, 'Albums')).create();
      expect(
        await resolveDesktopPickerInitialDirectory(selected.path),
        selected.path,
      );
    });

    test('uses the nearest existing parent without creating output', () async {
      final music = await Directory(p.join(root.path, 'Music')).create();
      final output = Directory(p.join(music.path, 'Mornye', 'Albums'));
      expect(
        await resolveDesktopPickerInitialDirectory(output.path),
        music.path,
      );
      expect(await Directory(p.join(music.path, 'Mornye')).exists(), isFalse);
    });

    test('uses the parent when the saved path is now a file', () async {
      final file = await File(p.join(root.path, 'Albums')).create();
      expect(await resolveDesktopPickerInitialDirectory(file.path), root.path);
    });

    test('handles an unset output and a missing Music directory', () async {
      debugDesktopMusicDirectoryOverride = p.join(root.path, 'Music');
      for (final preferred in [null, '']) {
        expect(
          await resolveDesktopPickerInitialDirectory(preferred),
          root.path,
        );
      }
    });

    test('leaves the native default when no Music path is available', () async {
      debugDesktopMusicDirectoryOverride = '';
      expect(await resolveDesktopPickerInitialDirectory(null), isNull);
    });

    test('does not pass a relative path to the native picker', () async {
      expect(
        await resolveDesktopPickerInitialDirectory('Music/Mornye'),
        isNull,
      );
    });
  });

  group('database directory', () {
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    late Directory root;
    late TestDefaultBinaryMessenger messenger;

    setUp(() async {
      messenger =
          TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
      root = await Directory.systemTemp.createTemp('desktop-db-dir-');
      messenger.setMockMethodCallHandler(paths, (call) async {
        return call.method == 'getApplicationSupportDirectory'
            ? '${root.path}/support'
            : '${root.path}/documents';
      });
    });

    tearDown(() async {
      messenger.setMockMethodCallHandler(paths, null);
      await root.delete(recursive: true);
    });

    test('mobile keeps databases in documents', () async {
      expect((await appDatabaseDirectory()).path, '${root.path}/documents');
    });

    test('desktop keeps databases in application support', () async {
      debugDesktopPlatformOverride = true;
      final directory = await appDatabaseDirectory();
      expect(directory.path, '${root.path}/support');
      expect(await directory.exists(), isTrue);
    });
  });

  group('native platform name', () {
    test('tests see the mobile default unless desktop is opted in', () {
      expect(isDesktopPlatform, isFalse);
      expect(nativePlatformName(), Platform.isAndroid ? 'android' : 'ios');
    });

    test('desktop reports its own OS, never ios', () {
      debugDesktopPlatformOverride = true;
      expect(nativePlatformName(), Platform.operatingSystem);
      expect(nativePlatformName(), isNot('ios'));
    });
  });

  group('desktop setup', () {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    late Directory root;
    const permissions = MethodChannel(
      'flutter.baseflow.com/permissions/methods',
    );
    var permissionCalls = 0;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('desktop-setup-dir-');
      await Directory(p.join(root.path, 'Music')).create();
      await Directory(p.join(root.path, 'Albums')).create();
      SharedPreferences.setMockInitialValues({});
      permissionCalls = 0;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(permissions, (
        _,
      ) async {
        permissionCalls++;
        return null;
      });
    });

    tearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        permissions,
        null,
      );
      await root.delete(recursive: true);
    });

    for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
      testWidgets('${platform.name} setup picks a folder before output exists', (
        tester,
      ) async {
        debugDesktopPlatformOverride = true;
        debugDefaultTargetPlatformOverride = platform;
        final music = p.join(root.path, 'Music');
        final output = Directory(p.join(music, desktopOutputFolderName));
        final selected = p.join(root.path, 'Albums');
        debugDesktopMusicDirectoryOverride = music;
        final picker = _DirectoryPicker(selected);
        final originalPicker = FilePickerPlatform.instance;
        FilePickerPlatform.instance = picker;
        addTearDown(() => FilePickerPlatform.instance = originalPicker);
        tester.view.physicalSize = const Size(1200, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [settingsProvider.overrideWith(_Settings.new)],
            child: const MaterialApp(
              locale: Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: SetupScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('1/3'), findsOneWidget);
        for (var step = 0; step < 2; step++) {
          await tester.tap(find.text('Next'));
          await tester.pumpAndSettle();
        }
        expect(find.text('3/3'), findsOneWidget);
        // The default output is selected but only created on setup completion.
        expect(find.text(output.path), findsOneWidget);
        expect(output.existsSync(), isFalse);

        await tester.tap(findByTooltip('Change folder'));
        for (var frame = 0; picker.calls == 0 && frame < 30; frame++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(picker.calls, 1);
        expect(picker.initialDirectory, music);
        expect(find.text(selected), findsOneWidget);
        expect(output.existsSync(), isFalse);
        expect(permissionCalls, 0);
        debugDefaultTargetPlatformOverride = null;
      });
    }
  });
}
