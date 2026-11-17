import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart'
    show FlutterSecureStorage;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/services/backend/native_backend_transport.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_icon_finder.dart';
import 'support/tooltip_finder.dart';

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(isInitialized: true);
}

class _FolderPicker extends FilePickerPlatform {
  _FolderPicker(this.result);

  final String? result;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => result;
}

class _Transport implements NativeBackendTransport {
  _Transport(this.handler);
  final Future<Object?> Function(MethodCall) handler;
  late NativeMessageListener listener;

  @override
  void init(Uint8List configJson, NativeMessageListener listener) =>
      this.listener = listener;
  @override
  void call(int id, String method, Uint8List argsJson, Uint8List? bytes) {
    unawaited(() async {
      final result = await handler(
        MethodCall(method, jsonDecode(utf8.decode(argsJson))),
      );
      listener(id, NativeMessageKind.result, utf8.encode(jsonEncode(result)));
    }());
  }

  @override
  void subscribe(int kind) {}
  @override
  void unsubscribe(int kind) {}
}

Future<void> _settleIo(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  });
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const lyrics = '[00:01.00]Lyrics from the imported file';
  final cover = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  );

  for (final scenario in [
    for (final desktop in [false, true])
      for (final mornye in [false, true])
        (desktop: desktop, mornye: mornye, saf: false, cached: false),
    for (final mornye in [false, true])
      (desktop: false, mornye: mornye, saf: true, cached: false),
    (desktop: true, mornye: false, saf: false, cached: true),
  ]) {
    testWidgets('imported file exports JPG and LRC: $scenario', (tester) async {
      final (directory, source) = (await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'local-sidecars-',
        );
        final source = await File(
          '${directory.path}/Imported.flac',
        ).writeAsString('original audio');
        if (scenario.cached) {
          await File('${directory.path}/cached.jpg').writeAsBytes(cover);
        }
        return (directory, source);
      }))!;
      final audioPath = scenario.saf
          ? 'content://example.documents/tree/root/document/opaque-song'
          : source.path;
      final calls = <MethodCall>[];
      final staged = <String>[];
      const base = 'Fixture Artist - Fixture Song';
      Future<Object?> backend(MethodCall call) async {
        calls.add(call);
        final args = call.arguments is Map
            ? Map<Object?, Object?>.from(call.arguments as Map)
            : const <Object?, Object?>{};
        switch (call.method) {
          case 'acquireDownloadDirectory':
            return 'fixture-scope';
          case 'safStat':
            return {'exists': true, 'size': 100};
          case 'readAudioMetadata':
          case 'readFileMetadata':
            return {'format': 'flac', 'audio_codec': 'flac', 'hasLyrics': true};
          case 'getSafFileModTimes':
            return {};
          case 'getLyricsLRCWithSource':
            return {'lyrics': lyrics, 'source': 'embedded'};
          case 'extractCoverToFile':
            final output = args['output_path'] as String;
            if (!output.endsWith('$base.jpg') || scenario.cached) {
              return {'error': 'No embedded cover'};
            }
            expect(args['audio_path'], audioPath);
            await File(output).writeAsBytes(cover);
            return {'success': true};
          case 'fetchAndSaveLyrics':
            expect(args['audio_file_path'], audioPath);
            expect(args['spotify_id'], '');
            await File(args['output_path'] as String).writeAsString(lyrics);
            return {'success': true};
          case 'safWriteSidecarFromPath':
            expect(args['audio_uri'], audioPath);
            final input = args['src_path'] as String;
            staged.add(input);
            final name = args['file_name'] as String;
            await File(input).copy('${directory.path}/$name');
            return 'content://example.documents/document/$name';
          default:
            return null;
        }
      }

      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      debugDesktopPlatformOverride = scenario.desktop;
      const channel = MethodChannel('com.zarz.mornye/backend');
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, backend);
      messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
      if (scenario.desktop) {
        final transport = _Transport(backend);
        RustFfiBackend.debugShared = RustFfiBackend(
          openTransport: () => transport,
          loadConfig: () async => DesktopBackendConfig(
            appSupportDir: directory.path,
            documentsDir: directory.path,
            tempDir: directory.path,
          ),
        );
      }
      addTearDown(() async {
        debugDesktopPlatformOverride = null;
        RustFfiBackend.debugShared = null;
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(paths, null);
        await directory.delete(recursive: true);
      });
      tester.view.physicalSize = scenario.desktop
          ? const Size(1200, 900)
          : const Size(900, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [extensionProvider.overrideWith(_Extensions.new)],
          child: MaterialApp(
            theme: scenario.mornye
                ? MornyeTheme.build(Brightness.light)
                : AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: TrackMetadataScreen(
              localItem: LocalLibraryItem(
                id: 'imported-$scenario',
                trackName: 'Fixture Song',
                artistName: 'Fixture Artist',
                albumName: 'Fixture Album',
                filePath: audioPath,
                scannedAt: DateTime.utc(2026),
                format: 'flac',
                coverPath: scenario.cached
                    ? '${directory.path}/cached.jpg'
                    : null,
              ),
            ),
          ),
        ),
      );
      await _settleIo(tester);
      for (final (label, extension) in [
        ('Save Cover Art', 'jpg'),
        ('Save Lyrics (.lrc)', 'lrc'),
      ]) {
        await tester.tap(
          scenario.mornye
              ? findByTooltip('Show menu')
              : findAppIcon(Icons.more_vert),
        );
        await tester.pumpAndSettle();
        expect(find.text(label), findsOneWidget);
        // A long menu scrolls, and these rows start below its fold.
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await _settleIo(tester);
        expect(
          await tester.runAsync(
            () => File('${directory.path}/$base.$extension').exists(),
          ),
          isTrue,
        );
      }
      await tester.runAsync(() async {
        expect(await File('${directory.path}/$base.jpg').readAsBytes(), cover);
        expect(
          await File('${directory.path}/$base.lrc').readAsString(),
          lyrics,
        );
        expect(await source.readAsString(), 'original audio');
        for (final path in staged) {
          expect(await File(path).parent.exists(), isFalse);
        }
      });
      expect(
        calls.where((call) => call.method == 'downloadCoverToFile'),
        isEmpty,
      );
      if (scenario.saf) {
        expect(staged, hasLength(2));
        expect(
          calls.where((call) => call.method == 'safCreateFromPath'),
          isEmpty,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await _settleIo(tester);
    });
  }

  for (final scenario in const [
    (platform: TargetPlatform.android, picks: true),
    (platform: TargetPlatform.iOS, picks: true),
    (platform: TargetPlatform.macOS, picks: true),
    (platform: TargetPlatform.macOS, picks: false),
  ]) {
    testWidgets('a moved library song exports to a chosen folder: $scenario', (
      tester,
    ) async {
      final platform = scenario.platform;
      final (directory, chosen) = (await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'moved-sidecars-',
        );
        await File('${directory.path}/cached.jpg').writeAsBytes(cover);
        return (
          directory,
          await Directory('${directory.path}/chosen').create(),
        );
      }))!;
      final missing = '${directory.path}/old/Moved.flac';
      final calls = <MethodCall>[];
      const base = 'Fixture Artist - Fixture Song';
      Future<Object?> backend(MethodCall call) async {
        calls.add(call);
        final args = call.arguments is Map
            ? Map<Object?, Object?>.from(call.arguments as Map)
            : const <Object?, Object?>{};
        switch (call.method) {
          case 'pickSafTree':
            return {'tree_uri': 'content://example.documents/tree/chosen'};
          case 'pickIosDirectory':
            return {'path': chosen.path, 'bookmark': 'fixture-bookmark'};
          case 'startAccessingIosBookmark':
            expect(args['bookmark'], 'fixture-bookmark');
            return {'path': chosen.path, 'token': 'fixture-lease'};
          case 'fetchAndSaveLyrics':
            expect(args['audio_file_path'], '');
            await File(args['output_path'] as String).writeAsString(lyrics);
            return {'success': true};
          case 'safCreateFromPath':
            expect(args['tree_uri'], 'content://example.documents/tree/chosen');
            expect(args['relative_dir'], '');
            final name = args['file_name'] as String;
            await File(args['src_path'] as String).copy('${chosen.path}/$name');
            return 'content://example.documents/document/$name';
          default:
            return null;
        }
      }

      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final desktop = platform == TargetPlatform.macOS;
      debugDesktopPlatformOverride = desktop;
      debugDefaultTargetPlatformOverride = platform;
      final picker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = _FolderPicker(
        scenario.picks ? chosen.path : null,
      );
      const channel = MethodChannel('com.zarz.mornye/backend');
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, backend);
      messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
      if (desktop) {
        final transport = _Transport(backend);
        RustFfiBackend.debugShared = RustFfiBackend(
          openTransport: () => transport,
          loadConfig: () async => DesktopBackendConfig(
            appSupportDir: directory.path,
            documentsDir: directory.path,
            tempDir: directory.path,
          ),
        );
      }
      addTearDown(() async {
        debugDesktopPlatformOverride = null;
        FilePickerPlatform.instance = picker;
        RustFfiBackend.debugShared = null;
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(paths, null);
        await directory.delete(recursive: true);
      });
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [extensionProvider.overrideWith(_Extensions.new)],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: TrackMetadataScreen(
              localItem: LocalLibraryItem(
                id: 'moved-$scenario',
                trackName: 'Fixture Song',
                artistName: 'Fixture Artist',
                albumName: 'Fixture Album',
                filePath: missing,
                scannedAt: DateTime.utc(2026),
                format: 'flac',
                coverPath: '${directory.path}/cached.jpg',
              ),
            ),
          ),
        ),
      );
      await _settleIo(tester);
      for (final label in ['Save Cover Art', 'Save Lyrics (.lrc)']) {
        await tester.tap(findAppIcon(Icons.more_vert));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await _settleIo(tester);
      }
      await tester.runAsync(() async {
        final saved = await chosen.list().map((file) => file.path).toSet();
        expect(
          saved,
          scenario.picks
              ? {'${chosen.path}/$base.jpg', '${chosen.path}/$base.lrc'}
              : isEmpty,
        );
        if (!scenario.picks) return;
        expect(await File('${chosen.path}/$base.jpg').readAsBytes(), cover);
        expect(await File('${chosen.path}/$base.lrc').readAsString(), lyrics);
      });
      expect(await tester.runAsync(() => File(missing).exists()), isFalse);
      expect(
        calls.where((call) => call.method == 'fetchAndSaveLyrics'),
        hasLength(scenario.picks ? 1 : 0),
      );
      if (platform == TargetPlatform.iOS) {
        expect(
          calls.where((call) => call.method == 'stopAccessingIosBookmark'),
          hasLength(2),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await _settleIo(tester);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('a moved song with no saved cover offers lyrics only', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [extensionProvider.overrideWith(_Extensions.new)],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: TrackMetadataScreen(
            localItem: LocalLibraryItem(
              id: 'moved-no-cover',
              trackName: 'Fixture Song',
              artistName: 'Fixture Artist',
              albumName: 'Fixture Album',
              filePath: '/missing/Moved.flac',
              scannedAt: DateTime.utc(2026),
              format: 'flac',
            ),
          ),
        ),
      ),
    );
    await _settleIo(tester);
    await tester.tap(findAppIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Save Cover Art'), findsNothing);
    expect(find.text('Save Lyrics (.lrc)'), findsOneWidget);
  });
}
