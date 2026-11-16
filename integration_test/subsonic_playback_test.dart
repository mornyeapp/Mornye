import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/network_library_scanner.dart';
import 'package:mornye/services/network_metadata_service.dart';
import 'package:mornye/services/network_storage_service.dart';

import '../test/support/subsonic_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Subsonic catalogue, metadata and native playback with seek', (
    tester,
  ) async {
    final wav = Uint8List(44 + 8000 * 2 * 5);
    final data = ByteData.sublistView(wav);
    wav.setRange(0, 4, 'RIFF'.codeUnits);
    data.setUint32(4, wav.length - 8, Endian.little);
    wav.setRange(8, 16, 'WAVEfmt '.codeUnits);
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, 8000, Endian.little);
    data.setUint32(28, 16000, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    wav.setRange(36, 40, 'data'.codeUnits);
    data.setUint32(40, wav.length - 44, Endian.little);
    final server = await SubsonicFixture.start();
    server.audio = wav;
    server.song.addAll({
      'suffix': 'wav',
      'contentType': 'audio/wav',
      'duration': 5,
      'size': wav.length,
    });
    final directory = await Directory.systemTemp.createTemp(
      'subsonic-playback-',
    );
    final storage = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
      ensureAccess: (_) async {},
    );
    final deck = const PlaybackDependencies().createDeck(
      'subsonic-integration',
    );
    try {
      await storage.save(server.connection());
      final scanner = NetworkLibraryScanner(
        storage: storage,
        supportDirectory: () async => directory,
        temporaryDirectory: () async => directory,
      );
      final scan = await scanner.scan(
        'network://fixture/',
        checkpoint: () async {},
        onProgress: (_, _, _) {},
      );
      expect(scan.expectedCount, 1);
      final row = (await scan.rows().toList()).single;
      final metadata = await NetworkMetadataService(
        storage: storage,
        cacheDirectory: () async => directory,
      ).read(row['filePath'] as String);
      expect(metadata['title'], 'A song');
      expect(metadata['cover_path'], isNotNull);
      expect(
        server.requests.where((uri) => uri.path.contains('/stream.')),
        isEmpty,
      );
      await deck.configureOutput();
      await deck.setVolume(0);
      await deck.setNetworkSource(
        await storage.resolve(row['filePath'] as String),
      );
      expect(await deck.getDuration(), const Duration(seconds: 5));
      await deck.resume();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(
        (await deck.getCurrentPosition())!.inMilliseconds,
        greaterThan(100),
      );
      await deck.seek(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(
        (await deck.getCurrentPosition())!.inMilliseconds,
        greaterThanOrEqualTo(1900),
      );
      expect(
        server.requests.where((uri) => uri.path.contains('/stream.')),
        isNotEmpty,
      );
      expect(
        server.requests
            .where((uri) => uri.path.contains('/stream.'))
            .every(
              (uri) =>
                  !uri.queryParameters.containsKey('format') &&
                  !uri.queryParameters.containsKey('maxBitRate'),
            ),
        isTrue,
      );
      expect(server.authorizations, everyElement(isNull));
    } finally {
      await deck.dispose();
      await storage.dispose();
      await server.close();
      await directory.delete(recursive: true);
    }
  });
}
