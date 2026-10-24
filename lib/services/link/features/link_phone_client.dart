import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// Mornye Link's phone features run in the Android and iOS builds, the
/// builds that are not desktop. Host tests count as a phone unless they set
/// [debugDesktopPlatformOverride].
bool get isLinkPhonePlatform => !isDesktopPlatform;

/// The paired desktop's session on a phone, or null when none is paired or
/// this is the desktop app. Phone UI shows link actions only while it is set.
final linkPhoneClientProvider = Provider<LinkClientApi?>((ref) {
  final client = ref.watch(linkActiveClientProvider);
  return isLinkPhonePlatform ? client : null;
});

/// The connection state of [linkPhoneClientProvider]'s session.
final linkConnectionStateProvider =
    StreamProvider.autoDispose<LinkConnectionState>((ref) {
      final client = ref.watch(linkPhoneClientProvider);
      if (client == null) return Stream.value(LinkConnectionState.disconnected);
      return Stream<LinkConnectionState>.multi((listener) {
        listener.add(client.connectionState);
        final subscription = client.connectionStates.listen(
          listener.add,
          onError: listener.addError,
        );
        listener.onCancel = subscription.cancel;
      });
    });
