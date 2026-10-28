import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/client/link_client_bonsoir.dart';
import 'package:mornye/services/link/client/link_client_discovery.dart';

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const channel = MethodChannel('fr.skyost.bonsoir');
  const codec = StandardMethodCodec();
  late String events;

  setUp(() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'discovery.initialize') {
        final id = (call.arguments as Map)['id'];
        events = 'fr.skyost.bonsoir.discovery.$id';
        messenger.setMockMethodCallHandler(
          MethodChannel(events),
          (_) async => null,
        );
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(MethodChannel(events), null);
  });

  Future<void> send(ByteData? message) async {
    ServicesBinding.instance.channelBuffers.push(events, message, (_) {});
    await pumpEventQueue();
  }

  for (final ended in [false, true]) {
    test(
      'a native browser that stops is recoverable (stream ended: $ended)',
      () async {
        final discovery = LinkDiscovery(
          createBrowser: BonsoirLinkServiceBrowser.new,
          ensureAccess: () async {},
          onChanged: () {},
        );
        addTearDown(discovery.stop);
        await discovery.start();
        expect(discovery.running, isTrue);
        await send(
          ended
              ? null
              : codec.encodeSuccessEnvelope({'id': 'discoveryStopped'}),
        );
        expect(discovery.status, LinkDiscoveryStatus.failed);
        await discovery.start();
        expect(discovery.running, isTrue);
      },
    );
  }

  test(
    'Bonjour permission denial is reported instead of automatically retried',
    () async {
      final discovery = LinkDiscovery(
        createBrowser: BonsoirLinkServiceBrowser.new,
        ensureAccess: () async {},
        onChanged: () {},
      );
      addTearDown(discovery.stop);
      await discovery.start();
      await send(
        codec.encodeErrorEnvelope(
          code: 'discoveryError',
          message: 'Local network denied',
          details: -65570,
        ),
      );
      expect(discovery.status, LinkDiscoveryStatus.permissionDenied);
    },
  );
}
