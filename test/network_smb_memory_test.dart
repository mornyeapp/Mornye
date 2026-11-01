import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_library_scanner.dart';
import 'package:mornye/services/network_smb_client.dart';
import 'package:mornye/services/network_storage_service.dart';

import 'support/vm_service_probe.dart';

Future<int> _smbWorkers(Uri service) async {
  final vm = await callTestVmService(service, 'getVM');
  return (vm['isolates'] as List)
      .where((isolate) => (isolate as Map)['name'] == 'dart_smb2 worker')
      .length;
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = (await developer.Service.getInfo()).serverUri;
  final address = Platform.environment['TEST_SMB_ADDRESS'];
  test(
    '12 native SMB scans share one worker and release handles and streams',
    () async {
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = overrides);
      final directory = await Directory.systemTemp.createTemp('smb-memory-');
      addTearDown(() => directory.delete(recursive: true));
      final storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
      );
      addTearDown(storage.dispose);
      await storage.save(
        NetworkConnection(
          id: 'fixture',
          name: 'SMB fixture',
          protocol: NetworkProtocol.smb,
          address: address!,
          username: 'test',
          password: 'secret',
        ),
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final scanner = NetworkLibraryScanner(
        storage: storage,
        supportDirectory: () async => directory,
        temporaryDirectory: () async => directory,
        readMetadata: (source) async {
          final url = await storage.resolve(source);
          final request = await client.getUrl(Uri.parse(url));
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-31');
          final response = await request.close();
          expect(response.statusCode, 206);
          final bytes = await response.fold<List<int>>(
            [],
            (bytes, chunk) => bytes..addAll(chunk),
          );
          expect(bytes, List.generate(32, (i) => i));
          return {'title': 'Fixture'};
        },
      );
      final workersBefore = await _smbWorkers(service!);
      final probe = await NetworkSmbClient.connect(
        Uri.parse(address),
        username: 'test',
        password: 'secret',
        domain: '',
        timeout: const Duration(seconds: 5),
      );
      try {
        expect(await _smbWorkers(service), greaterThan(workersBefore));
      } finally {
        await probe.close();
      }
      for (var run = 0; run < 12; run++) {
        final result = await scanner.scan(
          NetworkStorageService.source('fixture', ''),
          checkpoint: () async {},
          onProgress: (_, _, _) {},
        );
        expect(result.expectedCount, 1);
        expect(result.errorCount, 0);
        await result.delete();
        await collectTestGarbage(service);
        // The read session stays for the next scan instead of a worker per
        // listing and byte range.
        expect(await _smbWorkers(service), workersBefore + 1);
      }
      await storage.dispose();
      await collectTestGarbage(service);
      expect(await _smbWorkers(service), workersBefore);
      expect(
        await Directory('${directory.path}/network_scans').list().toList(),
        isEmpty,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: address == null || service == null
        ? 'Requires TEST_SMB_ADDRESS and --enable-vmservice'
        : false,
  );
}
