// These tests read production files across Dart, Kotlin and Swift by path and
// pin literal source text on purpose. When a refactor moves code, update the
// path or the assertion here in the same commit; never delete the check.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/utils/audio_format_utils.dart';

void main() {
  group('app state database migrations', () {
    final source = File(
      'lib/services/app_state_database.dart',
    ).readAsStringSync();

    test('current schema retains v4 playback queue and scalar state', () {
      expect(source, contains('const _dbVersion = 5;'));
      expect(source, contains('await _migratePlaybackSessionToV4(db);'));
      expect(source, contains('media_json TEXT NOT NULL'));
      expect(source, contains('position_ms INTEGER NOT NULL DEFAULT 0'));
      expect(source, contains('updatePlaybackSessionState'));
    });
  });

  group('iOS background download lifecycle', () {
    final appDelegateSource = File(
      'ios/Runner/AppDelegate.swift',
    ).readAsStringSync();
    final queueProviderSource = File(
      'lib/providers/download_queue_provider.dart',
    ).readAsStringSync();

    test('acquires background time before starting long-running work', () {
      final beginCase = RegExp(
        r'case "beginBackgroundDownloadTask":[\s\S]*?result\(nil\)',
      ).firstMatch(appDelegateSource);
      expect(beginCase, isNotNull);
      expect(
        beginCase!.group(0)!.indexOf('beginBackgroundDownloadTask()'),
        lessThan(beginCase.group(0)!.indexOf('result(nil)')),
      );
    });

    test('expiration safely defers and foreground resumes the queue', () {
      expect(appDelegateSource, contains('iosBackgroundDownloadExpired'));
      final expirationHandler = RegExp(
        r'if self\?\.downloadsActive == true \{[\s\S]*?\n\s*\}',
      ).firstMatch(appDelegateSource);
      expect(expirationHandler, isNotNull);
      expect(
        expirationHandler!.group(0)!,
        contains('self?.coreBackend.cancelActiveDownloads()'),
      );
      expect(
        expirationHandler
            .group(0)!
            .indexOf('self?.coreBackend.cancelActiveDownloads()'),
        lessThan(
          expirationHandler.group(0)!.indexOf('iosBackgroundDownloadExpired'),
        ),
      );
      expect(
        RegExp(
          r'pauseQueue\(\s*persistAcrossRestarts:\s*false,\s*'
          r'nativeCancelledItemIds:\s*cancelledItemIds,\s*\)',
        ).hasMatch(queueProviderSource),
        true,
      );
      expect(queueProviderSource, contains('_iosBackgroundExecutionExpired'));
      expect(queueProviderSource, contains('final requeueItemIds ='));
      expect(
        queueProviderSource,
        contains('if (!state.isProcessing && requeueItemIds.isEmpty) return;'),
      );
      expect(queueProviderSource, contains('if (alreadyForeground) {'));
      expect(
        queueProviderSource,
        contains('resumePendingDownloadsOnForeground();'),
      );
    });
  });

  group('native worker contracts', () {
    final finalizerSource = File(
      'android/app/src/main/kotlin/com/zarz/mornye/'
      'NativeDownloadFinalizer.kt',
    ).readAsStringSync();
    final finalizerHistorySource = File(
      'android/app/src/main/kotlin/com/zarz/mornye/'
      'NativeFinalizerHistory.kt',
    ).readAsStringSync();
    final historyStoreSource = File(
      'android/app/src/main/kotlin/com/zarz/mornye/'
      'NativeHistoryStore.kt',
    ).readAsStringSync();
    final historyDatabaseSource = File(
      'lib/services/history_schema.dart',
    ).readAsStringSync();
    final workerSnapshotSource = File(
      'android/app/src/main/kotlin/com/zarz/mornye/'
      'DownloadServiceSnapshot.kt',
    ).readAsStringSync();
    final nativeWorkerProviderSource = File(
      'lib/providers/download_queue_provider_native_worker.dart',
    ).readAsStringSync();

    int kotlinConstant(String name, String source) {
      final match = RegExp('const val $name = (\\d+)').firstMatch(source);
      expect(match, isNotNull, reason: 'Missing Kotlin constant $name');
      return int.parse(match!.group(1)!);
    }

    test('uses the same worker contract version in Dart and Kotlin', () {
      expect(
        kotlinConstant('NATIVE_WORKER_CONTRACT_VERSION', finalizerSource),
        DownloadRequestPayload.nativeWorkerContractVersion,
      );
    });

    test('uses the same history schema version in Dart and Kotlin', () {
      expect(
        kotlinConstant('HISTORY_SCHEMA_VERSION', historyStoreSource),
        HistoryDatabase.schemaVersion,
      );
    });

    test(
      'waits on one progress delta stream and preserves concurrent items',
      () {
        expect(
          RegExp(
            r'coreBackend\.openDownloadProgress\(',
          ).allMatches(workerSnapshotSource),
          hasLength(1),
        );
        expect(workerSnapshotSource, isNot(contains('Gobackend.')));
        expect(
          RegExp(
            r'\.waitDelta\(sinceSeq, 5_000L\)',
          ).allMatches(workerSnapshotSource),
          hasLength(1),
        );
        expect(workerSnapshotSource, contains('"item_deltas"'));
        expect(
          workerSnapshotSource,
          contains('progressItemIds = orderedItemIds'),
        );
        expect(workerSnapshotSource, contains('progressCoordinatorEpoch'));
        expect(
          workerSnapshotSource,
          contains('nativeWorkerProgressEpoch.get()'),
        );
        expect(nativeWorkerProviderSource, contains("snapshot['item_deltas']"));
      },
    );

    Map<String, String> historyTableDefinitions(String source) {
      final match = RegExp(
        r'CREATE TABLE(?: IF NOT EXISTS)? history\s*\(([\s\S]*?)\n\s*\)',
      ).firstMatch(source);
      expect(match, isNotNull, reason: 'Missing history CREATE TABLE');
      final definitions = <String, String>{};
      for (final definition in match!.group(1)!.split(',')) {
        final tokens = definition.trim().split(RegExp(r'\s+'));
        definitions[tokens.first] = tokens.skip(1).join(' ');
      }
      return definitions;
    }

    Map<String, String> historyIndexes(String source) {
      final indexes = <String, String>{};
      final pattern = RegExp(
        r'CREATE INDEX(?: IF NOT EXISTS)?\s+(\w+)\s+'
        r'ON history\s*\(([^)]+)\)',
      );
      for (final match in pattern.allMatches(source)) {
        indexes[match.group(1)!] = match
            .group(2)!
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
      }
      return indexes;
    }

    test('uses the same history columns in Dart and native writers', () {
      final dartDefinitions = historyTableDefinitions(historyDatabaseSource);
      final nativeBlock = RegExp(
        r'historyColumns\s*=\s*linkedMapOf\(([\s\S]*?)\n\s*\)',
      ).firstMatch(historyStoreSource);
      expect(nativeBlock, isNotNull, reason: 'Missing native history schema');
      final nativeDefinitions = {
        for (final match in RegExp(
          r'"([a-z0-9_]+)"\s+to\s+"([^"]+)"',
        ).allMatches(nativeBlock!.group(1)!))
          match.group(1)!: match.group(2)!,
      };
      expect(nativeDefinitions, dartDefinitions);

      final buildHistoryRow = RegExp(
        r'internal fun NativeDownloadFinalizer\.buildHistoryRow\('
        r'[\s\S]*?return values',
      ).firstMatch(finalizerHistorySource);
      expect(buildHistoryRow, isNotNull);
      final nativeWrittenColumns = RegExp(
        r'values\.put\("([a-z0-9_]+)"',
      ).allMatches(buildHistoryRow!.group(0)!).map((m) => m.group(1)!).toSet();
      expect(
        dartDefinitions.keys,
        containsAll(nativeWrittenColumns),
        reason: 'Native finalizer writes a column missing from Dart schema',
      );
    });

    test('uses the same history indexes in Dart and native writers', () {
      expect(
        historyIndexes(historyStoreSource),
        historyIndexes(historyDatabaseSource),
      );
    });

    test('matches shared Dart/native finalization quality cases', () {
      final fixture = File(
        'android/app/src/test/resources/finalization_quality_cases.tsv',
      ).readAsLinesSync();
      for (final line in fixture) {
        if (line.isEmpty || line.startsWith('#')) continue;
        final fields = line.split('\t');
        expect(fields, hasLength(6), reason: 'Invalid shared fixture: $line');
        final actual = buildQualityVariantFilenameLabel(
          detectedFormat: fields[0],
          bitDepth: int.tryParse(fields[1]),
          sampleRate: int.tryParse(fields[2]),
          bitrateKbps: int.tryParse(fields[3]),
          measuredQuality: fields[4],
        );
        final expected = fields[5] == '<null>' ? null : fields[5];
        expect(actual, expected, reason: 'Shared fixture: $line');
      }
    });
  });
}
