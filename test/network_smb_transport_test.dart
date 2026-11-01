import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_smb_client.dart';

void main() {
  test(
    'native negotiation offers SMB3 and never sends an SMB1 negotiate',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final received = Completer<List<int>>();
      final subscription = server.listen((socket) {
        final bytes = <int>[];
        socket.listen((chunk) {
          bytes.addAll(chunk);
          if (bytes.length < 4) return;
          final size = (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
          if (bytes.length < size + 4 || received.isCompleted) return;
          received.complete(bytes.sublist(4, size + 4));
          socket.destroy();
        });
      });
      try {
        final attempt = NetworkSmbClient.connect(
          Uri.parse('smb://127.0.0.1:${server.port}/MUSIC'),
          username: 'test',
          password: 'secret',
          domain: '',
          timeout: const Duration(seconds: 2),
        );
        final failure = expectLater(attempt, throwsA(isA<Exception>()));
        final packet = await received.future.timeout(
          const Duration(seconds: 5),
        );
        expect(packet.take(4), [0xfe, 0x53, 0x4d, 0x42]);
        final data = ByteData.sublistView(Uint8List.fromList(packet));
        final count = data.getUint16(66, Endian.little);
        final dialects = [
          for (var i = 0; i < count; i++)
            data.getUint16(100 + 2 * i, Endian.little),
        ];
        expect(dialects, containsAll([0x0202, 0x0210, 0x0300, 0x0302, 0x0311]));
        await failure;
      } finally {
        await subscription.cancel();
        await server.close();
      }
    },
  );
}
