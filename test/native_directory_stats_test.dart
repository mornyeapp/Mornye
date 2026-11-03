import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/backend/ffi_backend_transport.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/services/cache_maintenance_service.dart';
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/desktop_platform.dart';

import 'support/directory_stats_reference.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('directory-stats-');
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(paths, null);
    await root.delete(recursive: true);
  });

  test(
    'native statistics receive a path and link policy without reading Dart files',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'runNativeDataJob');
        final request = jsonDecode(
          (call.arguments as Map)['request_json'] as String,
        );
        expect(request, {
          'operation': 'directory_stats',
          'path': root.absolute.path,
          'follow_links': false,
        });
        calls++;
        return {'file_count': 12, 'total_size_bytes': 345};
      });
      final actual = await CacheMaintenanceService.scanDirectory(root);
      expect(actual.fileCount, 12);
      expect(actual.totalSizeBytes, 345);
      expect(calls, 1);
    },
  );

  test(
    'cover cache shares the native scan and retains link-following policy',
    () async {
      messenger.setMockMethodCallHandler(paths, (_) async => root.path);
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'runNativeDataJob');
        final request = jsonDecode(
          (call.arguments as Map)['request_json'] as String,
        );
        expect(request, {
          'operation': 'directory_stats',
          'path': '${root.absolute.path}/cover_cache',
          'follow_links': true,
        });
        return {'file_count': 2, 'total_size_bytes': 10};
      });
      final actual = await CoverCacheManager.getStats();
      expect(actual.fileCount, 2);
      expect(actual.totalSizeBytes, 10);
    },
  );

  test(
    'missing plugin uses isolated traversal with unchanged counts',
    () async {
      await createDirectoryStatsFixture(root, 100);
      for (final follow in [false, true]) {
        final expected = await scanDirectoryReference(
          root,
          followLinks: follow,
        );
        final actual = await CacheMaintenanceService.scanDirectory(
          root,
          followLinks: follow,
        );
        expect(actual.fileCount, expected.fileCount);
        expect(actual.totalSizeBytes, expected.totalSizeBytes);
      }
      final missing = await CacheMaintenanceService.scanDirectory(
        Directory('${root.path}/missing'),
      );
      expect(missing.fileCount, 0);
      expect(missing.totalSizeBytes, 0);
    },
  );

  test(
    'symlink policy and cycles match the original traversal',
    () async {
      await Directory('${root.path}/nested').create();
      await File('${root.path}/nested/file').writeAsString('123');
      await Link('${root.path}/alias').create('${root.path}/nested');
      await Link('${root.path}/file-link').create('${root.path}/nested/file');
      await Link('${root.path}/nested/cycle').create(root.path);
      await Link('${root.path}/dangling').create('${root.path}/absent');
      for (final follow in [false, true]) {
        final expected = await scanDirectoryReference(
          root,
          followLinks: follow,
        );
        final actual = await CacheMaintenanceService.scanDirectory(
          root,
          followLinks: follow,
        );
        expect(actual.fileCount, expected.fileCount);
        expect(actual.totalSizeBytes, expected.totalSizeBytes);
      }
    },
    skip: Platform.isWindows
        ? 'Creating symlinks requires Windows developer permissions'
        : false,
  );

  test(
    'native errors are not hidden by the Dart compatibility route',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'CANCELLED'),
      );
      await expectLater(
        CacheMaintenanceService.scanDirectory(root),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'CANCELLED',
          ),
        ),
      );
    },
  );

  for (final invalid in [
    <String, Object>{},
    {'file_count': -1, 'total_size_bytes': 0},
    {'file_count': 0, 'total_size_bytes': -1},
    {'file_count': 1.5, 'total_size_bytes': 1},
    {'file_count': 1, 'total_size_bytes': '1'},
  ]) {
    test('rejects malformed native statistics: $invalid', () async {
      messenger.setMockMethodCallHandler(channel, (_) async => invalid);
      await expectLater(
        CacheMaintenanceService.scanDirectory(root),
        throwsStateError,
      );
    });
  }

  final enabled =
      Platform.environment[desktopBackendLibraryEnvironmentKey]?.isNotEmpty ??
      false;
  group('actual native directory statistics', () {
    late Directory support;
    setUpAll(() async {
      support = await Directory.systemTemp.createTemp('mornye-stats-ffi-');
      debugDesktopPlatformOverride = true;
      RustFfiBackend.debugShared = RustFfiBackend(
        openTransport: FfiBackendTransport.open,
        loadConfig: () async => DesktopBackendConfig(
          appSupportDir: support.path,
          documentsDir: support.path,
          tempDir: support.path,
        ),
      );
    });
    tearDownAll(() async {
      RustFfiBackend.debugShared = null;
      debugDesktopPlatformOverride = null;
      await support.delete(recursive: true);
    });

    Future<void> checkParity(Directory directory) async {
      for (final follow in [false, true]) {
        final expected = await scanDirectoryReference(
          directory,
          followLinks: follow,
        );
        final raw = await PlatformBridge.runNativeDataJob({
          'operation': 'directory_stats',
          'path': directory.absolute.path,
          'follow_links': follow,
        });
        expect(raw, {
          'file_count': expected.fileCount,
          'total_size_bytes': expected.totalSizeBytes,
        });
        final actual = await CacheMaintenanceService.scanDirectory(
          directory,
          followLinks: follow,
        );
        expect(actual.fileCount, expected.fileCount);
        expect(actual.totalSizeBytes, expected.totalSizeBytes);
      }
    }

    test('nested and empty directories match the original Dart scan', () async {
      await checkParity(root);
      await createDirectoryStatsFixture(root, 100);
      await checkParity(root);
    });

    test('missing and regular-file roots retain zero statistics', () async {
      await checkParity(Directory('${root.path}/missing'));
      await File('${root.path}/file').writeAsString('123');
      await checkParity(Directory('${root.path}/file'));
    });

    test(
      'directory aliases cycles dangling links and root links preserve counts',
      () async {
        await Directory('${root.path}/contents/nested').create(recursive: true);
        final contents = Directory('${root.path}/contents');
        await File('${contents.path}/nested/file').writeAsString('123');
        await Link('${contents.path}/alias').create('${contents.path}/nested');
        await Link(
          '${contents.path}/file-link',
        ).create('${contents.path}/nested/file');
        await Link('${contents.path}/nested/cycle').create(contents.path);
        await Link(
          '${contents.path}/dangling',
        ).create('${contents.path}/absent');
        await Link('${root.path}/root-link').create(contents.path);
        final baseline = await scanDirectoryReference(
          contents,
          followLinks: true,
        );
        expect(baseline.fileCount, 8);
        expect(baseline.totalSizeBytes, 24);
        await checkParity(contents);
        await checkParity(Directory('${root.path}/root-link'));
      },
      skip: Platform.isWindows
          ? 'Creating symlinks requires Windows developer permissions'
          : false,
    );
  }, skip: !enabled);
}
