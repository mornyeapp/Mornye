import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/autoplay_taste.dart';
import 'package:mornye/services/backend/ffi_backend_transport.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/services/cache_maintenance_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:path_provider/path_provider.dart';

import '../test/support/autoplay_taste_fixture.dart';
import '../test/support/directory_stats_reference.dart';

Future<Map<String, Object>> _compare<T>(
  Future<T> Function() baseline,
  Future<T> Function() native,
  void Function(T expected, T actual) verify,
) async {
  final expected = await baseline();
  verify(expected, await native());
  final samples = <Map<String, Object>>[];
  for (var pair = 0; pair < 3; pair++) {
    for (final useNative in pair.isEven ? [false, true] : [true, false]) {
      final clock = Stopwatch()..start();
      var lastTick = 0;
      var maxGap = 0;
      final heartbeat = Timer.periodic(const Duration(milliseconds: 10), (_) {
        final now = clock.elapsedMicroseconds;
        final gap = now - lastTick;
        if (gap > maxGap) maxGap = gap;
        lastTick = now;
      });
      late T result;
      try {
        result = await (useNative ? native() : baseline());
      } finally {
        clock.stop();
        heartbeat.cancel();
      }
      final tail = clock.elapsedMicroseconds - lastTick;
      if (tail > maxGap) maxGap = tail;
      verify(expected, result);
      samples.add({
        'pair': pair,
        'route': useNative ? 'native' : 'dart',
        'elapsed_ms': clock.elapsedMicroseconds / 1000,
        'heartbeat_max_gap_ms': maxGap / 1000,
      });
    }
  }
  return {'samples': samples, 'parity': true};
}

void _sameTaste(AutoplayTasteModel expected, AutoplayTasteModel actual) {
  expect(actual.tokens, expected.tokens);
  expect(actual.positives, expected.positives);
  expect(actual.through, expected.through);
  expect(actual.vectors.length, expected.vectors.length);
  var maxError = 0.0;
  for (var index = 0; index < actual.vectors.length; index++) {
    final error = (actual.vectors[index] - expected.vectors[index]).abs();
    if (error > maxError) maxError = error;
  }
  expect(maxError, lessThanOrEqualTo(1e-6));
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  Directory? desktopSupport;
  setUpAll(() async {
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      final root = await Directory.systemTemp.createTemp('backend-profile-');
      desktopSupport = root;
      RustFfiBackend.debugShared = RustFfiBackend(
        openTransport: FfiBackendTransport.open,
        loadConfig: () async => DesktopBackendConfig(
          appSupportDir: root.path,
          documentsDir: root.path,
          tempDir: root.path,
        ),
      );
    }
  });
  tearDownAll(() async {
    if (desktopSupport != null) {
      RustFfiBackend.debugShared = null;
      await desktopSupport!.delete(recursive: true);
    }
  });
  final results = <String, Object>{
    'platform': Platform.operatingSystem,
    'profile': kProfileMode,
    'measurement':
        'Full worker route, including DTO, bridge and hydration; '
        'one warmup then three alternating pairs. Fixtures excluded.',
  };
  binding.reportData = {'native_backend_followup': results};

  testWidgets('directory statistics native parity and full-route timings', (
    tester,
  ) async {
    final temporary = await getTemporaryDirectory();
    await temporary.create(recursive: true);
    final root = await temporary.createTemp('stats-');
    try {
      final missing = await PlatformBridge.runNativeDataJob({
        'operation': 'directory_stats',
        'path': '${root.path}/missing',
        'follow_links': false,
      });
      expect(missing, {'file_count': 0, 'total_size_bytes': 0});
      for (final count in [100, 5000]) {
        final directory = Directory('${root.path}/$count');
        await createDirectoryStatsFixture(directory, count);
        for (final follow in [false, true]) {
          results['stats_${count}_follow_$follow'] = await _compare(
            () => scanDirectoryReference(directory, followLinks: follow),
            () => CacheMaintenanceService.scanDirectory(
              directory,
              followLinks: follow,
            ),
            (expected, actual) {
              expect(actual.fileCount, expected.fileCount);
              expect(actual.totalSizeBytes, expected.totalSizeBytes);
            },
          );
        }
      }
    } finally {
      await root.delete(recursive: true);
    }
  });

  testWidgets('native taste training preserves model across full routes', (
    tester,
  ) async {
    final empty = await PlatformBridge.runNativeDataJob({
      'operation': 'train_autoplay_taste',
      'plays': <Object?>[],
    });
    expect(empty['tokens'], isEmpty);
    final edge = autoplayTasteEdgeFixture();
    _sameTaste(
      await trainAutoplayTasteDartInBackground(edge),
      await trainAutoplayTasteInBackground(edge),
    );
    for (final count in [500, 5000]) {
      final plays = autoplayTasteFixture(count);
      results['taste_$count'] = await _compare(
        () => trainAutoplayTasteDartInBackground(plays),
        () => trainAutoplayTasteInBackground(plays),
        _sameTaste,
      );
    }
  });
}
