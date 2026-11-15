import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/hires_check_service.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/widgets/audio_analysis_widget.dart';
import 'package:mornye/widgets/hires_check_card.dart';

Uint8List _hiResWav() {
  const sampleRate = 96000;
  const channels = 2;
  const seconds = 5;
  const frameBytes = channels * 3;
  final bytes = ByteData(44 + sampleRate * seconds * frameBytes);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  bytes.setUint32(4, bytes.lengthInBytes - 8, Endian.little);
  text(8, 'WAVEfmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, channels, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * frameBytes, Endian.little);
  bytes.setUint16(32, frameBytes, Endian.little);
  bytes.setUint16(34, 24, Endian.little);
  text(36, 'data');
  bytes.setUint32(40, bytes.lengthInBytes - 44, Endian.little);
  for (var frame = 0; frame < sampleRate * seconds; frame++) {
    for (var channel = 0; channel < channels; channel++) {
      final value =
          (3000000 *
                  math.sin(
                    2 * math.pi * (1000 + 23000 * channel) * frame / sampleRate,
                  ))
              .round();
      final offset = 44 + frame * frameBytes + channel * 3;
      bytes.setUint8(offset, value & 255);
      bytes.setUint8(offset + 1, (value >> 8) & 255);
      bytes.setUint8(offset + 2, (value >> 16) & 255);
    }
  }
  return bytes.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const smbAddress = String.fromEnvironment('SMB_TEST_URL');
  testWidgets('network cards run real FFmpeg and Rust analysers', (
    tester,
  ) async {
    final local = await Directory.systemTemp.createTemp('network-reference-');
    var file = File('${local.path}/reference.wav');
    await file.writeAsBytes(_hiResWav());
    if (smbAddress.isEmpty) {
      final flac = File('${local.path}/reference.flac');
      final session = await FFmpegKit.executeWithArguments([
        '-i',
        file.path,
        '-c:a',
        'flac',
        flac.path,
      ]);
      expect(ReturnCode.isSuccess(await session.getReturnCode()), true);
      file = flac;
    }
    final audio = await file.readAsBytes();
    final reference = await HiResCheckService.check(file.path);
    final storage = NetworkStorageService.instance;
    final id = 'analysis-fixture-${DateTime.now().microsecondsSinceEpoch}';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var fullReads = 0;
    final requests = <({String method, String? authorization})>[];
    server.listen((request) async {
      requests.add((
        method: request.method,
        authorization: request.headers.value(HttpHeaders.authorizationHeader),
      ));
      request.response.contentLength = audio.length;
      if (request.method == 'GET') {
        fullReads++;
        request.response.add(audio);
      }
      await request.response.close();
    });
    try {
      await storage.save(
        NetworkConnection(
          id: id,
          name: 'Analysis fixture',
          protocol: smbAddress.isEmpty
              ? NetworkProtocol.webdav
              : NetworkProtocol.smb,
          address: smbAddress.isEmpty
              ? 'http://127.0.0.1:${server.port}/'
              : smbAddress,
          username: 'test',
          password: 'secret',
        ),
      );
      final source = NetworkStorageService.source(
        id,
        smbAddress.isEmpty ? 'Rock & Roll.flac' : 'A B.wav',
      );
      final remote = await HiResCheckService.check(source);
      expect(remote.supported, true);
      expect(remote.declaredSampleRate, reference.declaredSampleRate);
      expect(remote.declaredBitDepth, reference.declaredBitDepth);
      expect(remote.effectiveBitDepth, reference.effectiveBitDepth);
      expect(remote.cutoffFrequencyHz, reference.cutoffFrequencyHz);
      expect(remote.verdict, reference.verdict);
      fullReads = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  HiResCheckCard(filePath: source),
                  AudioAnalysisCard(filePath: source),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(fullReads, 0, reason: 'opening cards must not fetch audio');
      await tester.tap(find.text('Check'));
      for (
        var i = 0;
        i < 300 && find.text('96.0 kHz').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('96.0 kHz'), findsOneWidget);
      if (smbAddress.isEmpty) expect(fullReads, 1);
      await tester.ensureVisible(find.byType(AudioAnalysisCard));
      await tester.tap(find.text('Audio Quality Analysis'));
      for (var i = 0; i < 600 && find.text('24-bit').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('24-bit'), findsOneWidget);
      expect(find.text('96.0 kHz'), findsNWidgets(2));
      expect(find.text('Dynamic Range: '), findsOneWidget);
      expect(find.text('Ch 1'), findsOneWidget);
      if (smbAddress.isEmpty) expect(fullReads, 2);
      await tester.ensureVisible(find.text('Ch 1'));
      await tester.tap(find.text('Ch 1'));
      await tester.pump();
      for (
        var i = 0;
        i < 600 && find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(LinearProgressIndicator), findsNothing);
      if (smbAddress.isEmpty) expect(fullReads, 3);
      expect(requests.every((r) => ['GET', 'HEAD'].contains(r.method)), true);
      expect(
        requests.every(
          (r) =>
              r.authorization ==
              'Basic ${base64Encode(utf8.encode('test:secret'))}',
        ),
        true,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: SingleChildScrollView(
              child: AudioAnalysisCard(filePath: source),
            ),
          ),
        ),
      );
      for (var i = 0; i < 300 && find.text('24-bit').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('24-bit'), findsOneWidget);
      expect(find.text('Ch 1'), findsOneWidget);
      if (smbAddress.isEmpty) {
        expect(fullReads, 3, reason: 'reopen uses cached analysis');
      }
      final temporary = await getTemporaryDirectory();
      expect(
        await temporary
            .list()
            .where(
              (entry) => entry.uri.pathSegments
                  .where((part) => part.isNotEmpty)
                  .last
                  .startsWith('network-analysis-'),
            )
            .toList(),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    } finally {
      await storage.remove(id);
      await server.close(force: true);
      await local.delete(recursive: true);
    }
  });
}
