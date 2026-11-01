import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/link/client/link_client_controller.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// The Mornye Link devices behind network sources, by source id (the host
/// of a `network://` song): on a phone, its paired computers' connections;
/// on the desktop, the song sources of its paired phones. Such a source is
/// a whole Mornye on another device, not a plain file server.
final linkSourceNamesProvider = Provider<Map<String, String>>((ref) {
  if (isDesktopPlatform) {
    final devices = ref.watch(linkDesktopHostProvider.select((s) => s.devices));
    return {
      for (final device in devices)
        linkPhoneSourceId(device.deviceId): device.name,
    };
  }
  if (!ref.watch(linkClientSupportedProvider)) return const {};
  final servers = ref.watch(
    linkClientControllerProvider.select((s) => s.servers),
  );
  return {for (final server in servers) server.connectionId: server.name};
});

/// The Mornye Link device that serves the `network://` [source], if any.
String? linkSourceName(Map<String, String> names, String? source) {
  if (source == null || !source.startsWith('network://')) return null;
  return names[Uri.tryParse(source)?.host];
}
