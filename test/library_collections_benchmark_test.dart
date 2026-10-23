import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/library_collections_benchmark.dart';

void main() {
  test(
    'paired large collection workers benchmark',
    () async {
      final report = {
        'platform': Platform.operatingSystem,
        'mode': 'flutter test host',
        'collection_hydration': await benchmarkCollectionHydration(),
        'playlist_search': await benchmarkPlaylistSearch(),
        'playlist_metadata_copy': await benchmarkPlaylistMetadataCopy(),
        'collection_json_export': await benchmarkCollectionJsonExport(),
      };
      const output = String.fromEnvironment('COLLECTIONS_BENCHMARK_OUTPUT');
      if (output.isNotEmpty) {
        final file = File(output);
        await file.parent.create(recursive: true);
        await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert(report),
        );
      }
      expect(report['collection_hydration'], isA<Map<String, dynamic>>());
    },
    skip: !const bool.fromEnvironment('RUN_COLLECTIONS_BENCHMARK'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
