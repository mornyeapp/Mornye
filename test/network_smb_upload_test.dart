import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_smb_client.dart';
import 'package:mornye/services/network_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test(
    'SMB uploads, reconciles retries and deletes only the selected file',
    () async {
      final storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
      );
      final temp = await Directory.systemTemp.createTemp('smb-upload-');
      addTearDown(() async {
        await storage.dispose();
        await temp.delete(recursive: true);
      });
      final c = NetworkConnection(
        id: 'nas',
        name: 'Test NAS',
        protocol: NetworkProtocol.smb,
        address:
            'smb://127.0.0.1:${Platform.environment['TEST_SMB_PORT'] ?? '1446'}/MUSIC/',
        username: 'test',
        password: 'secret',
      );
      await storage.save(c);
      final audio = await File(
        '${temp.path}/song.flac',
      ).writeAsBytes(List.generate(700000, (i) => i % 251));
      await storage.checkUploadAccess('network://nas/');
      final name = 'Song #${NetworkStorageService.newId()}.flac';
      final target = await storage.prepareUpload(
        'network://nas/',
        'Uploads/Album/',
        name,
      );
      var lastProgress = 0;
      await storage.publishUpload(
        target,
        audio,
        'smb-test',
        checkpoint: () {},
        progress: (sent, total) {
          expect(sent, greaterThanOrEqualTo(lastProgress));
          expect(sent, lessThanOrEqualTo(total));
          lastProgress = sent;
        },
      );
      expect(lastProgress, await audio.length());
      final verifier = await NetworkSmbClient.connect(
        networkTarget(c, Uri.parse(target).pathSegments.join('/')),
        username: c.username,
        password: c.password,
        domain: c.domain,
        timeout: NetworkStorageService.timeout,
      );
      try {
        expect(
          await verifier.matchesFile(
            audio,
            await audio.length(),
            checkpoint: () {},
          ),
          isTrue,
        );
        final corrupted = await File(
          '${temp.path}/corrupted.flac',
        ).writeAsBytes(List.generate(700000, (i) => (i + 1) % 251));
        expect(
          await verifier.matchesFile(
            corrupted,
            await audio.length(),
            checkpoint: () {},
          ),
          isFalse,
        );
        expect(
          await verifier.matchesFile(
            audio,
            await audio.length() + 1,
            checkpoint: () {},
          ),
          isFalse,
        );
        var checks = 0;
        await expectLater(
          verifier.matchesFile(
            audio,
            await audio.length(),
            checkpoint: () {
              if (++checks == 3) throw StateError('Verification cancelled');
            },
          ),
          throwsStateError,
        );
        expect(
          await verifier.matchesFile(
            audio,
            await audio.length(),
            checkpoint: () {},
          ),
          isTrue,
        );
      } finally {
        await verifier.close();
      }
      // Existing identical content is adopted without overwriting the file.
      await storage.publishUpload(
        target,
        audio,
        'smb-test',
        checkpoint: () {},
        progress: (_, _) {},
      );
      final uri = Uri.parse(target);
      final parent = uri.pathSegments
          .take(uri.pathSegments.length - 1)
          .join('/');
      final entries = await storage.list(c, '$parent/');
      expect(entries.map((e) => e.name).toList(), [name]);
      expect(entries.single.size, await audio.length());
      final collision = await storage.prepareUpload(
        'network://nas/',
        '$parent/',
        name,
      );
      expect(
        Uri.parse(collision).pathSegments.last,
        name.replaceFirst('.flac', ' (2).flac'),
      );
      // A path without a trailing slash still must not delete a directory.
      expect(await storage.deleteFile('network://nas/$parent'), isFalse);
      expect(await storage.deleteFile(target), isTrue);
      expect(await storage.list(c, '$parent/'), isEmpty);
      expect(await storage.deleteFile(target), isTrue);
    },
    skip: Platform.environment['TEST_SMB_UPLOAD'] != '1',
  );
}
